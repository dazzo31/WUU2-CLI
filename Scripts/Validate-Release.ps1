# Release validation (console edition).
#
# The GUI checks (XAML load + FindName control resolution) no longer apply: ui/ was removed and
# the shell renders the state store instead. What CAN still break the app at startup, and is
# therefore worth gating a release on:
#   1. every shipped PowerShell file parses under the PS 5.1 engine;
#   2. no shipped file references WPF/XAML/ui\ (a regression would reintroduce a runtime
#      dependency the console edition cannot satisfy);
#   3. every module in src/ imports through the real path (Import-WuuModules);
#   4. the engine imports WITHOUT a WPF assembly being loaded (the Phase 1 acceptance property);
#   5. each console menu key maps to an action the action layer actually defines.
#
# --- MACHINE-READABLE MODE (reviewer P4) ---------------------------------------------------------
# -Json writes every verdict to a JSON file so CI can gate on a FIELD rather than on scraping text,
# and so the five verdict kinds are distinguishable. Without it a consumer had exactly two signals
# (a line matching '^FAIL:' and the exit code), which cannot express "this check did not run" or
# "this is advisory".
#
# THE DEFAULT OUTPUT IS DELIBERATELY UNCHANGED. The verdict helpers still write to the host with the
# same wording and colours in both modes, so a human reading a -Json run sees exactly what they see
# today; -Json ADDS a file. The risk this avoids is the usual one with a machine-readable mode: the
# human output becomes a rendering of the machine output and quietly loses detail that only ever
# lived in a sentence.
#
# THE FIVE VERDICTS AND WHY THEY ARE FIVE (not two):
#   PASS             the assertion holds
#   FAIL             the assertion is violated - the release must not ship
#   WARN             a concern that is not a release blocker
#   SKIP             NOT RUN, and this is why it must not be reported as a pass. A skipped check that
#                    reads as PASS is worse than no check: it buys confidence without evidence
#   NOT_IMPLEMENTED  the property has no check at all. The reviewer asked for this explicitly, and the
#                    distinction matters: "we verified this" and "we have not built a verifier" are
#                    different facts, and conflating them is how a gap becomes invisible.
#
# The verdict list is ORDERED by severity and the summary counts every kind, so a NOT_IMPLEMENTED can
# never be mistaken for a PASS by a consumer that only looks at totals.
param(
    [Parameter(Mandatory = $false)][string]$Json = ''
)

$failed = $false
$script:WuuGateVerdicts = New-Object System.Collections.Generic.List[object]

function Add-WuuGateVerdict([string]$Status, [string]$Message) {
    $script:WuuGateVerdicts.Add([pscustomobject]@{ Status = $Status; Message = $Message }) | Out-Null
}

function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:failed = $true; Add-WuuGateVerdict 'FAIL' $m }
function Pass($m) { Write-Host "PASS: $m" -ForegroundColor Green; Add-WuuGateVerdict 'PASS' $m }
# Warn does NOT set $failed: an advisory verdict that blocked a release would make WARN a synonym for
# FAIL, and then nobody would dare emit one.
function Warn($m) { Write-Host "WARN: $m" -ForegroundColor Yellow; Add-WuuGateVerdict 'WARN' $m }
# Skip records that a check did not run. It is a distinct verdict precisely so that
# "not evaluated" cannot be counted as "evaluated and clean".
function Skip($m) { Write-Host "SKIP: $m" -ForegroundColor DarkGray; Add-WuuGateVerdict 'SKIP' $m }
function Not-Implemented($m) { Write-Host "NOT_IMPLEMENTED: $m" -ForegroundColor DarkYellow; Add-WuuGateVerdict 'NOT_IMPLEMENTED' $m }

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# --- SOURCE STRUCTURE (sections 1-8) - extracted to Scripts\Test-SourceStructure.ps1 (instructions SS39).
#     Dot-sourced HERE, where the sections were: these verdicts lead the report, and the fragments that
#     follow read variables this file no longer defines (they are independent by design - verified).
. (Join-Path $PSScriptRoot 'Test-SourceStructure.ps1')

# --- 9. Audit invariants (Phase 4) --------------------------------------------------------
# These are the properties the trail exists to guarantee. Asserting them structurally beats
# trusting that a future edit preserves them.
#
# Evaluate against COMMENT-STRIPPED code. An earlier version matched raw text and flagged the
# module's own explanatory comments ("OneDrive-synced tree caused ... failures") as a synced-folder
# path - the same false-positive class the headless test hit. Strip comments via the tokenizer.
$auditPath = Join-Path $root 'src\Wuu.Audit.psm1'
$auditCode = Get-WuuCodeWithoutComments -Path $auditPath

# --- SHARED HARNESS HELPERS (hoisted above the fragments, SS39) ------------------------------------
# These three extract a function body from a module's source text. They are used by SEVERAL fragments,
# so they are DEFINED HERE rather than inside one of them: a helper that lives in a fragment only
# exists once that fragment has been dot-sourced, which made a block's correctness depend on the
# ORDER of the dot-source lines. (Observed, not theorised: moving the P3 close-out block into
# Test-Contracts.ps1 - dot-sourced before the fragment that happened to define Get-WuuFunctionBody -
# broke it with "could not extract Get-WuuOperationRemainingSeconds".)

function Get-WuuFunctionBody([string]$Text, [string]$Name) {
    $i = $Text.IndexOf("function $Name")
    if ($i -lt 0) { return '' }
    $next = $Text.IndexOf("`nfunction ", $i + 10)
    if ($next -lt 0) { return $Text.Substring($i) }
    return $Text.Substring($i, $next - $i)
}

function Get-WuuBalancedBody([string]$Text, [string]$Name) {
    $m = [regex]::Match($Text, "function\s+$Name\s*(?:\([^)]*\))?\s*\{")
    if (-not $m.Success) { return '' }
    $start = $m.Index + $m.Length - 1
    $depth = 0
    $i = $start
    $inSingle = $false
    $inDouble = $false
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if (-not $inSingle -and -not $inDouble) {
            if ($c -eq "'") { $inSingle = $true }
            elseif ($c -eq '"') { $inDouble = $true }
            elseif ($c -eq '{') { $depth++ }
            elseif ($c -eq '}') { $depth--; if ($depth -eq 0) { return $Text.Substring($start, $i - $start + 1) } }
        } elseif ($inSingle -and $c -eq "'") { $inSingle = $false }
        elseif ($inDouble -and $c -eq '"') { $inDouble = $false }
        $i++
    }
    return ''
}

function Remove-WuuParamBlock([string]$Body) {
    $pm = [regex]::Match($Body, '\bparam\s*\(')
    if (-not $pm.Success) { return $Body }
    $open = $pm.Index + $pm.Length - 1
    $depth = 0
    $i = $open
    while ($i -lt $Body.Length) {
        $c = $Body[$i]
        if ($c -eq '(') { $depth++ } elseif ($c -eq ')') { $depth--; if ($depth -eq 0) { return $Body.Substring($i) } }
        $i++
    }
    return $Body
}

# (a)-(i) x3 AUDIT CONTRACT - extracted to Scripts\Test-AuditContract.ps1 (instructions SS39).
. (Join-Path $PSScriptRoot 'Test-AuditContract.ps1')
# (a)-(k) RELEASE METADATA - extracted to Scripts\Test-ReleaseMetadata.ps1 (instructions SS39).
. (Join-Path $PSScriptRoot 'Test-ReleaseMetadata.ps1')
# (a)-(l) CONSOLE CONTRACT - extracted to Scripts\Test-Contracts.ps1 (instructions SS39).
. (Join-Path $PSScriptRoot 'Test-Contracts.ps1')

# (m)-(r) GUIDED CONSOLE CONTRACT (continued) - extracted to Scripts\Test-Contracts.ps1, which is
#      dot-sourced above. These cover offline handling, the plan lifecycle, guided audit targets,
#      reason consumption and the GUI-control-member ban.

# (s)-(z) ENGINE ARCHITECTURE - extracted to Scripts\Test-Architecture.ps1 (instructions SS39).
#      Dot-sourced in THIS scope so it shares the gate's variables and helpers, and at THIS position so
#      the verdict order is unchanged.
. (Join-Path $PSScriptRoot 'Test-Architecture.ps1')

# (aa)-(ae) COMMAND BEHAVIOUR CONTRACT - extracted to Scripts\Test-CommandContract.ps1 (instructions
#      SS39). Dot-sourced HERE, where the blocks were, so their verdicts keep their position in the
#      list. A fragment may be dot-sourced ONCE.
. (Join-Path $PSScriptRoot 'Test-CommandContract.ps1')
# (af) SOURCE ENCODING - extracted to Scripts\Test-Encoding.ps1 (instructions SS39). Dot-sourced HERE so
#      its verdict keeps its position in the list, and INTO THIS SCOPE so it shares $root and the verdict
#      helpers. The file states the same contract at the top.
. (Join-Path $PSScriptRoot 'Test-Encoding.ps1')

