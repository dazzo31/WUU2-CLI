# Release validation, CONSOLE CONTRACT group: guided navigation, handler resolution, reason gating, retry narrowing, offline handling. Extracted from Validate-Release.ps1 (instructions SS39).
#
# DOT-SOURCED FRAGMENT - not a standalone script. Validate-Release.ps1 dot-sources it into its own
# scope, which is what gives this file $root, the verdict helpers (Pass/Fail/Warn/Skip/Not-Implemented)
# and any variable the gate computed above the dot-source line. It is dot-sourced AT ITS ORIGINAL
# POSITION because the order of the verdict list is part of what CI reads.

# (a) Spec 3 / P0: acquisition must be the ENTRY state when the set is empty. If this regresses the
#     app once again exposes update operations before it knows what it is managing.
if ($navRaw -notmatch "'DASHBOARD'\s*\}\s*else\s*\{\s*'ACQUIRE'") {
    Fail 'guided workflow does not start at ACQUIRE for an empty computer set (spec 3 / P0)'
} else { Pass 'guided workflow starts at computer acquisition when the set is empty' }

# (b) Spec 9: top-level navigation must be grouped.
if ($navRaw -notmatch 'function\s+Get-WuuNavigationTree') {
    Fail 'no Get-WuuNavigationTree - the top-level navigation is not grouped (spec 9)'
} else { Pass 'top-level navigation tree exists (grouped, spec 9)' }

# (c) Spec 23: the guided UI must DELEGATE, not reimplement. A guided screen calling an update
#     engine function directly would fork the engine and bypass the audit reason rule.
$engineHits = @([regex]::Matches($navRaw, '\b(Start-UpdateCheckJob|Start-PendingUpdateCheck|Invoke-WuuRemoteTask|New-ComputerRunspace)\b'))
if ($engineHits.Count -gt 0) {
    Fail "Wuu.Navigate calls the engine directly ($($engineHits[0].Value)) - it must delegate to the action layer (spec 23)"
} else { Pass 'guided workflow delegates to the action layer (no direct engine calls, spec 23)' }

# (d) Every menu entry that names a Handler must resolve to a real $consoleActions assignment.
#     This is the gate that catches the unwired-handler defect class ($eventAddAD was implemented,
#     unreachable and invisible to every test because nothing could invoke it).
$wired = @{}
foreach ($m in [regex]::Matches($coreRaw2, '\$consoleActions\.(\w+)\s*=')) { $wired[$m.Groups[1].Value] = $true }
$named = @()
foreach ($m in [regex]::Matches($navRaw, "Handler\s*=\s*'(\w+)'")) { $named += $m.Groups[1].Value }
foreach ($m in [regex]::Matches($conRaw, "Handler\s*=\s*'(\w+)'")) { $named += $m.Groups[1].Value }
$dead = @($named | Where-Object { $_ -and -not $wired.ContainsKey($_) } | Sort-Object -Unique)
if ($dead.Count -gt 0) {
    Fail "menu entries name handlers that are never wired into `$consoleActions: $($dead -join ', ')"
} else { Pass "every menu entry resolves to a wired handler ($($named.Count) references checked)" }

# (e) The audit subverbs used by the Reports category must be exported, or those entries fail at
#     runtime with "not recognized" - a dead entry that only appears when the operator selects it.
if ($cmdRaw -notmatch "'Invoke-WuuAuditCommand'") {
    Fail 'Invoke-WuuAuditCommand is not exported - the guided Reports/audit entries would fail at runtime'
} else { Pass 'audit subverbs are exported for the guided Reports menu' }

# (f) Spec 25 P0: mutating operations in the guided flow must be FLAGGED as mutating, or they
#     bypass the required-reason audit rule.
$updMenu = [regex]::Match($navRaw, '(?s)function\s+Get-WuuUpdateManagementMenu.*?\n\}').Value
$unflagged = @()
foreach ($mut in @('EventDownloadUpdates', 'EventInstallUpdates', 'EventRestartComputer')) {
    if ($updMenu -notmatch "Handler\s*=\s*'$mut'[^}]*Mutating\s*=\s*\`$true") { $unflagged += $mut }
}
if ($unflagged.Count -gt 0) {
    Fail "guided update menu does not flag as mutating: $($unflagged -join ', ') - they would skip the audit reason rule"
} else { Pass 'mutating guided operations are flagged for the audit reason rule' }

