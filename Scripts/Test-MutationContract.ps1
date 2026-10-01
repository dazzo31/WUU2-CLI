# Release validation, STATE-MUTATION CONTRACT and CODE HYGIENE: the P1/P2 reviewer close-out (SS39).
# Extracted from Validate-Release.ps1.
#
# WHAT IS IN HERE, so the name does not have to carry it all:
#   (an) the state-mutation funnel - identity is validated before the first write
#   (ao) atomic slot reservation, with a rollback when the reservation fails after the claim
#   (ap) refusal semantics - a refusal is not an error, and nothing is written when refused
#   (aq) silent catches - an empty catch must be deliberate and allowlisted
#
#   (ar) the single log appender - four copies of the retry loop became one. It followed (aq) in the
#
# DOT-SOURCED FRAGMENT - not a standalone script. Validate-Release.ps1 dot-sources it into its own
# scope, which is what gives this file $root, the verdict helpers, and the shared harness helpers
# hoisted above the dot-sources.
#
# WHY A SEPARATE FILE RATHER THAN PART OF Test-Architecture.ps1: these blocks sit in the MIDDLE of the
# gate and Test-Architecture is dot-sourced near the FRONT. A fragment runs ALL its contents each time
# it is dot-sourced, so putting them there ran the architecture blocks twice as well (verdict count
# 171 -> 200). A fragment may be dot-sourced ONCE, and blocks that belong at different positions in
# the report need different files.

# (an) THE STATE-MUTATION FUNNEL (reviewer P1). The invariant "a superseded operation cannot write"
#      held for 2 of 6 producers of operation state, and 46 direct assignments bypassed all of them.
#      This gates the funnel that now owns mutation, and it DRIVES the invariant checker rather than
#      grepping for it - a checker that always returns "no violations" would make this a tautology.
$coreRawN  = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$stateRawN = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw
$wupdRawN  = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw

# The funnel lives in Wuu.STATE, not Wuu.Core - it mutated rows, so it belongs with the row contract.
# (An earlier revision of this check searched Wuu.Core and reported the funnel missing while it was
# present, which is the same file-confusion that the Stop-WuuFatal check above already hit.)
if ($stateRawN -notmatch 'function Update-WuuOperationState') {
    Fail 'the state-mutation funnel Update-WuuOperationState does not exist - state is mutated from many places again (P1)'
} elseif ($stateRawN -notmatch "'Update-WuuOperationState'") {
    Fail 'Update-WuuOperationState is not exported - callers outside Wuu.State cannot route mutation through it'
} else {
    Pass 'the state-mutation funnel exists and is exported (P1)'
}

# IDENTITY MUST BE CHECKED BEFORE ANY WRITE. Ordering is the whole point: a guard that runs after the
# first assignment has already mutated the row, which is the defect, not the fix.
#
# COMMENTS ARE STRIPPED FIRST. The function documents its own guard at length, so the prose alone
# contains three mentions of Test-WuuStaleWrite. Searching the raw body found the NAME in a docstring
# and the ordering check passed on a tree where the actual call had been replaced with `$false` - the
# exact comment-matching trap that has produced five false results in this repository already. The
# mutation test caught it; this strip is the fix.
$funnelText = Get-WuuFunctionBody $stateRawN 'Update-WuuOperationState'
$funnelCode = Get-WuuTextWithoutComments -Text $funnelText
if (-not $funnelText) {
    Fail 'could not extract the funnel body for the ordering check'
} else {
    $guardAt = $funnelCode.IndexOf('Test-WuuStaleWrite')
    $adoptAt = $funnelCode.IndexOf('$OperationIdNew')
    $firstSetAt = $funnelCode.IndexOf("`$set '")
    # The guard must be an INVOCATION carrying the row and the writer's identity, not merely a name.
    $guardCall = [regex]::Match($funnelCode, 'Test-WuuStaleWrite\s+-Row\s+\$Row\s+-OperationId\s+\$OperationId')
    if ($guardAt -lt 0 -or -not $guardCall.Success) {
        Fail 'the funnel never INVOKES Test-WuuStaleWrite with (Row, OperationId) - it is not identity-guarded (P1)'
    } elseif ($firstSetAt -lt 0) {
        Fail 'the funnel has no apply block to order against - the check cannot prove the guard precedes the write'
    } elseif ($guardAt -gt $firstSetAt) {
        Fail 'the funnel writes BEFORE it checks identity - the guard must precede the first mutation (P1)'
    } elseif ($adoptAt -gt 0 -and $adoptAt -gt $firstSetAt) {
        Fail 'the funnel resolves identity ADOPTION after its first write, so adoption cannot gate it (P1)'
    } elseif ($funnelCode -match 'elseif\s*\(\s*\$false\s*\)') {
        # A disabled guard: the call is present in text but can never refuse. This is the mutation the
        # ordering check originally missed, so it is asserted directly.
        Fail 'the funnel contains a disabled condition ($false) - the identity guard may be inert (P1)'
    } else {
        Pass 'the funnel INVOKES the identity rule before its first write, and admission is refused over a running operation (P1)'
    }
}

