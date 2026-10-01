# Release validation, P3 CLOSE-OUT: remaining-budget propagation (av) and external audit anchoring (aw).
# Extracted from Validate-Release.ps1 (instructions SS39).
#
# DOT-SOURCED FRAGMENT - not a standalone script. Validate-Release.ps1 dot-sources it into its own
# scope, which is what gives this file $root, the verdict helpers, the shared harness helpers
# (Get-WuuFunctionBody and friends, hoisted above every dot-source) and any variable the gate computed
# above the dot-source line.
#
# WHY THIS IS ITS OWN FILE RATHER THAN PART OF Test-Contracts.ps1: these blocks sit at the END of the
# gate, and Test-Contracts is dot-sourced near the FRONT. Dot-sourcing them with that file moved their
# verdicts to the head of the report - a gratuitous reordering of the artifact CI reads. A fragment must
# be dot-sourced WHERE ITS BLOCKS WERE.

# (av) REMAINING-BUDGET PROPAGATION (P3). The reviewer's finding: an operation's deadline was enforced
#      only at the outermost level, while its inner probes each took a FIXED timeout chosen independently
#      of how much budget was left. An operation one second from expiry still started a 30-second probe,
#      holding a pool slot 29 seconds after the cleanup loop had abandoned it; an operation 44 minutes
#      into a 45-minute budget killed a 15-second probe for no reason but timing, and the operator
#      concluded the HOST was broken.
#
#      TWO THINGS MUST HOLD, and the second is the one that would have shipped broken.
#
#      1. The rule exists and is reachable: min(own, remaining), with a floor so an expiring probe is
#         still usable, and no deadline meaning DO NOT CAP rather than a fabricated zero.
#      2. The helpers that apply it must NOT CALL IT. Invoke-CimWithTimeout and Invoke-ServiceWithTimeout
#         are DEFINED inside payload scriptblocks, so they run in a runspace whose InitialSessionState is
#         CreateDefault() with no module imported - a module function is not callable there and the call
#         THROWS. The first version of this code did exactly that. The gate now forbids it.
#
#      Because the rule is therefore duplicated (a helper in Wuu.State, inlined arithmetic in the
#      payloads), the gate also DRIVES both and requires them to AGREE - duplication without an agreement
#      test is how one rule silently becomes two.
$stateRawAV = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.State.psm1'))
# Get-WuuTextWithoutComments, NOT Get-WuuCodeWithoutComments: the latter joins tokens with a space, which
# DISCARDS newlines (so Get-WuuFunctionBody, which slices to the next "\nfunction ", returns the whole
# file) and drops '$' (so a $-anchored pattern can never match). Its own docstring says to use this one
# when slicing a function body. Using the wrong one produced five false "missing" findings here - the
# same RAW-vs-tokenised mistake recorded in this project's gate notes.
$stateCodeAV = Get-WuuTextWithoutComments -Text $stateRawAV
$coreRawAV = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Core.psm1'))
$coreCodeAV = Get-WuuTextWithoutComments -Text $coreRawAV

foreach ($fnName in 'Get-WuuOperationRemainingSeconds', 'Get-WuuEffectiveInnerTimeout') {
    if ($stateCodeAV -notmatch "function\s+$fnName\b") {
        Fail "$fnName is missing - an inner probe cannot be capped by what is left of its operation's budget (P3)"
    }
}
# Reachability, not presence: the rule is worthless if the caller cannot resolve it.
$exportMatchAV = [regex]::Match($stateCodeAV, '(?s)Export-ModuleMember.*')
foreach ($fnName in 'Get-WuuOperationRemainingSeconds', 'Get-WuuEffectiveInnerTimeout') {
    if ($exportMatchAV.Success -and -not $exportMatchAV.Value.Contains($fnName)) {
        Fail "$fnName exists but is not exported - the payload call sites cannot reach it (P3)"
    }
}

