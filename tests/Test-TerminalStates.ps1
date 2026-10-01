# Test: terminal-state semantics (invariant 8.4).
#
# WHY THIS SUITE EXISTS
# ---------------------
# Invariant 8.4 says a terminal operation stays terminal. The gate reported it as NOT_IMPLEMENTED, and on
# inspection the reason was NOT the one the invariant's wording suggests. Two functions each decided
# independently what "finished" meant, and they DISAGREED:
#
#   Test-WuuStateTransitionAllowed  treated only Complete and Error as terminal
#   Get-WuuTargetOutcome            ALSO treated Timeout as settled, and counted it toward the exit code
#
# The consequence was a silently-overwritable FAILURE, and it is worth stating exactly because the
# severity is not obvious from "a guard is inconsistent":
#
#   1. an operation times out; the row is settled as `TimedOut` by the classifier, which is what produces
#      exit code 4 (PartialSuccess) in a mixed fleet;
#   2. the guard considered `Timeout` NOT terminal, so it allowed the transition;
#   3. and because the first version of the rule only refused terminal -> NON-terminal, even `Timeout` ->
#      `Complete` was permitted;
#   4. so an unattributed writer could convert a counted FAILURE into a counted SUCCESS, and nothing
#      anywhere recorded that it had happened.
#
# A retry is unaffected by any of this: a retry is a NEW operation with a new OperationId, which the rule
# permits. Terminal protects the ROW'S OUTCOME from being rewritten by a writer that cannot name an
# operation - not the operator's ability to retry.
#
# This suite asserts:
#   1. the terminal set is single-sourced, and no caller keeps its own copy
#   2. the guard and the classifier agree on ONE row, for every state in the vocabulary - the assertion
#      that would have caught the original defect
#   3. a settled outcome cannot be rewritten without a new attributed operation - including
#      terminal-to-terminal, which is the case the loose rule missed
#   4. a retry stays legal, and writing the SAME state again is bookkeeping rather than a transition
#   5. the declaration is internally consistent (Test-WuuTerminalStateInvariant), and that checker can
#      actually fail
#   6. the outcome classifier's behaviour on every pre-existing case is unchanged
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-TerminalStates.ps1
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

# The full shipped vocabulary, taken from Set-ComputerState's ValidateSet - the ONE authoritative list of
# canonical states. Read from source so this suite fails if a state is added there and not considered here.
$coreSource = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Core.psm1'))
$vs = [regex]::Match($coreSource, "ValidateSet\('Queued'[^)]*\)")
Assert-True $vs.Success 'Set-ComputerState''s state ValidateSet was found (the vocabulary is taken from the product, not invented)'
$vocabulary = if ($vs.Success) { $vs.Value -replace "ValidateSet\(", '' -replace "\)$", '' -replace "'", '' -split ',' } else { @() }
Assert-True ($vocabulary.Count -ge 10) "the vocabulary has $($vocabulary.Count) states"

function New-Row([string]$State, [string]$UpdatesStatus = '') {
    $r = [pscustomobject]@{ State = $State; UpdatesStatus = $UpdatesStatus; OperationId = 'op-x' }
    return $r
}

'=== 1. the set is single-sourced ==='
$set = @(Get-WuuTerminalStates)
Assert-True ($set.Count -gt 0) "the terminal set is not empty ($($set -join ', ')) - an empty set makes every transition legal"
Assert-True ($set -contains 'Complete') 'Complete is terminal'
Assert-True ($set -contains 'Error') 'Error is terminal'
Assert-True ($set -contains 'Timeout') 'Timeout is terminal (the state the original defect missed)'
Assert-False ($set -contains 'RebootRequired') 'RebootRequired is NOT terminal - it is transient (RebootRequired -> Rebooting -> Complete)'
Assert-False ($set -contains 'Downloading') 'an in-flight state is not terminal'

