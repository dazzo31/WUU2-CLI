# Release validation, Audit contract canonicalisation chain and retention. Extracted from Validate-Release.ps1 (instructions SS39).
#
# DOT-SOURCED FRAGMENT - not a standalone script. Validate-Release.ps1 dot-sources it into its own
# scope, which is what gives this file $root, the verdict helpers (Pass/Fail/Warn/Skip/Not-Implemented)
# and any variable the gate computed above the dot-source line. It is dot-sourced AT ITS ORIGINAL
# POSITION because the order of the verdict list is part of what CI reads.

# (a) The canonical form must distinguish an array from a string. A collision here means two
#     different records hash identically - fatal for a hash chain, and easy to reintroduce by
#     "simplifying" the serialiser.
if ($auditCode -notmatch 'Array\s*/\s*list' -and $auditCode -notmatch 'IEnumerable') {
    Fail 'Wuu.Audit has no array branch in its canonical serialiser (array/string collision risk)'
} else { Pass 'audit canonical serialiser handles arrays separately from strings' }

# (b) The hash must include prevHash, or removing/reordering a record would not break the chain.
#     NOTE: the token-stripped text has runs of whitespace AND loses '$' and quotes - `$canonical
#     + '|' + $PrevHash` appears as `canonical + | + PrevHash`. Verified by dumping the text
#     rather than guessing the pattern (guessing cost three failed attempts).
$auditFlat = ($auditCode -replace '\s+', ' ')
if ($auditFlat -notlike '*material = canonical + | + PrevHash*') {
    Fail 'audit hash does not mix in prevHash - the chain would not detect removal/reordering'
} else { Pass 'audit hash mixes in prevHash (removal/reordering is detectable)' }

# (c) Mutating actions must be able to fail closed.
if ($auditCode -notmatch 'FailClosed') { Fail 'Wuu.Audit has no fail-closed path; an unlogged mutation would be possible' }
else { Pass 'audit supports fail-closed writes for mutating actions' }

# (d) The log must be append-only: no rewrite/truncate/overwrite of an existing file.
if ($auditCode -match 'Set-Content.*LogPath|Out-File.*LogPath|WriteAllText.*LogPath|FileMode\]::Create') {
    Fail 'Wuu.Audit appears to rewrite the log file (must be append-only)'
} else { Pass 'audit writes are append-only (no rewrite path found)' }

# (e) The trail must not live in a cloud-synced folder (a real, repeated failure mode here).
if ($auditCode -match 'OneDrive') { Fail 'audit path appears to reference a synced folder' }
elseif ($auditCode -notmatch 'Get-WuuAuditDirectory') { Fail 'audit has no dedicated directory resolver' }
else { Pass 'audit resolves its own directory (not a synced path)' }
# (f) Mutating command verbs must require a reason.
$cmdText = Get-Content (Join-Path $root 'src\Wuu.Command.psm1') -Raw
if ($cmdText -notmatch 'requires -Reason') { Fail 'mutating verbs do not enforce -Reason' }
else { Pass 'mutating verbs enforce -Reason' }

# (g)-(i) Concurrency + durability invariants.
#     Checked against RAW file text, not the token-stripped text used above: the tokenizer
#     normalises away '::', '$' and quotes, so structural patterns like these cannot be matched
#     there. (Matching the tokenised text here previously produced three false failures on code
#     that was demonstrably correct - verify against the right representation.)
$auditRaw = Get-Content -LiteralPath $auditPath -Raw

# (g) Concurrent writers must take an EXCLUSIVE cross-process lock for the whole
#     read-modify-write. Without it two processes chain from the same prevHash and verification
#     reports FALSE tampering on an intact trail - a real bug, found by probe and reproduced by
#     tests\Test-AuditConcurrency.ps1 against the pre-fix code.
if ($auditRaw -notmatch 'FileShare\]::None') {
    Fail 'audit append takes no exclusive cross-process lock - concurrent writers can fork the chain'
} else { Pass 'audit append takes an exclusive cross-process lock' }

