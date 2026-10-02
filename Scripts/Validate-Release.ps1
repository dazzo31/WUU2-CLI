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
#
# --- MACHINE-READABLE MODE (reviewer P4) ---------------------------------------------------------
# -Json writes every verdict to a JSON file so CI can gate on a FIELD rather than on scraping text,
# and so the five verdict kinds are distinguishable. Without it a consumer had exactly two signals
# (a line matching '^FAIL:' and the exit code), which cannot express "this check did not run" or
# "this is advisory".
#
# THE DEFAULT OUTPUT IS DELIBERATELY UNCHANGED. The verdict helpers still write to the host with the
# same wording and colours in both modes, so a human reading a -Json run sees exactly what they see
# today; -Json ADDS a file. The risk this avoids is the usual one with a machine-readable mode: the
# human output becomes a rendering of the machine output and quietly loses detail that only ever
# lived in a sentence.
#
# THE FIVE VERDICTS AND WHY THEY ARE FIVE (not two):
#   PASS             the assertion holds
#   FAIL             the assertion is violated - the release must not ship
#   WARN             a concern that is not a release blocker
#   SKIP             NOT RUN, and this is why it must not be reported as a pass. A skipped check that
#                    reads as PASS is worse than no check: it buys confidence without evidence
#   NOT_IMPLEMENTED  the property has no check at all. The reviewer asked for this explicitly, and the
#                    distinction matters: "we verified this" and "we have not built a verifier" are
#                    different facts, and conflating them is how a gap becomes invisible.
#
# The verdict list is ORDERED by severity and the summary counts every kind, so a NOT_IMPLEMENTED can
# never be mistaken for a PASS by a consumer that only looks at totals.
param(
    [Parameter(Mandatory = $false)][string]$Json = ''
)

$failed = $false
$script:WuuGateVerdicts = New-Object System.Collections.Generic.List[object]

function Add-WuuGateVerdict([string]$Status, [string]$Message) {
    $script:WuuGateVerdicts.Add([pscustomobject]@{ Status = $Status; Message = $Message }) | Out-Null
}

function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:failed = $true; Add-WuuGateVerdict 'FAIL' $m }
function Pass($m) { Write-Host "PASS: $m" -ForegroundColor Green; Add-WuuGateVerdict 'PASS' $m }
# Warn does NOT set $failed: an advisory verdict that blocked a release would make WARN a synonym for
# FAIL, and then nobody would dare emit one.
function Warn($m) { Write-Host "WARN: $m" -ForegroundColor Yellow; Add-WuuGateVerdict 'WARN' $m }
# Skip records that a check did not run. It is a distinct verdict precisely so that
# "not evaluated" cannot be counted as "evaluated and clean".
function Skip($m) { Write-Host "SKIP: $m" -ForegroundColor DarkGray; Add-WuuGateVerdict 'SKIP' $m }
function Not-Implemented($m) { Write-Host "NOT_IMPLEMENTED: $m" -ForegroundColor DarkYellow; Add-WuuGateVerdict 'NOT_IMPLEMENTED' $m }

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# --- SOURCE STRUCTURE (sections 1-8) - extracted to Scripts\Test-SourceStructure.ps1 (instructions SS39).
#     Dot-sourced HERE, where the sections were: these verdicts lead the report, and the fragments that
#     follow read variables this file no longer defines (they are independent by design - verified).
. (Join-Path $PSScriptRoot 'Test-SourceStructure.ps1')

# --- 9. Audit invariants (Phase 4) --------------------------------------------------------
# These are the properties the trail exists to guarantee. Asserting them structurally beats
# trusting that a future edit preserves them.
#
# Evaluate against COMMENT-STRIPPED code. An earlier version matched raw text and flagged the
# module's own explanatory comments ("OneDrive-synced tree caused ... failures") as a synced-folder
# path - the same false-positive class the headless test hit. Strip comments via the tokenizer.
$auditPath = Join-Path $root 'src\Wuu.Audit.psm1'
$auditCode = Get-WuuCodeWithoutComments -Path $auditPath

