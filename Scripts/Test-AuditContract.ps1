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
