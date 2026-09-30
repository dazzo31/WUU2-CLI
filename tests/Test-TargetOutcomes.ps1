# Test: per-target outcomes and exit code 4 / PartialSuccess (hardening brief SS10).
#
# WHY THIS SUITE EXISTS
# ---------------------
# Exit code 4 was RESERVED BUT NEVER PRODUCED, and the reason was structural: a `-Computer A,B`
# selection was resolved by one shared answer, so "A succeeded and B failed" was not observable
# anywhere. A mixed fleet therefore reported a flat 1 (OperationFailed), which tells a script nothing
# about which targets to re-run.
#
# The brief asks for exactly the opposite:
#
#     Target A = Success
#     Target B = Success
#     Target C = Failed     ->  PartialSuccess, not generic failure
#
# Get-WuuTargetOutcome / Get-WuuAggregateOutcome supply the missing per-target verdict, and the
# command-mode classifier consumes it. This suite pins the RULE, because the subtle cases are the
# ones that turn a working script into a flapping one:
#
#   * a target that has NOT SETTLED is ignored, not counted as a failure - otherwise `wuu check -All`
#     would report partial success merely for still working through a large estate;
#   * a stale `State='Complete'` must not mask a CURRENT error (failure is checked first);
#   * "every settled target failed" is 1, not 4 - there is nothing partial about it.
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-TargetOutcomes.ps1
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

$failures = @()
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -eq "$Expected") { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host ("FAIL: {0} - expected '{1}', got '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red; $script:failures += $Name }
}
function Assert-True($Condition, $Name) {
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host ("FAIL: {0}" -f $Name) -ForegroundColor Red; $script:failures += $Name }
}

function New-Row([string]$Name, [string]$State, [string]$UpdatesStatus) {
    $r = New-WuuComputerRow -Computer $Name
    $r.State = $State
    $r.UpdatesStatus = $UpdatesStatus
    return $r
}

# ---------------------------------------------------------------------------------------
# 1. per-target outcome
# ---------------------------------------------------------------------------------------
Assert-Equal (Get-WuuTargetOutcome -Row (New-Row 'T1' 'Complete' 'All updates installed')) 'Success' '1. a completed, clean row is Success'
Assert-Equal (Get-WuuTargetOutcome -Row (New-Row 'T2' 'Error' 'Error')) 'Failed' '1. an errored row is Failed'
Assert-Equal (Get-WuuTargetOutcome -Row (New-Row 'T3' 'Timeout' 'Timeout')) 'TimedOut' '1. a timed-out row is TimedOut'
Assert-Equal (Get-WuuTargetOutcome -Row (New-Row 'T4' 'Checking' 'Initializing')) 'Unknown' '1. a row still working is Unknown (not settled)'
Assert-Equal (Get-WuuTargetOutcome -Row (New-Row 'T5' 'Queued' 'Initializing')) 'Unknown' '1. a queued row is Unknown'
Assert-Equal (Get-WuuTargetOutcome -Row $null) 'Unknown' '1. a null row is Unknown (a lookup miss is not a failure)'

# A row can carry a STALE 'Complete' from an earlier operation while the current one errored. The
# error is the outcome. If completion won, a failed re-check on a previously-clean host would be
# reported as success.
Assert-Equal (Get-WuuTargetOutcome -Row (New-Row 'T6' 'Complete' 'Error')) 'Failed' '1. a stale Complete does NOT mask a current Error (failure is checked first)'
Assert-Equal (Get-WuuTargetOutcome -Row (New-Row 'T7' 'Complete' 'Timeout')) 'TimedOut' '1. a stale Complete does not mask a current Timeout'
# And the reverse: an error written only to UpdatesStatus (the classification) still counts.
Assert-Equal (Get-WuuTargetOutcome -Row (New-Row 'T8' 'Checking' 'Error')) 'Failed' '1. Error in UpdatesStatus alone is Failed (both fields are read)'
Assert-Equal (Get-WuuTargetOutcome -Row (New-Row 'T9' 'Timeout' 'Initializing')) 'TimedOut' '1. Timeout in State alone is TimedOut'

# ---------------------------------------------------------------------------------------
# 2. aggregate outcome - the brief's scenario
# ---------------------------------------------------------------------------------------
$rows = @(
    (New-Row 'A' 'Complete' 'All updates installed'),
    (New-Row 'B' 'Complete' 'All updates installed'),
    (New-Row 'C' 'Error' 'Error')
)
Assert-Equal (Get-WuuAggregateOutcome -Rows $rows) 'PartialSuccess' '2. the brief scenario (2 success, 1 failed) is PartialSuccess'

$allOk = @(
    (New-Row 'A' 'Complete' 'All updates installed'),
    (New-Row 'B' 'Complete' 'All updates installed')
)
Assert-Equal (Get-WuuAggregateOutcome -Rows $allOk) 'Success' '2. every target successful is Success'

$allBad = @(
    (New-Row 'A' 'Error' 'Error'),
    (New-Row 'B' 'Timeout' 'Timeout')
)
Assert-Equal (Get-WuuAggregateOutcome -Rows $allBad) 'OperationFailed' '2. every settled target failed is OperationFailed, NOT partial'
Assert-Equal (Get-WuuAggregateOutcome -Rows $allBad) 'OperationFailed' '2. a failure and a timeout together are not "partial success"'