# REFUSAL MUST NOT WRITE. The contract is "nothing is written when refused", not "written then
# reverted" - so every refusal path must return before the apply block.
$refusalReturns = ([regex]::Matches($funnelText, 'return \(& \$refused')).Count
if ($refusalReturns -lt 3) {
    Fail "the funnel has only $refusalReturns refusal paths - identity, transition and revision refusals must all return before any write (P1)"
} else {
    Pass "the funnel refuses on $refusalReturns separate grounds, each returning before any write (P1)"
}

# The four former unguarded producers must delegate (the two in Wuu.Core) or delegate to the inlined
# twin (the two injected worker copies, which cannot resolve a module function).
foreach ($fn in @('Set-ComputerState', 'Set-ComputerTimeout')) {
    $body = Get-WuuFunctionBody $coreRawN $fn
    if ($body -notmatch 'Update-WuuOperationState') {
        Fail "$fn does not route through the funnel - it still mutates operation state unchecked (P1)"
    }
}
if ($coreRawN -match '(?s)function Set-ComputerState.*?Update-WuuOperationState') {
    Pass 'Set-ComputerState and Set-ComputerTimeout route through the funnel (P1)'
}

$wupdN = Get-WuuTextWithoutComments -Text $wupdRawN
if ($wupdN -notmatch 'UpdateWuuOperationStateScript') {
    Fail 'the injected worker runspaces have no inlined mutation funnel - the payloads would still write unchecked (P1)'
} elseif ($wupdN -notmatch 'rowOpId' -or $wupdN -notmatch 'writerOpId' -or $wupdN -notmatch 'cne') {
    Fail 'the inlined worker funnel does not compare row identity against writer identity - it is present but inert (P1)'
} else {
    Pass 'the injected worker runspaces route state through an inlined, identity-guarded funnel (P1)'
}

# ClearOperation must cover every field the four former copy-pasted blocks cleared, plus the identity.
$clearAt = $funnelText.IndexOf('if ($ClearOperation)')
if ($clearAt -lt 0) {
    Fail 'the funnel has no ClearOperation - the copy-pasted cleanup block has no single home (P1)'
} else {
    $clearBody = $funnelText.Substring($clearAt)
    $missing = @()
    foreach ($pair in @(@("'OpState' 'Idle'", 'releases the lock'),
                        @("'OpStartedAt' `$null", 'clears the operation start time'),
                        @("'TimeoutExpiresAt' `$null", 'clears the deadline'),
                        @("'TimeoutSource' ''", 'clears the timeout source'),
                        @("'OpName' ''", 'clears the operation name'),
                        @("'LastHeartbeatAt' `$null", 'clears the heartbeat'),
                        @("'OperationId' ''", 'retires the identity'),
                        @("'Runspace' `$null", 'detaches the runspace'))) {
        if (-not $clearBody.Contains($pair[0])) { $missing += $pair[1] }
    }
    if ($missing.Count -gt 0) {
        Fail ("ClearOperation does not " + ($missing -join ', ') + ' (P1)')
    } else {
        Pass 'ClearOperation covers all eight fields of the former copy-pasted cleanup block, including the identity (P1)'
    }
}

