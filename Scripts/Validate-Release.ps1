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
$failed = $false
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:failed = $true }
function Pass($m) { Write-Host "PASS: $m" -ForegroundColor Green }

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# --- 1. Parse every shipped script -------------------------------------------------------
$files = @(Get-ChildItem -Path (Join-Path $root 'src') -Filter '*.psm1' -File)
$files += Get-ChildItem -Path $root -Filter '*.ps1' -File
$files += @(Get-ChildItem -Path (Join-Path $root 'Scripts') -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike '_*' })   # dev-only helpers are excluded from releases
foreach ($f in $files) {
    $errs = $null; $toks = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$toks, [ref]$errs)
    if ($errs -and $errs.Count) {
        Fail ("{0} does not parse: {1} (line {2})" -f $f.Name, $errs[0].Message, $errs[0].Extent.StartLineNumber)
    }
}
if (-not $failed) { Pass "all $($files.Count) shipped PowerShell files parse under the PS 5.1 engine" }

# --- 2. No WPF/XAML/ui references in shipped code ---------------------------------------
# Comments are stripped first: explanatory notes ("was: XamlReader") are not dependencies and
# matching them would be a false positive (this bit us in the headless test).
#
# GOTCHA: do NOT strip comments with a naive '#.*$' regex - it also removes the '#' in
# subexpressions inside strings, e.g. "...($([math]::Round($x/1MB))MB)." becomes
# "...($([math]::Round($x/1MB))MB)." with the ')' eaten, which then reports PHANTOM syntax
# errors on a perfectly valid file. Use the parser's own tokenizer, which knows what a comment
# is, and rebuild the code text from non-comment tokens.
function Get-WuuCodeWithoutComments {
    param([string]$Path)
    $tkErrs = $null
    $tokens = [System.Management.Automation.PSParser]::Tokenize((Get-Content -LiteralPath $Path -Raw), [ref]$tkErrs)
    $sb = New-Object System.Text.StringBuilder
    foreach ($t in $tokens) {
        if ($t.Type -ne 'Comment') { [void]$sb.Append($t.Content).Append(' ') }
    }
    return $sb.ToString()
}

$wpfPattern = 'XamlReader|PresentationFramework|PresentationCore|WindowsBase|ItemContainerGenerator|clientObservable|Out-GridView'
# The GUI-only namespace patterns. These were MISSING from the list above, which let a genuine,
# reachable defect through this very gate: the AD connectivity test ended in a
# [System.Windows.MessageBox]::Show call, so it threw "Unable to find type" on its last line -
# precisely when an operator asks for it, since it is only offered after AD access has failed.
#
# WHY THE FIRST PATTERN LIST COULD NOT CATCH IT: it matches assembly and type NAMES the GUI used
# for rendering (PresentationFramework, XamlReader, ...). It does not match the fully-qualified
# SYSTEM namespace forms - System.Windows.MessageBox, System.Windows.Forms.*,
# Microsoft.VisualBasic.Interaction - which is how the residual calls are written. So the gate
# was watching for the framework rather than for the dialogs.
#
# Checked against COMMENT-STRIPPED text, like $wpfPattern above. This is load-bearing: the modules
# now carry explanatory comments that name every one of these patterns ("This was a WPF
# MessageBox..."), so matching RAW text here flags the very explanations of the fix - the same
# false-positive class the headless test and the audit checks both hit. (Note the audit checks go
# the other way and read raw text, because there the thing being searched for is NOT quoted in a
# neighbouring comment. Match the representation to the text, never to habit.)
$guiOnlyPattern = '\[System\.Windows\.MessageBox\]|\[System\.Windows\.Forms\.|\[Microsoft\.VisualBasic\.|Microsoft\.Win32\.OpenFileDialog'
$wpfHits = New-Object System.Collections.ArrayList
foreach ($f in $files) {
    # Skip this validator itself: it necessarily contains the very patterns it searches for.
    if ($f.Name -eq 'Validate-Release.ps1') { continue }
    $code = Get-WuuCodeWithoutComments -Path $f.FullName
    if ($code -match $wpfPattern) { [void]$wpfHits.Add($f.Name) }
    elseif ($code -match $guiOnlyPattern) { [void]$wpfHits.Add("$($f.Name) (GUI-only type call)") }
}
if ($wpfHits.Count) { Fail ('WPF/XAML/ui reference in shipped code: ' + (($wpfHits | Select-Object -Unique) -join ', ')) }
else { Pass 'no WPF/XAML/ui references in shipped code (incl. GUI-only System.Windows.* / VisualBasic form types)' }

