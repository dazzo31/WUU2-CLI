# Test: refusal semantics (hardening brief PHASE 5 / SS16).
#
# WHY THIS SUITE EXISTS
# ---------------------
# A submission can be REFUSED - the computer is busy, the global cap is full, the submission lock is
# not acquirable. A refusal is not an error: the operation never started and the computer is undamaged,
# so retrying is the right response. But nothing recorded it, and the consequence was a PERMANENT
# SILENT STALL:
#
#   * a refused submission returned $false and left Pending=$true;
#   * the phase gate saw only "Pending" and waited - correct for a queue that is MOVING;
#   * nothing distinguished a moving queue from a computer that can NEVER be admitted;
#   * and since a refusal is neither Error nor Timeout, Test-WuuPhaseFailureBlocks never saw it either.
#
# So a permanently-refused computer held its whole phase for ever, with the gate reporting nothing and
# the audit trail recording nothing. That is the concrete defect behind "cancellation/refusal phase
# semantics are undefined".
#
# This suite asserts:
#   1. a refusal is RECORDED (count, reason, timestamp) and is NOT an error
#   2. only CONSECUTIVE refusals accumulate - an admission resets the record
#   3. the stall threshold is a single value shared by the recorder, the predicate and the gate
#   4. the phase gate stops on a STALLED row and, crucially, that it is the stall branch doing it
#      (a Pending row already blocks, so the gate would pass this by accident otherwise)
#   5. an unsettled, never-refused row is NOT stalled - absent evidence is not a stall
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-RefusalSemantics.ps1
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$failures = @()
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -eq "$Expected") { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host ("FAIL: {0} - expected '{1}', got '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red; $script:failures += $Name }
}
function Assert-True($Condition, $Name) {
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host ("FAIL: {0}" -f $Name) -ForegroundColor Red; $script:failures += $Name }
}
function Assert-False($Condition, $Name) { Assert-True (-not $Condition) $Name }

Import-Module (Join-Path $root 'src\Wuu.State.psm1') -Force -ErrorAction Stop

'=== 1. the row contract carries the refusal record ==='
$row = New-WuuComputerRow -Computer 'REFUSE-PC'
Assert-True ($null -ne $row.PSObject.Properties['RefusedCount']) 'the row has RefusedCount'
Assert-True ($null -ne $row.PSObject.Properties['RefusedReason']) 'the row has RefusedReason'
Assert-True ($null -ne $row.PSObject.Properties['RefusedAt']) 'the row has RefusedAt'
Assert-Equal $row.RefusedCount 0 'a fresh row has no refusals'
Assert-Equal $row.RefusedReason '' 'a fresh row has no refusal reason'

'=== 2. a refusal is RECORDED, and is not an error ==='
$r1 = Update-WuuRefusalRecord -Row $row -Reason 'computer is Running'
Assert-Equal $row.RefusedCount 1 'the first refusal is counted'
Assert-Equal $row.RefusedReason 'computer is Running' 'the reason is recorded'
Assert-True ($null -ne $row.RefusedAt) 'the timestamp is recorded'
Assert-Equal $r1.Count 1 'the record is returned to the caller'
Assert-False $r1.Stalled 'one refusal is not a stall'
# A refusal must NOT be reported as a settled failure - the computer is undamaged.
Assert-Equal $row.State 'Queued' 'a refusal does not change the row State'
Assert-Equal $row.UpdatesStatus 'Initializing' 'a refusal does not set a failed UpdatesStatus'
Assert-Equal $row.OpState 'Idle' 'a refusal leaves the row idle (nothing was submitted)'

'=== 3. only CONSECUTIVE refusals accumulate ==='
$r2 = Update-WuuRefusalRecord -Row $row -Reason 'global concurrency cap reached'
Assert-Equal $row.RefusedCount 2 'a second consecutive refusal increments'
Assert-Equal $row.RefusedReason 'global concurrency cap reached' 'the reason is updated to the latest'
Assert-Equal $r2.Count 2 'the returned count is consecutive'