# The floor and the no-fabricated-zero contract, asserted as PROPERTIES of the body rather than as text.
$remainBodyAV = Get-WuuFunctionBody -Text $stateCodeAV -Name 'Get-WuuOperationRemainingSeconds'
if ([string]::IsNullOrWhiteSpace($remainBodyAV)) {
    Fail 'Get-WuuFunctionBody could not extract Get-WuuOperationRemainingSeconds, so its contract is unverified (P3)'
} else {
    if ($remainBodyAV -notmatch "Known\s*=\s*\`$false") {
        Fail 'Get-WuuOperationRemainingSeconds has no explicit Known=$false path - a caller cannot tell "no deadline" from "expired" (P3)'
    }
    # A clamp here would hide the overshoot from the caller's log, which is the number an operator needs.
    if ($remainBodyAV -match 'Remaining[^\r\n]*=\s*\[math\]::Max\(\s*0') {
        Fail 'Get-WuuOperationRemainingSeconds CLAMPS Remaining to zero - the overshoot is then invisible to the caller (P3)'
    }
    if ($remainBodyAV -notmatch 'PSObject\.Properties') {
        Fail 'Get-WuuOperationRemainingSeconds does not guard property existence - production rows are PSCustomObjects and an unguarded read of a missing field is a silent no-op (P3)'
    } else {
        Pass 'Get-WuuOperationRemainingSeconds distinguishes "no deadline" from "deadline passed", and does not clamp overshoot (P3)'
    }
}

$effBodyAV = Get-WuuFunctionBody -Text $stateCodeAV -Name 'Get-WuuEffectiveInnerTimeout'
if ([string]::IsNullOrWhiteSpace($effBodyAV)) {
    Fail 'Get-WuuFunctionBody could not extract Get-WuuEffectiveInnerTimeout, so the min() rule is unverified (P3)'
} elseif ($effBodyAV -notmatch '\[math\]::Max\(') {
    Fail 'Get-WuuEffectiveInnerTimeout applies no FLOOR - an expiring probe would be handed a fractional or negative timeout (P3)'
} else {
    Pass 'Get-WuuEffectiveInnerTimeout caps to the remaining budget behind a floor (P3)'
}

foreach ($helperName in 'Invoke-CimWithTimeout', 'Invoke-ServiceWithTimeout') {
    $helperBodyAV = Get-WuuBalancedBody $coreCodeAV $helperName
    if ([string]::IsNullOrWhiteSpace($helperBodyAV)) {
        Fail "$helperName could not be extracted with a brace-balanced slice, so the budget wiring is unverified (P3)"
        continue
    }
    # FIXTURE SANITY: a slice that ran past this function would let the NEXT helper's code satisfy these
    # assertions. Without this, three checks below could pass while reading the wrong body.
    if ($helperBodyAV -match 'function\s+Invoke-(Cim|Service)WithTimeout') {
        Fail "the extracted body for $helperName contains another helper definition - the slice ran past the function and the checks below would inspect the wrong code (P3)"
        continue
    }
    if ($helperBodyAV -match 'Get-WuuEffectiveInnerTimeout\s*-|Get-WuuOperationRemainingSeconds\s*-') {
        Fail "$helperName CALLS a module function to apply the budget cap - these helpers run inside an isolated payload runspace where no module is imported, so the call throws on every production probe. Inline the arithmetic (P3)"
    } elseif ($helperBodyAV -notmatch "PSObject\.Properties\['TimeoutExpiresAt'\]") {
        Fail "$helperName does not read the operation deadline off its row, so an accepted -Row does nothing (P3)"
    } elseif ($helperBodyAV -notmatch '\[math\]::Max\(') {
        Fail "$helperName caps the timeout with no floor - an overdue operation passes a negative timeout to the API (P3)"
    } elseif ($helperBodyAV -notmatch '-TimeoutSeconds\s+\$effectiveTimeout') {
        # Capping into a variable that is then ignored is indistinguishable from not capping. The capped
        # value must be what the pool receives.
        Fail "$helperName computes a capped timeout but does not PASS it to the pool - the original timeout is still used, so the cap has no effect (P3)"
    } elseif ((Remove-WuuParamBlock $helperBodyAV) -match '-TimeoutSeconds\s+\$TimeoutSeconds\b') {
        # NEGATIVE ASSERTION, and it is the discriminating one. The check above is satisfied by
        # `$effectiveTimeout =` line alone, so a mutation that restores the UNCAPPED value at the pool call
        # still passed the gate - proven: the M3 tautology mutation ("pass the UNCAPPED timeout to the
        # pool") was caught by the suite and MISSED by the gate. Both directions are required: the capped
        # value must be passed, AND the original must not be.
        Fail "$helperName still passes its ORIGINAL `$TimeoutSeconds to the pool somewhere - the capped value is computed and then bypassed, so the cap has no effect on that call (P3)"
    } elseif ((Remove-WuuParamBlock $helperBodyAV) -match '\$TimeoutSeconds\s*=\s*[^=]') {
        # Reassigning a parameter is a gated defect class in this project: a declared type is enforced on
        # every assignment and a later coercion can throw where a local cannot. Scanned AFTER the param
        # block, so the DECLARATION is not mistaken for an assignment.
        Fail "$helperName reassigns its own `$TimeoutSeconds parameter instead of a local - a gated defect class here (P3)"
    } else {
        Pass "$helperName applies the remaining-budget cap inline, with a floor, passes the capped value on, and never reassigns its parameter (P3)"
    }
}

