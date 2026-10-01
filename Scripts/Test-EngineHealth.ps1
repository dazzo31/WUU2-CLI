# Release validation, ENGINE HEALTH: pool diagnostics, terminal state and the direct-write ratchet
# (SS39). Extracted from Validate-Release.ps1.
#
# WHAT IS IN HERE:
#   (at) worker pool diagnostics - capacity, utilisation, abandoned wrappers, starvation
#   (ax) the pool-versus-cap invariant - the pool must be able to run every operation the cap admits
#   (au) CI must use the machine-readable modes and take its summary from the report, not from text
#   (ay) invariant 8.4 - terminal operations stay terminal, driven on real functions
#   (az) direct operation-state writes outside Wuu.State - a RATCHET: it fails if the count rises
#
# (as), the report/verdict-kind check, is NOT here. It reads the gate's OWN source for its
# writer/exit ORDER window, and inside a dot-sourced file $PSCommandPath resolves to the FRAGMENT
# (measured, not assumed) - so that window would be measured against the wrong file. It stays in the
# gate, immediately before this dot-source, and its verdicts keep their position.
#
# DOT-SOURCED FRAGMENT - not a standalone script. Validate-Release.ps1 dot-sources it into its own
# scope AT THE POSITION THESE BLOCKS OCCUPIED, which is what gives this file $root, the verdict
# helpers, the shared harness helpers, and the variables the gate computed above it.

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