# (g) The guided workflow must be drivable non-interactively. A screen calling Read-Host directly
#     cannot be tested and will hang a scripted run - the defect that hid the console-shell crash.
#
#     Checked against COMMENT-STRIPPED text. Matching the raw text is a false positive here: this
#     module's own header comment explains the rule and therefore contains the literal string
#     "Read-Host". (Same class as the validator's own comment-stripper bug from Phase 1, where
#     explanatory text was mistaken for code - in the opposite direction.)
$navCode = Get-WuuCodeWithoutComments -Path (Join-Path $root 'src\Wuu.Navigate.psm1')
if ($navCode -match 'Read-Host') {
    Fail 'Wuu.Navigate calls Read-Host directly - that screen cannot be tested and will hang a scripted run'
} else { Pass 'guided screens read input only through the non-interactive choke point' }

# (h) The guided workflow must actually be the interactive default, with the flat menu retained as
#     a fallback - a redesign that silently left the old path active would pass every other check.
if ($coreRaw2 -notmatch 'Start-WuuGuidedWorkflow') {
    Fail 'Core never invokes Start-WuuGuidedWorkflow - the guided UI is not wired in'
} elseif ($coreRaw2 -notmatch '\-\-flat-menu') {
    Fail 'no flat-menu fallback - an operator cannot bypass a broken guided flow'
} else { Pass 'guided workflow is wired as the interactive default, with a flat-menu fallback' }

# (i) ARRAY SHAPE. PowerShell unwraps a one-element array to a scalar, which deletes `.Count`; the
#     field symptom was entering a SINGLE computer name crashing the manual-entry screen while
#     entering three worked.
#
#     The codebase convention is: functions return plainly, call sites wrap with @(). The opposite
#     "fix" - returning `,$array` or `-NoEnumerate` - does NOT prevent unwrapping when the caller
#     also wraps; it produces a NESTED array whose element is itself an array (so $names[0] is an
#     Object[] rather than a name). Both directions are gated here, because each one alone looks
#     correct and the failure only appears at a specific input size.
$sessRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Session.psm1') -Raw
# Checked against COMMENT-STRIPPED text: the module's own header documents the anti-pattern and
# therefore contains the literal strings being searched for. Matching raw text here is a false
# positive (the same class of mistake as the Phase 1 comment-stripper bug, in the other direction).
$sessCode = Get-WuuCodeWithoutComments -Path (Join-Path $root 'src\Wuu.Session.psm1')
if ($sessCode -match '(?m)^\s*return\s+,') {
    Fail "Wuu.Session returns an array with a leading comma - nesting risk when callers wrap with @()"
} elseif ($sessCode -match 'Write-Output\s+-NoEnumerate') {
    Fail "Wuu.Session uses -NoEnumerate to force array-ness - same nesting risk as a leading comma"
} else { Pass 'Wuu.Session returns collections plainly (no comma / -NoEnumerate nesting risk)' }

# Call sites that keep a returned collection and then touch .Count must wrap it in @().
$unwrapped = @()
foreach ($line in ($navRaw -split "`n")) {
    if ($line -match '=\s*(Split-WuuComputerNames|Get-WuuComputerSetComputers|Get-WuuComputerSetPhases|Get-WuuMenuActions)\b' -and $line -notmatch '@\(') {
        $unwrapped += $line.Trim()
    }
}
if ($unwrapped.Count -gt 0) {
    Fail "collection call site(s) not wrapped in @() - .Count would throw for a single result: $($unwrapped -join ' | ')"
} else { Pass 'collection call sites wrap results in @() (single-element safe)' }

# --- 13. Pre-flight, confirmation and audit-target invariants (spec 7 / 12 / 15) ------------
#     The same P0-encoding idea as section 12: these are the properties a future edit is most
#     likely to undo without noticing, because each one still LOOKS fine when it is wrong.