# THE CALL SITES. A helper caps only when handed a row, so a call site that omits -Row silently opts out
# of the entire mechanism - and the omission is invisible at runtime, because the probe simply keeps its
# old fixed timeout. Nothing else in this gate would notice.
$innerCallSitesAV = [regex]::Matches($coreCodeAV, 'Invoke-(?:Cim|Service)WithTimeout\s+(?=-[A-Za-z])[^\r\n]*')
$callsWithRowAV = 0
$callsMissingRowAV = New-Object System.Collections.ArrayList
foreach ($csAV in $innerCallSitesAV) {
    if ($csAV.Value -match '-Row\s+\$Computer') { $callsWithRowAV++ }
    else { $null = $callsMissingRowAV.Add($csAV.Value.Trim()) }
}
if ($innerCallSitesAV.Count -eq 0) {
    Fail 'no inner-timeout invocations were found in Wuu.Core - either the matcher broke or the probes were removed, and in both cases the budget wiring is unverified (P3)'
} elseif ($callsMissingRowAV.Count -gt 0) {
    Fail "$($callsMissingRowAV.Count) inner-timeout call site(s) omit -Row, so those probes silently keep their fixed timeout and escape the budget cap entirely: $($callsMissingRowAV -join ' | ') (P3)"
} else {
    Pass "all $callsWithRowAV inner-timeout call sites pass the row they already hold, so every probe is subject to the budget cap (P3)"
}