# --- 3 & 4. Modules import, and importing them loads no WPF ------------------------------
$wpfNames = @('PresentationFramework', 'PresentationCore', 'WindowsBase')
$wpfBefore = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -in $wpfNames })
try {
    Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force -ErrorAction Stop
    Import-WuuModules -WuuRoot $root
    Pass 'all src/ modules import via Import-WuuModules'
} catch {
    Fail "module import failed: $($_.Exception.Message)"
}
$wpfAfter = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -in $wpfNames })
if ($wpfAfter.Count -gt $wpfBefore.Count) { Fail ('importing the engine loaded WPF: ' + (($wpfAfter | ForEach-Object { $_.GetName().Name }) -join ', ')) }
else { Pass 'importing the engine loads no WPF assembly' }

# --- 5. Console menu keys all map to action handlers ------------------------------------
$consoleCode = Get-Content (Join-Path $root 'src\Wuu.Console.psm1') -Raw
$coreCode = Get-Content (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$menuHandlers = [regex]::Matches($consoleCode, '\$ctx\.([A-Za-z]+)') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique | Where-Object { $_ -ne 'Quit' }   # Quit is a control flag, not an action handler
$missing = @()
foreach ($handler in $menuHandlers) {
    if ($coreCode -notmatch ('\$consoleActions\.' + [regex]::Escape($handler) + '\s*=')) { $missing += $handler }
}
if ($missing.Count) { Fail ('menu references undefined action handler(s): ' + ($missing -join ', ')) }
else { Pass "all $($menuHandlers.Count) menu handlers are defined in the action layer" }

# --- 6. Command verbs map to action handlers --------------------------------------------
# A verb naming a handler the action layer does not define would fail only when an operator
# typed it, which is exactly the kind of gap a release check should catch instead.
$cmdCode = Get-Content (Join-Path $root 'src\Wuu.Command.psm1') -Raw
$verbActions = [regex]::Matches($cmdCode, "Action\s*=\s*'([A-Za-z]+)'") |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$missingVerb = @()
foreach ($va in $verbActions) {
    if ($coreCode -notmatch ('\$consoleActions\.' + [regex]::Escape($va) + '\s*=')) { $missingVerb += $va }
}
if ($missingVerb.Count) { Fail ('command verbs reference undefined action handler(s): ' + ($missingVerb -join ', ')) }
else { Pass "all $($verbActions.Count) command verb handlers are defined in the action layer" }

# Sub-dispatched verbs (show/config/audit) name their handlers inside a hashtable literal.
foreach ($sub in 'EventShowAvailableUpdates', 'EventShowInstalledUpdates', 'EventShowUpdateHistory', 'EventSaveConfig', 'EventLoadConfig') {
    if ($cmdCode -match [regex]::Escape($sub) -and $coreCode -notmatch ('\$consoleActions\.' + [regex]::Escape($sub) + '\s*=')) {
        Fail "sub-dispatched handler '$sub' is not defined in the action layer"
    }
}
if (-not $failed) { Pass 'sub-dispatched verb handlers resolved' }

# --- 7. Every verb in the table has help text and an Answers builder ---------------------
$verbKeys = [regex]::Matches($cmdCode, "(?m)^\s*'([a-z-]+)'\s*=\s*@\{\s*$") | ForEach-Object { $_.Groups[1].Value }
$noHelp = @()
foreach ($k in $verbKeys) {
    if ($cmdCode -notmatch ("'$([regex]::Escape($k))'\s*=\s*@\{[\s\S]{0,400}?Help\s*=")) { $noHelp += $k }
}
if ($noHelp.Count) { Fail ('verb(s) missing Help text: ' + ($noHelp -join ', ')) }
else { Pass "all $($verbKeys.Count) verbs have Help text" }

# --- 8. UTF-8 BOM on every file containing non-ASCII bytes -------------------------------
# PS 5.1 reads a BOM-less file as ANSI. Multi-byte characters (the status emoji in Wuu.Core,
# for example) then consume a following quote and the parse error surfaces far from the cause
# ("Unexpected token 'MB'"). This has now recurred three times, so it is a release check rather
# than a memory note. `Set-Content -Encoding UTF8` under PS 7 writes BOM-less - use
# [Text.UTF8Encoding]::new($true) instead.
$bomMissing = @()
foreach ($f in $files) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $hasNonAscii = $false
    foreach ($byte in $bytes) { if ($byte -gt 127) { $hasNonAscii = $true; break } }
    if ($hasNonAscii) {
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        if (-not $hasBom) { $bomMissing += $f.Name }
    }
}
if ($bomMissing.Count) { Fail ('non-ASCII file(s) missing the UTF-8 BOM (PS 5.1 will mis-read these): ' + (($bomMissing | Select-Object -Unique) -join ', ')) }
else { Pass 'every file with non-ASCII bytes carries the UTF-8 BOM' }