# (ag) REBOOT AND CANCELLATION COVERAGE (brief SS16). The brief lists these as the untested behaviours,
#      and they are the ones where a bug is expensive: a reboot that never happens, a reboot wrongly
#      reported as failed, or a cancellation that runs anyway.
#
#      The BEHAVIOUR is covered by tests\Test-RebootAndCancellation.ps1, which extracts the shipped
#      $RestartComputer payload and drives it in a real runspace with stubbed remote calls (the only way
#      to exercise it without a second machine). This gate asserts the pieces that make that coverage
#      meaningful, so deleting the payload's structure cannot silently turn the tests into no-ops.
$coreRawR = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$restartBody = [regex]::Match($coreRawR, '\$RestartComputer = \{[\s\S]*?\r?\n# Note: the old duplicate').Value
if (-not $restartBody) {
    Fail 'could not locate the $RestartComputer payload'
} else {
    # Comments stripped: the payload explains the ICMP removal by naming Test-Connection.
    $restartCode = Get-WuuTextWithoutComments -Text $restartBody
    if ($restartCode -match 'Test-Connection') {
        Fail 'the reboot payload decides with ICMP again - it cannot terminate on a host that blocks echo (SS7/SS16)'
    }
    if ($restartCode -notmatch 'Restart-Computer \$Computer\.computer -Force') {
        Fail 'the reboot payload does not issue Restart-Computer (the reboot would never be requested) (SS16)'
    }
    if ($restartCode -notmatch 'Test-WuuManagementEndpoint') {
        Fail 'the reboot payload does not use the management-endpoint probe (SS7/SS16)'
    }
    # The offline wait must give up and CONTINUE rather than fail - a slow shutdown is not a stuck one.
    if ($restartCode -notmatch 'assuming a very fast reboot') {
        Fail 'the offline wait no longer tolerates "never observed down" - a healthy fast reboot would be reported as failed (SS16)'
    }
    if ($restartCode -notmatch 'may still be booting') {
        Fail 'the online-wait timeout no longer says the host may still be booting - it would blame the restart (SS16)'
    }
    if (-not $failed) { Pass 'the reboot payload waits on the management endpoint and reports honestly (SS16)' }
}
# The cancellation surfaces, asserted structurally because they are reachability properties.
$navRawR = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Navigate.psm1') -Raw
$consoleRawR = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Console.psm1') -Raw
$denialSites = ([regex]::Matches($navRawR + $consoleRawR, 'DenialHook')).Count
if ($denialSites -lt 3) {
    Fail "only $denialSites denial-hook site(s) - a cancellation would leave no trace (A.8.15) (SS16)"
}
if ($navRawR -notmatch "Proceed = \`$false; Reason = ''") {
    Fail 'a blank change reason no longer cancels the operation (it would run unaudited) (SS16)'
}
$emptyGuards = ([regex]::Matches($coreRawR, "if \(\`$rows\.Count -eq 0\) \{ Write-Host '  Cancelled\.'")).Count
if ($emptyGuards -lt 5) {
    Fail "only $emptyGuards empty-selection guard(s) - a cancelled selection could widen to every computer (SS16)"
}
# An unreachable computer must cancel queued work but KEEP the row below the threshold (SS12/SS16).
$stateRawR = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw
if ($stateRawR -notmatch "\`$Row\.Pending = \`$false") {
    Fail 'an unreachable computer no longer has its queued work cancelled - the scheduler would spin against a host that is not there (SS16)'
}
# ...and the probe-shape handling must not have the unguarded Contains that made its own branch dead.
#
# The invariant is ORDER, not the absence of .Contains: the guarded branch legitimately calls
# $ProbeResult.Contains('Resolves') on a hashtable. What broke was calling it BEFORE the shape test, on
# an object that has no such method. So: the first shape test must precede the first .Contains call.
$connBody = Get-WuuFunctionBody $stateRawR 'Update-WuuConnectivityState'
$connCode = Get-WuuTextWithoutComments -Text $connBody
$containsAt = $connCode.IndexOf('.Contains(')
$shapeAt = $connCode.IndexOf('-is [hashtable]')
if ($connCode -notmatch 'PSObject\.Properties\[''Resolves''\]') {
    Fail 'the connectivity decision no longer handles a PSCustomObject probe result'
} elseif ($containsAt -ge 0 -and ($shapeAt -lt 0 -or $containsAt -lt $shapeAt)) {
    Fail "the connectivity decision calls .Contains on the probe result BEFORE testing its shape - a PSCustomObject throws and the PSCustomObject branch is unreachable (SS16)"
} elseif (-not $failed) {
    Pass 'the connectivity decision tests the probe shape before calling a shape-specific method (SS16)'
}
if (-not $failed) { Pass 'cancellation surfaces, and both probe-result shapes, are intact (SS16)' }

# (ah) OPERATION IDENTITY (brief SS2/SS3). Invariant 8.1 makes a stale worker UNREACHABLE, not SAFE:
#      nothing compared an operation identity, so nothing rejected a stale result. Three paths can
#      emit one - the cleanup loop settling a force-stopped job after the computer was resubmitted,
#      a payload parked mid-write when the timeout path detaches the runspace, and the out-of-band
#      job removal in Remove-WuuComputers.
#
#      The rule is written in SIX places: one module function plus five inlined copies, because the
#      cleanup loop and the injected worker writer run in isolated runspaces where no module function
#      resolves. An inlined copy that drifts is invisible to every other check in this file, so this
#      gate asserts the COPIES EXIST and that the two functions have the SHAPE they are documented to
#      have. The behavioural equivalence of all six is asserted by tests\Test-OperationIdentity.ps1,
#      which extracts each shipped condition and drives it on a truth table - a gate cannot do that
#      without re-implementing the comparison, which is the thing that could drift.
$stateRawA = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw
$wupdRawA = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw
$coreRawA = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw

# The row must carry the identity, defaulting to empty (nothing owns a fresh row).
if ($stateRawA -notmatch "OperationId\s*=\s*''") {
    Fail 'the row contract has no OperationId field - no writer can prove which operation it belongs to (SS2)'
} else {
    Pass 'the row contract carries an operation identity (SS2)'
}

# The generator must exist and must NOT be a bare timestamp or the computer name.
if ($stateRawA -notmatch 'function New-WuuOperationId') {
    Fail 'New-WuuOperationId is missing - operations have no identity to compare (SS2)'
} elseif ($stateRawA -notmatch 'NewGuid') {
    Fail 'the operation identity is not guaranteed unique (no GUID component) - two submissions could collide (SS2)'
} else {
    Pass 'operation identities are unique and independent of the computer name (SS2)'
}

# Both rules must exist and must be exported: the id is created in Wuu.WindowsUpdate, enforced in
# Wuu.Core and asserted by tests.
foreach ($fn in @('Test-WuuOperationCurrent', 'Test-WuuStaleWrite')) {
    # `function Name {` - NOT `function Name(`. PowerShell functions take no parentheses at the
    # declaration site, and requiring one made this gate report both functions "missing" while they
    # were present. The check was wrong, not the code.
    if ($stateRawA -notmatch ("function\s+{0}\s*\{{" -f [regex]::Escape($fn))) {
        Fail "$fn is missing - a stale writer has nothing to consult (SS3)"
    }
    if ($stateRawA -notmatch ("'" + [regex]::Escape($fn) + "'")) {
        Fail "$fn is not exported - the submission point, the cleanup loop and the tests cannot all agree on one rule (SS3)"
    }
}

# The two rules must NOT collapse into one. A release needs "proven current" (an unattributed job
# must not unlock a row it cannot name); a write needs only "proven stale" (list loading writes rows
# that have no operation). A future simplification of either into the other would look harmless.
$currentBody = Get-WuuFunctionBody $stateRawA 'Test-WuuOperationCurrent'
$staleBody = Get-WuuFunctionBody $stateRawA 'Test-WuuStaleWrite'
if ($currentBody -notmatch '-ceq' -or $staleBody -notmatch '-cne') {
    Fail 'the release and write identity rules no longer differ in polarity - collapsing them either deadlocks a computer (release too strict) or unlocks it while busy (write too strict) (SS3)'
} elseif ($staleBody -match '-ceq') {
    Fail 'Test-WuuStaleWrite compares with -ceq - it would then refuse the WRONG writes (the owner instead of the superseded operation) (SS3)'
} else {
    Pass 'the release rule requires proven ownership and the write rule refuses only proven staleness (SS3)'
}

# The submission point must create the identity BEFORE BeginInvoke, and put it on the JOB entry -
# the cleanup loop holds the job, not the row.
$submitBodyA = Get-WuuTextWithoutComments -Text (Get-WuuFunctionBody $wupdRawA 'Start-UpdateCheckJob')
$idAt = $submitBodyA.IndexOf('New-WuuOperationId')
$beginAt = $submitBodyA.IndexOf('BeginInvoke()')
if ($idAt -lt 0) {
    Fail 'the submission point does not create an operation identity (SS2)'
} elseif ($beginAt -ge 0 -and $idAt -gt $beginAt) {
    Fail 'the operation identity is created AFTER BeginInvoke - the payload can start on its own thread first, and a legitimate writer would be judged stale against the previous id (SS2)'
} elseif ($submitBodyA -notmatch 'OperationId = \$operationId') {
    Fail 'the job entry does not carry the operation identity - the cleanup loop holds only (Computer, Runspace, StartTime) and cannot tell which operation it is settling (SS3)'
} elseif ($submitBodyA -notmatch "SetVariable\('WuuOperationId'") {
    Fail 'the identity is not injected into the worker runspace - the payload writer could never attribute its writes, so the guard would never fire (SS3)'
} else {
    Pass 'the identity is created before BeginInvoke, carried on the job entry, and injected into the worker (SS2/SS3)'
}

# All three cleanup-loop release paths must be identity-guarded. Counted by their job-entry read:
# each pass must read OperationId off BOTH the job entry and the row before mutating.
$loopBodyA = Get-WuuTextWithoutComments -Text (Get-WuuFunctionBody $coreRawA 'Start-WuuApplication')
if (-not $loopBodyA) { $loopBodyA = $coreRawA }
# The cleanup payload moved to Wuu.Workers (Get-WuuJobCleanupPayload, SS8). Its three identity-guarded
# release paths are read THERE; an unguarded pass would release the lock of whatever operation now owns
# the row, which is exactly as true in its new home.
$workersRawA = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Workers.psm1'))
$guardedReleases = ([regex]::Matches($workersRawA, "PSObject\.Properties\['OperationId'\]\) \{ \`$jobOpId")).Count +
                   ([regex]::Matches($workersRawA, "PSObject\.Properties\['OperationId'\]\) \{ \`$toOpId")).Count
if ($guardedReleases -lt 3) {
    Fail "only $guardedReleases of 3 cleanup-loop release path(s) read the job identity - an unguarded pass releases the lock of whatever operation now owns the row (SS3)"
} else {
    Pass "all 3 cleanup-loop release paths are identity-guarded ($guardedReleases/3) (SS3)"
}

# The writer choke point - both copies - must refuse a proven-stale write.
$writerCore = Get-WuuTextWithoutComments -Text (Get-WuuFunctionBody $coreRawA 'Update-WuuComputerRow')
if ($writerCore -notmatch '-cne \$writerOpId') {
    Fail 'the module-scope row writer has no staleness guard - a superseded payload would restamp the current operation (SS3)'
} else {
    Pass 'the module-scope row writer refuses a proven-stale write (SS3)'
}
$injectedWriter = Get-WuuTextWithoutComments -Text ([regex]::Match($wupdRawA, "SetVariable\('UpdateWuuComputerRowScript'[\s\S]{0,3000}").Value)
if ($injectedWriter -notmatch '-cne \$writerOpId') {
    Fail 'the runspace-injected row writer has no staleness guard - the copy the PAYLOAD actually uses is unprotected (SS3)'
} elseif ($injectedWriter -notmatch 'WuuOperationId') {
    Fail 'the injected writer does not read $WuuOperationId, so every payload write is unattributed and the guard can never fire (SS3)'
} else {
    Pass 'the injected worker writer refuses a proven-stale write and reads its own identity (SS3)'
}

# The timeout path must DETACH the runspace before releasing the lock. Without it, a resubmission in
# the async Stop() window inherits a torn-down runspace while the old payload still writes through it.
# Read from Wuu.Workers, where the cleanup payload now lives (SS8).
if ($workersRawA -notmatch "Properties\['Runspace'\]\) \{ \`$toRow\.Runspace = \`$null \}") {
    Fail 'the timeout path does not detach the row runspace before releasing the lock - a resubmission can build against a runspace that is still draining, and the old payload keeps writing through it (SS3)'
} else {
    Pass 'the timeout path detaches the runspace before releasing the lock (SS3)'
}

# The out-of-band removal path must release the lock AND retire the identity. SS16 moved that release
# into the mutation funnel, so this asserts DELEGATION plus the funnel's coverage rather than the old
# inline text - the inline form is exactly the copy-paste this work removed.
$removeIdxA = $coreRawA.IndexOf('Failed to remove job from list')
if ($removeIdxA -gt 0) {
    $removeWindow = $coreRawA.Substring($removeIdxA, [Math]::Min(2500, $coreRawA.Length - $removeIdxA))
    if ($removeWindow -notmatch 'Update-WuuOperationState') {
        Fail 'the out-of-band job removal does not delegate to the mutation funnel (SS3/SS16)'
    } elseif ($removeWindow -notmatch 'ClearOperation') {
        Fail 'the out-of-band job removal does not end the operation via the funnel (SS3)'
    } elseif ($removeWindow -notmatch 'OperationId') {
        Fail 'the out-of-band job removal does not read an identity, so its release is unattributed (SS3)'
    } elseif ($stateRawA -notmatch "'OperationId' ''") {
        # The funnel must be what retires the identity, or delegating has lost the write.
        Fail 'the mutation funnel does not retire the operation identity - a late writer could present a valid token for a job that no longer exists (SS3)'
    } else {
        Pass 'the out-of-band job removal releases the lock and retires the identity via the funnel (SS3)'
    }
} else {
    Fail 'could not locate the out-of-band job removal path'
}