# DRIVE THE RULE. A predicate that always returns one answer would satisfy every check above.
#
# The assertions below pin EXACT remainders, which was impossible before the clock was fixed. The
# function truncates toward zero, so a deadline set a few milliseconds before it is read turned a
# 6-second budget into a 5-second answer, and asserting "exactly 6" failed for a cap that was working
# perfectly. With -Now pinned to the deadline's own base the remainder is exact (20.0 -> 20, not
# 19.99... -> 19), so the assertion can be exact AND the verdict is the same on every run.
if (Get-Command Get-WuuEffectiveInnerTimeout -ErrorAction SilentlyContinue) {
    try {
        $budgetRowAV = New-WuuComputerRow -Computer 'GATE-BUDGET-PROBE'
        $noDeadlineAV = Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds 30 -Row $budgetRowAV

        # ONE FIXED INSTANT for every probe. Without it the remainder depends on the sub-millisecond
        # moment each call samples the clock: AddSeconds(20) followed by a call a few ms later gives
        # 19.99... -> floor 19, but a call landing in the same millisecond gives exactly 20. So the
        # VERDICT TEXT changed between runs ("caps the 30s probe to 19s" or "to 20s") and no two runs
        # produced the same report - which is what made this gate impossible to diff or compare in CI.
        # Passing the deadline's own base as -Now makes the remainder exact and the verdict
        # reproducible WITHOUT weakening the check: the real function is still driven, on a real row,
        # with a real deadline, and the floor/cap/uncapped shapes are still asserted.
        $probeNowAV = Get-Date

        $budgetRowAV.TimeoutExpiresAt = $probeNowAV.AddSeconds(600)
        $looseAV = Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds 30 -Row $budgetRowAV -Now $probeNowAV

        # A distinctly tiny budget: the floor is the only thing that can produce the answer.
        $budgetRowAV.TimeoutExpiresAt = $probeNowAV.AddSeconds(1)
        $floorAV = Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds 30 -Row $budgetRowAV -Now $probeNowAV

        # A tight but non-trivial budget: the cap must bind, and land at or just under the budget.
        $budgetRowAV.TimeoutExpiresAt = $probeNowAV.AddSeconds(20)
        $tightAV = Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds 30 -Row $budgetRowAV -Now $probeNowAV
        $budgetLeftAV = [int](($budgetRowAV.TimeoutExpiresAt - $probeNowAV).TotalSeconds)

        # Indexed access: the function returns a HASHTABLE, and .PSObject.Properties does not surface
        # hashtable keys (the same trap that already produced one false finding in this gate).
        if ($noDeadlineAV['Seconds'] -ne 30 -or $noDeadlineAV['Capped']) {
            Fail "an operation with no recorded deadline had its inner timeout changed (got $($noDeadlineAV['Seconds'])s) - the cap must apply only where a budget exists, and inventing one changes every unscheduled submission (P3)"
        } elseif ($looseAV['Seconds'] -ne 30 -or $looseAV['Capped']) {
            Fail "a generous budget inflated a 30-second probe (got $($looseAV['Seconds'])s) - the probe's own timeout is the ceiling and must not be overridden upward (P3)"
        } elseif ($floorAV['Seconds'] -ne 5 -or -not $floorAV['Capped']) {
            Fail "a 1-second remaining budget did not produce the 5-second floor (got $($floorAV['Seconds'])s, capped=$($floorAV['Capped'])) - an expiring probe would be handed a timeout too small to be answered, or a negative one, which the API rejects (P3)"
        } elseif (-not $tightAV['Capped']) {
            Fail "a 20-second remaining budget did not cap a 30-second probe (got $($tightAV['Seconds'])s) - the cap is inert (P3)"
        } elseif ($tightAV['Seconds'] -ne 20) {
            # EXACT, because the clock is pinned: 20 seconds left must cap the 30-second probe to 20.
            # $budgetLeftAV is reported too: when this fails, "the budget read 20 but the cap gave 19"
            # and "the budget read 19" are different diagnoses, and the message must tell them apart.
            Fail "a 20-second remaining budget capped the 30-second probe to $($tightAV['Seconds'])s, not 20s (budget read $($budgetLeftAV)s) - the cap is not using the remaining budget (P3)"
        } else {
            Pass "the remaining-budget rule is live: no deadline leaves 30s uncapped, 600s left keeps 30s, 1s left floors to 5s, and 20s left caps the 30s probe to $($tightAV['Seconds'])s (P3)"
        }
    } catch {
        Fail "the remaining-budget rule threw when driven instead of returning a verdict: $($_.Exception.Message) (P3)"
    }
} else {
    Fail 'Get-WuuEffectiveInnerTimeout could not be resolved, so the budget rule was never driven (P3)'
}