# NO SECOND COPY. The defect was two definitions, so a literal terminal list anywhere else is the defect
# returning. Scanned with comments stripped, because the prose legitimately NAMES the states.
$statePath = Join-Path $root 'src\Wuu.State.psm1'
$stateText = [System.IO.File]::ReadAllText($statePath)
$stateCode = [regex]::Replace($stateText, '(?s)<#.*?#>', '')
$stateCode = [regex]::Replace($stateCode, '(?m)^\s*#.*$', '')
$inlineSets = ([regex]::Matches($stateCode, "@\(\s*'Complete'\s*,\s*'Error'")).Count
Assert-Equal $inlineSets 0 'no function keeps its own @(''Complete'',''Error'') literal - the single-source fix is still in place'
$readsSingleSource = ([regex]::Matches($stateCode, 'Test-WuuTerminalState|Get-WuuTerminalStates|Get-WuuTerminalOutcomeMap')).Count
Assert-True ($readsSingleSource -ge 3) "the guard and the classifier both read the shared declaration ($readsSingleSource references)"

'=== 2. THE ASSERTION THAT WOULD HAVE CAUGHT THE DEFECT ==='
# For every state in the shipped vocabulary, the two functions must agree about whether a row in that
# state is finished. The rule: if the classifier SETTLES the row (it returns something other than
# 'Unknown'), the guard must consider that state terminal - otherwise the row has a counted outcome that
# an unattributed writer is free to rewrite.
$disagreements = @()
foreach ($s in $vocabulary) {
    # Give the row a matching UpdatesStatus so the classifier judges the same state from both fields.
    $row = New-Row -State $s -UpdatesStatus $s
    $outcome = Get-WuuTargetOutcome -Row $row
    $terminal = (Test-WuuTerminalState -State $s).Terminal
    $settled = ($outcome -ne 'Unknown')
    if ($settled -and -not $terminal) {
        $disagreements += "$s (classifier says '$outcome' but the guard says not terminal)"
    }
}
if ($disagreements.Count -eq 0) {
    Write-Host "PASS: for all $($vocabulary.Count) canonical states, a state the classifier SETTLES is a state the guard treats as TERMINAL" -ForegroundColor Green
} else {
    Write-Host ("FAIL: {0} state(s) are settled to the classifier but open to the guard - a counted outcome can be rewritten: {1}" -f $disagreements.Count, ($disagreements -join '; ')) -ForegroundColor Red
    $failures += 'guard and classifier disagree on settled states'
}
# NOT VACUOUS: the loop must have found at least one settled state, or it proves nothing.
$settledCount = @($vocabulary | Where-Object { (Get-WuuTargetOutcome -Row (New-Row -State $_ -UpdatesStatus $_)) -ne 'Unknown' }).Count
Assert-True ($settledCount -ge 3) "the comparison exercised $settledCount settled states (not vacuous)"

# AND THE REVERSE: every declared terminal state must EXIST in the canonical vocabulary. A declaration
# naming a state the product cannot write protects nothing while leaving the state it replaced
# unprotected - and the forward check above cannot see it, because a row in an unknown state simply stops
# classifying as settled and gets skipped. That is exactly how the tautology proof's "rename Timeout to
# TimedOut" mutation slipped past the forward direction.
$offVocab = @($set | Where-Object { $vocabulary -notcontains $_ })
if ($offVocab.Count -eq 0) {
    Write-Host "PASS: every declared terminal state exists in the canonical vocabulary ($($set -join ', '))" -ForegroundColor Green
} else {
    Write-Host ("FAIL: the terminal declaration names state(s) Set-ComputerState cannot write: {0}" -f ($offVocab -join ', ')) -ForegroundColor Red
    $failures += 'terminal declaration names off-vocabulary states'
}

'=== 3. a settled outcome cannot be rewritten without a new attributed operation ==='
foreach ($terminalState in $set) {
    foreach ($target in @('Complete', 'Error', 'Timeout', 'Downloading', 'Queued')) {
        $row = New-Row -State $terminalState -UpdatesStatus $terminalState
        $verdict = Test-WuuStateTransitionAllowed -Row $row -ToState $target -OperationId $null
        if ($target -eq $terminalState) {
            # Writing the same state again is not a transition - it is bookkeeping.
            Assert-True $verdict.Allowed "$terminalState -> $terminalState (same state, unattributed) is ALLOWED (bookkeeping, not a transition)"
        } else {
            Assert-False $verdict.Allowed "$terminalState -> $target (unattributed) is REFUSED"
        }
    }
}
# The specific case the loose rule missed, named explicitly so a regression is unmistakable.
$timedOut = New-Row -State 'Timeout' -UpdatesStatus 'Timeout'
$looseHole = Test-WuuStateTransitionAllowed -Row $timedOut -ToState 'Complete' -OperationId $null
Assert-False $looseHole.Allowed 'Timeout -> Complete unattributed is refused (terminal-to-terminal was the hole in the first rule)'
Assert-True ($looseHole.Reason -like '*settled*') "and the reason names the settled rule ($($looseHole.Reason))"