# (h) The chain head must be read INSIDE that lock, not before it (the TOCTOU race).
if ($auditRaw -notmatch 'Read-WuuAuditTailFromStream -Stream \$fs') {
    Fail 'audit does not read the chain head inside the exclusive lock (TOCTOU race)'
} else { Pass 'audit reads the chain head inside the exclusive lock (no read-modify-write race)' }

# (i) Records must be flushed to disk - a record that is not durable is not evidence.
if ($auditRaw -notmatch 'Flush\(\$true\)') {
    Fail 'audit does not flush records to disk (a crash could lose "durable" records)'
} else { Pass 'audit flushes records to disk' }

# --- 10. ISO 27001 A.8.15 event-logging invariants -----------------------------------------
#     These assert the CONTENT contract: an auditor needs WHO/WHAT/WHICH/WHEN/WHERE/OUTCOME on
#     every event, denied attempts as first-class records, and reads logged as well as changes.
#     Same RAW-vs-tokenised caveat as (g)-(i): these patterns contain '::', '$' and quotes.
#     See docs/ISO_27001_A815_MAPPING.md.

# (a) Every event must identify the actor, the host it came from, and the originating process.
#     Dropping any of these makes "who did this, from where" unanswerable for that record.
foreach ($field in @(
    @{ Name = 'runId';         Pattern = 'runId\s+=';                       Why = 'actor/run identifier' }
    @{ Name = 'timestampUtc';  Pattern = 'timestampUtc\s+=';                Why = 'when the event occurred' }
    @{ Name = 'operator';      Pattern = 'operator\s+=';                    Why = 'which account acted' }
    @{ Name = 'host';          Pattern = 'host\s+=';                        Why = 'where the action came from' }
    @{ Name = 'processId';     Pattern = 'processId\s+=';                   Why = 'originating process' }
    @{ Name = 'category';      Pattern = 'category\s+=';                    Why = 'event classification' }
    @{ Name = 'action';        Pattern = 'action\s+=';                      Why = 'what was done' }
    @{ Name = 'targets';       Pattern = 'targets\s+=';                     Why = 'which target was affected' }
    @{ Name = 'result';        Pattern = 'result\s+=';                      Why = 'outcome of the action' }
    @{ Name = 'durationMs';    Pattern = 'durationMs\s+=';                  Why = 'how long the action took' }
    @{ Name = 'wuuVersion';    Pattern = 'wuuVersion\s+=';                  Why = 'producing build' }
)) {
    if ($auditRaw -notmatch $field.Pattern) {
        Fail "audit record is missing '$($field.Name)' ($($field.Why)) - required by ISO 27001 A.8.15"
    }
}
if ($failed) { } else { Pass 'audit records carry the full A.8.15 event field set (who/what/which/when/where/outcome)' }

# (b) Timestamps must be ISO 8601 in UTC. A local-time or format-less timestamp is ambiguous
#     across DST and across hosts, which is exactly where an incident timeline gets contested.
if ($auditRaw -notmatch "ToUniversalTime\(\)\.ToString\('o'\)") {
    Fail 'audit timestamps are not ISO 8601 UTC to millisecond precision'
} else { Pass 'audit timestamps are ISO 8601 UTC (round-trip format)' }

# (c) Refusals must be recorded as FIRST-CLASS events. A.8.15 expects denied/unsuccessful
#     attempts to be logged; a run of refusals is the signal an auditor looks for.
if ($auditRaw -notmatch "function\s+Write-WuuAuditDenial") {
    Fail 'no Write-WuuAuditDenial - refusals would not be recorded (A.8.15 requires denied attempts logged)'
} elseif ($auditRaw -notmatch "Result\s+'denied'") {
    Fail 'Write-WuuAuditDenial does not write result=denied'
} else { Pass 'refused attempts are recorded as first-class denied events' }

# (d) A denial must NOT be fail-closed. The operation was already blocked; a logging failure
#     must not turn a refusal into an error the operator cannot interpret.
$denialBlock = [regex]::Match($auditRaw, '(?s)function\s+Write-WuuAuditDenial\s*\{.*?\n\}').Value
if ($denialBlock -match 'FailClosed') {
    Fail 'Write-WuuAuditDenial uses the fail-closed path - a refusal must never be blocked by logging'
} else { Pass 'denials are recorded best-effort (a refusal is never blocked by logging)' }

