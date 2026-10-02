# Release validation, Engine scheduling admission and state store. Extracted from Validate-Release.ps1 (instructions SS39).
#
# DOT-SOURCED FRAGMENT - not a standalone script. Validate-Release.ps1 dot-sources it into its own
# scope, which is what gives this file $root, the verdict helpers (Pass/Fail/Warn/Skip/Not-Implemented)
# and any variable the gate computed above the dot-source line. It is dot-sourced AT ITS ORIGINAL
# POSITION because the order of the verdict list is part of what CI reads.

# (s) The scheduler and phase gating must read the STATE STORE, not a display collection. Checked
#     separately from (r) so a regression that swapped Listview for some other non-store collection
#     is also caught.
#
#     Matched against RAW text with a bounded window, NOT the token-stripped text: the tokenizer
#     discards newlines (it rebuilds from token content joined by spaces), so a `.*?\n\}` body
#     pattern can never match there. A window after the function name is simpler and has no
#     escaping traps.
$wupdRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw
foreach ($fn in @('Start-PendingUpdateCheck', 'Test-PhaseCompletion')) {
    $idx = $wupdRaw.IndexOf("function $fn")
    if ($idx -lt 0) { Fail "could not locate function $fn in Wuu.WindowsUpdate.psm1" }
    else {
        $window = $wupdRaw.Substring($idx, [Math]::Min(4000, $wupdRaw.Length - $idx))
        if ($window -notmatch 'Get-WuuComputerRow') {
            Fail "$fn does not read the state store (Get-WuuComputerRow) - the queue/phase gate would be empty"
        }
    }
}
if (-not $failed) { Pass 'scheduler and phase gating read the state store, not a display collection' }

# (t) The three auto-setting gates must read $stateStore.Settings. A revert to a GUI member is
#     already caught by (r); this catches a revert to something else entirely (a hard-coded $true,
#     or a different variable).
#
#     TWO escaping traps here, and this gate hit both in sequence - worth recording because the
#     failure mode of each was a FALSE FAILURE, which is how a gate gets disabled by whoever is
#     trying to ship:
#       1. In a DOUBLE-quoted PowerShell string, `\$` is NOT an escape - the backslash survives and
#          the variable interpolates to ''. The pattern silently became `\.Settings\.AutoDownload`.
#       2. Even correctly single-quoted, a bare `$stateStore` in a REGEX is an end-of-line ANCHOR,
#          so it can never match mid-line. It must be `\$stateStore`.
#     Both directions are why this pattern is single-quoted with -f AND backslash-escaped.
$coreRaw4 = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
foreach ($setting in @('AutoDownload', 'AutoInstall', 'AutoReboot')) {
    $pattern = '\$stateStore\.Settings\.{0}\b' -f $setting
    if ($coreRaw4 -notmatch $pattern) {
        Fail "no gate reads `$stateStore.Settings.$setting - that automatic behaviour cannot be controlled"
    }
}
if (-not $failed) { Pass 'all three automatic behaviours are gated on $stateStore.Settings' }