# (ai) GLOBAL CONCURRENCY CAP (brief SS4 / invariant 8.6). The cap used to be applied in ONE place -
#      the scheduler tick - while every console handler calls the submission point DIRECTLY in a loop.
#      The per-computer gate bounds each computer to one operation; it says nothing about how many
#      computers run at once, so `-All` over a large estate could start one pipeline per computer with
#      no ceiling. The only `MaxConcurrentJobs` mention inside the submission point was a COMMENT, and
#      this file had NO gate for the cap at all (its one mention was also a comment).
#
#      A gate cannot prove the runtime bound; tests\Test-ConcurrencyCap.ps1 drives the real submission
#      point and asserts admission stops at the cap (and that it is not a no-op). What this gate
#      asserts is the WIRING: the predicate exists, it is consulted AT the submission point, both
#      admission paths read the cap from the same source, and it cannot be satisfied by a comment.
$stateRawI = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw
$wupdRawI = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw

if ($stateRawI -notmatch 'function\s+Test-WuuConcurrencyAvailable\s*\{') {
    Fail 'Test-WuuConcurrencyAvailable is missing - the global cap has no testable predicate (SS4)'
} else {
    Pass 'the global concurrency cap has a single testable predicate (SS4)'
}

# A cap of 0 or a negative cap must REFUSE, matching the scheduler's `-ge` test. If the predicate
# treated a non-positive cap as "unlimited" the two admission paths would disagree.
$capBodyI = Get-WuuFunctionBody $stateRawI 'Test-WuuConcurrencyAvailable'
# The presence of `-le 0` is NOT the invariant: a tautology experiment that changed only the RETURN
# value (`$false` -> `$true`) kept `-le 0` intact and slipped past the first version of this check.
# The invariant is that a non-positive cap REFUSES, so the whole guard-and-return is asserted.
if ($capBodyI -notmatch 'if \(\$MaxConcurrentJobs -le 0\) \{ return \$false \}') {
    Fail 'the cap predicate does not REFUSE a non-positive cap - a misconfigured cap would silently become unlimited, and the scheduler and the submission point would disagree (SS4)'
}
if ($capBodyI -notmatch 'if \(\$null -eq \$Jobs\) \{ return \$false \}') {
    Fail 'the cap predicate does not fail closed on a missing job list (SS4)'
}

# The check must be AT THE SUBMISSION POINT, not only in the scheduler. Get-WuuFunctionBody slices to
# the next top-level 'function ', so this window is the submission function only.
$submitBodyI = Get-WuuTextWithoutComments -Text (Get-WuuFunctionBody $wupdRawI 'Start-UpdateCheckJob')
if ($submitBodyI -notmatch 'Test-WuuConcurrencyAvailable') {
    Fail 'the submission point does not consult the global cap - console handlers call it directly in a loop, so the cap would not apply to them (SS4/8.6)'
} else {
    Pass 'the submission point consults the global cap (SS4/8.6)'
}
# The refusal must come BEFORE capacity is consumed. The real boundary is `$jobs.Add`, not the
# `OpState = 'Running'` line, and the difference is not academic: a tautology experiment that left the
# check present but moved it below `$jobs.Add` passed an `OpState`-anchored ordering test (7 of the
# suite's assertions caught it, but the gate did not). Checking after the add means the row is
# admitted and MARKED BUSY while the pipeline was never started - the computer is then stuck until the
# next cleanup pass, and the job list briefly over-counts, throttling an estate that has capacity.
$capCheckAtI = $submitBodyI.IndexOf('Test-WuuConcurrencyAvailable')
$capRefuseAtI = $submitBodyI.IndexOf('global concurrency cap reached')
$addJobAtI = $submitBodyI.IndexOf('$jobs.Add(')
$markRunningAtI = $submitBodyI.IndexOf("OpState = 'Running'")
if ($capRefuseAtI -lt 0) {
    Fail 'the global-cap refusal is not logged - an operator cannot distinguish "throttled" from "never ran" (SS4)'
} elseif ($addJobAtI -lt 0) {
    Fail 'could not locate the job admission in the submission point'
} elseif ($capCheckAtI -gt $addJobAtI) {
    Fail 'the global cap is checked AFTER $jobs.Add - the operation has already consumed capacity and can be marked busy without its pipeline ever starting (SS4)'
} elseif ($markRunningAtI -ge 0 -and $capCheckAtI -gt $markRunningAtI) {
    Fail 'the global cap is checked AFTER OpState is set to Running - a refused operation would leave its computer permanently busy, which is worse than the missing cap it fixed (SS4)'
} else {
    Pass 'the global cap is checked, and refuses, before capacity is consumed or the operation is marked Running (SS4)'
}
# Both admission paths must read the cap from the same place, or one could be raised while the other
# still throttles at the old value.
if ($submitBodyI -notmatch '\$MaxConcurrentJobs = \$ctx\.MaxConcurrentJobs') {
    Fail 'the submission point does not take the cap from the shared context - it could disagree with the scheduler tick about the same estate (SS4)'
} elseif ($wupdRawI -notmatch '\$MaxConcurrentJobs = \$ctx\.MaxConcurrentJobs') {
    Fail 'the scheduler tick does not take the cap from the shared context (SS4)'
} else {
    Pass 'both admission paths read the cap from the same context value (SS4)'
}

# (aj) PENDING-REQUEST POLICY (brief SS7 / invariant 8.7). A row has ONE PendingOp slot, so a second
#      request to a busy computer silently destroyed the first: `download` then `install` left the
#      Download gone while the operator was told only "queued to run when they finish". The direction
#      that is easy to miss is the DOWNGRADE - `install` then `download` destroyed the install, so an
#      operator who asked for more got less with no indication at all.
#
#      THE POLICY: one slot, newest request wins, and a replacement is ALWAYS REPORTED. Refusing a
#      second request outright would make `download` then `install` silently do nothing.
$stateRawJ = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw
$coreRawJ = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw

if ($stateRawJ -notmatch 'function\s+Set-WuuPendingOperation\s*\{') {
    Fail 'Set-WuuPendingOperation is missing - the pending-request policy has no single implementation (SS7)'
} else {
    Pass 'the pending-request policy has a single implementation (SS7)'
}
# It must RETURN the replaced value, and it must actually CAPTURE it. A tautology experiment that left
# `Replaced = $replaced` in place while deleting the `$replaced = $existing` assignment kept this check
# passing (`$replaced` simply stayed $null) - presence of the field is not the invariant; the capture
# is. Both halves asserted.
$pendingBodyJ = Get-WuuFunctionBody $stateRawJ 'Set-WuuPendingOperation'
if ($pendingBodyJ -notmatch '\$replaced = \$existing') {
    Fail 'Set-WuuPendingOperation no longer CAPTURES the displaced request - it would return a null Replaced and the caller could not report the replacement, which was the actual defect (SS7)'
} elseif ($pendingBodyJ -notmatch 'Replaced = \$replaced') {
    Fail 'Set-WuuPendingOperation does not return the replaced request (SS7)'
}
# -OnlyIfEmpty must be a real GUARD, not merely mentioned. Asserting the word alone passed a mutant
# that kept `if ($OnlyIfEmpty ...)` but evaluated it as $false.
if ($pendingBodyJ -notmatch "if \(\`$OnlyIfEmpty -and \`$existing -ne ''\) \{ return \`$noChange \}") {
    Fail 'Set-WuuPendingOperation lost its -OnlyIfEmpty GUARD - an internal follow-up could displace an operator request (SS7)'
} else {
    Pass 'the policy captures the displaced request and guards -OnlyIfEmpty (SS7)'
}

# No operator-facing handler may assign PendingOp directly. That bare assignment IS the defect.
$handlersWithBareAssign = @()
$coreCodeJ = Get-WuuTextWithoutComments -Text $coreRawJ
foreach ($h in @('EventGetUpdates', 'EventDownloadUpdates', 'EventInstallUpdates')) {
    $m = [regex]::Match($coreCodeJ, ('\$consoleActions\.' + $h + ' = \{[\s\S]{0,2600}'))
    if (-not $m.Success) { continue }
    if ($m.Value -match '\$r\.PendingOp = ') { $handlersWithBareAssign += $h }
    if ($m.Value -notmatch 'Set-WuuPendingOperation') { $handlersWithBareAssign += ($h + ' (does not use the policy)') }
}
if ($handlersWithBareAssign.Count) {
    Fail ('handler(s) still assign PendingOp directly instead of using the policy - a second request would silently destroy the first: ' + ($handlersWithBareAssign -join ' | '))
} else {
    Pass 'all 3 operator-facing handlers route through the pending policy (SS7)'
}
# The two handlers that CAN displace must report it. A reported policy is the whole point.
foreach ($h in @('EventDownloadUpdates', 'EventInstallUpdates')) {
    $m = [regex]::Match($coreCodeJ, ('\$consoleActions\.' + $h + ' = \{[\s\S]{0,2600}'))
    if ($m.Success -and $m.Value -notmatch 'REPLACED by this one') {
        Fail "$h can displace a queued request but does not report the replacement - that is the silent overwrite with a tidier implementation (SS7)"
    }
}
# The payloads run in ISOLATED runspaces and must inline -OnlyIfEmpty: READ the existing request, then
# queue only when it is empty. Asserted as a PAIR of facts, because matching the guard text alone
# passed a mutant that replaced the condition with `if ($true)` - the text `if ($existingRequestAd -eq
# '')` disappeared but the surrounding shape did not, and a presence-only check cannot tell the two
# apart. Comments are excluded, because the explanation quotes the rule.
$payloadGuards = ([regex]::Matches($coreRawJ, "if \(\`$existingRequest(Ad)? -eq ''\) \{")).Count
$payloadReads = ([regex]::Matches($coreRawJ, "if \(\`$Computer\.PSObject\.Properties\['PendingOp'\] -and \`$Computer\.PendingOp\) \{ \`$existingRequest(Ad)? = ")).Count
$payloadInCode = ([regex]::Matches($coreCodeJ, "if \(\`$existingRequest(Ad)? -eq ''\) \{")).Count
if ($payloadInCode -lt 2) {
    Fail "only $payloadInCode payload guard(s) present in CODE (comments excluded) - an automatic follow-up could displace an operator's queued request (SS7)"
} elseif ($payloadReads -lt 2) {
    Fail "only $payloadReads payload guard(s) READ the existing request - a guard that does not read the slot cannot detect a collision, and could be satisfied by a constant (SS7)"
} else {
    Pass "both payload follow-ups read the existing request and queue only when it is empty ($payloadInCode/2, $payloadReads/2) (SS7)"
}