# (j) Spec 12: a mutating operation must not run without an explicit reason. The confirmation gate
#     is the guided UI's choke point, so it - not the screen that calls it - must refuse a blank
#     reason. Putting the check only in the screen leaves every other caller unauditable.
$confirmCode = Get-WuuCodeWithoutComments -Path (Join-Path $root 'src\Wuu.Navigate.psm1')
if ($confirmCode -notmatch "A change reason is required") {
    Fail 'the confirmation gate does not refuse a blank change reason (spec 12)'
} else { Pass 'the confirmation gate refuses a blank change reason (spec 12)' }

# (k) A refusal is an auditable event (ISO 27001 A.8.15). The confirmation gate must record it
#     itself rather than delegating to the caller: a caller that forgets produces an unrecorded
#     refusal, which is the exact gap the control exists to close.
if ($confirmCode -notmatch 'DenialHook') {
    Fail 'the confirmation gate never records a refusal as a denial (A.8.15)'
} else { Pass 'the confirmation gate records refusals as denials (A.8.15)' }

# (l) Spec 15: retry-failed must narrow to the failures. If the narrowed list does not reach the
#     row selector, the retry silently becomes an all-computers operation - the worst possible
#     outcome for a failed patch run, and invisible until someone reads the audit trail.
$consoleCode2 = Get-WuuCodeWithoutComments -Path (Join-Path $root 'src\Wuu.Console.psm1')
if ($consoleCode2 -notmatch 'WuuGuidedTargets') {
    Fail 'Read-WuuSelection honours no guided target override - retry-failed would re-target everything (spec 15)'
} else { Pass 'Read-WuuSelection honours the guided target override (retry-failed is safe)' }

# ...and that override must be an EXPLICIT $null test, never a truthiness test. An empty guided
# list means "target nothing"; `if ($guidedTargets)` would treat it as absent and fall through to
# prompting for a selection the operator already authorised.
#
# Matched against RAW text, not the comment-stripped text: the tokenizer DROPS the '$', so a
# pattern containing a variable reference cannot match there. This is the same representation
# trap the audit checks (g)-(i) document - verified by observing the failure rather than
# assumed, and the reason those checks read $auditRaw instead of $auditCode.
$consoleRaw2 = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Console.psm1') -Raw
if ($consoleRaw2 -notmatch '\$null\s+-ne\s+\$global:WuuGuidedTargets') {
    Fail 'the guided target override is not tested for $null - an empty list would fall through to prompting'
} else { Pass 'the guided target override distinguishes "none" from "not decided"' }

# (m) THE EXPORT ACTION MUST NOT USE A WPF FILE DIALOG. "Export list to file" (menu key x, the guided
#     UI, and the EventSaveComputerList action behind `wuu export`) built a Microsoft.Win32.SaveFileDialog
#     - a PresentationFramework type this edition deliberately does not load - so it threw "Cannot find
#     type" the moment an operator used it. Reachable, therefore a live defect, not dead GUI debris.
#     Asserted in two halves, because either alone re-opens the hole: the action must not build a GUI
#     dialog, and the export verb's answer builder must actually supply the path the action now prompts
#     for - the old builder supplied @() because the dialog, not the choke point, produced the value.
# Sliced from the variable's assignment to the next top-level '$event' assignment. A brace-balanced
# slice is the wrong tool here: the action's own comment names the dialog type it must not use, so a
# brace count would walk into the comment text. Slicing to the NEXT assignment has no such exposure,
# and it is the same "slice to the next definition" rule Get-WuuFunctionBody documents.
$exportStart = $coreRaw2.IndexOf('$eventSaveComputerList = {')
$exportEnd = if ($exportStart -ge 0) { $coreRaw2.IndexOf('$eventSaveConfig = {', $exportStart) } else { -1 }
$exportBody = if ($exportStart -ge 0 -and $exportEnd -gt $exportStart) { $coreRaw2.Substring($exportStart, $exportEnd - $exportStart) } else { '' }
# COMMENT-STRIPPED before matching, because the action's own comment NAMES the dialog type it must not
# use. Matching raw text here flagged the explanation of the fix - the identical false positive the
# audit and SS8 checks document, and the reason Get-WuuTextWithoutComments exists.
$exportCode = Get-WuuTextWithoutComments -Text $exportBody
if (-not $exportBody) {
    Fail 'could not locate the $eventSaveComputerList action - the export path is unverified'
} elseif ($exportCode -match 'Microsoft\.Win32\.|System\.Windows\.Forms\.|SaveFileDialog|OpenFileDialog') {
    Fail 'the export action uses a GUI file dialog (a WPF/WinForms type this edition cannot load) - it throws "Cannot find type" when an operator exports (P2)'
} elseif ($exportBody -notmatch 'Read-WuuAnswer') {
    Fail 'the export action does not obtain its destination through the input choke point - a scripted or non-interactive export could not answer it (SS15)'
} else {
    $exportAnswers = [regex]::Match($cmdRaw, "(?s)'export'\s*=\s*@\{.*?Answers\s*=\s*\{\s*param\(\`$p\)([^}]*)\}")
    if (-not $exportAnswers.Success) {
        Fail 'could not read the export verb answer builder - the command-mode export path is unverified (SS10)'
    } elseif ($exportAnswers.Groups[1].Value.Trim() -eq '@()') {
        Fail "the export verb supplies no answers, so its path prompt can never be satisfied - scripted export fails with 'Required input missing' (SS10/SS15)"
    } else {
        Pass 'the export action prompts for its path through the choke point and the export verb supplies it (no WPF dialog, SS10/SS15)'
    }
}