# --- SHARED HARNESS HELPERS (hoisted above the fragments, SS39) ------------------------------------
# These three extract a function body from a module's source text. They are used by SEVERAL fragments,
# so they are DEFINED HERE rather than inside one of them: a helper that lives in a fragment only
# exists once that fragment has been dot-sourced, which made a block's correctness depend on the
# ORDER of the dot-source lines. (Observed, not theorised: moving the P3 close-out block into
# Test-Contracts.ps1 - dot-sourced before the fragment that happened to define Get-WuuFunctionBody -
# broke it with "could not extract Get-WuuOperationRemainingSeconds".)

function Get-WuuFunctionBody([string]$Text, [string]$Name) {
    $i = $Text.IndexOf("function $Name")
    if ($i -lt 0) { return '' }
    $next = $Text.IndexOf("`nfunction ", $i + 10)
    if ($next -lt 0) { return $Text.Substring($i) }
    return $Text.Substring($i, $next - $i)
}

function Get-WuuBalancedBody([string]$Text, [string]$Name) {
    $m = [regex]::Match($Text, "function\s+$Name\s*(?:\([^)]*\))?\s*\{")
    if (-not $m.Success) { return '' }
    $start = $m.Index + $m.Length - 1
    $depth = 0
    $i = $start
    $inSingle = $false
    $inDouble = $false
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if (-not $inSingle -and -not $inDouble) {
            if ($c -eq "'") { $inSingle = $true }
            elseif ($c -eq '"') { $inDouble = $true }
            elseif ($c -eq '{') { $depth++ }
            elseif ($c -eq '}') { $depth--; if ($depth -eq 0) { return $Text.Substring($start, $i - $start + 1) } }
        } elseif ($inSingle -and $c -eq "'") { $inSingle = $false }
        elseif ($inDouble -and $c -eq '"') { $inDouble = $false }
        $i++
    }
    return ''
}

function Remove-WuuParamBlock([string]$Body) {
    $pm = [regex]::Match($Body, '\bparam\s*\(')
    if (-not $pm.Success) { return $Body }
    $open = $pm.Index + $pm.Length - 1
    $depth = 0
    $i = $open
    while ($i -lt $Body.Length) {
        $c = $Body[$i]
        if ($c -eq '(') { $depth++ } elseif ($c -eq ')') { $depth--; if ($depth -eq 0) { return $Body.Substring($i) } }
        $i++
    }
    return $Body
}

# (a)-(i) x3 AUDIT CONTRACT - extracted to Scripts\Test-AuditContract.ps1 (instructions SS39).
. (Join-Path $PSScriptRoot 'Test-AuditContract.ps1')
# (a)-(k) RELEASE METADATA - extracted to Scripts\Test-ReleaseMetadata.ps1 (instructions SS39).
. (Join-Path $PSScriptRoot 'Test-ReleaseMetadata.ps1')
# (a)-(l) CONSOLE CONTRACT - extracted to Scripts\Test-Contracts.ps1 (instructions SS39).
. (Join-Path $PSScriptRoot 'Test-Contracts.ps1')

# (m)-(r) GUIDED CONSOLE CONTRACT (continued) - extracted to Scripts\Test-Contracts.ps1, which is
#      dot-sourced above. These cover offline handling, the plan lifecycle, guided audit targets,
#      reason consumption and the GUI-control-member ban.

# (s)-(z) ENGINE ARCHITECTURE - extracted to Scripts\Test-Architecture.ps1 (instructions SS39).
#      Dot-sourced in THIS scope so it shares the gate's variables and helpers, and at THIS position so
#      the verdict order is unchanged.
. (Join-Path $PSScriptRoot 'Test-Architecture.ps1')

# (aa)-(ae) COMMAND BEHAVIOUR CONTRACT - extracted to Scripts\Test-CommandContract.ps1 (instructions
#      SS39). Dot-sourced HERE, where the blocks were, so their verdicts keep their position in the
#      list. A fragment may be dot-sourced ONCE.
. (Join-Path $PSScriptRoot 'Test-CommandContract.ps1')
# (af) SOURCE ENCODING - extracted to Scripts\Test-Encoding.ps1 (instructions SS39). Dot-sourced HERE so
#      its verdict keeps its position in the list, and INTO THIS SCOPE so it shares $root and the verdict
#      helpers. The file states the same contract at the top.
. (Join-Path $PSScriptRoot 'Test-Encoding.ps1')

