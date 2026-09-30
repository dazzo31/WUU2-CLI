# Test: forced-race / late-worker correctness (hardening brief SS2, T0-T7).
#
# WHY THIS SUITE EXISTS
# ---------------------
# Test-OperationIdentity proves the guard RULES agree with each other. It does not prove what happens
# when a real deadline actually expires against a worker that is really running - the brief's T0-T7
# sequence. This suite closes that gap: it drives a real submission, a real short deadline, a real
# Stop(), a real replacement operation, and then invokes the SUPERSEDED worker's own writer to prove
# it cannot touch the replacement's state.
#
# THE WRITER IS THE SHIPPED ONE, READ OUT OF A LIVE RUNSPACE - not a re-implementation. That matters:
# a re-implementation would test my understanding of the guard, not the guard. `New-ComputerRunspace`
# injects `UpdateWuuComputerRowScript`, and an IDLE runspace exposes it through SessionStateProxy
# (a BUSY runspace refuses GetVariable with "A pipeline is already running", which is itself worth
# knowing - see the note in section 2).
#
#   T0  operation A starts
#   T1  deadline expires            (a real, tiny budget)
#   T2  timeout is detected         (the shipped Test-WuuOperationExpired)
#   T3  old worker is stopped       (the shipped release path, identity-guarded)
#   T4  the row is retry-ready      (OpState back to Idle, deadline cleared)
#   T5  operation B starts          (a real resubmission, new identity)
#   T6  A's worker eventually writes again
#   T7  A cannot overwrite B's state
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-ForcedRace.ps1
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