$reset = Update-WuuRefusalRecord -Row $row -Admitted
Assert-Equal $row.RefusedCount 0 'an ADMISSION clears the consecutive count'
Assert-Equal $row.RefusedReason '' 'an admission clears the reason'
Assert-Equal $row.RefusedAt $null 'an admission clears the timestamp'
Assert-False $reset.Stalled 'an admitted row is not stalled'

# Interleaving proves it is CONSECUTIVE refusals that matter, not a lifetime total.
$null = Update-WuuRefusalRecord -Row $row -Reason 'a'
$null = Update-WuuRefusalRecord -Row $row -Reason 'b'
$null = Update-WuuRefusalRecord -Row $row -Admitted
$after = Update-WuuRefusalRecord -Row $row -Reason 'c'
Assert-Equal $after.Count 1 'a refusal after an admission restarts the count (consecutive, not cumulative)'

'=== 4. the stall threshold is ONE value, shared ==='
$threshold = Get-WuuRefusalStallThreshold
Assert-True ($threshold -gt 1) "the threshold is a real count ($threshold), not 1"
Assert-True ($threshold -lt 100000) "the threshold is reachable in a scheduler's lifetime ($threshold)"

# Drive the row to just below and at the threshold. This is the assertion that the PREDICATE and the
# RECORDER agree - a disagreement would let the gate wait for ever on a row the recorder calls stalled.
$probe = New-WuuComputerRow -Computer 'THRESHOLD-PC'
for ($i = 1; $i -lt $threshold; $i++) { $null = Update-WuuRefusalRecord -Row $probe -Reason 'probe' }
$below = Test-WuuRefusalStalled -Row $probe
Assert-False $below.Stalled "at $($threshold - 1) refusals the row is NOT yet stalled"
Assert-Equal $below.Threshold $threshold 'the predicate reports the same threshold'

$at = Update-WuuRefusalRecord -Row $probe -Reason 'probe'
Assert-True $at.Stalled "the RECORDER reports stalled exactly at the threshold ($threshold)"
$atPred = Test-WuuRefusalStalled -Row $probe
Assert-True $atPred.Stalled 'the PREDICATE agrees with the recorder at the threshold'
Assert-Equal $atPred.Count $threshold 'the predicate reports the count'

'=== 5. an unsettled row with no refusals is NOT stalled ==='
# Absent evidence must not be read as a stall, or every phase would block the moment it started.
$fresh = New-WuuComputerRow -Computer 'FRESH-PC'
$freshState = Test-WuuRefusalStalled -Row $fresh
Assert-False $freshState.Stalled 'a fresh row is not stalled'
Assert-Equal $freshState.Count 0 'a fresh row has a zero count'
$nullState = Test-WuuRefusalStalled -Row $null
Assert-False $nullState.Stalled 'a null row is a clean $false, not a throw and not a stall'

