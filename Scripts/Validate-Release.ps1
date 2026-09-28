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
$wpfHits = New-Object System.Collections.ArrayList
foreach ($f in $files) {
    # Skip this validator itself: it necessarily contains the very patterns it searches for.
    if ($f.Name -eq 'Validate-Release.ps1') { continue }
    $code = Get-WuuCodeWithoutComments -Path $f.FullName
    if ($code -match $wpfPattern) { [void]$wpfHits.Add($f.Name) }
}
if ($wpfHits.Count) { Fail ('WPF/XAML/ui reference in shipped code: ' + (($wpfHits | Select-Object -Unique) -join ', ')) }
else { Pass 'no WPF/XAML/ui references in shipped code' }

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

if ($failed) { Write-Host "`nValidation FAILED" -ForegroundColor Red; exit 1 }
else { Write-Host "`nAll validation checks passed" -ForegroundColor Cyan }