# (e) A denial must NOT write an intent record: a 'started' row would falsely imply the change
#     had begun when it was in fact refused.
if ($denialBlock -match "'started'") {
    Fail "Write-WuuAuditDenial writes a 'started' intent record - implies a refused change began"
} else { Pass 'denials write no intent record (a refused change never began)' }

# (f) The category taxonomy must exist so reports can be filtered without per-callsite drift,
#     and the ValidateSet must list the categories the classifier can actually return.
if ($auditRaw -notmatch 'function\s+Resolve-WuuAuditCategory') {
    Fail 'no Resolve-WuuAuditCategory - events would carry no ISO category'
}
foreach ($cat in @('session', 'access', 'configuration_change', 'data_change', 'operational', 'outcome')) {
    if ($auditRaw -notmatch ("'" + [regex]::Escape($cat) + "'")) {
        Fail "audit category taxonomy is missing '$cat' (A.8.15 grouping)"
    }
}
if ($failed) { } else { Pass 'audit category taxonomy is complete (6 categories)' }

# (g) READ-ONLY access must be logged. A.8.15 covers access to information, not only change
#     to it - "who inspected which hosts, when" must be answerable after an incident.
$cmdRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Command.psm1') -Raw
if ($cmdRaw -notmatch "'operational'") {
    Fail 'read-only verbs are not categorised - reads are not being logged (A.8.15)'
} elseif ($cmdRaw -notmatch 'Logged\s*=\s*\$true') {
    Fail 'read-only verbs do not report Logged - callers cannot tell logged from unaudited'
} else { Pass 'read-only access is logged (reported distinctly from the fail-closed path)' }

# (h) A read must not be routed through the mutating choke point: that would write a spurious
#     'started' intent record for an operation that changes nothing, and wrongly demand -Reason.
if ($cmdRaw -match "(?s)else\s*\{\s*Invoke-WuuAuditedAction") {
    Fail 'read-only path appears to use the mutating choke point (spurious intent records)'
} else { Pass 'read-only access bypasses the mutating choke point (no spurious intent records)' }

# (i) Retention: no code path may delete audit DATA. Deletion capability would silently defeat
#     the "keep forever" policy - see docs/AUDIT_RETENTION.md.
#     Deliberately precise: the module DOES legitimately remove a transient '.wuu-write-probe'
#     file from the directory resolver (a writability test). That is not audit data, so the
#     check targets removal of the record file ($LogPath) or anything matching the audit file
#     pattern, rather than any use of Remove-Item. A blunt check here would have been a false
#     positive, and a false positive in a compliance gate is worse than no gate - it trains
#     people to ignore the gate.
$dataDeletePatterns = @(
    'Remove-Item[^\r\n]*\$LogPath'
    'Remove-Item[^\r\n]*\$Session\.LogPath'
    'Remove-Item[^\r\n]*\.jsonl'
    'Remove-Item[^\r\n]*transcript'
    'Clear-Content[^\r\n]*\$LogPath'
    'Clear-Content[^\r\n]*\.jsonl'
    'FileMode\]::Truncate'
    '\[IO\.File\]::Delete'
    '\.Delete\(\)\s*$'
    'Set-Content[^\r\n]*\.jsonl'
    'Out-File[^\r\n]*\.jsonl'
    # A whole-file rewrite of the log path destroys every prior record's chain position, so it
    # counts as deletion for retention purposes. (The directory resolver legitimately uses
    # Set-Content on its transient probe file, which is why this is anchored to $LogPath.)
    'Set-Content[^\r\n]*\$LogPath'
    'Out-File[^\r\n]*\$LogPath'
    'WriteAllText[^\r\n]*\$LogPath'
)
$deleteHits = @($dataDeletePatterns | Where-Object { [regex]::IsMatch($auditRaw, $_, 'IgnoreCase') })
if ($deleteHits.Count -gt 0) {
    Fail "audit module contains a delete/truncate path for audit data (violates keep-forever retention): $($deleteHits -join ', ')"
} else { Pass 'audit module has no delete/truncate path for audit data (retention is structural)' }

