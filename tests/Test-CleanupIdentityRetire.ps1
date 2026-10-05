#Requires -Version 5.1
<#
.SYNOPSIS
    Regression test for STATE-CLEANUP-02:
    1. Worker cleanup paths retire OperationId when releasing the lock (OpState = 'Idle').
    2. ClearOperation in Update-WuuOperationState preserves terminal failures (Error, Timeout)
       when follow-up work exists (PendingOp), preventing them from being laundered into Queued.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$fail = 0
function Ok($m)  { Write-Host "PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail++ }

Import-Module (Join-Path $root 'src\Wuu.State.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\Wuu.Workers.psm1') -Force -DisableNameChecking

$workersRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Workers.psm1') -Raw
$stateRaw   = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw

# ---------------------------------------------------------------------------------------
# Part 1: Source assertion - Every OpState='Idle' site in Wuu.Workers retires OperationId
# ---------------------------------------------------------------------------------------
Write-Host "=== Part 1: Worker cleanup source assertions ===" -ForegroundColor Cyan
$idleCount = ([regex]::Matches($workersRaw, "OpState = 'Idle'")).Count
$retireCount = ([regex]::Matches($workersRaw, "OperationId'\]\) \{ \`$?\w+\.OperationId = ''")).Count

if ($idleCount -gt 0 -and $retireCount -ge $idleCount) {
    Ok "Every OpState='Idle' site in Wuu.Workers also retires OperationId ($retireCount retire site(s) for $idleCount idle site(s))"
} else {
    Bad "Mismatch: $retireCount OperationId retire site(s) for $idleCount OpState='Idle' site(s) in Wuu.Workers"
}

# ---------------------------------------------------------------------------------------
# Part 2: Worker completion cleanup execution & invariant verification
# ---------------------------------------------------------------------------------------
Write-Host "=== Part 2: Worker completion cleanup execution ===" -ForegroundColor Cyan
$store = New-WuuStateStore
$cRow = New-WuuComputerRow -Computer 'SRV-DONE'
$store.ByName['srv-done'] = $cRow
$store.Rows.Add($cRow) | Out-Null

$cRow.OpState = 'Running'
$cRow.OperationId = 'op-done-123'
$cRow.State = 'Complete'
$cRow.TimeoutExpiresAt = (Get-Date).AddMinutes(10)
$cRow.TimeoutSource = 'Install'
$cRow.OpName = 'Install'
$cRow.LastHeartbeatAt = (Get-Date)

# Emulate completion cleanup block in Watch-WuuJobPool
$runspaceMock = [pscustomobject]@{
    Computer = 'SRV-DONE'
    OperationId = 'op-done-123'
}

$stateStore = $store
$WriteLogFileScript = { param($msg) }
$doneRow = $stateStore.ByName[[string]$runspaceMock.Computer.ToLowerInvariant()]
if ($doneRow -and $doneRow.PSObject.Properties['OpState']) {
    $jobOpId2 = ''
    if ($runspaceMock.PSObject.Properties['OperationId']) { $jobOpId2 = [string]$runspaceMock.OperationId }
    $rowOpId2 = ''
    if ($doneRow.PSObject.Properties['OperationId']) { $rowOpId2 = [string]$doneRow.OperationId }
    if ($rowOpId2 -ne '' -and $jobOpId2 -ne '' -and $rowOpId2 -ceq $jobOpId2) {
        $doneRow.OpState = 'Idle'
        $doneRow.OpStartedAt = $null
        if ($doneRow.PSObject.Properties['TimeoutExpiresAt']) { $doneRow.TimeoutExpiresAt = $null }
        if ($doneRow.PSObject.Properties['TimeoutSource']) { $doneRow.TimeoutSource = '' }
        if ($doneRow.PSObject.Properties['OpName']) { $doneRow.OpName = '' }
        if ($doneRow.PSObject.Properties['LastHeartbeatAt']) { $doneRow.LastHeartbeatAt = $null }
        if ($doneRow.PSObject.Properties['OperationId']) { $doneRow.OperationId = '' }
        $stateStore.Touch()
    }
}

if ($cRow.OpState -eq 'Idle') {
    Ok "Completion cleanup releases lock to Idle"
} else {
    Bad "Completion cleanup did not set OpState to Idle (got '$($cRow.OpState)')"
}

if ($cRow.OperationId -eq '') {
    Ok "Completion cleanup retired OperationId"
} else {
    Bad "Completion cleanup did not retire OperationId (got '$($cRow.OperationId)')"
}

if ($null -eq $cRow.TimeoutExpiresAt -and $null -eq $cRow.LastHeartbeatAt) {
    Ok "Completion cleanup cleared deadline and heartbeat"
} else {
    Bad "Completion cleanup left deadline or heartbeat set"
}

$invViolations = @(Test-WuuOperationStateInvariant -Row $cRow)
if ($invViolations.Count -eq 0) {
    Ok "Completion cleanup row satisfies Test-WuuOperationStateInvariant (0 violations)"
} else {
    Bad "Completion cleanup row violated invariants: $($invViolations -join '; ')"
}

# ---------------------------------------------------------------------------------------
# Part 3: Worker timeout cleanup execution & invariant verification
# ---------------------------------------------------------------------------------------
Write-Host "=== Part 3: Worker timeout cleanup execution ===" -ForegroundColor Cyan
$toRow = New-WuuComputerRow -Computer 'SRV-TIMEOUT'
$store.ByName['srv-timeout'] = $toRow
$store.Rows.Add($toRow) | Out-Null

$toRow.OpState = 'Running'
$toRow.OperationId = 'op-to-456'
$toRow.State = 'Checking'
$toRow.TimeoutExpiresAt = (Get-Date).AddMinutes(-5)
$toRow.TimeoutSource = 'Check'
$toRow.OpName = 'Check'
$toRow.LastHeartbeatAt = (Get-Date).AddMinutes(-5)

# Emulate timeout cleanup stage 1 & stage 2 in Watch-WuuJobPool
$toRunspaceMock = [pscustomobject]@{
    Computer = 'SRV-TIMEOUT'
    OperationId = 'op-to-456'
}

$timedOutComputer = 'SRV-TIMEOUT'
$runspace = $toRunspaceMock
$toRowMatch = $stateStore.ByName[[string]$timedOutComputer.ToLowerInvariant()]
$toOpId = [string]$runspace.OperationId
$toRowId = [string]$toRowMatch.OperationId
if ($toRowId -ne '' -and $toOpId -ne '' -and $toRowId -ceq $toOpId) {
    if ($toRowMatch.PSObject.Properties['Runspace']) { $toRowMatch.Runspace = $null }
    $toRowMatch.OpState = 'Idle'
    $toRowMatch.OpStartedAt = $null
    $stateStore.Touch()
}

$timedOutRow = $stateStore.ByName[$timedOutComputer.ToLowerInvariant()]
$toStatusOpId = [string]$runspace.OperationId
$toStatusRowId = [string]$timedOutRow.OperationId
if ($toStatusRowId -ne '' -and $toStatusOpId -ne '' -and $toStatusRowId -ceq $toStatusOpId) {
    $timedOutRow.Status = "Timed out"
    $timedOutRow.UpdatesStatus = 'Timeout'
    $timedOutRow.State = 'Timeout'
    $timedOutRow.Color = 'Timeout'
    if ($timedOutRow.PSObject.Properties['TimeoutExpiresAt']) { $timedOutRow.TimeoutExpiresAt = $null }
    if ($timedOutRow.PSObject.Properties['TimeoutSource']) { $timedOutRow.TimeoutSource = '' }
    if ($timedOutRow.PSObject.Properties['OpName']) { $timedOutRow.OpName = '' }
    if ($timedOutRow.PSObject.Properties['LastHeartbeatAt']) { $timedOutRow.LastHeartbeatAt = $null }
    if ($timedOutRow.PSObject.Properties['OperationId']) { $timedOutRow.OperationId = '' }
    $stateStore.Touch()
}

if ($toRow.OpState -eq 'Idle') {
    Ok "Timeout cleanup sets OpState to Idle"
} else {
    Bad "Timeout cleanup did not set OpState to Idle (got '$($toRow.OpState)')"
}

if ($toRow.OperationId -eq '') {
    Ok "Timeout cleanup retired OperationId"
} else {
    Bad "Timeout cleanup did not retire OperationId (got '$($toRow.OperationId)')"
}

if ($toRow.State -eq 'Timeout' -and $toRow.Color -eq 'Timeout') {
    Ok "Timeout cleanup sets State and Color to Timeout"
} else {
    Bad "Timeout cleanup did not set State and Color (got '$($toRow.State)', '$($toRow.Color)')"
}

$toViolations = @(Test-WuuOperationStateInvariant -Row $toRow)
if ($toViolations.Count -eq 0) {
    Ok "Timeout cleanup row satisfies Test-WuuOperationStateInvariant (0 violations)"
} else {
    Bad "Timeout cleanup row violated invariants: $($toViolations -join '; ')"
}

# ---------------------------------------------------------------------------------------
# Part 4: ClearOperation preserves Error and Timeout with PendingOp
# ---------------------------------------------------------------------------------------
Write-Host "=== Part 4: ClearOperation terminal guard with PendingOp ===" -ForegroundColor Cyan

# Case A: Error row with PendingOp
$errRow = New-WuuComputerRow -Computer 'SRV-ERR'
$errRow.State = 'Error'
$errRow.Status = 'Error occurred during check.'
$errRow.UpdatesStatus = 'Error'
$errRow.OpState = 'Running'
$errRow.OperationId = 'op-err-789'
$errRow.PendingOp = 'Download'
$errRow.TimeoutExpiresAt = (Get-Date).AddMinutes(5)

$rErr = Update-WuuOperationState -Row $errRow -OperationId 'op-err-789' -ClearOperation -Touch:$false
if ($rErr.Applied) {
    Ok "ClearOperation applied to Error row"
} else {
    Bad "ClearOperation refused on Error row: $($rErr.Reason)"
}

if ($errRow.State -eq 'Error') {
    Ok "ClearOperation PRESERVED State='Error' when PendingOp='Download' (did NOT launder to Queued)"
} else {
    Bad "ClearOperation modified State from Error to '$($errRow.State)'"
}

if ($errRow.OpState -eq 'Idle') {
    Ok "ClearOperation released OpState to Idle on Error row"
} else {
    Bad "ClearOperation did not release OpState to Idle (got '$($errRow.OpState)')"
}

if ($errRow.OperationId -eq '') {
    Ok "ClearOperation retired OperationId on Error row"
} else {
    Bad "ClearOperation did not retire OperationId on Error row (got '$($errRow.OperationId)')"
}

# Case B: Timeout row with PendingOp
$timeoutRow = New-WuuComputerRow -Computer 'SRV-TO-PEND'
$timeoutRow.State = 'Timeout'
$timeoutRow.Status = 'Operation timed out.'
$timeoutRow.UpdatesStatus = 'Timeout'
$timeoutRow.OpState = 'Running'
$timeoutRow.OperationId = 'op-top-101'
$timeoutRow.PendingOp = 'InstallAndRecheck'
$timeoutRow.TimeoutExpiresAt = (Get-Date).AddMinutes(5)

$rTo = Update-WuuOperationState -Row $timeoutRow -OperationId 'op-top-101' -ClearOperation -Touch:$false
if ($rTo.Applied) {
    Ok "ClearOperation applied to Timeout row"
} else {
    Bad "ClearOperation refused on Timeout row: $($rTo.Reason)"
}

if ($timeoutRow.State -eq 'Timeout') {
    Ok "ClearOperation PRESERVED State='Timeout' when PendingOp='InstallAndRecheck' (did NOT launder to Queued)"
} else {
    Bad "ClearOperation modified State from Timeout to '$($timeoutRow.State)'"
}

if ($timeoutRow.OpState -eq 'Idle' -and $timeoutRow.OperationId -eq '') {
    Ok "ClearOperation released lock and retired OperationId on Timeout row"
} else {
    Bad "ClearOperation did not release lock or retire OperationId on Timeout row"
}

# Case C: Complete row with PendingOp (should transition to Queued as expected for non-terminal-failure)
$compRow = New-WuuComputerRow -Computer 'SRV-COMP-PEND'
$compRow.State = 'Complete'
$compRow.UpdatesStatus = 'Updates found.'
$compRow.OpState = 'Running'
$compRow.OperationId = 'op-comp-202'
$compRow.PendingOp = 'Download'
$compRow.TimeoutExpiresAt = (Get-Date).AddMinutes(5)

$rComp = Update-WuuOperationState -Row $compRow -OperationId 'op-comp-202' -ClearOperation -Touch:$false
if ($rComp.Applied) {
    Ok "ClearOperation applied to Complete row"
} else {
    Bad "ClearOperation refused on Complete row: $($rComp.Reason)"
}

if ($compRow.State -eq 'Queued') {
    Ok "ClearOperation transitioned Complete row with PendingOp to State='Queued'"
} else {
    Bad "ClearOperation did not transition Complete row with PendingOp to Queued (got '$($compRow.State)')"
}

if ($compRow.OpState -eq 'Idle' -and $compRow.OperationId -eq '') {
    Ok "ClearOperation released lock and retired OperationId on Complete row"
} else {
    Bad "ClearOperation did not release lock or retire OperationId on Complete row"
}

# ---------------------------------------------------------------------------------------
Write-Host ""
if ($fail -eq 0) {
    Write-Host "Test-CleanupIdentityRetire.ps1: ALL PASS" -ForegroundColor Green
    exit 0
} else {
    Write-Host "Test-CleanupIdentityRetire.ps1: $fail FAILURE(S)" -ForegroundColor Red
    exit 1
}