# --- 9. Audit invariants (Phase 4) --------------------------------------------------------
# These are the properties the trail exists to guarantee. Asserting them structurally beats
# trusting that a future edit preserves them.
#
# Evaluate against COMMENT-STRIPPED code. An earlier version matched raw text and flagged the
# module's own explanatory comments ("OneDrive-synced tree caused ... failures") as a synced-folder
# path - the same false-positive class the headless test hit. Strip comments via the tokenizer.
$auditPath = Join-Path $root 'src\Wuu.Audit.psm1'
$auditCode = Get-WuuCodeWithoutComments -Path $auditPath

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

# (u) ONE OPERATION PER COMPUTER (brief SS3). Two properties, because either alone can be defeated:
#     the submission path must consult the gate, AND the gate must exist and be exported. A gate that
#     is never called is decoration; a call to a missing function is a runtime failure.
#
#     Function bodies are extracted by finding the next top-level "function " to EOF, NOT by a fixed
#     character window. A 3000-char window silently truncated Start-UpdateCheckJob (6143 chars after
#     the comments were added) and reported a FALSE FAILURE - the same trap as the token-stripped
#     `\n\}` pattern earlier. Slicing to the next function has no size assumption.
function Get-WuuFunctionBody([string]$Text, [string]$Name) {
    $i = $Text.IndexOf("function $Name")
    if ($i -lt 0) { return '' }
    $next = $Text.IndexOf("`nfunction ", $i + 10)
    if ($next -lt 0) { return $Text.Substring($i) }
    return $Text.Substring($i, $next - $i)
}