# (t2) The MASTER automation toggle must be deterministic, not three independent inversions.
#
#      `$s.AutoX = -not $s.AutoX` for each setting looks symmetrical and is what a "toggle" is
#      usually assumed to mean - but from a MIXED state it produces a different mixture, so the
#      operator cannot predict the result of the control they press precisely when unsure of the
#      current state. From `ON / OFF / OFF` it yields `OFF / ON / OFF`: auto-install is ENABLED while
#      the operator was aiming to turn everything off.
#
#      The specified rule is absolute: ALL ON -> all off; anything else -> all on.
#
#      Matched on the AST's assignment nodes, so a comment explaining the old behaviour (as this one
#      does) cannot match itself - the false-positive class recorded at (r) and gate 2.
$coreAstA = $null
try { $coreAstA = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src\Wuu.Core.psm1'), [ref]$null, [ref]$null) } catch { $coreAstA = $null }
if (-not $coreAstA) {
    Fail 'could not parse Wuu.Core.psm1, so the master-toggle check would pass vacuously'
} else {
    $settingNames = @('AutoDownload', 'AutoInstall', 'AutoReboot')
    $inverting = @()
    foreach ($assign in $coreAstA.FindAll({
                $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $args[0].Left -is [System.Management.Automation.Language.MemberExpressionAst]
            }, $true)) {
        # The member name must be read from the AST node it actually is. `$s.AutoX` parses as
        # MemberExpressionAst whose Member is a StringConstantExpressionAst - which has NO
        # .VariablePath (that is on VariableExpressionAst). Reading .VariablePath anyway yields
        # $null in PS 5.1 rather than throwing, so the name compared as $null, the loop skipped every
        # assignment, and this check PASSED against the pre-fix code. Found by mutation-testing the
        # gate itself; the first version of this block was vacuous.
        $memberName = ''
        if ($assign.Left.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $memberName = [string]$assign.Left.Member.Value
        } elseif ($assign.Left.Member -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $memberName = [string]$assign.Left.Member.VariablePath.UserPath
        }
        if ($settingNames -notcontains $memberName) { continue }
        # -not applied to the SAME setting is the inverting shape. The regex is built from the name so
        # `-not $other.AutoDownload` cannot satisfy a check for AutoInstall.
        if ($assign.Right.Extent.Text -match ('-not\s+\$\w*\.?' + [regex]::Escape($memberName) + '\b')) {
            $inverting += "line $($assign.Extent.StartLineNumber): $($assign.Extent.Text.Trim())"
        }
    }

    # POSITIVE CONTROL, and it has to assert the RIGHT thing. Requiring N member-assignments would be
    # wrong: the corrected handler has ZERO, because it routes through the settings funnel. The
    # invariant is therefore two-sided -
    #   * the handler must not invert (checked above), and
    #   * it must SET through the funnel, so a revert to direct assignments is caught rather than
    #     reading as "nothing to see here".
    # Counting the funnel calls also proves this check is looking at the handler at all, which is what
    # the first attempted control was reaching for.
    $toggleHandler = $coreAstA.FindAll({
            $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $args[0].Extent.Text -match '^\s*\$consoleActions\.EventToggleSettings'
        }, $true) | Select-Object -First 1
    $funnelCalls = 0
    if ($toggleHandler) {
        foreach ($call in $toggleHandler.Right.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            if ($call.GetCommandName() -eq 'Set-WuuSetting') { $funnelCalls++ }
        }
    }
    if (-not $toggleHandler) {
        Fail 'the master toggle handler could not be located, so the inversion check could not run'
    } elseif ($inverting.Count -gt 0) {
        Fail ("automation setting(s) are INVERTED rather than set to an explicit value, so the master toggle is not deterministic (ALL ON -> all off, anything else -> all on): " + ($inverting -join '; '))
    } elseif ($funnelCalls -lt 3) {
        Fail "the master toggle makes only $funnelCalls call(s) to Set-WuuSetting - it must set all three settings through the settings funnel, not assign them directly"
    } else {
        Pass "the master automation toggle sets all three settings through the funnel and never inverts ($funnelCalls funnel call(s))"
    }
}

# (u) ONE ACTIVE OPERATION PER COMPUTER (brief SS3 / invariant 8.1). The gate must be consulted at the
#     submission point, the row must be marked Running so the gate can ever say "busy", and the claim
#     must use the sanctioned adoption path if it goes through the mutation funnel. Appendix A cites
#     this block for invariant 8.1, so the header is load-bearing: without it the citation pointed at
#     nothing and a reader could not find the check.
$supBody = Get-WuuFunctionBody $wupdRaw 'Start-UpdateCheckJob'
if (-not $supBody) { Fail 'could not locate Start-UpdateCheckJob' }
else {
    # The gate must be consulted BEFORE the submission, and the row must be marked Running.
    if ($supBody -notmatch 'Test-WuuComputerBusy') {
        Fail 'Start-UpdateCheckJob does not consult Test-WuuComputerBusy - a second operation on a busy computer would be silently discarded'
    }
    elseif ($supBody -notmatch "OpState\s*=\s*'Running'" -and $supBody -notmatch "-OpState\s*'Running'") {
        # SS16: the claim may be made either by a direct assignment or by the mutation funnel, which
        # takes OpState as a parameter. Both are accepted; NOTHING that leaves the row unmarked is.
        Fail 'Start-UpdateCheckJob does not mark the computer Running - the gate could never say busy'
    }
    elseif ($supBody -match 'Update-WuuOperationState' -and $supBody -notmatch 'OperationIdNew') {
        # If the claim goes through the funnel, it must use the sanctioned ADOPTION path - otherwise
        # the funnel's identity check would compare the new id against the row's old one and refuse a
        # legitimate submission.
        Fail 'the submission claims through the funnel without -OperationIdNew, so the identity check would refuse its own resubmission'
    }
}
$stateRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw
if ($stateRaw -notmatch 'function Test-WuuComputerBusy') { Fail 'Test-WuuComputerBusy is not defined' }
elseif ($stateRaw -notmatch "'Test-WuuComputerBusy'") { Fail 'Test-WuuComputerBusy is not exported (Start-UpdateCheckJob could not resolve it)' }
if (-not $failed) { Pass 'one operation per computer is enforced at the submission point (SS3)' }

# (v) The scheduler must not treat Pending as "busy". Its input queue IS the Pending rows, so doing
#     so would make it skip every row it was handed, for ever - a deadlock that still passes a
#     naive "does it read the store" check. The -IgnorePending switch is what prevents it.
$schedBody = Get-WuuFunctionBody $wupdRaw 'Start-PendingUpdateCheck'
if (-not $schedBody) { Fail 'could not locate Start-PendingUpdateCheck' }
else {
    if ($schedBody -match 'Test-WuuComputerBusy' -and $schedBody -notmatch 'IgnorePending') {
        Fail 'the scheduler consults Test-WuuComputerBusy without -IgnorePending - it would skip every Pending row for ever'
    }
    # The gate must run BEFORE Pending is cleared, or a refusal loses the request.
    $gateAt = $schedBody.IndexOf('Test-WuuComputerBusy')
    $clearAt = $schedBody.IndexOf('$item.Pending = $false')
    if ($gateAt -ge 0 -and $clearAt -ge 0 -and $gateAt -gt $clearAt) {
        Fail 'the scheduler clears Pending BEFORE checking busy - a refused request would be lost'
    }
}
if (-not $failed) { Pass 'the scheduler does not deadlock on its own Pending queue' }

# (w) OpState must be RELEASED on every path a job can leave the queue, or a computer becomes
#     permanently 'busy' and unschedulable - worse than the timeout it was recovering from.
$coreRaw5 = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$releaseCount = ([regex]::Matches($coreRaw5, "OpState\s*=\s*'Idle'")).Count
if ($releaseCount -gt 0) {
    # Two release sites are expected: the completion/failure path and the timeout path.
    if ($releaseCount -lt 3) {
        Fail "only $releaseCount OpState release site(s) found in Wuu.Core - each job-exit path needs one or a computer stays permanently busy"
    } else { Pass "per-computer operation state is released on every job-exit path ($releaseCount sites)" }
} elseif ($coreRaw5 -match 'OpState\s*=\s*''Running''') {
    Fail 'Wuu.Core sets OpState=Running but never releases it - computers would stay permanently busy'
} else { Pass 'per-computer operation state released in the cleanup loop' }

# (x) ONE SUBMISSION POINT (brief SS4). Every per-computer operation must go through
#     Start-UpdateCheckJob. A handler that composes its own [powershell]::Create().AddScript(...)
#     .BeginInvoke() bypasses the per-computer gate AND the global MaxConcurrentJobs cap - which is
#     exactly how EventGetUpdates took an unguarded branch on every re-check, and how four other
#     handlers submitted to busy runspaces without the gate being able to see them.
#
#     The check counts per-computer submission sites in Wuu.Core. The two BeginInvoke calls that are
#     legitimately NOT submissions are allowed by name:
#       * $searchPS / $rebootPS - bounded sub-pipelines INSIDE the update payload, not job submissions;
#       * $jobCleanup.PowerShell - the cleanup runspace, started once at wiring time.
$coreCode3 = Get-WuuCodeWithoutComments -Path (Join-Path $root 'src\Wuu.Core.psm1')
$allowed = @('$searchHandle', '$rebootHandle', '$jobCleanup.Thread')
$badSubmits = @()
foreach ($line in ($coreCode3 -split "`n")) {
    if ($line -match '\.BeginInvoke\(') {
        $isAllowed = $false
        foreach ($a in $allowed) { if ($line -match [regex]::Escape($a)) { $isAllowed = $true } }
        if (-not $isAllowed) { $badSubmits += $line.Trim() }
    }
}
if ($badSubmits.Count) {
    Fail ("per-computer submission(s) outside Start-UpdateCheckJob - these bypass the operation gate and the global cap: " + ($badSubmits -join ' | '))
} else { Pass 'all per-computer operations go through the single submission point (SS4)' }

# ...and the submission function must actually support the ops the handlers now request, or a
# delegation would fail at runtime with an invalid ValidateSet argument.
$supBody2 = Get-WuuFunctionBody $wupdRaw 'Start-UpdateCheckJob'
foreach ($op in @('Restart', 'RemoveOffline', 'ServiceAction')) {
    if ($supBody2 -notmatch "'$op'") { Fail "Start-UpdateCheckJob cannot accept the '$op' op - the console handlers delegate to it" }
}
if (-not $failed) { Pass 'the submission point supports every op the console handlers delegate' }

# (y) PHASE FAILURE POLICY (brief SS9). Three properties, because each can fail alone:
#     1. the policy is a validated setting with a safe default;
#     2. the phase gate consults it rather than skipping failures unconditionally (the old
#        `continue`, which hard-coded ContinueOnFailure);
#     3. a settled failure is evaluated BEFORE the outstanding-work check. Without that ordering the
#        policy is DEAD CONFIGURATION: an errored row also fails `UpdatesStatus -ne 'All updates
#        installed'`, so the phase could never complete and ContinueOnFailure/ContinueOnTimeout had no
#        effect on the only case they exist for. This ordering bug was found by the policy test.
$stateRaw2 = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw
if ($stateRaw2 -notmatch 'function Test-WuuPhaseFailureBlocks') {
    Fail 'Test-WuuPhaseFailureBlocks is not defined (SS9 has no decision function)'
} elseif ($stateRaw2 -notmatch "'Test-WuuPhaseFailureBlocks'") {
    Fail 'Test-WuuPhaseFailureBlocks is not exported - the phase gate could not resolve it'
} elseif ($stateRaw2 -notmatch "PhaseFailurePolicy\s*=\s*'BlockOnFailure'") {
    Fail 'the phase failure policy has no safe default of BlockOnFailure'
} else { Pass 'phase failure policy exists, is exported, and defaults to BlockOnFailure (SS9)' }

$phaseBody = Get-WuuFunctionBody $wupdRaw 'Test-PhaseCompletion'
if (-not $phaseBody) { Fail 'could not locate Test-PhaseCompletion' }
else {
    if ($phaseBody -notmatch 'Test-WuuPhaseFailureBlocks') {
        Fail 'Test-PhaseCompletion does not consult the failure policy - it would block or pass on failures unconditionally'
    }
    $policyAt = $phaseBody.IndexOf('Test-WuuPhaseFailureBlocks')
    $outstandingAt = $phaseBody.IndexOf("UpdatesStatus -ne 'All updates installed'")
    if ($policyAt -ge 0 -and $outstandingAt -ge 0 -and $policyAt -gt $outstandingAt) {
        Fail 'the failure policy is evaluated AFTER the outstanding-work check - tolerated failures could never complete a phase (dead configuration)'
    } else { Pass 'the phase gate evaluates the failure policy before outstanding work (policy is not dead configuration)' }
}

# (z) ICMP MUST NOT DECIDE STATE (brief SS7 / SS12), and inventory must not be evicted on one probe.
#
#     Two separate hazards, both real:
#       * SS7: the reboot wait was `While(Test-Connection ...)`, which NEVER terminates against a host
#         that blocks echo (the Windows Firewall default) - the loop burns its full window and then
#         reports a healthy reboot as FAILED.
#       * SS12: `$RemoveOfflineComputer` deleted the row on a single failed ping, so one lost packet
#         silently removed a server from the managed set and it stopped being patched.
#
#     Evaluated against COMMENT-STRIPPED text. This is load-bearing in BOTH directions here: my own
#     migration comments quote "Test-Connection" while explaining its removal, so raw text gives a
#     false failure (observed), while a pattern inside a string would be missed by a naive regex
#     (which is why the tokenizer is used rather than a '#.*$' strip).
$coreCodeOnly = Get-WuuCodeWithoutComments -Path (Join-Path $root 'src\Wuu.Core.psm1')
$offIdx = $coreCodeOnly.IndexOf('RemoveOfflineComputer =')
if ($offIdx -lt 0) { Fail 'could not locate the RemoveOfflineComputer payload' }
else {
    $offBody = $coreCodeOnly.Substring($offIdx, [Math]::Min(2500, $coreCodeOnly.Length - $offIdx))
    if ($offBody -match 'Test-Connection') {
        Fail 'the connectivity payload still decides with Test-Connection - one lost ICMP packet can evict a healthy computer (SS12)'
    } elseif ($offBody -notmatch 'Test-WuuManagementEndpoint') {
        Fail 'the connectivity payload does not use the management-endpoint probe'
    }
}
$rIdx = $coreCodeOnly.IndexOf('RestartComputer =')
if ($rIdx -lt 0) { Fail 'could not locate the RestartComputer payload' }
else {
    $rBody = $coreCodeOnly.Substring($rIdx, [Math]::Min(7000, $coreCodeOnly.Length - $rIdx))
    if ($rBody -match 'Test-Connection') {
        Fail 'the reboot wait still uses ICMP - it cannot terminate on a host that blocks echo (SS7)'
    }
    if ($rBody -notmatch 'Restart-Computer') {
        Fail 'the reboot payload never issues Restart-Computer (dropped once during editing; the host would never reboot)'
    }
    if ($rBody -notmatch 'Test-WuuManagementEndpoint') {
        Fail 'the reboot wait does not use the management-endpoint probe'
    }
}
if (-not $failed) { Pass 'no ICMP-decided state transition remains, and the restart is still issued (SS7/SS12)' }

# ...and the eviction decision must go through the tested function, not inline payload logic that is
# unreachable from a test scope (which is how a one-packet delete survived).
$stateRaw3 = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw
if ($stateRaw3 -notmatch 'function Update-WuuConnectivityState') {
    Fail 'Update-WuuConnectivityState is not defined - the SS12 decision is not testable'
} elseif ($stateRaw3 -notmatch "'Update-WuuConnectivityState'") {
    Fail 'Update-WuuConnectivityState is not exported'
} elseif ($coreCodeOnly -notmatch 'Update-WuuConnectivityState') {
    Fail 'the connectivity payload does not delegate to Update-WuuConnectivityState'
} else { Pass 'the connectivity decision is a tested function, and the payload delegates to it (SS12)' }