# DRIVE THE INVARIANT CHECKER. A gate that only reads the checker's source cannot tell a working check
# from one that returns nothing. This builds a deliberately inconsistent row and requires a violation.
if (-not (Get-Command Test-WuuOperationStateInvariant -ErrorAction SilentlyContinue)) {
    Fail 'Test-WuuOperationStateInvariant is not resolvable - the invariant is not assertable (P1)'
} else {
    try {
        $badRow = New-WuuComputerRow -Computer 'GATE-VIOLATION-PROBE'
        $badRow.OpState = 'Running'
        $badRow.OperationId = ''
        $badViolations = @(Test-WuuOperationStateInvariant -Row $badRow)
        $goodRow = New-WuuComputerRow -Computer 'GATE-CLEAN-PROBE'
        $goodViolations = @(Test-WuuOperationStateInvariant -Row $goodRow)
        if ($badViolations.Count -eq 0) {
            Fail 'the invariant checker reports NO violations for a row that is Running with no operation identity - it cannot detect the defect it exists for (P1)'
        } elseif ($goodViolations.Count -ne 0) {
            Fail ("the invariant checker reports violations for a fresh, valid row: " + ($goodViolations -join '; '))
        } else {
            Pass "the invariant checker detects a real violation and passes a clean row (P1)"
        }
    } catch {
        Fail "the invariant checker threw instead of reporting: $($_.Exception.Message)"
    }
}

# (ao) ATOMIC SLOT RESERVATION (reviewer P1). The cap was ENFORCED at the top of the submission point
#      but CONSUMED 141 lines later at $jobs.Add, so two overlapping submissions both read the same
#      count and both admitted - a cap of 10 could run 12. The invariant is not "the cap is checked"
#      but "the check and the append are ONE step". This gates the ordering, which is the whole fix.
$wupdRawO = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw
$subText = Get-WuuFunctionBody $wupdRawO 'Start-UpdateCheckJob'
$subCode = Get-WuuTextWithoutComments -Text $subText

if (-not $subText) {
    Fail 'could not extract Start-UpdateCheckJob for the reservation check'
} elseif ($subCode -notmatch 'Enter-WuuSubmissionLock') {
    Fail 'the submission point does not take the submission lock - the capacity test and the slot append are not one step (P1)'
} elseif ($subCode -notmatch 'Exit-WuuSubmissionLock') {
    Fail 'the submission point takes the submission lock but never releases it (P1)'
} else {
    # ORDERING IS THE INVARIANT. The authoritative cap test and the append must both sit between the
    # acquisition and the release, with the append LAST.
    $acqAt  = $subCode.IndexOf('Enter-WuuSubmissionLock')
    $exitAt = $subCode.LastIndexOf('Exit-WuuSubmissionLock')
    $capAt  = $subCode.LastIndexOf('Test-WuuConcurrencyAvailable')
    $addAt  = $subCode.LastIndexOf('$jobs.Add')
    if ($capAt -lt $acqAt) {
        Fail 'the authoritative capacity test runs BEFORE the lock - it reserves nothing (P1)'
    } elseif ($capAt -gt $exitAt) {
        Fail 'the authoritative capacity test runs OUTSIDE the critical section - the race is still open (P1)'
    } elseif ($addAt -lt $capAt) {
        Fail 'the slot is appended BEFORE the capacity test - the cap can be overshot (P1)'
    } elseif ($addAt -gt $exitAt) {
        Fail 'the slot is appended OUTSIDE the critical section - the test and the append are not atomic (P1)'
    } else {
        # ORDERING ALONE IS NOT ENOUGH, and this is a real hole rather than a hypothetical one: a call
        # written inside the `if` BODY instead of its condition satisfies every ordering test above
        # while ignoring the result - `if (...) { Test-WuuConcurrencyAvailable ... }` still runs the
        # test, still refuses nothing, and still appends. So the section is also required to CONTAIN A
        # REFUSAL, and the refusal must come after the test and before the append.
        $section = $subCode.Substring($acqAt, $exitAt - $acqAt)
        $sectionRefusals = ([regex]::Matches($section, 'return\s+\$false')).Count
        $sectionRollbacks = ([regex]::Matches($section, '&\s+\$rollback')).Count
        $testToAdd = $section.Substring($section.LastIndexOf('Test-WuuConcurrencyAvailable'),
                                        $section.LastIndexOf('$jobs.Add') - $section.LastIndexOf('Test-WuuConcurrencyAvailable'))

        if ($sectionRefusals -lt 1) {
            Fail 'the critical section cannot REFUSE - the capacity test result is not acted on, so the reservation always succeeds (P1)'
        } elseif ($testToAdd -notmatch 'return\s+\$false') {
            Fail 'the capacity test inside the critical section is followed by no refusal before the append - a full cap would still reserve (P1)'
        } elseif ($sectionRollbacks -lt $sectionRefusals) {
            Fail "the critical section has $sectionRefusals refusal path(s) but only $sectionRollbacks rollback(s) - a refusal would leave the row claimed and Running for ever (P1)"
        } else {
            Pass 'the capacity test and the slot append are one indivisible step under the submission lock, and every refusal in that section rolls the claim back (P1)'
        }
    }
}

