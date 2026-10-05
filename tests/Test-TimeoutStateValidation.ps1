#Requires -Version 5.1
<#
.SYNOPSIS
    Regression test for STATE-TIMEOUT-01:
    1. Validate effective state before applying implicit Timeout derived from -Phase.
    2. Unattributed -Phase calls on terminal rows (Complete, Error) are refused and leave rows untouched.
    3. Setting -Phase on an Idle row is refused, preventing idle rows from carrying active deadlines.
    4. Attributed -Phase on running operations transitions correctly and satisfies all invariants.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$fail = 0
function Ok($m)  { Write-Host "PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail++ }

Import-Module (Join-Path $root 'src\Wuu.State.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force -DisableNameChecking

# Helper to capture row fingerprint
function Get-RowFingerprint($Row) {
    $parts = @()
    foreach ($p in $Row.PSObject.Properties) {
        $v = $p.Value
        if ($v -is [datetime]) { $v = $v.ToString('o') }
        $parts += ("{0}={1}" -f $p.Name, $v)
    }
    return ($parts -join '|')
}

# Helper to extract functions nested inside Start-WuuApplication in Wuu.Core.psm1
function Get-FunctionText([string]$Text, [string]$Name) {
    $lines = $Text -split "`r?`n"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*function\s+$([regex]::Escape($Name))\b") { $start = $i; break }
    }
    if ($start -lt 0) { return '' }
    $out = @()
    $depth = 0
    $seenBrace = $false
    for ($i = $start; $i -lt $lines.Count; $i++) {
        $out += $lines[$i]
        $depth += ([regex]::Matches($lines[$i], '\{')).Count
        $depth -= ([regex]::Matches($lines[$i], '\}')).Count
        if ($depth -gt 0) { $seenBrace = $true }
        if ($seenBrace -and $depth -le 0) { break }
    }
    return ($out -join "`n")
}

# ---------------------------------------------------------------------------------------
# Part 1: Unattributed -Phase on terminal 'Complete' row is refused
# ---------------------------------------------------------------------------------------
Write-Host "=== Part 1: Unattributed -Phase on terminal Complete row ===" -ForegroundColor Cyan
$compRow = New-WuuComputerRow -Computer 'SRV-COMP'
$compRow.State = 'Complete'
$compRow.Status = 'All updates installed.'
$compRow.UpdatesStatus = 'All updates installed.'
$compRow.Color = 'Complete'
$compRow.OpState = 'Idle'
$compRow.OperationId = ''
$beforeComp = Get-RowFingerprint $compRow

$r1 = Update-WuuOperationState -Row $compRow -Phase 'Update Search' -TimeoutSec 300 -Touch:$false
if (-not $r1.Applied -and $r1.Refused) {
    Ok "Unattributed -Phase on Complete row is refused"
} else {
    Bad "Unattributed -Phase on Complete row was applied (expected refusal)"
}

if ($r1.Reason -like "*settled row ('Complete') may not move to 'Timeout'*") {
    Ok "Refusal reason names settled transition restriction: $($r1.Reason)"
} else {
    Bad "Unexpected refusal reason: $($r1.Reason)"
}

if ($compRow.State -eq 'Complete') {
    Ok "State remained Complete (not modified to Timeout)"
} else {
    Bad "State was modified to '$($compRow.State)'"
}

if ($null -eq $compRow.TimeoutExpiresAt) {
    Ok "TimeoutExpiresAt was not set on settled row"
} else {
    Bad "TimeoutExpiresAt was set: $($compRow.TimeoutExpiresAt)"
}

if ((Get-RowFingerprint $compRow) -eq $beforeComp) {
    Ok "Row is byte-identical after refusal"
} else {
    Bad "Row was mutated despite refusal"
}

# ---------------------------------------------------------------------------------------
# Part 2: Unattributed -Phase on terminal 'Error' row is refused
# ---------------------------------------------------------------------------------------
Write-Host "=== Part 2: Unattributed -Phase on terminal Error row ===" -ForegroundColor Cyan
$errRow = New-WuuComputerRow -Computer 'SRV-ERR'
$errRow.State = 'Error'
$errRow.Status = 'Update error occurred.'
$errRow.UpdatesStatus = 'Error'
$errRow.Color = 'Error'
$errRow.OpState = 'Idle'
$errRow.OperationId = ''
$beforeErr = Get-RowFingerprint $errRow

$r2 = Update-WuuOperationState -Row $errRow -Phase 'WUA Session' -TimeoutSec 120 -Touch:$false
if (-not $r2.Applied -and $r2.Refused) {
    Ok "Unattributed -Phase on Error row is refused"
} else {
    Bad "Unattributed -Phase on Error row was applied (expected refusal)"
}

if ($r2.Reason -like "*settled row ('Error') may not move to 'Timeout'*") {
    Ok "Refusal reason names settled transition restriction: $($r2.Reason)"
} else {
    Bad "Unexpected refusal reason: $($r2.Reason)"
}

if ($errRow.State -eq 'Error' -and $null -eq $errRow.TimeoutExpiresAt) {
    Ok "Error row preserved State='Error' and no deadline set"
} else {
    Bad "Error row modified: State='$($errRow.State)', TimeoutExpiresAt='$($errRow.TimeoutExpiresAt)'"
}

if ((Get-RowFingerprint $errRow) -eq $beforeErr) {
    Ok "Error row is byte-identical after refusal"
} else {
    Bad "Error row was mutated despite refusal"
}

# ---------------------------------------------------------------------------------------
# Part 3: -Phase on an Idle row without active operation is refused
# ---------------------------------------------------------------------------------------
Write-Host "=== Part 3: -Phase on an Idle row is refused ===" -ForegroundColor Cyan
$idleRow = New-WuuComputerRow -Computer 'SRV-IDLE'
$idleRow.State = 'Queued'
$idleRow.OpState = 'Idle'
$idleRow.OperationId = ''
$beforeIdle = Get-RowFingerprint $idleRow

$r3 = Update-WuuOperationState -Row $idleRow -Phase 'Update Search' -TimeoutSec 300 -Touch:$false
if (-not $r3.Applied -and $r3.Refused) {
    Ok "-Phase on Idle row is refused"
} else {
    Bad "-Phase on Idle row was applied (expected refusal)"
}

if ($r3.Reason -like "*cannot set Phase*on an Idle row*") {
    Ok "Refusal reason identifies idle row: $($r3.Reason)"
} else {
    Bad "Unexpected refusal reason: $($r3.Reason)"
}

if ($null -eq $idleRow.TimeoutExpiresAt) {
    Ok "No deadline set on idle row (Invariant 3 preserved)"
} else {
    Bad "TimeoutExpiresAt set on idle row: $($idleRow.TimeoutExpiresAt)"
}

$invIdle = @(Test-WuuOperationStateInvariant -Row $idleRow)
if ($invIdle.Count -eq 0) {
    Ok "Idle row produces 0 invariant violations"
} else {
    Bad "Idle row violated invariants: $($invIdle -join '; ')"
}

# ---------------------------------------------------------------------------------------
# Part 4: Attributed -Phase on running operation is accepted and recorded
# ---------------------------------------------------------------------------------------
Write-Host "=== Part 4: Attributed -Phase on running operation ===" -ForegroundColor Cyan
$runRow = New-WuuComputerRow -Computer 'SRV-RUN'
$null = Update-WuuOperationState -Row $runRow -OperationId 'op-run-777' -OperationIdNew 'op-run-777' -OpState 'Running' -State 'Searching'

$now = Get-Date
$r4 = Update-WuuOperationState -Row $runRow -OperationId 'op-run-777' -Phase 'Update Search' -TimeoutSec 600 -Now $now -Touch:$false
if ($r4.Applied -and -not $r4.Refused) {
    Ok "Attributed -Phase on Running row is applied"
} else {
    Bad "Attributed -Phase on Running row was refused: $($r4.Reason)"
}

if ($runRow.State -eq 'Timeout') {
    Ok "Derived State='Timeout' applied to row"
} else {
    Bad "Derived State was not applied (got '$($runRow.State)')"
}

if ($runRow.UpdatesStatus -eq 'Timeout') {
    Ok "UpdatesStatus='Timeout' applied to row"
} else {
    Bad "UpdatesStatus was not applied (got '$($runRow.UpdatesStatus)')"
}

if ($runRow.TimeoutSource -eq 'Update Search') {
    Ok "TimeoutSource='Update Search' recorded"
} else {
    Bad "TimeoutSource was not recorded (got '$($runRow.TimeoutSource)')"
}

if ($null -ne $runRow.TimeoutExpiresAt -and $runRow.TimeoutExpiresAt -gt $now) {
    Ok "Future deadline TimeoutExpiresAt recorded correctly"
} else {
    Bad "TimeoutExpiresAt was not set properly (got '$($runRow.TimeoutExpiresAt)')"
}

# Clear the operation to test the settled timeout invariant
$r4c = Update-WuuOperationState -Row $runRow -OperationId 'op-run-777' -ClearOperation -Touch:$false
if ($r4c.Applied) {
    Ok "ClearOperation settles the running timeout row"
} else {
    Bad "ClearOperation refused on running timeout row: $($r4c.Reason)"
}

$invSettled = @(Test-WuuOperationStateInvariant -Row $runRow)
if ($invSettled.Count -eq 0) {
    Ok "Settled timeout row produces 0 invariant violations"
} else {
    Bad "Settled timeout row violated invariants: $($invSettled -join '; ')"
}

# ---------------------------------------------------------------------------------------
# Part 5: Set-ComputerTimeout on a terminal row is safely refused
# ---------------------------------------------------------------------------------------
Write-Host "=== Part 5: Set-ComputerTimeout on terminal row ===" -ForegroundColor Cyan
$coreRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$sctCode = Get-FunctionText $coreRaw 'Set-ComputerTimeout'
function Write-DebugLog { param($msg, $level) }
. ([scriptblock]::Create($sctCode))

$termRow = New-WuuComputerRow -Computer 'SRV-TERM-SCT'
$termRow.State = 'Complete'
$termRow.Status = 'All updates installed.'
$termRow.UpdatesStatus = 'All updates installed.'
$termRow.OpState = 'Idle'
$termRow.OperationId = ''
$beforeTerm = Get-RowFingerprint $termRow

Set-ComputerTimeout -Computer $termRow -Phase 'Reboot Wait' -TimeoutSec 180

if ($termRow.State -eq 'Complete' -and $null -eq $termRow.TimeoutExpiresAt) {
    Ok "Set-ComputerTimeout safely refused on terminal Complete row"
} else {
    Bad "Set-ComputerTimeout altered terminal row: State='$($termRow.State)', Deadline='$($termRow.TimeoutExpiresAt)'"
}

if ((Get-RowFingerprint $termRow) -eq $beforeTerm) {
    Ok "Terminal row unchanged after Set-ComputerTimeout refusal"
} else {
    Bad "Terminal row was modified by Set-ComputerTimeout"
}

# ---------------------------------------------------------------------------------------
# Part 6: Stale operation -Phase call on a running row is refused
# ---------------------------------------------------------------------------------------
Write-Host "=== Part 6: Stale operation -Phase call is refused ===" -ForegroundColor Cyan
$staleRow = New-WuuComputerRow -Computer 'SRV-STALE'
$null = Update-WuuOperationState -Row $staleRow -OperationId 'op-current' -OperationIdNew 'op-current' -OpState 'Running' -State 'Downloading'
$beforeStale = Get-RowFingerprint $staleRow

$r6 = Update-WuuOperationState -Row $staleRow -OperationId 'op-stale-old' -Phase 'Update Search' -TimeoutSec 300 -Touch:$false
if (-not $r6.Applied -and $r6.Refused) {
    Ok "Stale writer -Phase call is refused"
} else {
    Bad "Stale writer -Phase call was applied"
}

if ($r6.Reason -like "*stale writer*") {
    Ok "Refusal identifies stale writer: $($r6.Reason)"
} else {
    Bad "Unexpected refusal reason: $($r6.Reason)"
}

if ((Get-RowFingerprint $staleRow) -eq $beforeStale) {
    Ok "Running row untouched after stale -Phase refusal"
} else {
    Bad "Running row was mutated by stale write"
}

# ---------------------------------------------------------------------------------------
Write-Host ""
if ($fail -eq 0) {
    Write-Host "Test-TimeoutStateValidation.ps1: ALL PASS" -ForegroundColor Green
    exit 0
} else {
    Write-Host "Test-TimeoutStateValidation.ps1: $fail FAILURE(S)" -ForegroundColor Red
    exit 1
}