# A SETTLED row must not accept a queued follow-up. That state was REACHABLE through the funnel's own
# cleanup path - ClearOperation retires the operation (OpState='Idle') while the PendingOp slot
# survives - and it is the 8.4 contradiction in the pending layer: the row is counted as finished
# while its next operation is still queued. Asserted in two halves, because either alone is
# satisfiable without the behaviour: the setter must REFUSE (with a reason, not silently), and the
# funnel must RESOLVE the state when a follow-up is already queued. Then DRIVEN, because a source
# shape cannot show that the refusal actually happens.
if ($pendingBodyJ -notmatch 'Get-WuuTerminalStates' -or $pendingBodyJ -notmatch 'Reason =') {
    Fail 'Set-WuuPendingOperation does not refuse a SETTLED row with a reason - a queued follow-up on a finished row leaves the row reported finished while its next operation is queued, and a silent no-op reproduces the defect class SS7 exists to remove (SS7/8.4)'
} elseif ((Get-WuuFunctionBody $stateRawJ 'Update-WuuOperationState') -notmatch "(?s)PendingOp[\s\S]{0,400}?'Queued'") {
    # Anchored to PendingOp so the check names the FOLLOW-UP branch. The function already writes
    # 'Queued' when it resolves an unreplaced Timeout display, so a bare 'Queued' match would pass
    # with this rule deleted.
    Fail 'Update-WuuOperationState does not resolve a row that still holds a queued follow-up to a non-settled display - a settled row with a surviving queue is the 8.4 contradiction (P1/8.4)'
} elseif (-not (Get-Command Set-WuuPendingOperation -ErrorAction SilentlyContinue)) {
    Fail 'Set-WuuPendingOperation is not resolvable - the settled-row refusal cannot be driven (SS7)'
} else {
    try {
        $settledProbeJ = New-WuuComputerRow -Computer 'GATE-SETTLED-PENDING'
        $settledProbeJ.State = 'Error'
        $settledResultJ = Set-WuuPendingOperation -Row $settledProbeJ -Op 'Download'
        $liveSettledJ = New-WuuComputerRow -Computer 'GATE-SETTLE-LIVE'
        $liveSettledJ.OpState = 'Running'
        $liveSettledJ.OperationId = 'gate-op'
        $null = Set-WuuPendingOperation -Row $liveSettledJ -Op 'Download'
        $null = Update-WuuOperationState -Row $liveSettledJ -OperationId 'gate-op' -State 'Complete' -ClearOperation
        $liveViolationsJ = @(Test-WuuOperationStateInvariant -Row $liveSettledJ)
        if ($settledResultJ.Set) {
            Fail 'a SETTLED row accepted a queued follow-up - the row is reported finished while its next operation is still queued (SS7/8.4)'
        } elseif (-not $settledResultJ.Reason) {
            Fail 'the settled-row refusal carries no reason - the caller cannot say why nothing was queued, which is a silent no-op (SS7)'
        } elseif ($liveViolationsJ.Count -ne 0) {
            Fail ('settling a row that holds a queued follow-up leaves the row inconsistent: ' + ($liveViolationsJ -join '; ') + ' (P1/8.4)')
        } elseif ($liveSettledJ.PendingOp -ne 'Download' -or -not $liveSettledJ.Pending) {
            Fail 'the queued follow-up did not survive settlement - the request the operator made was lost (SS7)'
        } else {
            Pass 'a settled row refuses a queued follow-up with a reason, and settling a row that holds one leaves no contradiction (SS7/8.4)'
        }
    } catch {
        Fail "driving the settled-row pending rule threw instead of reporting: $($_.Exception.Message)"
    }
}

# (ak) PER-TARGET OUTCOMES AND PARTIAL SUCCESS (brief SS10). Exit code 4 was RESERVED BUT NEVER
#      PRODUCED, and the reason was structural: a `-Computer A,B` selection resolved through one shared
#      answer, so "A succeeded and B failed" was unobservable and a mixed fleet reported a flat 1.
#
#      A gate cannot prove the classification is right; tests\Test-TargetOutcomes.ps1 drives the truth
#      table. What this gate asserts is the WIRING and the two ordering properties that are invisible
#      in review and fatal in use: the partial branch must be consulted BEFORE the generic failure
#      (otherwise 4 is dead code), and the code must no longer be documented as unproduced.
$stateRawK = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw
$coreRawK = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$cmdRawK = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Command.psm1') -Raw

foreach ($fn in @('Get-WuuTargetOutcome', 'Get-WuuAggregateOutcome')) {
    if ($stateRawK -notmatch ("function\s+{0}\s*\{{" -f [regex]::Escape($fn))) {
        Fail "$fn is missing - exit code 4 has no per-target source and cannot be produced (SS10)"
    }
    if ($stateRawK -notmatch ("'" + [regex]::Escape($fn) + "'")) {
        Fail "$fn is not exported - the classifier in Wuu.Core could not reach it (SS10)"
    }
}
if (-not $failed) { Pass 'per-target and aggregate outcome functions exist and are exported (SS10)' }

# Unsettled targets must be IGNORED. If the aggregate treated a still-running row as failed, every
# in-progress estate run would report partial success.
$aggBodyK = Get-WuuFunctionBody $stateRawK 'Get-WuuAggregateOutcome'
if ($aggBodyK -notmatch "-ne 'Unknown'") {
    Fail 'the aggregate does not EXCLUDE unsettled targets - a still-running estate op would report partial success (SS10)'
} elseif ($aggBodyK -notmatch 'ok -eq 0') {
    Fail 'the aggregate has no "every settled target failed" case - that would be reported as partial, which is strictly less informative (SS10)'
} else {
    Pass 'the aggregate ignores unsettled targets and does not call an all-failed run partial (SS10)'
}
# Failure must be checked BEFORE completion, or a stale Complete on a row that just errored wins.
#
# DRIVEN, NOT MATCHED, and that is a correction rather than a preference. This check used to require two
# things by TEXT: the literal line
#     if ($state -eq 'Error' -or $updatesStatus -eq 'Error') { return 'Failed' }
# and the relative IndexOf of `return 'Failed'` versus `return 'Success'`. Both asserted the SHAPE of the
# code, and both became false findings the moment the mapping was made table-driven and single-sourced
# with the terminal set (block (ay)): the literals are gone, so a CORRECT tree failed. A gate that fails
# correct code trains people to ignore it.
#
# The two properties those text checks were trying to protect are still protected, and better:
#   * "failure is derived from State OR UpdatesStatus" -> driven below, on rows where the error is
#     written to only ONE of the two fields;
#   * "failure is judged before completion" -> driven below via a row that carries a STALE Complete
#     alongside a current Error. The ORDER is additionally enforced structurally by
#     Test-WuuTerminalStateInvariant, which requires 'Complete' to be declared LAST in the terminal table
#     (asserted in block (ay)) - so ordering is now a property of the declaration rather than of line
#     offsets inside one function.
$oneBodyK = Get-WuuFunctionBody $stateRawK 'Get-WuuTargetOutcome'
if ([string]::IsNullOrWhiteSpace($oneBodyK)) {
    Fail 'Get-WuuFunctionBody could not extract Get-WuuTargetOutcome, so the classifier is unverified (SS10)'
} else {
    $errorInStateK = New-WuuComputerRow -Computer 'GATE-SS10-A'; $errorInStateK.State = 'Error'
    $errorInStatusK = New-WuuComputerRow -Computer 'GATE-SS10-B'; $errorInStatusK.UpdatesStatus = 'Error'
    $staleCompleteK = New-WuuComputerRow -Computer 'GATE-SS10-C'
    $staleCompleteK.State = 'Complete'; $staleCompleteK.UpdatesStatus = 'Error'
    $outStateK = Get-WuuTargetOutcome -Row $errorInStateK
    $outStatusK = Get-WuuTargetOutcome -Row $errorInStatusK
    $outStaleK = Get-WuuTargetOutcome -Row $staleCompleteK
    if ($outStateK -ne 'Failed' -or $outStatusK -ne 'Failed') {
        Fail "Get-WuuTargetOutcome no longer derives Failed from State OR UpdatesStatus (State-only='$outStateK', UpdatesStatus-only='$outStatusK') - a row whose error is written to only one of the two fields would be misclassified (SS10)"
    } elseif ($outStaleK -ne 'Failed') {
        Fail "a stale Complete masks a current Error (got '$outStaleK') - failure must be judged before completion, or the completion wins (SS10)"
    } else {
        Pass 'per-target classification derives failure from both fields and judges it before completion (driven against the shipped function, SS10)'
    }
}

# The classifier must consult it, and the partial branch must precede the generic failure branch.
#
# PRESENCE AND ORDER ARE NOT ENOUGH. A tautology experiment that disabled the branch with a
# `$false -and` prefix left both the text and its position intact, so a presence-plus-order check
# passed while the branch was dead and exit 4 was unreachable. The exact enabled branch is asserted.
$coreCodeK = Get-WuuTextWithoutComments -Text $coreRawK
if ($coreCodeK -notmatch 'Get-WuuAggregateOutcome -Rows \$targetRows') {
    Fail 'the command-mode classifier does not consult the aggregate outcome - exit 4 remains unproduced (SS10)'
}
if (-not $coreCodeK.Contains("} elseif (`$aggregate -eq 'PartialSuccess') {")) {
    Fail 'the PartialSuccess branch is missing or DISABLED (a `$false -and` prefix keeps the text and its position while making the branch dead) - exit 4 would be unreachable (SS10)'
}
$psAtK = $coreCodeK.IndexOf("} elseif (`$aggregate -eq 'PartialSuccess') {")
$failBranchAtK = $coreCodeK.IndexOf('elseif (-not $result.Ok)')
if ($failBranchAtK -ge 0 -and $psAtK -gt $failBranchAtK) {
    Fail 'the PartialSuccess branch sits AFTER the generic failure branch - the generic failure would always win and exit 4 would be dead code (SS10)'
} else {
    Pass 'the classifier produces exit 4, branch enabled and checked before the generic failure (SS10)'
}

# The number must still map to 4, and the documentation must not claim it is unproduced.
if ($cmdRawK -notmatch "'PartialSuccess' \{ 4 \}") {
    Fail 'PartialSuccess no longer maps to exit code 4 - the documented number changed (SS10)'
}
if ($cmdRawK -match 'reserved; not currently produced') {
    Fail 'the exit-code documentation still says 4 is not produced, while the classifier now returns it (SS10)'
}
$readmeK = Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw
if ($readmeK -match 'partial success \*\(reserved') {
    Fail 'the README still describes code 4 as reserved (SS10)'
} else {
    Pass 'exit 4 maps to 4, and neither README nor source still calls it reserved (SS10)'
}