$supBody = Get-WuuFunctionBody $wupdRaw 'Start-UpdateCheckJob'
if (-not $supBody) { Fail 'could not locate Start-UpdateCheckJob' }
else {
    # The gate must be consulted BEFORE the submission, and the row must be marked Running.
    if ($supBody -notmatch 'Test-WuuComputerBusy') {
        Fail 'Start-UpdateCheckJob does not consult Test-WuuComputerBusy - a second operation on a busy computer would be silently discarded'
    }
    elseif ($supBody -notmatch "OpState\s*=\s*'Running'") {
        Fail 'Start-UpdateCheckJob does not mark the computer Running - the gate could never say busy'
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

# (aa) EXIT CODES (brief SS10). Asserted by NUMBER and by the ORDER of the branches that produce
#      them, because the contract is the number a script branches on. The defect SS10 names is that a
#      scripted `wuu install` could exit 0 while the install was merely QUEUED - "accepted" read as
#      "done", silently, in every CI job that used it.
#
#      Static, like the neighbouring Core gates: driving the shell for real needs elevation, a live
#      WSUS target and minutes per run, so it cannot be a per-build gate. Literal .IndexOf is used
#      instead of -match for the patterns containing '$', because a bare '$busy' in a regex is an
#      end-of-line anchor - that produced a false failure while writing the accompanying test.
$cmdRawE = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Command.psm1') -Raw

# 1. The vocabulary itself: every name must map to its documented number.
$codeMap = @{ 'Success' = 0; 'OperationFailed' = 1; 'UsageError' = 2; 'Timeout' = 3; 'PartialSuccess' = 4; 'AuditFailure' = 5; 'Queued' = 6; 'Refused' = 7 }
$exitBody = Get-WuuFunctionBody $cmdRawE 'Get-WuuExitCode'
if (-not $exitBody) {
    Fail 'Get-WuuExitCode is not defined - SS10 has no vocabulary and every exit is folklore'
} else {
    foreach ($n in ($codeMap.Keys | Sort-Object)) {
        if ($exitBody -notmatch ("'" + $n + "'\s*\{\s*" + $codeMap[$n] + "\s*\}")) {
            Fail "exit code '$n' is not mapped to $($codeMap[$n])"
        }
    }
    # A name that reaches the default arm silently becomes 1, i.e. a usage error reported as an
    # operation failure. The ValidateSet is what makes that impossible.
    if ($exitBody -notmatch 'ValidateSet') {
        Fail 'Get-WuuExitCode has no ValidateSet - an unknown name would silently become 1'
    }
    if (-not $failed) { Pass 'the exit-code vocabulary maps all eight names to their documented numbers (SS10)' }
}

if ($cmdRawE -notmatch "'Get-WuuExitCode'") { Fail 'Get-WuuExitCode is not exported (the caller cannot resolve it)' }
if ($cmdRawE -notmatch 'function Get-WuuExitCodeMeaning') { Fail 'Get-WuuExitCodeMeaning is missing - a non-zero exit would be unexplained' }

# 2. -Async must be parsed AND forwarded. Either one alone makes the flag a silent no-op: parsed
#    but not forwarded and Core still calls an async command a timeout; forwarded but not parsed
#    and the option is reported as a typo before it ever reaches Core.
$coreRawE = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
if ($cmdRawE -notmatch "'-async'\s*=\s*'Async'") { Fail 'the command parser does not recognise -Async' }
if ($coreRawE.IndexOf('-Async:$parsed.Options[''Async'']') -lt 0) { Fail 'Core does not forward -Async from the parsed options' }

# 3. The four properties that make the exit code honest. Each can fail alone.
if ($coreRawE.IndexOf('OpState -eq ''Running''') -lt 0 -or $coreRawE.IndexOf('$_.Pending') -lt 0) {
    Fail 'outstanding work is not measured from the store rows (OpState/Pending) - the exit code would reflect a queue, not a result'
}
if ($coreRawE.IndexOf("Get-WuuExitCode -Result 'Timeout'") -lt 0) {
    Fail 'unfinished work does not produce the Timeout code - a queued install could still exit 0'
}
if ($coreRawE.IndexOf("Get-WuuExitCode -Result 'Queued'") -lt 0) {
    Fail 'queued work does not produce the Queued code (-Async has no distinct outcome)'
}
$timeoutAt = $coreRawE.IndexOf("Get-WuuExitCode -Result 'Timeout'")
$notOkAt = $coreRawE.IndexOf('elseif (-not $result')
if ($timeoutAt -gt 0 -and $notOkAt -gt 0 -and $timeoutAt -gt $notOkAt) {
    Fail 'the timeout branch is evaluated AFTER the result-object branch - a command that reported Ok but left work running would be classified as success'
}
if ($coreRawE.IndexOf('$script:CommandExitCode = $exitCode') -lt 0) {
    Fail 'the exit code is not assigned unconditionally - a stale non-zero code could persist into a later run'
}

# 4. Audit integrity is a DIFFERENT failure from a failed operation, so it gets its own code. The
#    old code set $script:CommandExitCode from inside Wuu.Command.psm1, which is that module's
#    script scope - not the caller's - so `audit verify` on a broken chain exited 0. Classification
#    travels on the result object instead, which crosses the scope boundary correctly.
if ($cmdRawE -notmatch "'AuditFailure'") { Fail 'audit-integrity failures carry no classification' }
if ($cmdRawE -match '\$script:CommandExitCode\s*=') {
    Fail 'Wuu.Command sets $script:CommandExitCode in the wrong scope - the value never reaches the exit path (audit verify would exit 0 on a broken chain)'
}
if (-not $failed) { Pass 'exit codes distinguish completion, timeout, queueing, usage, refusal and audit integrity (SS10)' }

if ($failed) { Write-Host "`nValidation FAILED" -ForegroundColor Red; exit 1 }
else { Write-Host "`nAll validation checks passed" -ForegroundColor Cyan }