# (m) Spec 7: an offline computer must not be probed. Probing a host that is not there is a
#     guaranteed bounded-timeout per probe, so pre-flight cost would scale with the number of
#     machines that are down - the opposite of what an operator needs at 02:00.
$sessCode2 = Get-WuuCodeWithoutComments -Path (Join-Path $root 'src\Wuu.Session.psm1')
if ($sessCode2 -notmatch 'skipped \(offline\)') {
    Fail 'pre-flight does not skip credential/service probes for offline computers (spec 7)'
} else { Pass 'pre-flight skips expensive probes for offline computers (spec 7)' }

# (n) "Cannot tell" must never be reported as "offline". Deriving the offline count as
#     (total - reachable) unconditionally told the operator every machine was down whenever no
#     ping probe was supplied - a false alarm, which is how a report trains people to ignore it.
#     Raw text again, for the '$' reason above.
$sessRaw2 = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Session.psm1') -Raw
if ($sessRaw2 -notmatch 'if \(\$PingProbe\)') {
    Fail 'pre-flight derives the offline count without checking a ping probe ran - "unknown" would report as "offline"'
} else { Pass 'pre-flight only reports offline when reachability was actually probed' }

# (o) Spec 12: the plan shown before a mutating operation must state the lifecycle explicitly
#     (spec 10). 'deploy' collapsing to a single step would mean the operator authorises an
#     install they were never told would also reboot machines.
if ($navRaw -notmatch "'Restart where required'") {
    Fail "the deployment workflow does not include an explicit restart step (spec 11)"
} else { Pass 'the deployment lifecycle is stated explicitly, including the reboot step (spec 11)' }

# (p) The guided audit record must carry the confirmed TARGETS. Without them an interactive change
#     is strictly less informative than a scripted one (`wuu install -Computer SRV01`), so the
#     trail could not answer "which hosts did this person change?" for human-authorised changes.
$coreRaw3 = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
if ($coreRaw3 -notmatch 'Invoke-WuuAuditedAction -Session \$auditSession -Action \$ActionName -Reason \$Reason -Body \$Body -Targets \$Targets') {
    Fail 'the interactive audit hook does not forward targets - guided audit records would be targetless'
} else { Pass 'the interactive audit hook forwards the confirmed targets' }

# (q) A mutating guided action must CONSUME its reason. Leaving it on the context means the second
#     step of a deployment silently reuses the first step's reason, so the audit trail would show
#     the same justification for actions the operator justified separately.
if ($navRaw -notmatch "NotePropertyName Reason -NotePropertyValue ''") {
    Fail 'the guided workflow never clears the change reason - later mutations would inherit it'
} else { Pass 'the guided workflow consumes each change reason (no reason is silently reused)' }