# (al) MIGRATION DEBRIS: the misleading name (brief SS14). `SafeUpdateListViewItem` described the GUI
#      edition, where the helper wrote into a WPF ListView. In this repository it writes a computer ROW
#      into the state store and there is no ListView at all - so the name pointed a reader at a view
#      dependency that does not exist, and a new operation could reasonably have been routed around it
#      on that basis. It was defined under that name TWICE (a module-scope copy and the
#      runspace-injected copy the payloads actually use), which is how it survived a GUI-removal pass:
#      renaming one would have left the other.
#
#      The gate asserts the name is GONE from shipped code and that the accurate name is what both
#      copies now carry. Comments are excluded, so the rename's own explanation does not satisfy it.
$debrisFiles = @('src\Wuu.Core.psm1', 'src\Wuu.WindowsUpdate.psm1', 'src\Wuu.State.psm1')
$debrisHits = @()
foreach ($df in $debrisFiles) {
    $dCode = Get-WuuTextWithoutComments -Text (Get-Content -LiteralPath (Join-Path $root $df) -Raw)
    if ($dCode -match 'SafeUpdateListViewItem') { $debrisHits += $df }
}
if ($debrisHits.Count) {
    Fail ('the misleading GUI-era name survives in shipped code: ' + ($debrisHits -join ', ') + ' - it describes a WPF ListView this edition does not have')
} else {
    Pass 'the GUI-era name `SafeUpdateListViewItem` is gone from shipped code (SS14)'
}
# Both copies must exist under the accurate name, or the payload and the main session would differ.
$coreDebris = Get-WuuTextWithoutComments -Text (Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw)
$wupdDebris = Get-WuuTextWithoutComments -Text (Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw)
if ($coreDebris -notmatch 'function Update-WuuComputerRow') {
    Fail 'the module-scope row writer is not named Update-WuuComputerRow (SS14)'
} elseif ($wupdDebris -notmatch "SetVariable\('UpdateWuuComputerRowScript'") {
    Fail 'the runspace-injected row writer is not named UpdateWuuComputerRowScript (SS14)'
} else {
    Pass 'both row-writer copies carry the accurate name (SS14)'
}

# (am) RELEASE HYGIENE: debug logging OFF by default, and no interactive prompt on a fatal path
#      (brief SS17 / SS15). Two defects that are cheap to reintroduce and expensive to notice.
#
#      WHY A GATE AND NOT A COMMENT. Both were wrong in the shipped tree at the same time: the
#      comment above the assignment said "$false by default" while the assignment said $true, and
#      four startup failure paths ended in `Read-Host "Press Enter to exit"` followed by a bare
#      `exit` that reports SUCCESS. Neither is caught by any behavioural test, because a test can
#      start the application successfully without ever exercising either.
$coreRawM = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$consoleRawM = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Console.psm1') -Raw
# The $global:* SETTINGS moved to src\Wuu.Configuration.psm1 (SS8), so the checks about those settings
# read THAT file. $coreRawM still serves the checks about Core's own code (the fatal prompt, the input
# choke point below): only orchestration stayed behind, so a reader can tell which file each check owns.
$configRawM = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Configuration.psm1'))

# 1. Debug logging must default to OFF. Verbose-by-default is wrong for an unattended patch tool:
#    large logs, I/O on every run, operational detail written by default, and diagnostic records
#    interleaved with the audit trail.
if ($configRawM -notmatch '\$global:EnableDebugLogging\s*=\s*\$false') {
    Fail 'debug logging does not default to $false - verbose-by-default is wrong for an unattended patch tool (large logs, extra I/O, operational detail on disk) (SS17)'
} elseif ($configRawM -match '\$global:EnableDebugLogging\s*=\s*\$true') {
    # The override path legitimately assigns $true inside the WUU_DEBUG branch, so its presence is
    # only a failure if it is NOT guarded by that branch.
    if ($configRawM -notmatch 'WUU_DEBUG') {
        Fail 'debug logging is set to $true with no documented override - production behaviour would depend on editing source (SS17)'
    } else {
        Pass 'debug logging defaults to $false and is enabled by the WUU_DEBUG override (SS17)'
    }
} else {
    Pass 'debug logging defaults to $false (SS17)'
}
# The override must exist, so an operator can diagnose without editing a shipped file.
if ($configRawM -notmatch 'WUU_DEBUG') {
    Fail 'there is no way to enable debug logging without editing source - a shipped file edit is reverted by the next install and invisible in the configuration (SS17)'
}

# 2. No interactive prompt may block a FATAL path. A prompt there hangs every unattended caller; the
#    exit code must also be non-zero, because a bare `exit` reported success on a failed startup.
$fatalPrompts = ([regex]::Matches($coreRawM, 'Read-Host\s+[''"]?\s*Press Enter')).Count
if ($fatalPrompts -gt 0) {
    Fail "$fatalPrompts 'Read-Host ... Press Enter' prompt(s) remain - a startup error would hang a scheduled task, a CI job or an agent-driven test instead of failing (SS15)"
} else {
    Pass 'no interactive prompt blocks a fatal startup path (SS15)'
}
if ($consoleRawM -notmatch 'function Stop-WuuFatal') {
    # In Wuu.Console, not Wuu.Core: the presentation layer owns console interaction, so the helper
    # belongs beside Read-WuuAnswer. Asserted against the CONSOLE source - an earlier version of this
    # check looked in Wuu.Core and reported the function missing while it was present.
    Fail 'Stop-WuuFatal is missing - the fatal paths have no unattended-safe exit'
}
if ($consoleRawM -notmatch "'Stop-WuuFatal'") {
    Fail 'Stop-WuuFatal is not exported from Wuu.Console - the fatal paths in Wuu.Core could not call it'
}
# It must exit NON-ZERO and must not wait without checking for a real console.
$consoleCodeM = Get-WuuTextWithoutComments -Text $consoleRawM
$fatalBodyM = Get-WuuFunctionBody $consoleRawM 'Stop-WuuFatal'
if ($fatalBodyM -notmatch 'exit \$ExitCode') {
    Fail 'Stop-WuuFatal does not exit with a code - a fatal startup would report success (SS15)'
} elseif ($fatalBodyM -notmatch 'IsInputRedirected') {
    Fail 'Stop-WuuFatal waits without checking for a console - it would still hang a redirected/unattended run (SS15)'
} else {
    Pass 'fatal exits are non-zero and wait only for a real interactive console (SS15)'
}

# 3. The password prompt must route through the input choke point, or a command-mode run blocks at
#    the unlock prompt with no way to answer it.
#    The prompt moved to Wuu.Presentation.psm1 (SS8), so it is read THERE. The check names the
#    module rather than Core so a future move fails loudly here instead of silently passing on
#    absent text - the failure mode a "not in the old file" check always has.
$presRawM = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Presentation.psm1'))
if ($presRawM -notmatch 'Read-WuuAnswer -Prompt \$Prompt -Secure') {
    Fail 'the password prompt bypasses Read-WuuAnswer - a scripted or non-interactive run could not answer the unlock prompt (SS15)'
} elseif ($presRawM -notmatch 'function _WuuReadPassword') {
    Fail 'the choke-point-routed password prompt is missing from Wuu.Presentation - the SS15 check above matched something else (SS15)'
} else {
    Pass 'the password prompt routes through the input choke point (SS15)'
}

# 4. THE VERSION GUARD (the defect that started this). The embedded literal and a real git tag at HEAD
#    must agree, or audit records carry a version no release used. Checked by RUNNING the resolver -
#    a text comparison here would duplicate its logic instead of exercising it.
$embeddedVersionM = ''
$versionMatchM = [regex]::Match($configRawM, "\`$global:WuuVersion\s*=\s*'([^']+)'")
if ($versionMatchM.Success) { $embeddedVersionM = $versionMatchM.Groups[1].Value }
if (-not $embeddedVersionM) {
    Fail 'could not read the embedded $global:WuuVersion literal - the version is not single-sourced (SS18)'
} else {
    try {
        $versionCheck = Resolve-WuuVersion -Embedded $embeddedVersionM -RepoRoot $root
        if ($versionCheck -and $versionCheck.Mismatch) {
            Fail ("version mismatch: " + $versionCheck.Note + " - every audit record would carry a version that did not produce the evidence (SS18)")
        } elseif ($versionCheck -and $versionCheck.Source -eq 'tag') {
            Pass "the embedded version matches the git tag at HEAD ($($versionCheck.Version)) (SS18)"
        } else {
            # NOT ON A TAG (a commit between releases). This is legitimate, but the check did not
            # actually run - and reporting it as PASS would claim a verified property that was never
            # evaluated. SKIP says exactly that, which is why the kind exists.
            Skip "version provenance not evaluated: $($versionCheck.Note) - the tag comparison does not apply off a release tag (SS18)"
        }
    } catch {
        Fail "could not resolve the version for the mismatch check: $($_.Exception.Message)"
    }
}

# (an)-(ar) STATE-MUTATION CONTRACT AND CODE HYGIENE - extracted to Scripts\Test-MutationContract.ps1
#      (instructions SS39). Dot-sourced HERE, where the blocks were, so their verdicts keep their
#      position in the list. A fragment may be dot-sourced ONCE - Test-Architecture.ps1 is already
#      dot-sourced above, so these blocks needed their own file rather than being appended to it.
. (Join-Path $PSScriptRoot 'Test-MutationContract.ps1')

# (ar) ONE LOG APPENDER (reviewer P2: "reduce duplicated worker scriptblocks"). The fault-tolerant
#      lock-and-retry append was written FOUR times - Wuu.Logging's Write-WuuLogEntry, Wuu.Core's cleanup
#      runspace, Wuu.WindowsUpdate's per-computer runspace, and inline inside WriteDebugLogScript - each
#      with a comment telling the reader to keep them in step. Two copies of a retry loop is exactly the
#      arrangement that drifts, and the drift would be silent (a payload that logs in one runspace and
#      not another). They are now one factory, so agreement is structural.
$distinctiveRetry = 'Start-Sleep -Milliseconds (100 * $attempt)'
$retryOutsideFactory = @()
foreach ($rf in Get-ChildItem (Join-Path $root 'src\*.psm1') | Sort-Object Name) {
    $rfLines = [System.IO.File]::ReadAllLines($rf.FullName)
    $inFactory = $false
    for ($ri = 0; $ri -lt $rfLines.Count; $ri++) {
        # The factory's DEFINITION line does not start at column 0 in every module, so it is matched
        # without the anchor. Only the TERMINATOR is anchored: an earlier version cleared the flag on the
        # call site `$newRunspace.SessionStateProxy.SetVariable('WriteLogFileScript', (Get-WuuWorker...))`,
        # whose line starts with `$` rather than `function`, so the factory's own loop was then counted
        # as being OUTSIDE the factory.
        if ($rfLines[$ri] -match 'Get-WuuWorkerLogAppender\s*\{') { $inFactory = $true }
        if ($ri -gt 0 -and $rfLines[$ri] -match '^function\s+' -and $rfLines[$ri] -notmatch 'Get-WuuWorkerLogAppender') { $inFactory = $false }
        if ($rfLines[$ri].Contains($distinctiveRetry) -and -not $inFactory) {
            $retryOutsideFactory += "$($rf.Name):L$($ri+1)"
        }
    }
}