# --- 11. Release-readiness invariants (v1.4.0-cli) -----------------------------------------
#     Each of these encodes a defect that shipped in the pre-release tree and was found by
#     actually running the entry point, not by reading it. They exist so the same class of
#     regression fails the build instead of reaching a tester.

$coreRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$pkgRaw = Get-Content -LiteralPath (Join-Path $root 'Scripts\Package-WUU2.ps1') -Raw

# (a) The elevation relaunch must forward the REAL arguments. The original used `if ($args)`,
#     which is ALWAYS empty inside a param() function, so `WUU.ps1 install -Computer X` relaunched
#     into the interactive menu with the operator's arguments silently discarded.
if ($coreRaw -match '(?m)^\s*if\s*\(\$args\)\s*\{') {
    Fail "elevation/STA relaunch tests `$args, which is always empty inside a param() function - forwarded arguments would be silently dropped"
} else { Pass 'no relaunch relies on $args (arguments would not be silently dropped)' }

# (b) Both relaunches must pass -STA. A relaunch without it trips the STA validation and relaunches
#     a SECOND time, losing the arguments again (the bug that made this a two-hop problem).
#     Match the argument-array construction lines, identified by the '-NoProfile' string literal.
#     (Matching on 'powershell.exe' instead also hits `$processStartInfo.FileName = 'powershell.exe'`,
#     which is a false positive - the gate was probed against the real file before being trusted.)
$relaunchLines = @($coreRaw -split "`n" | Where-Object { $_ -match "'-NoProfile'" })
$missingSta = @($relaunchLines | Where-Object { $_ -notmatch "'-STA'" })
if ($relaunchLines.Count -lt 2) {
    Fail "expected 2 relaunch argument lists (elevation + STA), found $($relaunchLines.Count)"
} elseif ($missingSta.Count -gt 0) {
    Fail "a relaunch does not pass -STA (would trigger a second relaunch and lose arguments): $($missingSta[0].Trim())"
} else { Pass 'both relaunch paths pass -STA' }

# (c) The elevation relaunch must forward $CommandArguments (the real parameter).
if ($coreRaw -notmatch '\$forwardArgs') {
    Fail 'elevation relaunch does not build a forwarded-argument list'
} else { Pass 'elevation relaunch forwards the real command arguments' }

# (d) A declined UAC prompt must NOT block on input - Read-Host after a cancellation hangs any
#     unattended/CI invocation forever.
$elevBlock = [regex]::Match($coreRaw, '(?s)Requesting elevation.*?#endregion Administrator Privilege Check').Value
if ($elevBlock -match 'Read-Host') {
    Fail 'elevation failure path calls Read-Host (hangs non-interactive invocations on a declined UAC prompt)'
} else { Pass 'declined elevation exits without blocking on input' }

# (e) A sub-dispatch token must never be passed to a ValidateSet parameter meant for something
#     else. Binding $parsed.SubVerb to -ServiceAction hard-threw for every sub-dispatched verb
#     except `service restart` (whose subverb happens to be a valid service action):
#       `audit export` -> "Cannot validate argument on parameter 'ServiceAction'" -> CRITICAL ERROR,
#     which made audit verify/show/export look permanently unreachable.
if ($coreRaw -match '(?m)^\s*-ServiceAction\s+\$parsed\.SubVerb\s*$') {
    Fail "-ServiceAction is bound directly to `$parsed.SubVerb - every non-service subverb crashes on the ValidateSet"
} else { Pass '-ServiceAction is guarded by verb (subverbs cannot crash the ValidateSet)' }

# (f) Command mode must log the raw argv. Without it, command mode leaves NO trace that a command
#     was requested, making "my arguments were ignored" impossible to diagnose after the fact.
if ($coreRaw -notmatch 'Command mode: argv') {
    Fail 'command mode does not log its argv (argument-loss failures are undiagnosable)'
} else { Pass 'command mode logs its argv' }