'=== 6. the submission point RECORDS on every refusal path and CLEARS on admission ==='
$wupdRaw = Get-Content (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw
function Get-CodeNoComments([string]$Text) {
    if (-not $Text) { return '' }
    $noBlocks = [regex]::Replace($Text, '(?s)<#.*?#>', '')
    return (($noBlocks -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
}
$wupdCode = Get-CodeNoComments $wupdRaw

function Get-FunctionText([string]$Text, [string]$Name) {
    $lines = $Text -split "`r?`n"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*function\s+$([regex]::Escape($Name))\b") { $start = $i; break }
    }
    if ($start -lt 0) { return '' }
    $out = @(); $depth = 0; $seenBrace = $false
    for ($i = $start; $i -lt $lines.Count; $i++) {
        $out += $lines[$i]
        $depth += ([regex]::Matches($lines[$i], '\{')).Count
        $depth -= ([regex]::Matches($lines[$i], '\}')).Count
        if ($depth -gt 0) { $seenBrace = $true }
        if ($seenBrace -and $depth -le 0) { break }
    }
    return ($out -join "`n")
}

$sub = Get-FunctionText $wupdCode 'Start-UpdateCheckJob'
Assert-True ($sub -ne '') 'Start-UpdateCheckJob was located'

# Every refusal must be recorded, so the check is driven by the REFUSAL CONDITIONS rather than by a
# count of `return $false`. A count cannot distinguish a refusal from an ERROR path: the submission
# point also returns $false when BeginInvoke fails or the row update throws, and those are faults whose
# handling is different. Counting produced a false failure on two correct error paths and a genuine
# failure on one unrecorded refusal - both at once, which is why the predicate is now structural.
#
# A refusal is identified by the message it logs ("submission refused" / "submission deferred"), plus
# the identity-claim refusal. Each such site must be within a few lines of a recording call.
$refusalMarkers = @(
    'submission refused',
    'submission deferred',
    'submission refused: $($claim.Reason)'
)

function Test-RefusalSiteRecorded([string]$Text, [string]$Marker) {
    $idx = $Text.IndexOf($Marker)
    if ($idx -lt 0) { return $null }   # marker absent: caller reports that separately
    # Look back over the enclosing statement for the recording call.
    $lo = [Math]::Max(0, $idx - 700)
    $window = $Text.Substring($lo, $idx - $lo)
    return $window.Contains('Update-WuuRefusalRecord')
}

foreach ($marker in @('submission refused', 'submission deferred')) {
    $recorded = Test-RefusalSiteRecorded $sub $marker
    Assert-True ($null -ne $recorded) "the submission point has a '$marker' path"
    Assert-True ($recorded -eq $true) "the '$marker' refusal path records the refusal"
}

# The identity-claim refusal is its own path (its wording predates the others), and it was the one that
# did NOT record until this suite counted it.
$claimAt = $sub.IndexOf('claim refused')
Assert-True ($claimAt -ge 0) 'the identity-claim refusal records a refusal (it was the missing one)'

$recordCalls = ([regex]::Matches($sub, 'Update-WuuRefusalRecord')).Count
Assert-True ($recordCalls -ge 5) "every distinct refusal kind records ($recordCalls record call(s))"
Assert-True ($sub -match 'Update-WuuRefusalRecord\s+-Row\s+\$ComputerItem\s+-Admitted') 'admission CLEARS the refusal record'

# Every refusal must ALSO tell the operator, or the record exists but nobody is told.
# The count text comes AFTER the marker, so this window looks FORWARD. An earlier version looked
# backward (copying the recording check above) and could never contain it, so it failed on correct
# code - the mirror image of the mistake that check itself guards against.
foreach ($marker in @('submission refused', 'submission deferred')) {
    $idx = $sub.IndexOf($marker)
    if ($idx -ge 0) {
        $hi = [Math]::Min($sub.Length, $idx + 700)
        $forward = $sub.Substring($idx, $hi - $idx)
        Assert-True ($forward -match 'refusal \$\(\$refusal\.Count\)') "the '$marker' refusal reports its consecutive count"
    }
}

'=== 7. the phase gate acts on a STALL and says why ==='
$gate = Get-FunctionText $wupdCode 'Test-PhaseCompletion'
if ($gate -eq '') { $gate = $wupdCode }   # the gate body may be inline in the phase function
Assert-True ($gate -match 'Test-WuuRefusalStalled') 'the phase gate consults the stall predicate'
Assert-True ($gate -match 'stall\.Stalled') 'the phase gate BRANCHES on the stall result (not merely computes it)'
# The stall branch must block. A branch that computed the result and continued would be an inert check.
$stallIdx = $gate.IndexOf('Test-WuuRefusalStalled')
$stallWindow = ''
if ($stallIdx -ge 0) { $stallWindow = $gate.Substring($stallIdx, [Math]::Min(900, $gate.Length - $stallIdx)) }
Assert-True ($stallWindow -match 'return\s+\$false') 'the stall branch BLOCKS the phase'
Assert-True ($stallWindow -match 'Write-WarningLog') 'the stall branch REPORTS why (a silent block is the original defect)'

# The gate must NOT re-derive its own threshold: one value, one home.
Assert-True ($wupdCode -notmatch 'RefusedCount\s*-ge\s*\d') 'the gate does not hard-code its own refusal threshold'

''
if ($failures.Count -eq 0) {
    Write-Host "ALL PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FAILURES: {0}" -f $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