# (r) NO SHIPPED SOURCE MAY READ A GUI CONTROL MEMBER.
#
#     This is the highest-value gate in this file. Three P0 defects and one total scheduler failure
#     all had the same shape: live code reading `$uiHash.<Control>` in an edition where `$uiHash` is
#     an EMPTY hashtable. Nothing threw, because Wuu.Core has no Set-StrictMode - a missing hashtable
#     key is $null, and `@($null)` is an empty list. Concretely:
#
#       * AutoDownload/AutoInstall gates: `if ($null -and ...)`      -> never fired
#       * AutoReboot gate:                `-not $null`               -> always returned early
#       * Start-PendingUpdateCheck:       `@($null)` -> no items     -> the QUEUE WAS DEAD
#       * Test-PhaseCompletion:           `@($null)` -> count 0      -> every phase reported complete
#       * $eventAuditWSUSUpdates:         `@($null)` -> no rows      -> silent no-op
#
#     Two tests passed throughout because they HAND-BUILT the missing GUI objects, so they supplied
#     the dependency they were meant to be exercising. That is why this is checked in the validator
#     against shipped source, not left to a test suite.
#
#     Comments are stripped with the tokenizer: the modules' own history notes quote these members
#     deliberately when explaining the migration, and a '#.*$' regex would also eat '#' inside
#     strings and subexpressions (the false-positive class documented at gate 2).
$guiMemberHits = @()
foreach ($f in $files) {
    if ($f.Name -eq 'Validate-Release.ps1') { continue }
    $code2 = Get-WuuCodeWithoutComments -Path $f.FullName
    if ($code2 -match '\$uiHash\.\w*(List[Vv]iew|CheckBox|TextBox|Menu|GridView)') {
        $guiMemberHits += $f.Name
    }
}
if ($guiMemberHits.Count) {
    Fail ('shipped source reads a GUI control member - in this edition $uiHash is empty, so the read is silently $null and the behaviour is dead: ' + (($guiMemberHits | Select-Object -Unique) -join ', '))
} else { Pass 'no shipped source reads a GUI control member (no silent-$null dead behaviour)' }

# (s) A GUIDED HANDLER'S OUTPUT MUST NOT REACH THE PIPELINE.
#
#     Every screen that calls Invoke-WuuGuidedHandler RETURNS A WORKFLOW STATE, and a PowerShell
#     function's output goes to the pipeline - so an unpiped `& $Ctx.Actions[$Handler]` makes the
#     caller return an ARRAY of (handler output..., state) rather than the state. That produced two
#     field symptoms, neither of which named its cause:
#
#       * the workflow loop received a PSCustomObject (a $GetErrors error row, Timestamp and all -
#         the results screen's "2. View errors" path) and printed it as an unknown workflow state;
#       * and since a switch over a 2-element array runs EVERY matching arm, the arm that reassigns
#         $state ran alongside `default`, which then printed $state AFTER the reassignment - naming a
#         perfectly VALID state ('DASHBOARD') as unknown.
#
#     Matched on the AST's command nodes rather than on text, because the function's own comment
#     explains the defect and quotes the unpiped call - the false-positive class this file records at
#     (r) and gate 2. A comment cannot be a CommandAst.
$navPathForLeak = Join-Path $root 'src\Wuu.Navigate.psm1'
$navAstForLeak = $null
try { $navAstForLeak = [System.Management.Automation.Language.Parser]::ParseFile($navPathForLeak, [ref]$null, [ref]$null) } catch { $navAstForLeak = $null }
if (-not $navAstForLeak) {
    Fail 'could not parse Wuu.Navigate.psm1, so the handler-output leak check would pass vacuously'
} else {
    $unpiped = @()
    foreach ($cmd in $navAstForLeak.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        # Only plain invocations of the context's handler table; a piped one is a PipelineAst element
        # rather than a bare statement, which is exactly the distinction being asserted.
        $el = $cmd.Parent
        $isPiped = ($el -is [System.Management.Automation.Language.PipelineAst]) -and (@($el.PipelineElements).Count -gt 1)
        $text = $cmd.Extent.Text
        if (-not $isPiped -and $text -match '^\s*&\s*\$Ctx\.Actions\[.+\]\s*$') {
            $unpiped += "line $($cmd.Extent.StartLineNumber): $text"
        }
    }
    if ($unpiped.Count -gt 0) {
        Fail ("a guided handler is invoked WITHOUT piping its output, so the calling screen's return value becomes an array and the workflow state it hands back is corrupted: " + ($unpiped -join '; '))
    } else {
        Pass "every guided handler invocation discards its output, so a screen's return value stays a state name"
    }
}