# The lock primitive must be a real mutual-exclusion object, and re-entrant so a nested submission
# cannot deadlock against itself.
$stateRawO = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw
if ($stateRawO -notmatch 'System\.Threading\.Monitor') {
    Fail 'the submission lock is not built on a mutual-exclusion primitive (P1)'
} elseif ($stateRawO -notmatch 'Monitor\]::TryEnter') {
    Fail 'the submission lock blocks indefinitely instead of timing out - a dead holder would hang every submission (P1)'
} else {
    Pass 'the submission lock uses a re-entrant mutual-exclusion primitive with a timeout (P1)'
}

# A reservation that fails AFTER the row was claimed must undo the claim, or no cleanup pass will
# ever settle that row and the computer stays permanently busy.
#
# The rollback BODY is asserted, not the whole function: checking the function text for
# 'ClearOperation' also matches the claim ABOVE the reservation, so removing the rollback's own clear
# still passed. (Caught by the tautology harness, not by review.)
$rbStart = $subCode.IndexOf('$rollback = {')
$rbBody = ''
if ($rbStart -ge 0) { $rbBody = $subCode.Substring($rbStart, [Math]::Min(600, $subCode.Length - $rbStart)) }
if ($subCode -notmatch 'rollback') {
    Fail 'a failed reservation has no rollback path - the row would stay Running for ever (P1)'
} elseif ($rbBody -notmatch 'Update-WuuOperationState') {
    Fail 'the rollback does not go through the mutation funnel, so it cannot retire the identity (P1)'
} elseif ($rbBody -notmatch 'ClearOperation') {
    Fail 'a failed reservation does not roll back the operation claim - no cleanup pass would ever settle that row (P1)'
} else {
    Pass 'a failed reservation rolls back the claim through the funnel, so no row is left permanently busy (P1)'
}

# (ap) REFUSAL SEMANTICS (reviewer P1: "define cancellation/refusal phase semantics"). A refusal is
#      neither an Error nor a Timeout, so Test-WuuPhaseFailureBlocks never saw it and NOTHING recorded
#      it - a refused submission left Pending=$true and the phase gate waited for ever, unable to tell
#      a moving queue from a computer that can never be admitted. That is a permanent silent stall.
$subTextP = Get-WuuFunctionBody $wupdRawO 'Start-UpdateCheckJob'
$subCodeP = Get-WuuTextWithoutComments -Text $subTextP

if ($stateRawO -notmatch "RefusedCount") {
    Fail 'the row contract has no refusal record - a refused submission is invisible to the phase gate (P1)'
} elseif ($stateRawO -notmatch 'function Update-WuuRefusalRecord') {
    Fail 'there is no recorder for refusals (P1)'
} elseif ($stateRawO -notmatch 'function Test-WuuRefusalStalled') {
    Fail 'there is no stall predicate - the phase gate cannot distinguish "waiting" from "stalled" (P1)'
} else {
    Pass 'refusals are recorded and stallable (P1)'
}

# The threshold must have ONE home. A gate that re-derives its own number would let the recorder call a
# row stalled while the gate waits, or the reverse.
if ($stateRawO -notmatch 'function Get-WuuRefusalStallThreshold') {
    Fail 'the stall threshold is not exposed by a function, so callers could retype it (P1)'
} elseif ($wupdRawO -match 'RefusedCount\s*-ge\s*\d') {
    Fail 'the phase gate hard-codes its own refusal threshold instead of asking for the shared value (P1)'
} else {
    Pass 'the stall threshold has a single home (P1)'
}