# (g) The released version must be single-sourced. The banner and the audit records each hardcoded
#     their own string, so a release could ship with the log claiming one version and the audit
#     trail (an ISO 27001 field) recording another.
if ($coreRaw -notmatch '\$global:WuuVersion\s*=') {
    Fail 'no $global:WuuVersion constant - the version is not single-sourced'
} elseif ($auditRaw -match "wuuVersion\s*=\s*'v") {
    Fail 'Wuu.Audit hardcodes wuuVersion instead of reading $global:WuuVersion'
} else { Pass 'version is single-sourced ($global:WuuVersion)' }

# (h) The packager must ship docs\ (recursively). A non-recursive top-level *.md copy shipped a
#     release with NO compliance documentation at all.
if ($pkgRaw -notmatch "docsSrc") {
    Fail 'packager does not include docs\ - a release would ship without the ISO/retention docs'
} else { Pass 'packager includes docs\ (compliance documentation ships)' }

# (i) The packager must not ship GUI-edition documents into a console release.
if ($pkgRaw -notmatch 'guiOnlyDocs') {
    Fail 'packager does not exclude GUI-only docs (would misdirect a console-edition tester)'
} else { Pass 'packager excludes GUI-only docs from the console package' }

# (j) The command help must document -LogPath, since -Path means different things per subverb
#     (an inspected log for verify/show, an output destination for export).
if ($cmdRaw -notmatch "'-logpath'") {
    Fail "-LogPath is not registered as a known option (audit export cannot name its input log)"
} else { Pass '-LogPath is a registered option' }

# (k) NO FUNCTION MAY REASSIGN ITS OWN PARAMETER.
#     PowerShell variable names are CASE-INSENSITIVE, so a local named `$actions` IS the
#     `$Actions` parameter - and since a parameter's declared type is enforced on every
#     assignment, `$actions = Get-WuuMenuActions` (an Object[]) tried to coerce into the
#     [hashtable]$Actions parameter and threw
#         Cannot convert the "System.Object[]" value of type "System.Object[]" to
#         type "System.Collections.Hashtable"
#     That killed the console shell the instant the menu was drawn, making the interactive
#     edition completely unusable - while every non-interactive test suite stayed green, because
#     none of them draw the menu. This class has now bitten this project three times ($host,
#     $pid, and this), so it is gated.
$reassign = @()
foreach ($modFile in @(Get-ChildItem -Path (Join-Path $root 'src') -Filter '*.psm1' -File)) {
    $modErrs = $null
    $modAst = [System.Management.Automation.Language.Parser]::ParseFile($modFile.FullName, [ref]$null, [ref]$modErrs)
    if (-not $modAst) { continue }
    foreach ($fn in $modAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if (-not $fn.Body.ParamBlock) { continue }
        $paramNames = @($fn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        if ($paramNames.Count -eq 0) { continue }
        $assigned = @($fn.Body.FindAll({
            $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $args[0].Left -is [System.Management.Automation.Language.VariableExpressionAst]
        }, $true) | ForEach-Object { $_.Left.VariablePath.UserPath })
        # NOTE: compared with -contains on UserPath, which is already case-insensitive for the
        # comparison operators used here. Matching on the AST (not raw text) means comments
        # cannot produce false positives - the same lesson as the RAW-vs-tokenised rule.
        foreach ($a in $assigned) {
            if ($paramNames -contains $a) { $reassign += "$($modFile.Name)::$($fn.Name) reassigns `$$a" }
        }
    }
}
$reassign = @($reassign | Sort-Object -Unique)
if ($reassign.Count -gt 0) {
    Fail "function(s) reassign their own parameter (case-insensitive collision - type coercion can throw): $($reassign -join '; ')"
} else { Pass 'no function reassigns its own parameter (no case-insensitive collisions)' }

# --- 12. Interactive workflow invariants (docs/INTERACTIVE_UI_SPEC.md) ----------------------
#     Encodes the spec's P0 requirements (section 25) as STRUCTURAL facts, so a future change
#     cannot quietly undo the redesign.

$navRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Navigate.psm1') -Raw
$conRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Console.psm1') -Raw
$coreRaw2 = $coreRaw

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