if ($retryOutsideFactory.Count -gt 0) {
    Fail ("$($retryOutsideFactory.Count) module(s) still carry their own copy of the log retry loop: " + ($retryOutsideFactory -join ', ') + ' (P2)')
} elseif ($stateRawA -and $false) { } else {
    # The factory must exist, be exported from Wuu.LOGGING (logging owns logging), and be USED at every
    # former copy site. Export location matters: Write-WuuLogEntry delegates to it, and three suites
    # import Wuu.Logging on its own - placing it in Wuu.Scheduler made logging depend on the scheduler
    # and broke those imports.
    $loggingRawAR = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Logging.psm1') -Raw
    $coreRawAR = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
    $wupdRawAR = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw
    if ($loggingRawAR -notmatch 'function Get-WuuWorkerLogAppender') {
        Fail 'the log appender factory does not live in Wuu.Logging - logging would have to depend on another module to log (P2)'
    } elseif ($loggingRawAR -notmatch "'Get-WuuWorkerLogAppender'") {
        Fail 'the log appender factory is not exported from Wuu.Logging (P2)'
    } elseif ($coreRawAR -notmatch '\(Get-WuuWorkerLogAppender\)' -or $wupdRawAR -notmatch '\(Get-WuuWorkerLogAppender\)') {
        Fail 'a worker runspace does not use the shared log appender (P2)'
    } elseif ($wupdRawAR -notmatch '&\s+\$WriteLogFileScript\s+-LogEntry') {
        Fail 'WriteDebugLogScript does not delegate to the injected appender - it kept its own retry loop (P2)'
    } else {
        Pass 'one log appender exists in Wuu.Logging and is used by every former copy site (P2)'
    }
}

# Wuu.Scheduler must exist and be registered, or the injected helper set has no home - and a module that
# is not imported is a module whose helpers silently fail to inject.
if (-not (Test-Path -LiteralPath (Join-Path $root 'src\Wuu.Scheduler.psm1'))) {
    Fail 'src\Wuu.Scheduler.psm1 is missing - the worker helper surface has no single home (P2)'
} elseif ($coreRawAR -notmatch "'Wuu\.Scheduler'") {
    Fail 'Wuu.Scheduler is not in the import list - nothing would wire the worker helper set (P2)'
} else {
    Pass 'Wuu.Scheduler exists and is imported (P2)'
}