# (ag), (al)-(am) BEHAVIOUR COVERAGE AND RELEASE HYGIENE - extracted to
#      Scripts\Test-CoverageAndHygiene.ps1 (instructions SS39). Dot-sourced HERE, where the blocks were,
#      so their verdicts keep their position in the list. A fragment may be dot-sourced ONCE.
. (Join-Path $PSScriptRoot 'Test-CoverageAndHygiene.ps1')
# (an)-(ar) STATE-MUTATION CONTRACT AND CODE HYGIENE - extracted to Scripts\Test-MutationContract.ps1
#      (instructions SS39). Dot-sourced HERE, where the blocks were, so their verdicts keep their
#      position in the list. A fragment may be dot-sourced ONCE - Test-Architecture.ps1 is already
#      dot-sourced above, so these blocks needed their own file rather than being appended to it.
. (Join-Path $PSScriptRoot 'Test-MutationContract.ps1')

# (as) THE JSON REPORT AND THE FIVE VERDICT KINDS (reviewer P4). The gate had two signals - a line
#      matching '^FAIL:' and the exit code - which cannot express "did not run" or "advisory". It now
#      has five kinds, and a consumer can gate on a FIELD rather than scraping text.
#
#      WHY THIS BLOCK IS NEEDED AT ALL, given the report is generated by the code it describes: the
#      verdict kinds were DEFINED and NEVER EMITTED. WARN, SKIP and NOT_IMPLEMENTED appeared in the
#      helper definitions and in the report schema but at no call site, so the report's own totals read
#      WARN=0 SKIP=0 NOT_IMPLEMENTED=0 on every run - a schema advertising capability that did not
#      exist. That is the same defect as exit code 4 being reserved-but-unproducible, and a reserved
#      verdict is worse than an absent one because the report claims the distinction is available.
$selfText = Get-Content -LiteralPath $PSCommandPath -Raw
# THE CORPUS IS THE GATE PLUS ITS FRAGMENTS. Validate-Release.ps1 was decomposed (SS39) into
# Scripts\Test-*.ps1 files, and a verdict kind emitted from a fragment is just as reachable as one
# emitted here. Reading only this file would report "defined but never emitted" for a kind whose call
# site had moved - a FALSE FAILURE that would appear the moment someone extracted the block holding it.
# Reading the concatenation keeps the check about the set of checks the gate runs, not about one file.
$gateCorpus = @($selfText) + @(Get-ChildItem -Path $PSScriptRoot -Filter 'Test-*.ps1' -File |
        ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) })
$gateCode = Get-WuuTextWithoutComments -Text ($gateCorpus -join "`n")
foreach ($kind in @('Warn', 'Skip', 'Not-Implemented')) {
    # Count INVOCATIONS, not the definition. `function Warn($m) {` and the report's 'WARN' string both
    # contain the word; only a call site means the kind is reachable.
    $calls = ([regex]::Matches($gateCode, "(?m)^\s*$([regex]::Escape($kind))\s")).Count
    if ($calls -eq 0) {
        Fail "the '$kind' verdict is defined but never emitted - the report advertises a distinction no check can produce (P4)"
    }
}
if (-not $failed) {
    Pass 'every verdict kind (PASS/FAIL/WARN/SKIP/NOT_IMPLEMENTED) is emitted by at least one check (P4)'
}

# The report must be produced before the exit, so a FAILING run also yields a report - the case where
# it is most useful - and it must be produced AFTER every check, or the last blocks are missing from it.
#
# THE PROPERTY ASSERTED IS "NO VERDICT IS EMITTED AFTER THE WRITER", not "there is exactly one exit".
# An earlier version counted exit statements and kept counting its own quoted token: comment-stripping
# removes comments but NOT string literals, so the check's own pattern text inflated the count twice in a
# row. Counting occurrences of a token the check must quote is self-defeating. The window between the
# writer and the exit contains no such token and states the real requirement directly.
#
# MEASURED AGAINST THE GATE ALONE, not the corpus: this is about the ORDER of the gate's own file - the
# writer call, the exit statement, and whether a verdict is emitted between them. Concatenating the
# fragments would put fragment text between those two points and report verdicts that are not there.
$gateSelf = Get-WuuTextWithoutComments -Text $selfText
$writerCalls = ([regex]::Matches($gateSelf, 'Write-WuuGateJsonReport')).Count
$writerIdx = $gateSelf.LastIndexOf('Write-WuuGateJsonReport -Path')
$exitIdx = $gateSelf.LastIndexOf('Validation FAILED')
$lastCheckIdx = $gateSelf.LastIndexOf('Not-Implemented')