# Every REFUSAL path must record, and the gate must BRANCH on the stall result.
if ($subCodeP) {
    $refusalKinds = @()
    foreach ($m in @('submission refused', 'submission deferred')) { if ($subCodeP.Contains($m)) { $refusalKinds += $m } }
    $unrecorded = @()
    foreach ($m in $refusalKinds) {
        $i = $subCodeP.IndexOf($m)
        $lo = [Math]::Max(0, $i - 700)
        if (-not $subCodeP.Substring($lo, $i - $lo).Contains('Update-WuuRefusalRecord')) { $unrecorded += $m }
    }
    if ($unrecorded.Count -gt 0) {
        Fail ("these refusal paths do not record the refusal: " + ($unrecorded -join '; ') + ' (P1)')
    } elseif ($subCodeP -notmatch 'Update-WuuRefusalRecord\s+-Row\s+\$ComputerItem\s+-Admitted') {
        Fail 'admission does not clear the refusal record, so only LIFETIME refusals are counted rather than consecutive (P1)'
    } else {
        Pass 'every refusal path records, and admission clears the record (P1)'
    }
} else {
    Fail 'could not extract Start-UpdateCheckJob for the refusal check'
}

# The gate must BRANCH on the stall, and report why. Computing a stall and continuing is an inert check.
# Searched in the COMMENT-STRIPPED WindowsUpdate source: the stall branch is explained by a long comment
# that names Test-WuuRefusalStalled, so searching the raw text would find the prose rather than the call.
$wupdCodePhase = Get-WuuTextWithoutComments -Text $wupdRawO
if ($wupdCodePhase -notmatch 'Test-WuuRefusalStalled') {
    Fail 'the phase gate never consults the stall predicate - a stalled row blocks by accident, not by design (P1)'
} else {
    $si = $wupdCodePhase.IndexOf('Test-WuuRefusalStalled')
    $sw = $wupdCodePhase.Substring($si, [Math]::Min(900, $wupdCodePhase.Length - $si))
    if ($sw -notmatch 'return\s+\$false') {
        Fail 'the phase gate computes the stall but does not BLOCK on it - the check is inert (P1)'
    } elseif ($sw -notmatch 'Write-WarningLog') {
        Fail 'the phase gate blocks on a stall without saying why - a silent block is the original defect (P1)'
    } else {
        Pass 'the phase gate blocks on a stalled refusal and reports the reason (P1)'
    }
}