# Unsettled targets are IGNORED. This is the case that keeps a long run from flapping.
$mixedUnsettled = @(
    (New-Row 'A' 'Complete' 'All updates installed'),
    (New-Row 'B' 'Checking' 'Initializing'),
    (New-Row 'C' 'Queued' 'Initializing')
)
Assert-Equal (Get-WuuAggregateOutcome -Rows $mixedUnsettled) 'Success' '2. unsettled targets are ignored, not counted as failures'
$oneOkOneUnsettled = @(
    (New-Row 'A' 'Complete' 'All updates installed'),
    (New-Row 'B' 'Checking' 'Initializing')
)
Assert-Equal (Get-WuuAggregateOutcome -Rows $oneOkOneUnsettled) 'Success' '2. one settled success + one unsettled = Success (the unsettled one has not failed)'

# Nothing settled -> Unknown, so the caller keeps its existing code rather than inventing a verdict.
$noneSettled = @(
    (New-Row 'A' 'Checking' 'Initializing'),
    (New-Row 'B' 'Queued' 'Initializing')
)
Assert-Equal (Get-WuuAggregateOutcome -Rows $noneSettled) 'Unknown' '2. nothing settled is Unknown (no verdict from no evidence)'
Assert-Equal (Get-WuuAggregateOutcome -Rows @()) 'Unknown' '2. an empty set is Unknown'
Assert-Equal (Get-WuuAggregateOutcome -Rows $null) 'Unknown' '2. a null set is Unknown'

# One success + one FAILED + one still running -> partial (the failure is settled, the running one is not).
$okFailRunning = @(
    (New-Row 'A' 'Complete' 'All updates installed'),
    (New-Row 'B' 'Error' 'Error'),
    (New-Row 'C' 'Checking' 'Initializing')
)
Assert-Equal (Get-WuuAggregateOutcome -Rows $okFailRunning) 'PartialSuccess' '2. success + failed + still-running is PartialSuccess (settled mix decides)'

# Three-way mix including a timeout: still partial, not a distinct code.
$okTimeout = @(
    (New-Row 'A' 'Complete' 'All updates installed'),
    (New-Row 'B' 'Timeout' 'Timeout')
)
Assert-Equal (Get-WuuAggregateOutcome -Rows $okTimeout) 'PartialSuccess' '2. success + timeout is PartialSuccess'

# ---------------------------------------------------------------------------------------
# 3. the exit-code mapping (4 must map to 4, and the meaning must be specific)
# ---------------------------------------------------------------------------------------
Assert-Equal (Get-WuuExitCode -Result 'PartialSuccess') 4 '3. PartialSuccess maps to exit code 4'
Assert-Equal (Get-WuuExitCode -Result 'Success') 0 '3. Success maps to 0'
Assert-Equal (Get-WuuExitCode -Result 'OperationFailed') 1 '3. OperationFailed maps to 1'
Assert-Equal (Get-WuuExitCode -Result 'Timeout') 3 '3. Timeout maps to 3'
Assert-Equal (Get-WuuExitCode -Result 'Queued') 6 '3. Queued maps to 6'
Assert-Equal (Get-WuuExitCode -Result 'Refused') 7 '3. Refused maps to 7'
Assert-Equal (Get-WuuExitCode -Result 'AuditFailure') 5 '3. AuditFailure maps to 5'
Assert-Equal (Get-WuuExitCode -Result 'UsageError') 2 '3. UsageError maps to 2'
Assert-True ((Get-WuuExitCodeMeaning -Code 4) -match 'some targets succeeded') '3. the meaning of 4 says "partial, some succeeded" rather than a bare label'

# ---------------------------------------------------------------------------------------
# 4. the classifier actually PRODUCES 4 (it is wired, not merely available)
# ---------------------------------------------------------------------------------------
$coreRaw = Get-Content (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$coreCode = ([regex]::Replace($coreRaw, '(?s)<#.*?#>', '') -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
Assert-True ($coreCode -match 'Get-WuuAggregateOutcome -Rows \$targetRows') '4. the command-mode classifier consults the aggregate outcome'
Assert-True ($coreCode -match "\`$aggregate -eq 'PartialSuccess'") '4. the classifier has a PartialSuccess branch'
$psBranchAt = $coreCode.IndexOf("`$aggregate -eq 'PartialSuccess'")
$failBranchAt = $coreCode.IndexOf('elseif (-not $result.Ok)')
Assert-True ($psBranchAt -ge 0 -and $failBranchAt -ge 0 -and $psBranchAt -lt $failBranchAt) '4. the PartialSuccess branch is checked BEFORE the generic failure (more informative, so it must win)'

# Tautology: removing the branch must make the wiring check fail.
$without = $coreCode.Replace("elseif (`$aggregate -eq 'PartialSuccess')", 'elseif ($false)')
Assert-True (-not ($without -match "\`$aggregate -eq 'PartialSuccess'")) '4. tautology: the wiring check can fail (the branch text is what is being detected)'

# ---------------------------------------------------------------------------------------
# 5. the reservation comment is gone (the code is no longer documented as unproduced)
# ---------------------------------------------------------------------------------------
$cmdRaw = Get-Content (Join-Path $root 'src\Wuu.Command.psm1') -Raw
Assert-True (-not ($cmdRaw -match 'reserved; not currently produced')) '5. the "not currently produced" note for code 4 has been removed'
Assert-True (-not ($cmdRaw -match 'WHY 4 IS NOT PRODUCED')) '5. the "WHY 4 IS NOT PRODUCED" rationale has been replaced'
Assert-True ($cmdRaw -match 'WHY 4 IS PRODUCED') '5. the rationale now explains how 4 is produced'

# ---------------------------------------------------------------------------------------
Write-Host ''
if ($failures.Count) {
    Write-Host ("RESULT: {0} assertion(s) FAILED" -f $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'ALL PASS - per-target outcomes produce exit code 4 correctly (SS10)' -ForegroundColor Green
exit 0