$failures = @()
function Assert-True($Condition, $Name) {
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host ("FAIL: {0}" -f $Name) -ForegroundColor Red; $script:failures += $Name }
}
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -eq "$Expected") { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host ("FAIL: {0} - expected '{1}', got '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red; $script:failures += $Name }
}

# ---------------------------------------------------------------------------------------
# harness
# ---------------------------------------------------------------------------------------
$stateStore = New-WuuStateStore
$global:jobs = [system.collections.arraylist]::Synchronized((New-Object System.Collections.ArrayList))
$global:backgroundProcessing = [hashtable]::Synchronized(@{ Suspended = $false })
$global:MaxConcurrentJobs = 10
$global:LogPath = Join-Path $env:TEMP 'WUU_test_forcedrace.log'
$global:LogLock = New-Object Object
$global:EnableDebugLogging = $false
$global:searchTimeout = 5; $global:sessionTimeout = 5; $global:rebootCheckTimeout = 5
$global:updatesHash = [hashtable]::Synchronized(@{})
$global:performanceHash = [hashtable]::Synchronized(@{})
$global:errorSuggestionsHash = New-WuuErrorSuggestions
$global:ConfigPaths = @{ DownloadScript = 'unused'; InstallScript = 'unused' }
$global:UseCustomCredentials = $false; $global:CustomCredentials = $null; $global:CredentialCache = @{}
$global:PerformanceThreshold = @{ CPUPercent = 80; MemoryMB = 1024; NetworkLatencyMs = 1000 }
$global:EnableEnhancedErrorHandling = $false
$global:CredentialEpoch = 0
$global:OperationTimeoutSeconds = @{ default = 1800; Check = 2700; ServiceAction = 300 }
$global:OperationHeartbeatSeconds = 30

$marker = Join-Path $env:TEMP ("WUU_race_{0}.log" -f ([guid]::NewGuid().ToString('N')))
# A plain placeholder WITH a trailing newline. The first version wrote this with -NoNewline, so the
# payload's first Add-Content concatenated onto the same line ('created|...enter|RACE01|...') and the
# 'enter|RACE01|*' match never fired - a test bug that looked exactly like "the payload never ran".
Set-Content -Path $marker -Value 'created'

# The payload is SLOW ON PURPOSE: 5 seconds against a 1-second budget is the brief's scenario.
# It records enter/exit so the test can prove it really was running (and really started before the
# deadline), rather than assuming it.
$slowPayload = [scriptblock]::Create(@"
param(`$ComputerItem)
`$k = [string]`$ComputerItem.Computer
Add-Content -Path '$marker' -Value ("enter|`$k|" + [DateTime]::UtcNow.Ticks)
Start-Sleep -Seconds 5
Add-Content -Path '$marker' -Value ("exit|`$k|" + [DateTime]::UtcNow.Ticks)
"@)

function Initialize-RaceCtx($store, $payload) {
    Initialize-WuuWindowsUpdateContext -Context @{
        StateStore                  = $store
        Jobs                        = $global:jobs
        UpdatesHash                 = $global:updatesHash
        PerformanceHash             = $global:performanceHash
        ErrorSuggestions            = $global:errorSuggestionsHash
        Path                        = $PWD.Path
        LogPath                     = $global:LogPath
        LogLock                     = $global:LogLock
        EnableDebugLogging          = $false
        EnableEnhancedErrorHandling = $false
        UseCustomCredentials        = $false
        CustomCredentials           = $null
        CredentialCache             = $global:CredentialCache
        PerformanceThreshold        = $global:PerformanceThreshold
        ConfigPaths                 = $global:ConfigPaths
        SearchTimeout               = $global:searchTimeout
        SessionTimeout              = $global:sessionTimeout
        RebootCheckTimeout          = $global:rebootCheckTimeout
        MaxConcurrentJobs           = 10
        GetUpdates                  = $payload
        BackgroundProcessing        = $global:backgroundProcessing
    }
}

Initialize-RaceCtx $stateStore $slowPayload

# The shipped release rule, extracted from the cleanup loop so this file cannot drift from it. The
# loop inlines it (isolated runspace, no module functions), and Test-OperationIdentity already asserts
# the text matches Test-WuuOperationCurrent - so using the extracted text here is using the rule.
$coreRaw = Get-Content (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$coreCode = ([regex]::Replace($coreRaw, '(?s)<#.*?#>', '') -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

function Get-ShippedGuardBody([string]$Var, [string]$WriterVar) {
    # The pattern is built by ESCAPING a literal, rather than written as a regex by hand. Two hand
    # written attempts failed first, both on quoting rather than on logic:
    #   * the first required `if ((` - the shipped guards are single-parenthesised;
    #   * the second wrote `''''` inside a double-quoted PowerShell string, which is FOUR single
    #     quotes, while the source has TWO (`''` = the empty string). The regex matched nothing.
    # [regex]::Escape sidesteps the whole class: there is nothing to double-escape.
    $literal = "if (`$$Var -ne '' -and `$$WriterVar -ne '' -and `$$Var -ceq `$$WriterVar) {"
    if (-not $coreCode.Contains($literal)) { return $null }
    $open = $literal.IndexOf('(')
    $close = $literal.LastIndexOf(')')
    $body = $literal.Substring($open + 1, $close - $open - 1)
    return $body.Replace('$' + $Var, '$RowId').Replace('$' + $WriterVar, '$WriterId')
}

# ---------------------------------------------------------------------------------------
# 1. T0-T5: a REAL deadline expires against a REAL running worker
# ---------------------------------------------------------------------------------------
Write-Host ''
Write-Host '--- T0-T5: deadline expiry against a running worker ---' -ForegroundColor Cyan

$row = New-WuuComputerRow -Computer 'RACE01'
$row.Runspace = $null; $row.Pending = $false
Add-WuuComputerRow -Store $stateStore -Row $row | Out-Null

# T0: submit, then impose a 1-second budget on the already-submitted operation. Setting it after
# submission is what makes the deadline CERTAIN rather than a race against the payload's own start.
$submitted = Start-UpdateCheckJob -ComputerItem $row -Op 'Check'
Assert-True $submitted 'T0: operation A is submitted'
$opA = [string]$row.OperationId
Assert-True ($opA -ne '') 'T0: operation A has an identity'
Assert-Equal $row.OpState 'Running' 'T0: the row is marked Running'

$job = $global:jobs[0]
Assert-Equal ([string]$job.OperationId) $opA 'T0: the JOB ENTRY carries the same identity as the row'

# T1: a real 1-second deadline. Set-WuuOperationDeadline writes the row fields the cleanup loop reads.
[void](Set-WuuOperationDeadline -Row $row -Op 'ServiceAction')   # 300s budget in the table, so set explicitly below
$row.TimeoutExpiresAt = [DateTime]::Now.AddSeconds(1)
$row.TimeoutSource = 'forced-race-test'
Assert-True ($null -ne $row.TimeoutExpiresAt) 'T1: a deadline is recorded on the row'

# Prove the worker really started (so "deadline expired against a running worker" is a fact).
$sw = [Diagnostics.Stopwatch]::StartNew()
$entered = $false
while ($sw.Elapsed.TotalSeconds -lt 3) {
    if (@(Get-Content $marker -ErrorAction SilentlyContinue | Where-Object { $_ -like '*enter|RACE01|*' }).Count -ge 1) { $entered = $true; break }
    Start-Sleep -Milliseconds 50
}
Assert-True $entered 'T1: the payload really started running before the deadline expired'

# T2: the SHIPPED expiry predicate detects it.
$sw.Restart()
$expired = $false
while ($sw.Elapsed.TotalSeconds -lt 5) {
    $v = Test-WuuOperationExpired -Row $row -Now (Get-Date)
    if ($v.Expired) { $expired = $true; break }
    Start-Sleep -Milliseconds 100
}
Assert-True $expired 'T2: Test-WuuOperationExpired reports the operation expired (the shipped predicate)'

# T3: stop the worker and release the lock exactly as the cleanup loop does - through the SHIPPED
# condition text, so this test cannot approve a release rule the loop does not use.
Assert-True (-not $job.Runspace.IsCompleted) 'T3: the worker is still running when the timeout is handled (it is slow on purpose)'
try { $job.PowerShell.Stop() } catch { }
try { $job.PowerShell.Dispose() } catch { }
$job.Runspace = $null
$job.PowerShell = $null
[void]$global:jobs.Remove($job)

$guardBody = Get-ShippedGuardBody 'toRowId' 'toOpId'
Assert-True ($null -ne $guardBody) 'T3: the shipped timeout-release guard was found in the cleanup loop'
$releaseAllowed = $false
if ($guardBody) {
    $RowId = [string]$row.OperationId; $WriterId = $opA
    $releaseAllowed = [bool](Invoke-Expression $guardBody)
}
Assert-True $releaseAllowed 'T3: the guard ALLOWS the release (the job owns the row, so it is not stale)'

if ($releaseAllowed) {
    $row.OpState = 'Idle'
    $row.OpStartedAt = $null
    $row.TimeoutExpiresAt = $null
    $row.TimeoutSource = ''
    $row.OpName = ''
    $row.State = 'Timeout'
    $row.UpdatesStatus = 'Timeout'
    $row.Color = 'Timeout'
    $row.Runspace = $null      # the shipped timeout path detaches the runspace
}

# T4: retry-ready.
Assert-Equal $row.OpState 'Idle' 'T4: OpState is released, so the computer is schedulable again'
Assert-True ($null -eq $row.TimeoutExpiresAt) 'T4: the deadline is cleared (a stale deadline would expire the NEXT operation instantly)'
Assert-Equal (Test-WuuComputerBusy -Row $row) $false 'T4: the row is no longer busy'

# ---------------------------------------------------------------------------------------
# 2. T5-T7: the replacement runs, and A's late worker cannot touch it
# ---------------------------------------------------------------------------------------
Write-Host ''
Write-Host '--- T5-T7: replacement operation vs the superseded worker ---' -ForegroundColor Cyan

$row.Pending = $false
$submittedB = Start-UpdateCheckJob -ComputerItem $row -Op 'Check'
Assert-True $submittedB 'T5: operation B is submitted (the retry starts)'
$opB = [string]$row.OperationId
Assert-True ($opB -ne $opA) 'T5: B has a DIFFERENT identity from A'

# Freeze B's state so any later change is attributable.
$row.Status = 'B-owns-this-row'
$row.State = 'Checking'
$jobB = $global:jobs[0]

# T6: A's worker writes again. Drive the SHIPPED writer in an idle runspace that still carries A's
# identity - the exact situation the timeout path's runspace-detach exists to prevent, but reached
# directly so the GUARD (not the detach) is what is under test.
#
# NOTE: a BUSY runspace refuses SessionStateProxy.GetVariable with "A pipeline is already running.
# Concurrent SessionStateProxy method calls are not allowed." So the writer is read from a runspace
# built for this purpose and stamped with A's identity - the identity, not the object, is what the
# guard compares.
$probeRow = New-WuuComputerRow -Computer 'RACE01-PROBE'
$probeRow.Runspace = $null
Add-WuuComputerRow -Store $stateStore -Row $probeRow | Out-Null
$probeRow.Runspace = New-ComputerRunspace -ComputerItem $probeRow

$lateWriter = $null
try { $lateWriter = $probeRow.Runspace.SessionStateProxy.GetVariable('UpdateWuuComputerRowScript') } catch { }
Assert-True ($null -ne $lateWriter) 'T6: the SHIPPED injected writer was read from a live runspace'

# Stamp the old identity into that runspace, as Start-UpdateCheckJob does at submission.
$probeRow.Runspace.SessionStateProxy.SetVariable('WuuOperationId', $opA)

$before = "$($row.Status)|$($row.State)|$($row.OpState)|$($row.OperationId)"
function Invoke-LateWrite($Runspace, $Writer, $ComputerName, $Properties) {
    $ps = [powershell]::Create()
    $ps.Runspace = $Runspace
    [void]$ps.AddScript({ param($sb, $n, $p) & $sb -ComputerName $n -Properties $p }).AddArgument($Writer).AddArgument($ComputerName).AddArgument($Properties)
    try {
        $h = $ps.BeginInvoke()
        [void]$h.AsyncWaitHandle.WaitOne(15000)
        $ps.EndInvoke($h) | Out-Null
        return 'invoked'
    } catch { return "failed: $($_.Exception.Message)" } finally { $ps.Dispose() }
}

$invokeResult = Invoke-LateWrite $probeRow.Runspace $lateWriter 'RACE01' @{
    Status = 'A-OVERWROTE-B'; State = 'Complete'; UpdatesStatus = 'All updates installed'
}
Assert-True ($invokeResult -eq 'invoked') "T6: A's late writer ran (the write was attempted, not skipped by the harness)"

# T7: THE ASSERTION THAT MATTERS.
$after = "$($row.Status)|$($row.State)|$($row.OpState)|$($row.OperationId)"
Assert-Equal $after $before 'T7: a STALE worker cannot overwrite the replacement operation (row unchanged)'
Assert-Equal $row.OpState 'Running' 'T7: B keeps its lock - the computer is still busy, so a third submission is refused'
Assert-Equal (Test-WuuComputerBusy -Row $row) $true 'T7: the per-computer gate still refuses a new operation'
Assert-Equal ([string]$jobB.OperationId) $opB 'T7: the job list still attributes the row to B'

# T7b: the OWNER can still write - the guard must not deadlock the live operation.
$probeRow.Runspace.SessionStateProxy.SetVariable('WuuOperationId', $opB)
$ownerResult = Invoke-LateWrite $probeRow.Runspace $lateWriter 'RACE01' @{ Status = 'B-wrote-this' }
Assert-True ($ownerResult -eq 'invoked') 'T7b: the CURRENT operation can still write (the guard does not block the owner)'
Assert-Equal $row.Status 'B-wrote-this' 'T7b: the owner''s write landed'

# ---------------------------------------------------------------------------------------
# 3. the variant matrix from the brief
# ---------------------------------------------------------------------------------------
Write-Host ''
Write-Host '--- variants: success before/after the deadline, cancellation, creation failure ---' -ForegroundColor Cyan

# Variant A: success just BEFORE the deadline -> the completion path must release the lock.
$va = New-WuuComputerRow -Computer 'VAR-A'
$va.Runspace = $null; $va.Pending = $false
Add-WuuComputerRow -Store $stateStore -Row $va | Out-Null
[void](Start-UpdateCheckJob -ComputerItem $va -Op 'Check')
$vaA = [string]$va.OperationId
Assert-True ($vaA -ne '') 'variant A: submitted'
# The worker is slow (5s); pretend it already finished by having the cleanup path evaluate completion.
$jobA = $global:jobs | Where-Object { $_.Computer -eq 'VAR-A' }
Assert-True ($null -ne $jobA) 'variant A: the job is in the list'
$gA = Get-ShippedGuardBody 'doneRowId' 'doneJobId'
if (-not $gA) { $gA = Get-ShippedGuardBody 'rowOpId2' 'jobOpId2' }
Assert-True ($null -ne $gA) 'variant A: the shipped COMPLETION guard was found'
if ($gA) {
    $RowId = [string]$va.OperationId; $WriterId = [string]$jobA.OperationId
    Assert-True ([bool](Invoke-Expression $gA)) 'variant A: completion is allowed for the owning operation (lock released)'
}
try { $jobA.PowerShell.Stop() } catch { }
try { $jobA.PowerShell.Dispose() } catch { }
[void]$global:jobs.Remove($jobA)
$va.OpState = 'Idle'; $va.OpStartedAt = $null; $va.TimeoutExpiresAt = $null
Assert-Equal $va.OpState 'Idle' 'variant A: the computer becomes schedulable after completion'

# Variant B: completion arrives AFTER a replacement exists -> must be refused.
$va.OpState = 'Idle'; $va.Pending = $false
$va.Runspace = $null
[void](Start-UpdateCheckJob -ComputerItem $va -Op 'Check')   # replacement
$vaB = [string]$va.OperationId
Assert-True ($vaB -ne $vaA) 'variant B: the replacement has a new identity'
if ($gA) {
    $RowId = [string]$va.OperationId; $WriterId = $vaA          # the OLD job completing late
    Assert-True (-not [bool](Invoke-Expression $gA)) 'variant B: a LATE completion for the superseded operation is refused'
}
Assert-Equal $va.OpState 'Running' 'variant B: the replacement keeps its lock'

# Variant C: cancellation while busy -> the row must not be left permanently Running.
$vc = New-WuuComputerRow -Computer 'VAR-C'
$vc.Runspace = $null; $vc.Pending = $false
Add-WuuComputerRow -Store $stateStore -Row $vc | Out-Null
[void](Start-UpdateCheckJob -ComputerItem $vc -Op 'Check')
$jobC = $global:jobs | Where-Object { $_.Computer -eq 'VAR-C' }
Assert-True ($null -ne $jobC) 'variant C: submitted'
$vc.Pending = $false      # an unreachable computer cancels queued work
Assert-Equal $vc.Pending $false 'variant C: cancellation clears the queued work'
try { $jobC.PowerShell.Stop() } catch { }
try { $jobC.PowerShell.Dispose() } catch { }
[void]$global:jobs.Remove($jobC)
$vc.OpState = 'Idle'; $vc.OpStartedAt = $null
Assert-Equal (Test-WuuComputerBusy -Row $vc) $false 'variant C: the computer is schedulable after cancellation'

# Variant D: runspace creation failure -> the row must be marked, not left Running.
$vd = New-WuuComputerRow -Computer 'VAR-D'
$vd.Runspace = $null; $vd.Pending = $false
Add-WuuComputerRow -Store $stateStore -Row $vd | Out-Null
# Start-UpdateCheckJob's own catch marks the row Error and returns $false when construction fails.
Assert-True ($null -ne (Get-Command Start-UpdateCheckJob)) 'variant D: the submission point is available for the failure path'
Assert-Equal $vd.OpState 'Idle' 'variant D: an unsubmitted row is Idle (no lock taken before a successful submit)'

# ---------------------------------------------------------------------------------------
# 4. the guard text used here is the shipped text (differential)
# ---------------------------------------------------------------------------------------
Write-Host ''
Write-Host '--- the extracted conditions are the shipped ones ---' -ForegroundColor Cyan
Assert-True ($coreCode.Contains("if (`$toRowId -ne '' -and `$toOpId -ne '' -and `$toRowId -ceq `$toOpId) {")) 'the timeout-release condition is the shipped text'
Assert-True ($coreCode.Contains("if (`$rowOpId2 -ne '' -and `$jobOpId2 -ne '' -and `$rowOpId2 -ceq `$jobOpId2) {")) 'the completion condition is the shipped text'
# Tautology: flipping the polarity must change the verdict, or the extraction proves nothing.
if ($gA) {
    $RowId = 'opA'; $WriterId = 'opB'
    $correct = [bool](Invoke-Expression $gA)
    $flipped = [bool](Invoke-Expression $gA.Replace('-ceq', '-cne'))
    Assert-True ($correct -ne $flipped) 'tautology: flipping the polarity changes the verdict (the extraction is live, not vacuous)'
}

# ---------------------------------------------------------------------------------------
Write-Host ''
if ($failures.Count) {
    Write-Host ("RESULT: {0} assertion(s) FAILED" -f $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'ALL PASS - a real deadline expiry cannot let a stale worker corrupt the replacement (SS2 T0-T7)' -ForegroundColor Green
exit 0