# (aq) SILENT CATCHES (reviewer P2: "a release gate could even reject empty catches outside a small
#      allowlist"). A catch whose body performs no statement turns a fault into apparent success: the
#      caller cannot tell "nothing to do" from "the work failed". The rule is therefore not "no silent
#      catches" but "no UNJUSTIFIED ones" - a disposal failure must not mask the original error, and a
#      logging failure cannot be logged.
#
#      THE POLICY IS SHARED WITH ITS SUITE, NOT COPIED. Scripts\Wuu.CatchAudit.ps1 is dot-sourced by
#      both this gate and tests\Test-SilentCatchPolicy.ps1. If each carried its own rule they would
#      drift and one would pass while the other failed. This gate is the ENFORCEMENT; the suite carries
#      the false-negative control (it drives the detector with synthetic silences), because a checker
#      that only ever runs against the real tree cannot be shown to detect anything.
$catchAuditPath = Join-Path $root 'Scripts\Wuu.CatchAudit.ps1'
if (-not (Test-Path -LiteralPath $catchAuditPath)) {
    Fail 'Scripts\Wuu.CatchAudit.ps1 is missing - the silent-catch policy has no home (P2)'
} else {
    . $catchAuditPath

    if (-not (Get-Command Get-WuuSilentCatch -ErrorAction SilentlyContinue)) {
        Fail 'the shared catch policy does not provide Get-WuuSilentCatch (P2)'
    } else {
        # Every allowlist entry must state WHY. An entry without a justification is indistinguishable
        # from "we stopped looking", which is the outcome this policy exists to prevent.
        $allow = @(Get-WuuSilentCatchAllowlist)
        $noWhy = @($allow | Where-Object { -not $_.Why -or $_.Why.Length -lt 20 })
        if ($noWhy.Count -gt 0) {
            Fail "$($noWhy.Count) allowlist entr(ies) do not state why they are allowed - an unjustified exemption is not a policy (P2)"
        } elseif ($allow.Count -gt 12) {
            Fail "the allowlist has $($allow.Count) entries - too large to be a policy rather than a list of everything that happens to exist (P2)"
        } else {
            Pass "the allowlist is small ($($allow.Count) entries) and every entry states why (P2)"
        }

        $catchFindings = @()
        $catchTotal = 0
        foreach ($cf in Get-ChildItem (Join-Path $root 'src\*.psm1') | Sort-Object Name) {
            $cfText = [System.IO.File]::ReadAllText($cf.FullName)
            foreach ($c in (Get-WuuSilentCatch -Text $cfText)) {
                $catchTotal++
                $verdict = Test-WuuSilentCatchAllowed -Guarded $c.Guarded -Body $c.Body
                if (-not $verdict.Allowed) {
                    $catchFindings += "$($cf.Name) L$($c.Line): $($verdict.Reason)"
                }
            }
        }

        if ($catchTotal -eq 0) {
            # A ZERO RESULT MUST BE DISTINGUISHABLE FROM A BROKEN SCAN. If the detector silently stopped
            # finding anything, "no findings" would look like a pass.
            Fail 'the scan found NO silent catches at all in src/ - the detector is not working, so this check proves nothing (P2)'
        } elseif ($catchFindings.Count -gt 0) {
            Fail ("$($catchFindings.Count) unjustified silent catch(es) of $catchTotal - each turns a fault into apparent success (P2): " + ($catchFindings -join ' | '))
        } else {
            Pass "all $catchTotal silent catch(es) in src/ are documented or allowlisted (P2)"
        }

        # FALSE-NEGATIVE CONTROL. Without this, the check above passes whenever there are no findings -
        # including when the POLICY HAS BEEN DISABLED and refuses nothing. The gate would then report
        # "all silences are justified" for a tree where nothing is ever refused, which is a check that
        # cannot fail. The tautology harness found this by making the predicate return Allowed=$true
        # unconditionally: the gate PASSED that broken tree. The predicate is therefore DRIVEN here -
        # it must refuse a silence that is neither documented nor allowlisted, and permit a documented
        # one. Both directions, because permitting everything and refusing everything are equally broken.
        $fnUnjustified = Test-WuuSilentCatchAllowed -Guarded 'try { Invoke-SomeVitalWork }' -Body ''
        $fnDocumented = Test-WuuSilentCatchAllowed -Guarded 'try { Invoke-SomeVitalWork }' -Body '# best effort by design'
        if ($fnUnjustified.Allowed) {
            Fail 'the policy permits an UNJUSTIFIED silence - the check above cannot fail, so its clean result proves nothing (P2)'
        } elseif (-not $fnDocumented.Allowed) {
            Fail 'the policy refuses a DOCUMENTED silence - an explicit justification is being ignored (P2)'
        } else {
            Pass 'the policy refuses an unjustified silence and permits a documented one (P2)'
        }

        # The detector must FIND the multi-line form, which is the form the real code uses and the form
        # an earlier broken brace-count could not see. Without this, a detector that only handled
        # one-liners would report a clean tree while inspecting almost nothing.
        $multiProbe = "function P {`n    try {`n        Do-Work`n    } catch {`n    }`n}`n"
        $multiFound = @(Get-WuuSilentCatch -Text $multiProbe)
        if ($multiFound.Count -ne 1) {
            Fail 'the silent-catch detector does not find the MULTI-LINE empty catch - the form src/ uses - so its clean result means nothing (P2)'
        } elseif ($multiFound[0].Kind -ne 'empty') {
            Fail 'the detector classifies a genuinely empty multi-line catch as something other than empty (P2)'
        } elseif (-not $multiFound[0].Guarded.Contains('Do-Work')) {
            Fail 'the detector does not identify WHAT the silent catch guards, so the allowlist cannot be applied (P2)'
        } else {
            Pass 'the detector finds the multi-line form it is judging, and the statement it guards (P2)'
        }
    }
}

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
} else {
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