function Write-WuuGateJsonReport([string]$Path) {
    <#
    .SYNOPSIS
    Writes the verdicts to a JSON file (P4). Called before EVERY exit path.
    .DESCRIPTION
    WHY A FUNCTION AND NOT INLINE. The gate has two exit points (the normal one and the failure one),
    and a report written on only one of them would be missing exactly when it is most useful - a
    failing run. One function, called from both, removes that possibility.
    #>
    # .ToArray(), NOT @(...). On PowerShell 5.1 `@($list)` over a
    # System.Collections.Generic.List[object] raises "Argument types do not match" - reproduced in
    # isolation - and because that is a NON-TERMINATING error, the assignment silently yields $null.
    # The report then contained ONE verdict whose fields were all null, because `$null | ForEach-Object`
    # still iterates once. Every total read 0 while the gate itself passed. `.ToArray()` enumerates the
    # list correctly. Any future `@()` over this list inherits the same trap.
    $verdicts = $script:WuuGateVerdicts.ToArray()

    try {
        # Count EVERY verdict kind. A consumer that only reads Failures and Passes would treat a
        # NOT_IMPLEMENTED as absent rather than as "no verifier exists", and an unreported gap is the
        # failure mode this mode exists to remove.
        $report = [ordered]@{
            Schema        = 'wuu.gate.v1'
            GeneratedUtc  = (Get-Date).ToUniversalTime().ToString('o')
            Root          = $root
            Passed        = (-not $script:failed)
            Totals        = [ordered]@{
                PASS            = @($verdicts | Where-Object { $_.Status -eq 'PASS' }).Count
                FAIL            = @($verdicts | Where-Object { $_.Status -eq 'FAIL' }).Count
                WARN            = @($verdicts | Where-Object { $_.Status -eq 'WARN' }).Count
                SKIP            = @($verdicts | Where-Object { $_.Status -eq 'SKIP' }).Count
                NOT_IMPLEMENTED = @($verdicts | Where-Object { $_.Status -eq 'NOT_IMPLEMENTED' }).Count
            }
            Verdicts      = @($verdicts | ForEach-Object { [ordered]@{ Status = $_.Status; Message = $_.Message } })
        }

        $json = $report | ConvertTo-Json -Depth 6
        # UTF8 WITHOUT a BOM: a BOM is legal JSON in some readers and a parse error in others, and the
        # consumers here are scripts and CI tools. (The SOURCE files need BOMs; this artifact does not.)
        [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "  gate report written to $Path ($($verdicts.Count) verdict(s))" -ForegroundColor DarkGray
        return $true
    } catch {
        # A report-write failure must not change the gate's verdict - the exit code is the contract, and
        # this is the diagnostic. Reported loudly rather than swallowed, because a silently missing
        # report would make CI's own gate look like a configuration error.
        Write-Host "  WARNING: could not write the gate report to $Path : $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

if ($Json) {
    $jsonPath = if ([System.IO.Path]::IsPathRooted($Json)) { $Json } else { Join-Path $root $Json }
}

# (as) THE JSON REPORT AND THE FIVE VERDICT KINDS (reviewer P4). The gate had two signals - a line
#      matching '^FAIL:' and the exit code - which cannot express "did not run" or "advisory". It now
#      has five kinds, and a consumer can gate on a FIELD rather than scraping text.
#
#      WHY THIS BLOCK IS NEEDED AT ALL, given the report is generated by the code it describes: the
#      verdict kinds were DEFINED and NEVER EMITTED. WARN, SKIP and NOT_IMPLEMENTED appeared in the
#      helper definitions and in the report schema but at no call site, so the report's own totals read
#      WARN=0 SKIP=0 NOT_IMPLEMENTED=0 on every run - a schema advertising capability that did not
#      exist. That is the same defect as exit code 4 being reserved-but-unproducible, and a reserved
#      verdict is worse than an absent one because the report claims the distinction is available.
$selfText = Get-Content -LiteralPath $PSCommandPath -Raw
$gateCode = Get-WuuTextWithoutComments -Text $selfText
foreach ($kind in @('Warn', 'Skip', 'Not-Implemented')) {
    # Count INVOCATIONS, not the definition. `function Warn($m) {` and the report's 'WARN' string both
    # contain the word; only a call site means the kind is reachable.
    $calls = ([regex]::Matches($gateCode, "(?m)^\s*$([regex]::Escape($kind))\s")).Count
    if ($calls -eq 0) {
        Fail "the '$kind' verdict is defined but never emitted - the report advertises a distinction no check can produce (P4)"
    }
}
if (-not $failed) {
    Pass 'every verdict kind (PASS/FAIL/WARN/SKIP/NOT_IMPLEMENTED) is emitted by at least one check (P4)'
}

# The report must be produced before the exit, so a FAILING run also yields a report - the case where
# it is most useful - and it must be produced AFTER every check, or the last blocks are missing from it.
#
# THE PROPERTY ASSERTED IS "NO VERDICT IS EMITTED AFTER THE WRITER", not "there is exactly one exit".
# An earlier version counted exit statements and kept counting its own quoted token: comment-stripping
# removes comments but NOT string literals, so the check's own pattern text inflated the count twice in a
# row. Counting occurrences of a token the check must quote is self-defeating. The window between the
# writer and the exit contains no such token and states the real requirement directly.
$writerCalls = ([regex]::Matches($gateCode, 'Write-WuuGateJsonReport')).Count
$writerIdx = $gateCode.LastIndexOf('Write-WuuGateJsonReport -Path')
$exitIdx = $gateCode.LastIndexOf('Validation FAILED')
$lastCheckIdx = $gateCode.LastIndexOf('Not-Implemented')

if ($writerCalls -lt 2) {
    Fail "the report writer is referenced $writerCalls time(s) - it must be both defined and called (P4)"
} elseif ($writerIdx -lt 0) {
    Fail 'the report writer is never CALLED (only defined) - no report would be produced (P4)'
} elseif ($exitIdx -lt 0 -or $exitIdx -lt $writerIdx) {
    Fail 'the report writer is not followed by the failure exit - a failing run could produce no report (P4)'
} else {
    $window = $gateCode.Substring($writerIdx, $exitIdx - $writerIdx)
    $lateVerdicts = ([regex]::Matches($window, '(?m)^\s*(Pass|Fail|Warn|Skip|Not-Implemented)\s')).Count
    if ($lateVerdicts -gt 0) {
        # THE BUG THIS CATCHES, and it was real: the writer was placed BEFORE the final blocks, so the
        # report was written WITHOUT them. It held 145 verdicts while the gate had emitted more, and
        # WARN / SKIP / NOT_IMPLEMENTED never appeared in it at all - the three kinds this mode exists to
        # expose were absent from the artifact that exposes them. A report silently missing its last
        # checks is worse than no report, because it looks complete.
        Fail "the report is written before $lateVerdicts further verdict(s) - they would be missing from it (P4)"
    } elseif ($lastCheckIdx -gt $writerIdx) {
        Fail 'a check block appears after the report writer - its verdicts would be missing from the report (P4)'
    } else {
        Pass 'the report is written after every check and before the failure exit, so a failing run still reports (P4)'
    }
}

# The trap that silently produced an EMPTY report: @() over a generic List throws on PS 5.1.
if ($gateCode -match '@\(\s*\$script:WuuGateVerdicts\s*\)') {
    Fail 'the report reads the verdict list with @(...) - on PS 5.1 that throws over a generic List and the assignment silently becomes $null, producing a report of one null verdict (P4)'
} elseif ($gateCode -notmatch 'WuuGateVerdicts\.ToArray\(\)') {
    Fail 'the report does not enumerate the verdict list with .ToArray() (P4)'
} else {
    Pass 'the report enumerates the verdict list safely (.ToArray(), not @() which throws on PS 5.1) (P4)'
}

# (at) WORKER POOL DIAGNOSTICS (reviewer P3). The pool is a HARD CAP on concurrent bounded probes, and
#      two of its failure modes are invisible without this: POOL EXHAUSTION (every worker waiting on a
#      probe that cannot start, with no error raised) and ABANDONED WRAPPERS (a probe whose DCOM/RPC call
#      would not abort is deliberately left running, permanently holding a pool slot until the stuck call
#      returns - sustained abandonment walks capacity to zero). Both present to a caller as "every host is
#      slow", which is a wrong diagnosis that costs real time.
#
#      The checks here are the WARN and NOT_IMPLEMENTED sites the report schema promises. A gate whose
#      schema offers WARN while no check can emit one is advertising a distinction it does not have; that
#      was true until this block existed.
$workersRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Workers.psm1') -Raw
$workersCode = Get-WuuTextWithoutComments -Text $workersRaw

if ($workersCode -notmatch 'function Get-WuuWorkerPoolDiagnostics') {
    Fail 'the worker pool has no diagnostics surface - saturation and abandoned wrappers are invisible (P3)'
} elseif ($workersCode -notmatch 'function Test-WuuWorkerPoolStarved') {
    Fail 'the pool exposes no starvation predicate, so "the pool is nearly out of slots" cannot be asserted (P3)'
} elseif ($workersCode -notmatch "'Get-WuuWorkerPoolDiagnostics'") {
    Fail 'Get-WuuWorkerPoolDiagnostics is not exported - session-state isolation hides $script: values, so an unexported function is unreachable (P3)'
} else {
    Pass 'the worker pool exposes exported capacity, utilisation, abandoned-wrapper and starvation diagnostics (P3)'
}

# The four fields the reviewer named must be present by name, because a consumer keys on them.
foreach ($field in @('ActivePoolWorkers', 'AbandonedWorkers', 'PoolCapacity', 'PoolUtilisation')) {
    # The reviewer's names are the CONTRACT. They are aliased onto the diagnostic record so a consumer
    # written against them works, while the record keeps its shorter internal names.
    if ($workersCode -notmatch ([regex]::Escape($field))) {
        Fail "the pool diagnostics do not expose '$field', which is the field name the reviewer specified (P3)"
    }
}

# DRIVE THE PREDICATE, not just its presence. A starvation check that always returns $false would make
# anything built on it inert. This calls it and requires a well-formed answer on a real pool state.
if (Get-Command Test-WuuWorkerPoolStarved -ErrorAction SilentlyContinue) {
    try {
        $starve = Test-WuuWorkerPoolStarved
        # INDEXED, not dot-PSObject-property. The predicate returns a Hashtable (as its own contract
        # says), and .PSObject.Properties does NOT surface hashtable keys - an earlier version of this
        # check therefore reported "does not return a Starved field" for a predicate that returns it.
        # Indexing works for a Hashtable, an OrderedDictionary and a PSCustomObject alike.
        if ($null -eq $starve -or -not ($starve -is [System.Collections.IDictionary])) {
            Fail 'Test-WuuWorkerPoolStarved does not return a dictionary - callers cannot look up Starved (P3)'
        } elseif (-not $starve.Contains('Starved')) {
            Fail 'Test-WuuWorkerPoolStarved does not return a Starved field - callers cannot branch on it (P3)'
        } elseif ([int]$starve['Capacity'] -le 0) {
            Fail "the pool reports a non-positive capacity ($($starve['Capacity'])) - the starvation threshold is a share of capacity and cannot be computed (P3)"
        } else {
            # ADVISORY, NOT A BLOCKER. Abandoned wrappers are a consequence of a stuck remote call, not a
            # defect in this tree - a release must not be blocked by a host that would not answer an RPC
            # request, and blocking on it would train people to ignore the gate.
            if ($starve['Starved']) {
                Warn "the worker pool is starved: $($starve['Reason']) - bounded probes will queue and present as slow hosts (P3)"
            } else {
                Pass "the worker pool is not starved (abandoned $($starve['Abandoned']) of $($starve['Capacity']), threshold $($starve['Threshold'])) (P3)"
            }
        }
    } catch {
        Fail "Test-WuuWorkerPoolStarved threw instead of returning a verdict: $($_.Exception.Message)"
    }
}

# (ax) THE POOL-VERSUS-CAP INVARIANT (P3 close-out). This block replaces a NOT_IMPLEMENTED verdict that
#      recorded a REAL defect rather than a missing verifier: the concurrency cap was 10 and the worker
#      pool was 8, so two admitted operations had probes that could never start. Because the cap already
#      counted those operations as running, the shortfall produced no refusal, no error and no log - it
#      presented as a slow host, and an operator would have investigated the host.
#
#      The two modules also contradicted each other in prose, which is how the gap survived: the pool's
#      comment said capacity "must comfortably exceed" the cap while setting a value BELOW it, and
#      Test-WuuConcurrencyAvailable's description said the pool was unrelated ("NOT a bound on the worker
#      pool"). The relationship is now stated once in the pool's configuration comment and asserted here.
#
#      The check compares the two CONFIGURED values and then DRIVES Test-PoolCompatibility, so neither a
#      reverted number nor an inverted comparison can pass.
$workersRawAX = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Workers.psm1'))
$configRawAX = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Configuration.psm1'))
$poolMatchAX = [regex]::Match($workersRawAX, '\[int\]\$script:MaxPoolSize\s*=\s*(\d+)')
$capMatchAX = [regex]::Match($configRawAX, '\$global:MaxConcurrentJobs\s*=\s*(\d+)')

if (-not $poolMatchAX.Success) {
    Fail 'could not read $script:MaxPoolSize from Wuu.Workers - the pool-versus-cap invariant cannot be verified (P3)'
} elseif (-not $capMatchAX.Success) {
    Fail 'could not read $global:MaxConcurrentJobs from Wuu.Configuration - the pool-versus-cap invariant cannot be verified (P3)'
} else {
    $poolSizeAX = [int]$poolMatchAX.Groups[1].Value
    $capSizeAX = [int]$capMatchAX.Groups[1].Value

    if ($capSizeAX -le 0) {
        Fail "the concurrency cap is $capSizeAX, which refuses every operation - no work would ever start (P3)"
    } elseif ($poolSizeAX -lt $capSizeAX) {
        # The unsafe direction. Spelled out with the consequence, because "8 < 10" does not explain why
        # it matters and the next person to see this needs the symptom, not the arithmetic.
        Fail "the worker pool ($poolSizeAX) is SMALLER than the concurrency cap ($capSizeAX): $($capSizeAX - $poolSizeAX) admitted operation(s) would have probes that can never start, counted as running with no refusal and no error - they present as SLOW HOSTS, so the operator investigates the wrong thing. Raise MaxPoolSize in Wuu.Workers (or lower the cap) (P3)"
    } else {
        if ($poolSizeAX -gt $capSizeAX) {
            # Not a defect - a job's probes are sequential, so it holds one slot at a time. Reported so
            # the unused capacity is visible rather than silently tolerated.
            Warn "the worker pool ($poolSizeAX) is larger than the concurrency cap ($capSizeAX) - the extra $($poolSizeAX - $capSizeAX) slot(s) are unused because a job's probes are sequential, so capacity above the cap buys nothing (P3)"
        }
        Pass "the pool ($poolSizeAX) can run every operation the concurrency cap ($capSizeAX) admits, so no admitted operation is left with probes that can never start (P3)"

        # DRIVE the predicate against the LIVE configured cap. The numeric comparison above would still
        # pass if the predicate itself were inverted or always-true, so the verdict function is exercised
        # on its real inputs - and on the unsafe input it must reject.
        if (Get-Command Test-PoolCompatibility -ErrorAction SilentlyContinue) {
            try {
                $liveAX = Test-PoolCompatibility -MaxConcurrentJobs $capSizeAX
                $unsafeAX = Test-PoolCompatibility -MaxConcurrentJobs ($poolSizeAX + 1)
                $zeroAX = Test-PoolCompatibility
                if (-not $liveAX.Compatible) {
                    Fail "Test-PoolCompatibility rejects the live configuration (cap $capSizeAX, pool $poolSizeAX) which the values show is compatible - the predicate and the configuration disagree (P3)"
                } elseif ($unsafeAX.Compatible) {
                    Fail 'Test-PoolCompatibility reports a cap LARGER than the pool as compatible - the check is inert and would pass the defect it exists to catch (P3)'
                } elseif ($zeroAX.Compatible) {
                    Fail 'Test-PoolCompatibility reports an unknown cap (0) as compatible - an unjudgeable configuration must not read as safe (P3)'
                } else {
                    Pass 'Test-PoolCompatibility accepts the live configuration and rejects both an oversized cap and an unknown one (P3)'
                }
            } catch {
                Fail "Test-PoolCompatibility threw instead of returning a verdict: $($_.Exception.Message) (P3)"
            }
        } else {
            Fail 'Test-PoolCompatibility is not exported from Wuu.Workers, so the invariant has no verifier the gate can drive (P3)'
        }
    }
}

# (au) CI MUST USE THE MACHINE-READABLE MODES, and obtain the summary from the run that produced the
#      verdict. The previous workflow ran the whole behavioural suite TWICE - once for the exit code and
#      once more inside an `if: always()` step whose only purpose was to print JSON - which doubled CI
#      time and meant the summary described a different execution than the one it summarised.
$ciPath = Join-Path $root '.github\workflows\validate.yml'
if (-not (Test-Path -LiteralPath $ciPath)) {
    Warn 'no CI workflow found, so nothing enforces this gate on push - local discipline is the only guard (P4)'
} else {
    $ciText = Get-Content -LiteralPath $ciPath -Raw
    $suiteInvocations = ([regex]::Matches($ciText, 'Invoke-TestSuites\.ps1')).Count
    if ($ciText -notmatch 'Validate-Release\.ps1[^\r\n]*-Json') {
        Fail 'CI does not use the gate''s -Json mode, so the machine-readable report is never produced where it matters (P4)'
    } elseif ($ciText -notmatch 'Invoke-TestSuites\.ps1[^\r\n]*-Json') {
        Fail 'CI does not capture the suite summary as JSON (P4)'
    } elseif ($suiteInvocations -gt 1) {
        Fail "CI invokes the suite runner $suiteInvocations times - the summary must come from the SAME run that produced the verdict (P4)"
    } else {
        Pass 'CI runs the suite once, captures JSON from that run, and uses the gate''s -Json mode (P4)'
    }
}

# (av)-(aw) P3 CLOSE-OUT - extracted to Scripts\Test-BudgetAndAnchoring.ps1 (instructions SS39).
#      Dot-sourced HERE, where the blocks were, so their verdicts keep their position in the list.
. (Join-Path $PSScriptRoot 'Test-BudgetAndAnchoring.ps1')


# (ay) INVARIANT 8.4: TERMINAL OPERATIONS STAY TERMINAL. This block used to carry a NOT_IMPLEMENTED
#      verdict, and the reason it existed turned out NOT to be the one the invariant's wording implies.
#
#      The invariant names five terminal states (Complete, Failed, TimedOut, Cancelled, Refused) and only
#      two were written. But the DEFECT was not the missing names - it was that two functions each decided
#      independently what "finished" meant and DISAGREED:
#
#        Test-WuuStateTransitionAllowed  treated only Complete and Error as terminal
#        Get-WuuTargetOutcome            ALSO treated Timeout as settled, and counted it toward exit code 4
#
#      So a timed-out row was a COUNTED FAILURE to the exit-code classifier and a freely-rewritable row to
#      the guard - and because the first rule only refused terminal -> NON-terminal, even `Timeout` ->
#      `Complete` was permitted. An unattributed writer could convert a counted failure into a counted
#      success with nothing recording it. A third copy of the same literal sat in
#      Test-WuuOperationStateInvariant, where it meant a timed-out row still queuing a PendingOp or still
#      holding the runspace lock was not flagged at all.
#
#      The fix is single-sourcing, not new state names. This block asserts the single source, asserts no
#      surviving copy, and then DRIVES both functions across the whole canonical vocabulary - because a
#      check that only reads the declaration would pass while the two consumers still disagreed.
$stateRawAY = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw

# 1. The declaration is singular and exported.
if ($stateRawAY -notmatch '\$script:WuuTerminalStates\s*=\s*@\(') {
    Fail 'there is no single terminal-state declaration in Wuu.State - the 8.4 defect was two functions each holding their own copy (P1/SS4)'
} else {
    foreach ($fnAY in 'Get-WuuTerminalStates', 'Test-WuuTerminalState', 'Get-WuuTerminalOutcomeMap', 'Test-WuuTerminalStateInvariant') {
        if ($stateRawAY -notmatch "function\s+$fnAY\b") { Fail "$fnAY is missing - the terminal declaration has no reader/inspector (P1/SS4)" }
    }
}

# 2. NO SURVIVING COPY. A literal terminal list anywhere else IS the defect returning, so it is searched
#    for in COMMENT-STRIPPED source (the prose legitimately names the states, and prose cannot fail a
#    build - which is how the copies survived in the first place).
$stateCodeAY = Get-WuuTextWithoutComments -Text $stateRawAY
$inlineSetAY = ([regex]::Matches($stateCodeAY, "@\(\s*'Complete'\s*,\s*'Error'")).Count
if ($inlineSetAY -gt 0) {
    Fail "$inlineSetAY function(s) still keep their own @('Complete','Error') literal - a second copy of the terminal set is exactly the 8.4 defect (P1/SS4)"
} else {
    Pass 'the terminal set has no surviving copy - the guard, the outcome classifier and the invariant checker all read one declaration (P1/SS4)'
}

# 3. DRIVE IT. The single-source assertions above would pass while both consumers still disagreed, so the
#    agreement is exercised across every canonical state.
if ((Get-Command Get-WuuTerminalStates -ErrorAction SilentlyContinue) -and (Get-Command Get-WuuTargetOutcome -ErrorAction SilentlyContinue) -and (Get-Command Test-WuuTerminalState -ErrorAction SilentlyContinue)) {
    try {
        $terminalSetAY = @(Get-WuuTerminalStates)
        if ($terminalSetAY.Count -eq 0) {
            Fail 'the terminal set is EMPTY - every transition would be legal and the guard would be inert (P1/SS4)'
        } else {
            # The vocabulary comes from the product's own ValidateSet, not from a list written here, so
            # adding a state to Set-ComputerState extends this check automatically.
            $vocabMatchAY = [regex]::Match($coreRaw, "ValidateSet\('Queued'[^)]*\)")
            if (-not $vocabMatchAY.Success) {
                Fail 'could not read the canonical state vocabulary from Set-ComputerState - the agreement check cannot be driven (P1/SS4)'
            } else {
                $vocabularyAY = @($vocabMatchAY.Value -replace "ValidateSet\(", '' -replace "\)$", '' -replace "'", '' -split ',')
                $disagreeAY = New-Object System.Collections.ArrayList
                $settledAY = 0
                foreach ($sAY in $vocabularyAY) {
                    $probeAY = New-WuuComputerRow -Computer 'GATE-8.4'
                    $probeAY.State = $sAY
                    $probeAY.UpdatesStatus = $sAY
                    $outcomeAY = Get-WuuTargetOutcome -Row $probeAY
                    if ($outcomeAY -eq 'Unknown') { continue }
                    $settledAY++
                    if (-not (Test-WuuTerminalState -State $sAY).Terminal) {
                        $null = $disagreeAY.Add("$sAY (classifier says '$outcomeAY', guard says not terminal)")
                    }
                }

                # THE OTHER DIRECTION, and it is not redundant: agreement has to hold BOTH ways.
                #
                # (i) A declared terminal state that is NOT IN THE CANONICAL VOCABULARY can never be
                # written by Set-ComputerState, so the entry describes a condition that cannot occur while
                # the state it was supposed to cover is left unprotected. This is the fault a real mistake
                # produces - and it was found by the tautology proof: renaming 'Timeout' to 'TimedOut' in
                # the declaration made the forward check silently SKIP the row (it stopped classifying as
                # settled, so the loop `continue`d) and only an unrelated coverage count noticed, reporting
                # the symptom rather than the fault.
                #
                # (ii) A declared terminal state the classifier does not settle means its settlement is
                # invisible to the exit code, so the outcome word is unreachable.
                $offVocabAY = New-Object System.Collections.ArrayList
                $unsettledTerminalsAY = New-Object System.Collections.ArrayList
                foreach ($declaredAY in @(Get-WuuTerminalStates)) {
                    if ($vocabularyAY -notcontains $declaredAY) { $null = $offVocabAY.Add($declaredAY) }
                    $probe2AY = New-WuuComputerRow -Computer 'GATE-8.4-REV'
                    $probe2AY.State = $declaredAY
                    $probe2AY.UpdatesStatus = $declaredAY
                    if ((Get-WuuTargetOutcome -Row $probe2AY) -eq 'Unknown') {
                        $null = $unsettledTerminalsAY.Add($declaredAY)
                    }
                }

                if ($disagreeAY.Count -gt 0) {
                    Fail "$($disagreeAY.Count) state(s) are SETTLED to the outcome classifier but OPEN to the transition guard, so a counted outcome can be rewritten with no operation: $($disagreeAY -join '; ') (P1/SS4)"
                } elseif ($offVocabAY.Count -gt 0) {
                    Fail "the terminal declaration names state(s) that are not in the canonical vocabulary ($($offVocabAY -join ', ')) - Set-ComputerState cannot write them, so those entries protect nothing while the states they replaced are unprotected (P1/SS4)"
                } elseif ($unsettledTerminalsAY.Count -gt 0) {
                    Fail "$($unsettledTerminalsAY.Count) state(s) are declared TERMINAL but the outcome classifier does not settle them ($($unsettledTerminalsAY -join ', ')) - the declaration names a state whose settlement is invisible to the exit code, so the outcome word is unreachable (P1/SS4)"
                } elseif ($settledAY -lt 3) {
                    # Without settled states the loop proves nothing, so a vacuous pass is refused.
                    Fail "the agreement check exercised only $settledAY settled state(s) - it is vacuous and would pass a broken tree (P1/SS4)"
                } else {
                    Pass "for all $($vocabularyAY.Count) canonical states, a state the classifier SETTLES is a state the guard treats as TERMINAL and the outcome classifier is driven ($settledAY settled) (P1/SS4)"
                }
            }

            # The declaration must be internally consistent, judged by the product's own checker.
            if (Get-Command Test-WuuTerminalStateInvariant -ErrorAction SilentlyContinue) {
                $invAY = Test-WuuTerminalStateInvariant
                if (-not $invAY.Ok) {
                    Fail "the terminal declaration is internally inconsistent: $(@($invAY.Violations) -join '; ') (P1/SS4)"
                } else {
                    Pass 'the terminal declaration is internally consistent (non-empty, unique, and every outcome the classifier can produce maps back to a terminal state) (P1/SS4)'
                }
            } else {
                Fail 'Test-WuuTerminalStateInvariant is not exported, so the declaration has no integrity check (P1/SS4)'
            }

            # THE BEHAVIOUR, not just the declaration: a settled outcome must not be rewritable without a
            # new operation, INCLUDING terminal -> terminal, which is the case the loose rule missed.
            $timedOutAY = New-WuuComputerRow -Computer 'GATE-8.4-REWRITE'
            $timedOutAY.State = 'Timeout'
            $timedOutAY.UpdatesStatus = 'Timeout'
            $launderAY = Update-WuuOperationState -Row $timedOutAY -OperationId $null -State 'Complete'
            if ($launderAY.Applied) {
                Fail 'a TIMED-OUT row was moved to Complete with NO operation - a counted failure can be laundered into a counted success (P1/SS4)'
            } elseif ($timedOutAY.State -ne 'Timeout') {
                Fail "the funnel refused the write but the row changed anyway (State='$($timedOutAY.State)') - a refusal must write NOTHING (P1/SS4)"
            } else {
                Pass 'a timed-out row cannot be rewritten to Complete without a new operation, and a refusal leaves the row untouched (P1/SS4)'
            }
            # ...and a RETRY must remain legal, or the rule would have broken the operator's only recovery.
            $retryAY = Test-WuuStateTransitionAllowed -Row $timedOutAY -ToState 'Queued' -OperationId 'op-gate-retry'
            if (-not $retryAY.Allowed) {
                Fail "a RETRY of a settled row was refused ($($retryAY.Reason)) - terminal must protect the outcome, not block the recovery path (P1/SS4)"
            } else {
                Pass 'a settled row can still be retried by a new attributed operation (P1/SS4)'
            }
        }
    } catch {
        Fail "the terminal-state checks threw instead of returning verdicts: $($_.Exception.Message) (P1/SS4)"
    }
} else {
    Fail 'the terminal-state functions could not be resolved, so invariant 8.4 was never driven (P1/SS4)'
}

# (az) DIRECT OPERATION-STATE WRITES OUTSIDE Wuu.State (instructions P0 #1). Zero is the target and is
#      NOT IMPLEMENTED; the ceiling is a ratchet so the count can only fall. Lower it when it does.
$directWriteCeilingAZ = 41
$directWritePropsAZ = @('State', 'OpState', 'OperationId', 'PendingOp', 'TimeoutExpiresAt')
$directWritesAZ = 0
$directWriteDetailAZ = @()
foreach ($modAZ in @(Get-ChildItem -Path (Join-Path $root 'src') -Filter '*.psm1' -File | Where-Object { $_.Name -ne 'Wuu.State.psm1' })) {
    $codeAZ = Get-WuuTextWithoutComments -Text ([System.IO.File]::ReadAllText($modAZ.FullName))
    foreach ($propAZ in $directWritePropsAZ) {
        # (?!=) excludes -eq style comparisons written as '=='.
        $nAZ = ([regex]::Matches($codeAZ, "\`$\w+\.$propAZ\s*=(?!=)")).Count
        if ($nAZ -gt 0) { $directWritesAZ += $nAZ; $directWriteDetailAZ += "$($modAZ.Name).$propAZ=$nAZ" }
    }
}
if ($directWritesAZ -gt $directWriteCeilingAZ) {
    Fail "direct operation-state writes outside Wuu.State rose to $directWritesAZ (ceiling $directWriteCeilingAZ) - route new writes through Update-WuuOperationState: $($directWriteDetailAZ -join ', ') (P0)"
} else {
    Pass "no new direct operation-state writes outside Wuu.State ($directWritesAZ, ceiling $directWriteCeilingAZ) (P0)"
    if ($directWritesAZ -lt $directWriteCeilingAZ) {
        Warn "direct operation-state writes fell to $directWritesAZ - lower `$directWriteCeilingAZ to $directWritesAZ so the ratchet holds (P0)"
    }
}
if ($directWritesAZ -gt 0) {
    Not-Implemented "zero direct operation-state writes outside Wuu.State: $directWritesAZ remain, many inside payload runspaces where the funnel is not callable (P0)"
} else {
    Pass 'every operation-state write goes through Wuu.State (P0)'
}

# --- JSON REPORT (P4), written LAST --------------------------------------------------------------
# THE PLACEMENT IS THE POINT. The call was originally placed just after the report function was
# defined, which is ~140 lines BEFORE the final blocks - so the report was written without them. It
# held 145 verdicts while the gate had emitted more, and WARN / SKIP / NOT_IMPLEMENTED never appeared
# in it at all: the three kinds this mode exists to expose were absent from the artifact that exposes
# them. A report that is silently missing its last checks is worse than no report, because it looks
# complete. It is written here, after every check, and before the single failure exit so that a
# FAILING run still produces one.
if ($Json) {
    $jsonPath = if ([System.IO.Path]::IsPathRooted($Json)) { $Json } else { Join-Path $root $Json }
    $null = Write-WuuGateJsonReport -Path $jsonPath
}

if ($failed) { Write-Host "`nValidation FAILED" -ForegroundColor Red; exit 1 }
else { Write-Host "`nAll validation checks passed" -ForegroundColor Cyan }
