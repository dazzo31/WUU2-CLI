# Release validation, ENGINE INVARIANTS 8.1, 8.2, 8.6 and 8.7 (SS39). Extracted from Validate-Release.ps1.
#
# WHAT IS IN HERE - these are the invariants the brief numbers, and each is asserted against the code
# that has to hold it rather than against a comment:
#   (ah) operation identity (8.1/8.2) - a superseded worker cannot reach the row it lost
#   (ai) the global concurrency cap (8.6) - enforced at the submission boundary, not advised
#   (aj) the pending-request policy (8.7) - one slot, newest wins, and a replacement is always reported
#   (ak) per-target outcomes and partial success (exit code 4 became producible)
#
# DOT-SOURCED FRAGMENT - not a standalone script. Validate-Release.ps1 dot-sources it into its own
# scope AT THE POSITION THESE BLOCKS OCCUPIED, which is what gives this file $root, the verdict
# helpers, and the shared harness helpers hoisted above the dot-sources. It also keeps the verdict
# order unchanged - the report is what CI reads.

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

# (aj) PENDING-REQUEST POLICY (brief SS7/SS16 / invariant 8.7). A row has ONE PendingOp slot, so a
#      second request to a busy computer silently destroyed the first: `download` then `install` left
#      the Download gone while the operator was told only "queued to run when they finish". The
#      direction that is easy to miss is the DOWNGRADE - `install` then `download` destroyed the
#      install, so an operator who asked for more got less with no indication at all.
#
#      THE POLICY: one slot, SEMANTIC PRECEDENCE (Check < Download < Install < Restart), and every
#      decision reported. An UPGRADE replaces (it does the same work and more) and is reported. A
#      DOWNGRADE is DECLINED and the higher request is KEPT, which is the SS16 change: refusing an
#      UPGRADE outright would make `download` then `install` silently do nothing, but declining a
#      DOWNGRADE loses nothing, because the higher request still runs.
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

# SS16: the precedence itself, DRIVEN rather than matched. Source text cannot show that a downgrade is
# actually declined, and a presence check on `Get-WuuPendingOpRank` would pass a mutant that computed a
# rank and then ignored it. The table AND both directions of every ordered pair are exercised, because
# the behaviour that was wrong (install then download) is a single cell of that matrix.
if ($pendingBodyJ -notmatch 'Get-WuuPendingOpRank') {
    Fail 'Set-WuuPendingOperation does not consult Get-WuuPendingOpRank - the slot is back to blind newest-wins, so a later lower request can still replace a higher one (SS16)'
} elseif (-not (Get-Command Get-WuuPendingOpRank -ErrorAction SilentlyContinue)) {
    Fail 'Get-WuuPendingOpRank is not resolvable - the precedence table cannot be driven, so SS16 is asserted by text only (SS16)'
} else {
    try {
        $rankExpectedJ = @{ 'Check' = 1; 'Download' = 2; 'InstallAndRecheck' = 3; 'Install' = 3; 'Restart' = 4; 'AutoFlow' = 4 }
        $rankWrongJ = @()
        foreach ($k in $rankExpectedJ.Keys) {
            if ((Get-WuuPendingOpRank -Op $k) -ne $rankExpectedJ[$k]) { $rankWrongJ += $k }
        }
        # An unrecognised operation must rank LOWEST, so it is declined rather than displacing real work.
        if ((Get-WuuPendingOpRank -Op 'NoSuchOperation') -ge 1) { $rankWrongJ += 'NoSuchOperation(not lowest)' }

        $precedenceWrongJ = @()
        foreach ($existingJ in @('Check', 'Download', 'InstallAndRecheck', 'Restart')) {
            foreach ($requestedJ in @('Check', 'Download', 'InstallAndRecheck', 'Restart')) {
                $rowJ = New-WuuComputerRow -Computer 'GATE-PRECEDENCE'
                $rowJ.OpState = 'Running'
                $rowJ.PendingOp = $existingJ
                $resJ = Set-WuuPendingOperation -Row $rowJ -Op $requestedJ
                $eJ = Get-WuuPendingOpRank -Op $existingJ
                $rJ = Get-WuuPendingOpRank -Op $requestedJ
                if ($rJ -lt $eJ) {
                    # DECLINED: the higher request must survive AND still be flagged Pending.
                    if (-not $resJ.Refused -or [string]$rowJ.PendingOp -ne $existingJ) {
                        $precedenceWrongJ += "$existingJ->$requestedJ (should keep $existingJ)"
                    }
                } elseif ($rJ -gt $eJ) {
                    if (-not $resJ.Set -or [string]$rowJ.PendingOp -ne $requestedJ -or [string]$resJ.Replaced -ne $existingJ) {
                        $precedenceWrongJ += "$existingJ->$requestedJ (should replace and report)"
                    }
                }
            }
        }
        if ($rankWrongJ.Count) {
            Fail ('the pending precedence table is wrong for: ' + ($rankWrongJ -join ', ') + ' - the ordering is Check < Download < Install < Restart with AutoFlow at the top (SS16)')
        } elseif ($precedenceWrongJ.Count) {
            Fail ('semantic precedence is not enforced: ' + ($precedenceWrongJ -join '; ') + ' (SS16)')
        } else {
            Pass 'semantic precedence holds for every ordered pair of queued requests, and an unknown operation ranks lowest (SS16)'
        }
    } catch {
        Fail "driving the pending precedence threw instead of reporting: $($_.Exception.Message) (SS16)"
    }
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
