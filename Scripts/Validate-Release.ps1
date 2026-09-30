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

function Get-WuuTextWithoutComments {
    <#
    .SYNOPSIS Strips comment lines AND block comments from source text, preserving newlines and '$'.
    .DESCRIPTION
    Get-WuuCodeWithoutComments (above) cannot be used for gates that need to SLICE a function body or
    match '$'-anchored patterns: it joins every token with a space, which DISCARDS newlines (so
    Get-WuuFunctionBody, which slices to the next "\nfunction ", returned the whole file) and drops '$'
    (so a '\$state -in' pattern could never match). It is correct for its own callers - a whole-file
    pattern scan - and is left alone.

    This helper exists because three gates in this pass each hit the SAME failure: a check matched the
    comment that explains the code being checked. Examples, all observed:
      * the SS8 gate matched a comment quoting the removed 'UpdatesStatus -ne ...' predicate;
      * the SS6 gate matched a comment quoting the removed '$global:CredentialConfig.Username' read;
      * the SS6 gate matched "never a password" inside a block comment, which a line-prefix strip does
        NOT remove. (Block comments are why this helper exists: '# '-prefix stripping alone is not
        enough, and the first version of this very comment was itself broken by writing the block-comment
        delimiters literally inside it, which closed the comment early.)
    Trade-off: block-comment delimiters appearing inside a string literal would also be stripped. No such
    literal exists in this codebase, and a validator that occasionally needs its comment adjusted is
    better than three gates that silently pass on stale code.
    #>
    param([string]$Text)
    if (-not $Text) { return '' }
    $noBlocks = [regex]::Replace($Text, '(?s)<#.*?#>', '')
    return (($noBlocks -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
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

# (ab) OPERATION-SPECIFIC TIMEOUTS (brief SS5). The defect was ONE flat 10-minute stop for every
#      operation, which is wrong in both directions: it killed healthy long operations (a reboot's own
#      offline+online waits total 40 minutes!) and let a hung 5-minute service action hold a runspace
#      for ten minutes. Five properties, because each can fail alone:
#
#        1. a per-op budget table exists, keyed by the ops actually accepted, with a default;
#        2. the budget is recorded on the row AT SUBMISSION (one source of truth);
#        3. the row carries the op name - without it the cleanup loop cannot know WHICH budget applies,
#           which is exactly why the old code needed one number for everything;
#        4. the loop decides from that deadline, retains a bounded fallback, and records a heartbeat;
#        5. every OpState release CLEARS the deadline. This one is a trap: the deadline is READ, not
#           recomputed, so a finished row that kept a past deadline would make the NEXT operation look
#           expired on its first loop pass - every operation after the first killed instantly.
#
#      The loop cannot call module functions, so the decision logic exists twice. tests\
#      Test-OperationTimeouts.ps1 runs both copies on identical inputs and compares verdicts; that
#      differential is the guard against drift, and this gate asserts the pieces both copies need.
$coreRawT = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$stateRawT = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw
$wupdRawT = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw

# 1. the table, and that its numbers are per-op rather than one repeated value
$tableMatch = [regex]::Match($coreRawT, '\$global:OperationTimeoutSeconds\s*=\s*@\{([\s\S]*?)\}')
if (-not $tableMatch.Success) {
    Fail 'the per-op operation timeout table is missing (SS5) - a flat stop would come back'
} else {
    $tableBody = $tableMatch.Groups[1].Value
    if ($tableBody -notmatch "'default'") {
        Fail 'the operation timeout table has no default entry - an unrecognised op would be unbounded'
    }
    $values = @([regex]::Matches($tableBody, '=\s*(\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
    if (($values | Sort-Object -Unique).Count -lt 3) {
        Fail "the operation timeout table has only $(($values | Sort-Object -Unique).Count) distinct value(s) - that is not per-op"
    }
    # The reboot chain's own waits must fit inside its budget, or the budget guarantees a false timeout.
    $autoFlow = [regex]::Match($tableBody, "'AutoFlow'\s*=\s*(\d+)")
    $offline = [regex]::Match($coreRawT, '\$global:OfflineWaitSeconds\s*=\s*(\d+)')
    $online = [regex]::Match($coreRawT, '\$global:OnlineWaitSeconds\s*=\s*(\d+)')
    if ($autoFlow.Success -and $offline.Success -and $online.Success) {
        $needed = [int]$offline.Groups[1].Value + [int]$online.Groups[1].Value
        if ([int]$autoFlow.Groups[1].Value -le $needed) {
            Fail "the AutoFlow budget ($($autoFlow.Groups[1].Value)s) is shorter than its own reboot waits ($needed) - every reboot would report a false timeout"
        }
    }
    # Every op Start-UpdateCheckJob accepts must have its own budget.
    $opSet = [regex]::Match($wupdRawT, "ValidateSet\(([^)]*)\)\]\s*\r?\n\s*\[string\]\`$Op")
    if ($opSet.Success) {
        $ops = @($opSet.Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim("'") })
        $missingOps = @($ops | Where-Object { $_ -and $tableBody -notmatch "['""]$_['""]" })
        if ($missingOps.Count -gt 0) {
            Fail "op(s) accepted by Start-UpdateCheckJob with no budget entry (they inherit default silently): $($missingOps -join ', ')"
        }
    }
    if (-not $failed) { Pass 'operation timeouts are per-op, complete, and fit inside the reboot waits (SS5)' }
}

# 2. the row contract must carry what the decision needs
foreach ($field in @('OpName', 'TimeoutExpiresAt', 'TimeoutSource', 'LastHeartbeatAt', 'Heartbeats')) {
    if ($stateRawT -notmatch [regex]::Escape($field)) {
        Fail "the row contract does not carry $field - the per-op deadline decision cannot work (SS5)"
    }
}
if ($stateRawT -notmatch 'function Test-WuuOperationExpired') {
    Fail 'Test-WuuOperationExpired is missing - the SS5 decision is not testable'
} elseif ($stateRawT -notmatch "'Test-WuuOperationExpired'") {
    Fail 'Test-WuuOperationExpired is not exported'
} elseif (-not $failed) { Pass 'the SS5 row contract and decision function exist (SS5)' }

# 3. the deadline is recorded at submission, and the op name travels with it
$supBodyT = Get-WuuFunctionBody $wupdRawT 'Start-UpdateCheckJob'
if (-not $supBodyT) { Fail 'could not locate Start-UpdateCheckJob' }
elseif ($supBodyT -notmatch 'Set-WuuOperationDeadline') {
    Fail 'the submission point does not record the operation deadline - the loop would have to guess the budget'
} elseif (-not $failed) { Pass 'the operation deadline is recorded at submission, with the op name (SS5)' }

# 4. the loop must decide on the deadline, not on a flat elapsed-time threshold
$loopIdx = $coreRawT.IndexOf('#Routine to handle completed runspaces')
$loopBodyT = if ($loopIdx -ge 0) { $coreRawT.Substring($loopIdx, [Math]::Min(60000, $coreRawT.Length - $loopIdx)) } else { '' }
if (-not $loopBodyT) {
    Fail 'could not locate the job cleanup loop'
} else {
    if ($loopBodyT -match 'TotalMinutes -gt 10') {
        Fail 'the flat 10-minute stop is still present - healthy long operations would be killed (SS5)'
    }
    if ($loopBodyT -notmatch 'OperationTimeoutSeconds') {
        Fail 'the cleanup loop does not consult the per-op budget table'
    }
    if ($loopBodyT -notmatch 'TimeoutExpiresAt') {
        Fail 'the cleanup loop does not read the deadline recorded at submission'
    }
    if ($loopBodyT -notmatch 'StartTime\.AddSeconds\(\$budget\)') {
        Fail 'the cleanup loop has no start-time fallback - work not submitted through the single submission point would be unbounded'
    }
    if ($loopBodyT -notmatch 'Heartbeat') {
        Fail 'the cleanup loop records no heartbeat - slow and stuck would be indistinguishable'
    }
    if ($coreRawT -notmatch "SetVariable\('OperationTimeoutSeconds'") {
        Fail 'the per-op table is not injected into the cleanup runspace - the loop could not resolve any budget'
    }
    if (-not $failed) { Pass 'the cleanup loop enforces the per-op deadline with a bounded fallback and a heartbeat (SS5)' }
}

# 5. the trap: every OpState release must also clear the deadline
$idleSitesT = ([regex]::Matches($coreRawT, "OpState = 'Idle'")).Count
$clearSitesT = ([regex]::Matches($coreRawT, "TimeoutExpiresAt'\]\)\s*\{\s*\`$\w+\.TimeoutExpiresAt = \`$null")).Count
if ($idleSitesT -gt 0 -and $clearSitesT -lt $idleSitesT) {
    Fail "only $clearSitesT deadline clear site(s) for $idleSitesT OpState release site(s) - a stale deadline would make the NEXT operation expire immediately (SS5)"
} elseif ($idleSitesT -gt 0) {
    Pass "the operation deadline is cleared wherever the operation lock is released ($clearSitesT/$idleSitesT) (SS5)"
}

# (ac) WORKFLOW STATE IS NOT A DISPLAY STRING (brief SS8). Test-PhaseCompletion decided "is this row
#      settled?" from `UpdatesStatus -ne 'All updates installed'` - a DISPLAY string written from eight
#      sites with five different values. Two consequences, both real:
#
#        * re-wording a status message was a silent change to phase gating;
#        * 'Unknown' (set for a row LOADED FROM CONFIG in command mode, i.e. nothing has been checked
#          and there is nothing to report) was permanently "outstanding", so that row's phase could
#          never complete.
#
#      The check strips comments (including <# #> blocks) from the RAW text rather than using
#      Get-WuuCodeWithoutComments. Two reasons, both learned the hard way here: that tokenizer-based
#      helper joins every token with a space and DISCARDS newlines (so Get-WuuFunctionBody, which slices
#      to the next "\nfunction ", returned the whole file) and drops '$' (so a '\$state -in' pattern
#      could never match). Both produced false failures on correct code. Raw-minus-comments keeps both.
$wupdRawC = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw
$wupdBodyC = Get-WuuFunctionBody $wupdRawC 'Test-PhaseCompletion'
$wupdNoComments = Get-WuuTextWithoutComments -Text $wupdBodyC
if (-not $wupdNoComments) {
    Fail 'could not locate Test-PhaseCompletion'
} else {
    if ($wupdNoComments -match 'UpdatesStatus') {
        Fail 'the phase gate still reads UpdatesStatus - a display string is driving workflow gating (SS8)'
    }
    if ($wupdNoComments -notmatch 'CheckConcluded') {
        Fail 'the phase gate does not consult CheckConcluded - it has no workflow-state predicate (SS8)'
    }
    if ($wupdNoComments -notmatch '\$state -in') {
        Fail 'the phase gate does not distinguish mid-operation workflow states'
    }
    if (-not $failed) { Pass 'the phase gate decides from workflow state, not from a display string (SS8)' }
}

# The field must exist on the row, and must be THREE-state: $null has to stay distinguishable from
# $false, or "never checked" would be read as "checked and clean".
$stateRawW = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw
if ($stateRawW -notmatch 'CheckConcluded\s*=\s*\$null') {
    Fail 'CheckConcluded is not initialised to $null - "not established" must differ from "concluded clean" (SS8)'
} elseif (-not $failed) { Pass 'CheckConcluded is three-state ($null = not established) (SS8)' }

# The payload must SET it at every conclusion of a check, or the predicate never becomes non-null and
# the field is dead in the other direction.
$coreRawW = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$ccSets = ([regex]::Matches($coreRawW, "CheckConcluded'\]\)\s*\{\s*\`$\w+\.CheckConcluded\s*=\s*\`$(true|false)")).Count
if ($ccSets -lt 3) {
    Fail "only $ccSets CheckConcluded assignment(s) in the check payload - an outcome (updates available / reboot required / clean) would never be recorded (SS8)"
} elseif (-not $failed) { Pass "the check payload records CheckConcluded for all three outcomes ($ccSets sites) (SS8)" }

# (ad) CREDENTIAL PROPAGATION AND PERSISTENCE (brief SS6, which was marked NOT VERIFIED). Auditing it
#      found two real defects rather than a clean bill of health:
#
#        A. the saved credential block came from $global:CredentialConfig.Username/.Domain - a variable
#           assigned exactly ONCE in the codebase (its initialiser) - so every configuration recorded
#           Username='' while the real name sat in $global:CustomCredentials.UserName. Verified by
#           probe, not by reading.
#        B. nothing READ that block on load, so loading a list into a session with a different credential
#           mode silently changed which account remote operations would use.
#
#      The identity is now taken from the PSCredential and compared on load. What is persisted is
#      IDENTITY ONLY - never a password, or anything derived from one.
$credRawC = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Credentials.psm1') -Raw
# Comments are stripped - lines AND <# #> blocks - before the identity checks below, because the
# implementation explains the removal by quoting the old `$global:CredentialConfig.Username` read and
# its header says it "never handles a password". Matching raw text reported BOTH as defects (observed).
# This is the third time in this pass that a check matched its own explanatory comment, so the shared
# block-comment-aware helper is used rather than another ad-hoc line filter.
$credNoComments = Get-WuuTextWithoutComments -Text $credRawC

# 1. The signature must come from the PSCredential, not from the never-assigned CredentialConfig.
if ($credNoComments -notmatch 'function Get-WuuCredentialStateSignature') {
    Fail 'Get-WuuCredentialStateSignature is missing - SS6 has no single source for the credential identity'
} elseif ($credNoComments -notmatch 'CustomCredentials\.UserName') {
    Fail 'the credential signature does not read CustomCredentials.UserName - it would record an empty identity again (SS6)'
}
if ($credNoComments -match '\$global:CredentialConfig\.Username') {
    Fail 'the credential identity is still read from $global:CredentialConfig.Username, which is never assigned (SS6)'
}

# 2. Identity only. A password-shaped value must not be placed in the signature hashtable.
$sigBody = Get-WuuTextWithoutComments -Text (Get-WuuFunctionBody $credRawC 'Get-WuuCredentialStateSignature')
if ($sigBody) {
    if ($sigBody -match 'Password|SecureString|GetNetworkCredential|PtrToStringAuto') {
        Fail 'the credential signature handles password material - it must be identity only (SS6)'
    }
    if ($sigBody -notmatch 'Mode') {
        Fail 'the credential signature does not state the mode in words'
    }
}

# 3. The comparison must exist and be consulted by the load path, or the block stays write-only.
if ($credRawC -notmatch 'function Test-WuuCredentialStateMatches') {
    Fail 'Test-WuuCredentialStateMatches is missing - a saved credential mode could not be compared (SS6)'
}
if ($credRawC -notmatch "'Test-WuuCredentialStateMatches'") {
    Fail 'Test-WuuCredentialStateMatches is not exported'
}
if ($credRawC -notmatch "'Get-WuuCredentialStateSignature'") {
    Fail 'Get-WuuCredentialStateSignature is not exported (the save path could not reach it)'
}
if ($coreRawE -notmatch 'Test-WuuCredentialStateMatches') {
    Fail 'the config load path does not compare the saved credential mode - the saved block stays write-only (SS6)'
} elseif ($coreRawE -notmatch 'CREDENTIAL MODE DIFFERS') {
    Fail 'a credential-mode difference is not surfaced to the operator'
} else {
    if (-not $failed) { Pass 'credential identity is recorded from the PSCredential and compared on load (SS6)' }
}

# 4. The propagation matrix: the two remote task paths that CHANGE a machine must resolve and pass a
#    credential, and must skip resolution on the local machine (where the process token is already right
#    and passing credentials to local DCOM is rejected).
$passCount = ([regex]::Matches($coreRawE, "InvokeRemoteTaskScript[\s\S]{0,400}?Credential \`$remoteCred")).Count
if ($passCount -lt 2) {
    Fail "only $passCount remote-task call(s) pass the resolved credential - the download/install paths must both pass it (SS6)"
}
# PHASE 1 replaced the duplicated inline guard with a single rule in the resolver, so the gate now
# asserts the RULE EXISTS IN ONE PLACE rather than that it is repeated at the call sites. Both are
# acceptable; what is not acceptable is neither, or a fallback branch reappearing.
$guardCount = ([regex]::Matches($coreRawE, "UseCustomCredentials -and \`$Computer\.computer -ne 'localhost'")).Count
$wupdRawC = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw
$resolverHasLocalRule = [bool]($wupdRawC -match "\`$isLocal = \(\`$ComputerName -eq 'localhost' -or \`$ComputerName -eq \`$env:COMPUTERNAME\)")
if ($guardCount -eq 0 -and -not $resolverHasLocalRule) {
    Fail 'the local-machine rule is neither centralised in the resolver nor present at the call sites - custom credentials could be applied to the local host (SS6)'
}
if ($wupdRawC -notmatch '\[pscredential\]\$Cred') {
    Fail 'the credential probe is not typed [pscredential] - a plain-string password could be used as one (SS6)'
}
# PHASE 1 INVERSION. This gate used to REQUIRE a null cache entry ("caches the default-credentials
# outcome"), i.e. it demanded the very fallback that Phase 1 removes - a gate enforcing a defect. It
# now forbids the fallback on both sides, which is the property that actually matters.
$rsResolverC = [regex]::Match($wupdRawC, "SetVariable\('GetRemoteCredentialsScript', \[scriptblock\]::Create\(\{([\s\S]*?)\n        \}\.ToString\(\)\)\)").Groups[1].Value
$rsCodeC = Get-WuuTextWithoutComments -Text $rsResolverC
if ($rsCodeC -match "-ArgumentList @\(\`$ComputerName, \`$null\)") {
    Fail 'the runspace resolver probes the DEFAULT identity again - the silent credential fallback is back (Phase 1)'
}
if ($rsCodeC -match "CredentialCache\[\`$ComputerName\] = \`$null") {
    Fail "the resolver records a 'use default' cache entry again, so a silent fallback can occur (Phase 1)"
}
if ($rsCodeC -notmatch 'No fallback is attempted') {
    Fail 'the runspace resolver does not refuse explicitly when configured custom credentials are unusable (Phase 1)'
}
# ...and the module-side resolver must not fall back either: no default probe after a custom failure.
$credResolveBody = Get-WuuFunctionBody (Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Credentials.psm1') -Raw) 'Resolve-WuuOperationCredential'
$credResolveCode = Get-WuuTextWithoutComments -Text $credResolveBody
if ($credResolveCode -match 'Operation ''credential verification \(process identity\)''') {
    # A process-identity probe is legitimate ONLY on the Default path. It must be unreachable when the
    # mode is Custom, which is guaranteed by the mode being decided before any probe runs.
    $modeAt = $credResolveCode.IndexOf("`$mode = if (`$customConfigured")
    $probeAt = $credResolveCode.IndexOf("credential verification (process identity)")
    if ($modeAt -lt 0 -or $probeAt -lt 0 -or $modeAt -gt $probeAt) {
        Fail 'the module-side resolver can probe the process identity after deciding on custom credentials - the fallback shape (Phase 1)'
    }
}
if (-not $failed) {
    Pass 'credential identity is deterministic: no fallback on either side, and the local-machine rule in one place (Phase 1)'
}

# 5. No password in the logs or the audit trail. Matches password-shaped EXPRESSIONS, not the word
#    "password": four correct lines log that the secure PROMPT was unavailable and interpolate only the
#    exception text, and a word-match reported those as leaks (observed while writing the test).
$pwExpression = '\$(password|pass|pwd|plainPassword|plaintext|secret|sec)\b|\.Password\b|GetNetworkCredential|PtrToStringAuto|SecureStringToBSTR'
$leakFiles = @()
foreach ($candidate in @('Wuu.Core.psm1', 'Wuu.WindowsUpdate.psm1', 'Wuu.Credentials.psm1', 'Wuu.Remote.psm1')) {
    $text = Get-Content -LiteralPath (Join-Path $root "src\$candidate") -Raw
    $logLines = ($text -split "`r?`n") | Where-Object { $_ -match '(WriteWuuLog|Write-InfoLog|Write-DebugLog|Write-WarningLog|Write-ErrorLog)' }
    if (@($logLines | Where-Object { $_ -match $pwExpression }).Count -gt 0) { $leakFiles += $candidate }
}
if ($leakFiles.Count -gt 0) {
    Fail "password-shaped expression(s) interpolated into a log call in: $($leakFiles -join ', ') (SS6)"
} elseif (-not $failed) {
    Pass 'no log or audit call interpolates a password-shaped expression (SS6)'
}

# (ae) -WHATIF REPORTS A PER-COMPUTER PLAN (brief SS11). `-WhatIf` printed one sentence ("would run
#      'install' against all computers"), which is not reviewable before a production change - and for
#      a RESTART it is wrong in the most expensive direction: a busy computer is NOT deferred for
#      restart/service (the request is dropped), so "would restart 10 servers" can be false for three
#      of them.
#
#      The plan states three facts per computer (what it would do, whether it is busy, and why), and the
#      policy must MATCH THE HANDLERS rather than be a second opinion: deferring verbs set Pending so
#      the request is honoured later, refusing verbs do not.
$cmdRawP = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Command.psm1') -Raw
$coreRawP = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw

if ($cmdRawP -notmatch 'function Get-WuuCommandPlan') {
    Fail 'Get-WuuCommandPlan is missing - -WhatIf cannot report a per-computer breakdown (SS11)'
} elseif ($cmdRawP -notmatch "'Get-WuuCommandPlan'") {
    Fail 'Get-WuuCommandPlan is not exported'
} elseif ($cmdRawP -notmatch 'function Write-WuuCommandPlan') {
    Fail 'Write-WuuCommandPlan is missing'
} elseif ($cmdRawP -notmatch 'Get-WuuCommandPlan -Verb \$Verb') {
    Fail 'the -WhatIf path does not call the planner - it still prints one sentence (SS11)'
} elseif (-not $failed) {
    Pass 'the -WhatIf path produces a per-computer plan (SS11)'
}

# The policy table, and its agreement with the handlers.
if ($cmdRawP -match "\`$Verb -in @\('restart', 'service'\)\)\s*\{\s*'refuse'") {
    Pass 'the plan refuses (rather than defers) for restart and service, matching the handlers (SS11)'
} else {
    Fail "the plan's busy policy is not refuse-for-restart/service - it could promise a reboot it will not perform (SS11)"
}
# Deferring handlers must actually set Pending, or the plan's 'queue' action is a lie.
#
# Two acceptable forms, and the SECOND one is why this check was widened: after the SS7 pending-policy
# work, a handler delegates to Set-WuuPendingOperation instead of assigning Pending itself. The
# invariant is unchanged - a deferred request must end up Pending - so it is now asserted in two
# halves: the handler routes through the policy, AND the policy sets Pending. Checking only for the
# literal assignment would have failed correct code (it did), and checking only for the function name
# would prove nothing at all.
#
# The state source is read HERE rather than reused from gate (aj), which is defined further down this
# file - referencing it would be $null at this point and the check would silently pass a broken
# invariant. (It failed loudly instead, which is how this was found.)
$stateRawP = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw
$handlerSetsPending = [bool]($coreRawP -match 'if \(Test-WuuComputerBusy -Row \$r\) \{[\s\S]{0,400}?\$r\.Pending = \$true')
$handlerUsesPolicy = [bool]($coreRawP -match "Set-WuuPendingOperation -Row \`$r -Op '(Download|InstallAndRecheck)'")
$policySetsPending = [bool]((Get-WuuFunctionBody $stateRawP 'Set-WuuPendingOperation') -match '\$Row\.Pending = \$true')
if ($handlerSetsPending -or ($handlerUsesPolicy -and $policySetsPending)) {
    Pass 'the deferring handlers really set Pending (directly or via the SS7 policy), so the plan''s queue action is truthful (SS11)'
} else {
    Fail "a deferring handler no longer sets Pending - the plan would claim a request is honoured later when it is dropped (SS11)"
}
# ...and the restart handler must NOT defer.
$restartHandlerP = [regex]::Match($coreRawP, '\$consoleActions\.EventRestartComputer = \{[\s\S]*?\n\}').Value
if ($restartHandlerP -and $restartHandlerP -notmatch '\$r\.Pending = \$true') {
    Pass 'the restart handler never defers a busy computer, matching the plan (SS11)'
} else {
    Fail 'the restart handler defers after all - the plan claims it refuses, and the operator is told the wrong thing (SS11)'
}
# The no-op test must be the handler's own condition, not an independent interpretation.
if ($cmdRawP -match '\$avail -eq \$dl' -and $coreRawP -match 'if \(\$r\.Available -eq \$r\.Downloaded\)') {
    Pass "the plan's no-op test matches the handler's own condition (SS11)"
} else {
    Fail "the plan and the download handler disagree about what 'nothing to do' means (SS11)"
}
# Unresolved names must be REPORTED, or a typo in a change ticket becomes a silent no-op.
if ($cmdRawP -match 'Unresolved = @\(\$unresolved\)' -and $cmdRawP -match 'NOT RESOLVED') {
    Pass 'names that resolve to nothing are reported rather than silently dropped (SS11)'
} else {
    Fail 'unmatched names are not reported - a typo in a change ticket would go unnoticed (SS11)'
}
# The resolution must mirror the real selection helper (exact, then UNIQUE prefix). An ambiguous prefix
# must resolve to nothing: guessing a computer during a dry run is worse than reporting the name.
if ($cmdRawP -match "\`$hits\.Count -eq 1\) \{ return \`$hits\[0\]") {
    Pass 'the plan resolves names the way the selection helper does (unique prefix only) (SS11)'
} else {
    Fail 'the plan resolves names differently from the real selection helper (SS11)'
}
# -WhatIf must stay a Success, and must not claim to have queued anything.
# Literal match (no regex): the pattern contains '$true', '.', and a ';' - as a regex the unescaped
# escape sequence '\T' is an ArgumentException, which is how this gate first reported itself.
if ($cmdRawP.Contains("WhatIf = `$true; Would = `$plan.Detail; Result = 'Success'")) {
    Pass '-WhatIf still classifies as Success and never as Queued (SS10/SS11)'
} else {
    Fail '-WhatIf no longer reports Result=Success'
}
# ...and it must write NO audit record. A simulation is not a denied attempt, and mixing plans into the
# trail would make 'refused to make this change' indistinguishable from 'asked what it would do'. This
# is also asserted by tests\Test-AuditTrail.ps1, so the contract has two guards.
$whatIfBody = [regex]::Match($cmdRawP, 'if \(\$WhatIf -and \$entry\.Mutating\) \{[\s\S]*?\n    \}').Value
if ($whatIfBody -and $whatIfBody -notmatch 'Write-WuuAuditRecord' -and $whatIfBody -notmatch 'Start-WuuAuditSession') {
    Pass '-WhatIf writes no audit record: the trail records changes, not simulations (SS11)'
} else {
    Fail '-WhatIf writes audit records - simulations must not enter the compliance trail (SS11)'
}
# The JSON must be RETURNED, not emitted on the output stream. Emitting it made the call return two
# objects (measured); the exit code survived only because PowerShell member-enumerates across arrays,
# which is luck rather than design.
if ($cmdRawP -match '\$jsonText = \$null' -and $cmdRawP -match 'Plan = \$plan; Json = \$jsonText') {
    Pass 'the -WhatIf -Json output is returned on the result object, not emitted as a second object (SS11)'
} else {
    Fail 'the -WhatIf -Json path emits the JSON on the output stream - callers would receive two objects (SS11)'
}

# (af) SOURCE ENCODING. A shipped file that contains non-ASCII BYTES must carry a UTF-8 BOM.
#
#      This gate exists because I broke it while working on SS11: I rewrote Wuu.Core.psm1 with
#      Set-Content, which under PS7 writes UTF8 WITHOUT a BOM, and the file (which contains 51
#      non-ASCII bytes - the '-' ellipsis and friends) was corrupted by the encoding change. git showed
#      the first line as '´╗┐#Requires' - the BOM bytes reinterpreted. Nothing in the test suite noticed,
#      because none of them check encoding.
#
#      The rule is verified against every shipped file, not assumed:
#        * 4 files contain non-ASCII and ALL FOUR have a BOM (Command, Core, Session, Package-WUU2);
#        * all 20 remaining files have zero non-ASCII bytes and no BOM.
#      So the invariant is 'non-ASCII implies BOM', and it is checked in that direction only - a BOM on
#      an ASCII-only file is harmless and is not treated as a failure.
$encodingFiles = @()
$encodingFiles += @(Get-ChildItem -Path (Join-Path $root 'src') -Filter '*.psm1' -File)
$encodingFiles += @(Get-ChildItem -Path $root -Filter '*.ps1' -File)
$encodingFiles += @(Get-ChildItem -Path (Join-Path $root 'Scripts') -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike '_*' })
$encodingOffenders = @()
foreach ($ef in $encodingFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($ef.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if ($hasBom) { continue }
    $nonAscii = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -ge 0x80) { $nonAscii++ } }
    if ($nonAscii -gt 0) { $encodingOffenders += "$($ef.Name) ($nonAscii non-ASCII byte(s), no BOM)" }
}
if ($encodingOffenders.Count -gt 0) {
    Fail ("shipped file(s) contain non-ASCII bytes WITHOUT a UTF-8 BOM - their text is encoding-dependent and a rewrite will corrupt it: " + ($encodingOffenders -join '; '))
} else {
    Pass "every shipped file with non-ASCII bytes carries a UTF-8 BOM ($($encodingFiles.Count) file(s) checked)"
}

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
$guardedReleases = ([regex]::Matches($coreRawA, "PSObject\.Properties\['OperationId'\]\) \{ \`$jobOpId")).Count +
                   ([regex]::Matches($coreRawA, "PSObject\.Properties\['OperationId'\]\) \{ \`$toOpId")).Count
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
if ($coreRawA -notmatch "Properties\['Runspace'\]\) \{ \`$toRow\.Runspace = \`$null \}") {
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
# The ORDER alone is not the invariant: a tautology experiment that kept `return 'Failed'` in place but
# replaced its CONDITION with an impossible test (`$state -eq 'ZZZ'`) passed an order-only check while
# five of the suite's assertions failed. So the condition itself is asserted, not merely its position.
$oneBodyK = Get-WuuFunctionBody $stateRawK 'Get-WuuTargetOutcome'
$failAtK = $oneBodyK.IndexOf("return 'Failed'")
$okAtK = $oneBodyK.IndexOf("return 'Success'")
if ($oneBodyK -notmatch "if \(\`$state -eq 'Error' -or \`$updatesStatus -eq 'Error'\) \{ return 'Failed' \}") {
    Fail 'Get-WuuTargetOutcome no longer derives Failed from State OR UpdatesStatus - a row whose error is written to only one of the two fields would be misclassified (SS10)'
} elseif ($failAtK -lt 0 -or $okAtK -lt 0) {
    Fail 'Get-WuuTargetOutcome does not classify a settled target (SS10)'
} elseif ($failAtK -gt $okAtK) {
    Fail 'Get-WuuTargetOutcome checks completion BEFORE failure - a row carrying a stale Complete would mask a current error (SS10)'
} else {
    Pass 'per-target classification derives failure from both fields and checks it before completion (SS10)'
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

# 1. Debug logging must default to OFF. Verbose-by-default is wrong for an unattended patch tool:
#    large logs, I/O on every run, operational detail written by default, and diagnostic records
#    interleaved with the audit trail.
if ($coreRawM -notmatch '\$global:EnableDebugLogging\s*=\s*\$false') {
    Fail 'debug logging does not default to $false - verbose-by-default is wrong for an unattended patch tool (large logs, extra I/O, operational detail on disk) (SS17)'
} elseif ($coreRawM -match '\$global:EnableDebugLogging\s*=\s*\$true') {
    # The override path legitimately assigns $true inside the WUU_DEBUG branch, so its presence is
    # only a failure if it is NOT guarded by that branch.
    if ($coreRawM -notmatch 'WUU_DEBUG') {
        Fail 'debug logging is set to $true with no documented override - production behaviour would depend on editing source (SS17)'
    } else {
        Pass 'debug logging defaults to $false and is enabled by the WUU_DEBUG override (SS17)'
    }
} else {
    Pass 'debug logging defaults to $false (SS17)'
}
# The override must exist, so an operator can diagnose without editing a shipped file.
if ($coreRawM -notmatch 'WUU_DEBUG') {
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
if ($coreRawM -notmatch 'Read-WuuAnswer -Prompt \$Prompt -Secure') {
    Fail 'the password prompt bypasses Read-WuuAnswer - a scripted or non-interactive run could not answer the unlock prompt (SS15)'
} else {
    Pass 'the password prompt routes through the input choke point (SS15)'
}

# 4. THE VERSION GUARD (the defect that started this). The embedded literal and a real git tag at HEAD
#    must agree, or audit records carry a version no release used. Checked by RUNNING the resolver -
#    a text comparison here would duplicate its logic instead of exercising it.
$embeddedVersionM = ''
$versionMatchM = [regex]::Match($coreRawM, "\`$global:WuuVersion\s*=\s*'([^']+)'")
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
            # Not on a tag (a commit between releases) is legitimate - report it rather than fail.
            Pass "version $($versionCheck.Version) resolved from source; $($versionCheck.Note) (SS18)"
        }
    } catch {
        Fail "could not resolve the version for the mismatch check: $($_.Exception.Message)"
    }
}

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

if ($failed) { Write-Host "`nValidation FAILED" -ForegroundColor Red; exit 1 }
else { Write-Host "`nAll validation checks passed" -ForegroundColor Cyan }