# And the failure cannot be laundered into a success.
$okRow = New-Row -State 'Complete' -UpdatesStatus 'All updates installed'
$failedRow = New-Row -State 'Timeout' -UpdatesStatus 'Timeout'
$before = Get-WuuAggregateOutcome -Rows @($okRow, $failedRow)
$afterWrite = Update-WuuOperationState -Row $failedRow -OperationId $null -State 'Complete'
Assert-False $afterWrite.Applied 'the funnel REFUSES to write Complete over a timed-out row with no operation'
Assert-Equal $failedRow.State 'Timeout' 'the row still reads Timeout - nothing was written'
Assert-Equal (Get-WuuAggregateOutcome -Rows @($okRow, $failedRow)) $before 'the aggregate outcome is unchanged (the counted failure was not turned into a success)'

'=== 4. retries stay legal, and bookkeeping stays legal ==='
foreach ($terminalState in $set) {
    $row = New-Row -State $terminalState
    Assert-True (Test-WuuStateTransitionAllowed -Row $row -ToState 'Queued' -OperationId 'op-NEW').Allowed "$terminalState -> Queued WITH a new operation is allowed (a retry is a new operation)"
    Assert-True (Test-WuuStateTransitionAllowed -Row $row -ToState 'Downloading' -OperationId 'op-NEW').Allowed "$terminalState -> Downloading WITH a new operation is allowed"
}
# A non-terminal row is unaffected: the rule is about settled outcomes only.
$inFlight = New-Row -State 'Downloading'
Assert-True (Test-WuuStateTransitionAllowed -Row $inFlight -ToState 'Installing' -OperationId $null).Allowed 'Downloading -> Installing unattributed is still allowed (not settled)'
# A bookkeeping write (no -State) is not a transition at all, so the guard is not even consulted.
$bkRow = New-Row -State 'Complete' -UpdatesStatus 'All updates installed'
$bk = Update-WuuOperationState -Row $bkRow -OperationId 'op-x' -Heartbeat
Assert-True $bk.Applied 'a heartbeat on a settled row is allowed (bookkeeping, not a transition)'