# (aw) EXTERNAL AUDIT ANCHORING (P3). A hash chain is tamper-EVIDENT only to someone who already knows
#      what the head was: anyone with write access to the log AND the code can recompute a complete,
#      internally consistent chain over their own edits, and Test-WuuAuditChain then reports a clean log.
#      That is a property of every hash chain, not a defect in this one, and more hashing does not fix it.
#      The fix is holding the head somewhere the log's editor does not control, and comparing.
#
#      The check that matters is not "the functions exist" but "the SAME-DIRECTORY REFUSAL exists": an
#      anchor written beside the log is written through the same access path as the log, so it proves
#      nothing while looking like it proves everything. The gate drives that refusal, and drives a
#      REWRITTEN chain, because an anchoring check that passes on a rewritten log is decoration.
$auditCodeAW = Get-WuuTextWithoutComments -Text ([System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Audit.psm1')))
foreach ($fnName in 'New-WuuAuditAnchor', 'Test-WuuAuditAnchor', 'Get-WuuAuditRecordAtSeq') {
    if ($auditCodeAW -notmatch "function\s+$fnName\b") {
        Fail "$fnName is missing - the audit chain head cannot be anchored outside the log it describes (P3)"
    }
}
$auditExportAW = [regex]::Match($auditCodeAW, '(?s)Export-ModuleMember.*')
foreach ($fnName in 'New-WuuAuditAnchor', 'Test-WuuAuditAnchor') {
    if ($auditExportAW.Success -and -not $auditExportAW.Value.Contains($fnName)) {
        Fail "$fnName is not exported - the anchor must be written and compared by a caller that HOLDS it elsewhere (P3)"
    }
}

$anchorBodyAW = Get-WuuFunctionBody -Text $auditCodeAW -Name 'New-WuuAuditAnchor'
if ([string]::IsNullOrWhiteSpace($anchorBodyAW)) {
    Fail 'Get-WuuFunctionBody could not extract New-WuuAuditAnchor, so the separation control is unverified (P3)'
} else {
    # The refusal is the control. Assert it in the BODY, not in the function's docstring above it - and
    # require the SEPARATION to be named, not merely the word "refuse": the function has an unrelated
    # refusal path for un-normalisable paths, so 'refus' alone can survive the removal of the
    # same-directory check. The dry-run harness pins this message as the M4 detection needle.
    if ($anchorBodyAW -notmatch 'refus') {
        Fail 'New-WuuAuditAnchor does not refuse anything - an anchor in the log''s own directory would be written and would offer no separation from what it anchors (P3)'
    } elseif ($anchorBodyAW -notmatch 'no separation') {
        Fail 'New-WuuAuditAnchor compares directories but never says the anchor offers no separation - the same-directory refusal may have been dropped while an unrelated refusal path kept the word "refuse" in the body (P3)'
    } elseif ($anchorBodyAW -notmatch 'GetFullPath|DirectoryName') {
        Fail 'New-WuuAuditAnchor does not compare the anchor and log directories, so "beside the log" cannot be detected (P3)'
    } else {
        Pass 'New-WuuAuditAnchor compares the anchor directory against the log directory and refuses to offer false separation (P3)'
    }
    # Honesty about what the artifact is. Overstating it is worse than not having it.
    foreach ($needle in 'tamper-evident', 'NOT non-repudiation') {
        if ($anchorBodyAW -notmatch [regex]::Escape($needle)) {
            Fail "New-WuuAuditAnchor does not record that it is $needle - an operator would have to infer the limit of the guarantee (P3)"
        }
    }
}

# DRIVE IT. A rewrite the chain verifier calls clean must be caught; a missing anchor must NOT read as
# consistent, because absence of evidence is not evidence of integrity.
if ((Get-Command New-WuuAuditAnchor -ErrorAction SilentlyContinue) -and (Get-Command Test-WuuAuditAnchor -ErrorAction SilentlyContinue)) {
    $anchorBaseAW = Join-Path ([System.IO.Path]::GetTempPath()) ('wuu-gate-anchor-' + [guid]::NewGuid().ToString('N'))
    $anchorLogDirAW = Join-Path $anchorBaseAW 'logs'
    $anchorDirAW = Join-Path $anchorBaseAW 'anchors'
    $anchorForgedDirAW = Join-Path $anchorBaseAW 'forged'
    try {
        $null = New-Item -ItemType Directory -Path $anchorLogDirAW, $anchorDirAW, $anchorForgedDirAW -Force
        $writeRealLogAW = {
            param([string]$Directory, [string[]]$Messages)
            $s = Start-WuuAuditSession -Directory $Directory -Action 'gate-anchor-probe'
            foreach ($m in $Messages) {
                $null = Write-WuuAuditRecord -Session $s -Action 'gate-probe' -Category 'operational' -Result 'info' -Parameters @{ message = $m }
            }
            return (Join-Path $Directory ("audit-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd')))
        }
        $realLogAW = & $writeRealLogAW $anchorLogDirAW @('alpha', 'beta', 'gamma')
        $anchorFileAW = Join-Path $anchorDirAW 'anchor.json'
        $madeAW = New-WuuAuditAnchor -LogPath $realLogAW -AnchorPath $anchorFileAW -Operator 'GATE'

        if (-not $madeAW.Written) {
            Fail "New-WuuAuditAnchor did not write an anchor for a valid log ($($madeAW.Reason)) (P3)"
        } else {
            $sameDirAW = New-WuuAuditAnchor -LogPath $realLogAW -AnchorPath (Join-Path $anchorLogDirAW 'beside.json') -Operator 'GATE'
            if ($sameDirAW.Written) {
                Fail 'New-WuuAuditAnchor wrote an anchor into the log''s own directory - that anchor is written through the same access path as the log, so it offers no separation and proves nothing (P3)'
            } else {
                Pass 'the same-directory anchor is refused, so the separation that makes anchoring meaningful is enforced (P3)'
            }

            $cleanAW = Test-WuuAuditAnchor -LogPath $realLogAW -AnchorPath $anchorFileAW
            if (-not $cleanAW.Consistent) {
                Fail "an unchanged log did not compare consistent against its own anchor ($($cleanAW.Reason)) (P3)"
            } else {
                # THE DRIVING CASE: a chain rebuilt by the real writer verifies clean on its own terms, so
                # only the anchor can catch it. If this ever stops failing, the anchoring is decoration.
                $forgedLogAW = & $writeRealLogAW $anchorForgedDirAW @('FORGED-1', 'FORGED-2', 'FORGED-3')
                $forgedChainAW = Test-WuuAuditChain -LogPath $forgedLogAW -Quiet
                $forgedAnchorAW = Test-WuuAuditAnchor -LogPath $forgedLogAW -AnchorPath $anchorFileAW
                if (-not $forgedAnchorAW.Rewritten) {
                    Fail 'a REWRITTEN audit chain - internally consistent, and therefore reported clean by hash verification - was NOT caught by the anchor, which means anchoring adds no detection (P3)'
                } elseif (-not $forgedChainAW.Ok) {
                    # If the forged log did not verify clean, the case above proves nothing: it would have
                    # been caught by hashing alone.
                    Fail 'the forged-chain probe did not verify clean, so the anchoring check was not exercised against a chain that hashing alone accepts (P3)'
                } else {
                    Pass 'a rewritten chain that hash verification accepts is caught by the external anchor, and a same-directory anchor is refused (P3)'
                }
            }

            $missingAW = Test-WuuAuditAnchor -LogPath $realLogAW -AnchorPath (Join-Path $anchorDirAW 'absent.json')
            if ($missingAW.Consistent) {
                Fail 'a MISSING anchor was reported as consistent - absence of evidence must not read as evidence of integrity (P3)'
            } else {
                Pass 'a missing anchor reports unavailable rather than consistent, so an unanchored log is never presented as verified (P3)'
            }
        }
    } catch {
        Fail "the audit anchoring probe threw instead of returning verdicts: $($_.Exception.Message) (P3)"
    } finally {
        try { Remove-Item $anchorBaseAW -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
} else {
    Fail 'the audit anchoring functions could not be resolved, so nothing was driven (P3)'
}