if ($writerCalls -lt 2) {
    Fail "the report writer is referenced $writerCalls time(s) - it must be both defined and called (P4)"
} elseif ($writerIdx -lt 0) {
    Fail 'the report writer is never CALLED (only defined) - no report would be produced (P4)'
} elseif ($exitIdx -lt 0 -or $exitIdx -lt $writerIdx) {
    Fail 'the report writer is not followed by the failure exit - a failing run could produce no report (P4)'
} else {
    $window = $gateSelf.Substring($writerIdx, $exitIdx - $writerIdx)
    $lateVerdicts = ([regex]::Matches($window, '(?m)^\s*(Pass|Fail|Warn|Skip|Not-Implemented)\s')).Count
    if ($lateVerdicts -gt 0) {
        # THE BUG THIS CATCHES, and it was real: the writer was placed BEFORE the final blocks, so the
        # report was written WITHOUT them. It held 145 verdicts while the gate had emitted more, and
        # WARN / SKIP / NOT_IMPLEMENTED never appeared in it at all - the three kinds this mode exists to
        # expose were absent from the artifact that exposes them. A report silently missing its last
        # checks is worse than no report, because it looks complete.
        Fail "the report is written before $lateVerdicts further verdict(s) - they would be missing from it (P4)"
    } elseif ($lastCheckIdx -gt $writerIdx) {
        Fail 'a check block appears after the report writer - its verdicts would be missing from the report (P4)'
    } else {
        Pass 'the report is written after every check and before the failure exit, so a failing run still reports (P4)'
    }
}

# The trap that silently produced an EMPTY report: @() over a generic List throws on PS 5.1.
# Asserted against the GATE'S FULL CORPUS, not this file: the report writer moved into
# Test-MutationContract.ps1 with block (ar) (SS39), so reading only the gate would report "does not
# enumerate with .ToArray()" for code that does - a false failure, and exactly what happened when the
# writer moved. The property is about the report writer wherever it lives.
if ($gateCode -match '@\(\s*\$script:WuuGateVerdicts\s*\)') {
    Fail 'the report reads the verdict list with @(...) - on PS 5.1 that throws over a generic List and the assignment silently becomes $null, producing a report of one null verdict (P4)'
} elseif ($gateCode -notmatch 'WuuGateVerdicts\.ToArray\(\)') {
    Fail 'the report does not enumerate the verdict list with .ToArray() (P4)'
} else {
    Pass 'the report enumerates the verdict list safely (.ToArray(), not @() which throws on PS 5.1) (P4)'
}

# (at)-(az) ENGINE HEALTH - extracted to Scripts\Test-EngineHealth.ps1 (instructions SS39).
#      Dot-sourced HERE, where the blocks were, so their verdicts keep their position in the list.
#      A fragment may be dot-sourced ONCE.
. (Join-Path $PSScriptRoot 'Test-EngineHealth.ps1')
# DOC CONSISTENCY (SS40/SS45). Dot-sourced LAST: it measures the tree against the document, so it must
# run after every other block has had its say. Extracted to its own file rather than appended to
# Test-EngineHealth.ps1, because that fragment is already dot-sourced above and a fragment may be
# dot-sourced ONCE.
. (Join-Path $PSScriptRoot 'Test-DocConsistency.ps1')
# --- JSON REPORT (P4), written LAST --------------------------------------------------------------
# THE PLACEMENT IS THE POINT. The call was originally placed just after the report function was
# defined, which is ~140 lines BEFORE the final blocks - so the report was written without them. It
# held 145 verdicts while the gate had emitted more, and WARN / SKIP / NOT_IMPLEMENTED never appeared
# in it at all: the three kinds this mode exists to expose were absent from the artifact that exposes
# them. A report that is silently missing its last checks is worse than no report, because it looks
# complete. It is written here, after every check, and before the single failure exit so that a
# FAILING run still produces one.
if ($Json) {
    $jsonPath = if ([System.IO.Path]::IsPathRooted($Json)) { $Json } else { Join-Path $root $Json }
    $null = Write-WuuGateJsonReport -Path $jsonPath
}

if ($failed) { Write-Host "`nValidation FAILED" -ForegroundColor Red; exit 1 }
else { Write-Host "`nAll validation checks passed" -ForegroundColor Cyan }