'=== 5. the declaration is internally consistent, and the checker can fail ==='
$inv = Test-WuuTerminalStateInvariant
Assert-True $inv.Ok "Test-WuuTerminalStateInvariant passes on the shipped declaration" 
Assert-Equal @($inv.Violations).Count 0 'and reports no violations'
# The checker must be able to FAIL, or it asserts nothing. Driven by mutating the module-scope
# declaration from the PARENT session state.
#
# NOT by `$script:WuuTerminalStates = ...` in this script: the module was imported with a bare
# Import-Module, so `$script:` here is THIS SCRIPT's scope, not the module's. The assignment would be a
# no-op, the checker would keep reading the real declaration, and all four mutations below would
# "pass" while asserting nothing - which is what the first version of this section did, and the suite
# reported it as a FAILURE rather than silently proving nothing. The module's own session state is
# reached explicitly instead.
$stateModule = Get-Module Wuu.State
Assert-True ($null -ne $stateModule) 'the Wuu.State module object is available for driving its declaration'
# The RAW declaration, read out of the module's own scope. NOT Get-WuuTerminalStates: that returns the
# state NAMES, so saving from it and writing it back replaces the entries with strings - the map then
# builds nothing, every row classifies as 'Unknown', and a restore that looks successful has silently
# disabled the whole mechanism. That is what the first version of this section did.
$saved = @($stateModule.SessionState.PSVariable.GetValue('WuuTerminalStates'))
Assert-Equal $saved.Count 3 'the raw declaration was captured with its three entries (not names)'
Assert-True ([bool]$saved[0].State) 'and each captured entry still carries a State field'
try {
    $stateModule.SessionState.PSVariable.Set('WuuTerminalStates', @())
    $empty = Test-WuuTerminalStateInvariant
    Assert-False $empty.Ok 'an EMPTY terminal set is reported as a violation (an empty set makes the guard inert)'
    Assert-True ((@($empty.Violations) -join ' ') -like '*EMPTY*') 'and says why'

    $stateModule.SessionState.PSVariable.Set('WuuTerminalStates', @(
        @{ State = 'Complete'; Outcome = 'Success' }
        @{ State = 'Error';    Outcome = 'Failed' }
    ))
    $reordered = Test-WuuTerminalStateInvariant
    Assert-False $reordered.Ok 'Complete declared BEFORE Error is reported as a violation (a stale completion could mask a current failure)'
    Assert-True ((@($reordered.Violations) -join ' ') -like '*stale completion*') 'and names the consequence'

    $stateModule.SessionState.PSVariable.Set('WuuTerminalStates', @(
        @{ State = 'Complete'; Outcome = 'Success' }
        @{ State = 'Complete'; Outcome = 'Success' }
    ))
    $dup = Test-WuuTerminalStateInvariant
    Assert-False $dup.Ok 'a duplicated state is reported as a violation (the precedence would be ambiguous)'

    $stateModule.SessionState.PSVariable.Set('WuuTerminalStates', @(@{ State = 'Complete'; Outcome = 'Success' }))
    $gappy = Test-WuuTerminalStateInvariant
    Assert-False $gappy.Ok 'a terminal set whose outcomes omit Failed/TimedOut is reported (the classifier could settle a row the guard considers open)'
} finally {
    $stateModule.SessionState.PSVariable.Set('WuuTerminalStates', @($saved))
}
Assert-True (Test-WuuTerminalStateInvariant).Ok 'the declaration is restored and consistent again'
# And the mutation was real, not a silent no-op: the set must read back with its three members.
Assert-Equal (@(Get-WuuTerminalStates).Count) 3 'the restored declaration has its three states back'

'=== 6. the classifier is unchanged on every pre-existing case ==='
# Terminal semantics were touched, so the outcome classifier's behaviour must be proven unchanged. These
# are the cases the codebase already relied on, including the ordering that stops a stale completion
# masking a current failure.
$cases = @(
    @{ S = 'Error';          U = 'Error';                 Want = 'Failed';   Why = 'an errored row' }
    @{ S = 'Error';          U = '';                      Want = 'Failed';   Why = 'Error in State alone' }
    @{ S = '';               U = 'Error';                 Want = 'Failed';   Why = 'Error in UpdatesStatus alone' }
    @{ S = 'Complete';       U = 'Error';                 Want = 'Failed';   Why = 'a stale Complete must NOT mask a current Error' }
    @{ S = 'Complete';       U = 'All updates installed'; Want = 'Success';  Why = 'a genuinely completed row' }
    @{ S = 'Timeout';        U = 'Timeout';               Want = 'TimedOut'; Why = 'a timed-out row' }
    @{ S = 'Complete';       U = 'Timeout';               Want = 'TimedOut'; Why = 'a stale Complete must NOT mask a current Timeout' }
    @{ S = 'Downloading';    U = 'Updates required';      Want = 'Unknown';  Why = 'an unsettled row is not a failure' }
    @{ S = 'RebootRequired'; U = 'Reboot required';       Want = 'Unknown';  Why = 'RebootRequired is transient, not settled' }
    @{ S = 'Queued';         U = 'Initializing';          Want = 'Unknown';  Why = 'a queued row is not settled' }
)
foreach ($c in $cases) {
    $got = Get-WuuTargetOutcome -Row (New-Row -State $c.S -UpdatesStatus $c.U)
    Assert-Equal $got $c.Want "$($c.Why): '$($c.S)'/'$($c.U)' -> $($c.Want)"
}
Assert-Equal (Get-WuuTargetOutcome -Row $null) 'Unknown' 'a null row is Unknown (a lookup miss is not a failure)'

''
if ($failures.Count -eq 0) {
    Write-Host "ALL PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FAILURES: {0}" -f $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
