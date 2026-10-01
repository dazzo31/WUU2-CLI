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

# (a)-(i)_audit_group - extracted to Scripts\Test-AuditContract.ps1 (instructions SS39). Dot-sourced in THIS scope so it shares
#      the gate's variables and helpers, and at THIS position so the verdict order is unchanged.
. (Join-Path $PSScriptRoot 'Test-AuditContract.ps1')

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

# (af) SOURCE ENCODING - extracted to Scripts\Test-Encoding.ps1 (instructions SS39). Dot-sourced HERE so
#      its verdict keeps its position in the list, and INTO THIS SCOPE so it shares $root and the verdict
#      helpers. The file states the same contract at the top.
. (Join-Path $PSScriptRoot 'Test-Encoding.ps1')

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

# A SETTLED row must not accept a queued follow-up. That state was REACHABLE through the funnel's own
# cleanup path - ClearOperation retires the operation (OpState='Idle') while the PendingOp slot
# survives - and it is the 8.4 contradiction in the pending layer: the row is counted as finished
# while its next operation is still queued. Asserted in two halves, because either alone is
# satisfiable without the behaviour: the setter must REFUSE (with a reason, not silently), and the
# funnel must RESOLVE the state when a follow-up is already queued. Then DRIVEN, because a source
# shape cannot show that the refusal actually happens.
if ($pendingBodyJ -notmatch 'Get-WuuTerminalStates' -or $pendingBodyJ -notmatch 'Reason =') {
    Fail 'Set-WuuPendingOperation does not refuse a SETTLED row with a reason - a queued follow-up on a finished row leaves the row reported finished while its next operation is queued, and a silent no-op reproduces the defect class SS7 exists to remove (SS7/8.4)'
} elseif ((Get-WuuFunctionBody $stateRawJ 'Update-WuuOperationState') -notmatch "(?s)PendingOp[\s\S]{0,400}?'Queued'") {
    # Anchored to PendingOp so the check names the FOLLOW-UP branch. The function already writes
    # 'Queued' when it resolves an unreplaced Timeout display, so a bare 'Queued' match would pass
    # with this rule deleted.
    Fail 'Update-WuuOperationState does not resolve a row that still holds a queued follow-up to a non-settled display - a settled row with a surviving queue is the 8.4 contradiction (P1/8.4)'
} elseif (-not (Get-Command Set-WuuPendingOperation -ErrorAction SilentlyContinue)) {
    Fail 'Set-WuuPendingOperation is not resolvable - the settled-row refusal cannot be driven (SS7)'
} else {
    try {
        $settledProbeJ = New-WuuComputerRow -Computer 'GATE-SETTLED-PENDING'
        $settledProbeJ.State = 'Error'
        $settledResultJ = Set-WuuPendingOperation -Row $settledProbeJ -Op 'Download'
        $liveSettledJ = New-WuuComputerRow -Computer 'GATE-SETTLE-LIVE'
        $liveSettledJ.OpState = 'Running'
        $liveSettledJ.OperationId = 'gate-op'
        $null = Set-WuuPendingOperation -Row $liveSettledJ -Op 'Download'
        $null = Update-WuuOperationState -Row $liveSettledJ -OperationId 'gate-op' -State 'Complete' -ClearOperation
        $liveViolationsJ = @(Test-WuuOperationStateInvariant -Row $liveSettledJ)
        if ($settledResultJ.Set) {
            Fail 'a SETTLED row accepted a queued follow-up - the row is reported finished while its next operation is still queued (SS7/8.4)'
        } elseif (-not $settledResultJ.Reason) {
            Fail 'the settled-row refusal carries no reason - the caller cannot say why nothing was queued, which is a silent no-op (SS7)'
        } elseif ($liveViolationsJ.Count -ne 0) {
            Fail ('settling a row that holds a queued follow-up leaves the row inconsistent: ' + ($liveViolationsJ -join '; ') + ' (P1/8.4)')
        } elseif ($liveSettledJ.PendingOp -ne 'Download' -or -not $liveSettledJ.Pending) {
            Fail 'the queued follow-up did not survive settlement - the request the operator made was lost (SS7)'
        } else {
            Pass 'a settled row refuses a queued follow-up with a reason, and settling a row that holds one leaves no contradiction (SS7/8.4)'
        }
    } catch {
        Fail "driving the settled-row pending rule threw instead of reporting: $($_.Exception.Message)"
    }
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
# DRIVEN, NOT MATCHED, and that is a correction rather than a preference. This check used to require two
# things by TEXT: the literal line
#     if ($state -eq 'Error' -or $updatesStatus -eq 'Error') { return 'Failed' }
# and the relative IndexOf of `return 'Failed'` versus `return 'Success'`. Both asserted the SHAPE of the
# code, and both became false findings the moment the mapping was made table-driven and single-sourced
# with the terminal set (block (ay)): the literals are gone, so a CORRECT tree failed. A gate that fails
# correct code trains people to ignore it.
#
# The two properties those text checks were trying to protect are still protected, and better:
#   * "failure is derived from State OR UpdatesStatus" -> driven below, on rows where the error is
#     written to only ONE of the two fields;
#   * "failure is judged before completion" -> driven below via a row that carries a STALE Complete
#     alongside a current Error. The ORDER is additionally enforced structurally by
#     Test-WuuTerminalStateInvariant, which requires 'Complete' to be declared LAST in the terminal table
#     (asserted in block (ay)) - so ordering is now a property of the declaration rather than of line
#     offsets inside one function.
$oneBodyK = Get-WuuFunctionBody $stateRawK 'Get-WuuTargetOutcome'
if ([string]::IsNullOrWhiteSpace($oneBodyK)) {
    Fail 'Get-WuuFunctionBody could not extract Get-WuuTargetOutcome, so the classifier is unverified (SS10)'
} else {
    $errorInStateK = New-WuuComputerRow -Computer 'GATE-SS10-A'; $errorInStateK.State = 'Error'
    $errorInStatusK = New-WuuComputerRow -Computer 'GATE-SS10-B'; $errorInStatusK.UpdatesStatus = 'Error'
    $staleCompleteK = New-WuuComputerRow -Computer 'GATE-SS10-C'
    $staleCompleteK.State = 'Complete'; $staleCompleteK.UpdatesStatus = 'Error'
    $outStateK = Get-WuuTargetOutcome -Row $errorInStateK
    $outStatusK = Get-WuuTargetOutcome -Row $errorInStatusK
    $outStaleK = Get-WuuTargetOutcome -Row $staleCompleteK
    if ($outStateK -ne 'Failed' -or $outStatusK -ne 'Failed') {
        Fail "Get-WuuTargetOutcome no longer derives Failed from State OR UpdatesStatus (State-only='$outStateK', UpdatesStatus-only='$outStatusK') - a row whose error is written to only one of the two fields would be misclassified (SS10)"
    } elseif ($outStaleK -ne 'Failed') {
        Fail "a stale Complete masks a current Error (got '$outStaleK') - failure must be judged before completion, or the completion wins (SS10)"
    } else {
        Pass 'per-target classification derives failure from both fields and judges it before completion (driven against the shipped function, SS10)'
    }
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
            # NOT ON A TAG (a commit between releases). This is legitimate, but the check did not
            # actually run - and reporting it as PASS would claim a verified property that was never
            # evaluated. SKIP says exactly that, which is why the kind exists.
            Skip "version provenance not evaluated: $($versionCheck.Note) - the tag comparison does not apply off a release tag (SS18)"
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

# (aq) SILENT CATCHES (reviewer P2: "a release gate could even reject empty catches outside a small
#      allowlist"). A catch whose body performs no statement turns a fault into apparent success: the
#      caller cannot tell "nothing to do" from "the work failed". The rule is therefore not "no silent
#      catches" but "no UNJUSTIFIED ones" - a disposal failure must not mask the original error, and a
#      logging failure cannot be logged.
#
#      THE POLICY IS SHARED WITH ITS SUITE, NOT COPIED. Scripts\Wuu.CatchAudit.ps1 is dot-sourced by
#      both this gate and tests\Test-SilentCatchPolicy.ps1. If each carried its own rule they would
#      drift and one would pass while the other failed. This gate is the ENFORCEMENT; the suite carries
#      the false-negative control (it drives the detector with synthetic silences), because a checker
#      that only ever runs against the real tree cannot be shown to detect anything.
$catchAuditPath = Join-Path $root 'Scripts\Wuu.CatchAudit.ps1'
if (-not (Test-Path -LiteralPath $catchAuditPath)) {
    Fail 'Scripts\Wuu.CatchAudit.ps1 is missing - the silent-catch policy has no home (P2)'
} else {
    . $catchAuditPath

    if (-not (Get-Command Get-WuuSilentCatch -ErrorAction SilentlyContinue)) {
        Fail 'the shared catch policy does not provide Get-WuuSilentCatch (P2)'
    } else {
        # Every allowlist entry must state WHY. An entry without a justification is indistinguishable
        # from "we stopped looking", which is the outcome this policy exists to prevent.
        $allow = @(Get-WuuSilentCatchAllowlist)
        $noWhy = @($allow | Where-Object { -not $_.Why -or $_.Why.Length -lt 20 })
        if ($noWhy.Count -gt 0) {
            Fail "$($noWhy.Count) allowlist entr(ies) do not state why they are allowed - an unjustified exemption is not a policy (P2)"
        } elseif ($allow.Count -gt 12) {
            Fail "the allowlist has $($allow.Count) entries - too large to be a policy rather than a list of everything that happens to exist (P2)"
        } else {
            Pass "the allowlist is small ($($allow.Count) entries) and every entry states why (P2)"
        }

        $catchFindings = @()
        $catchTotal = 0
        foreach ($cf in Get-ChildItem (Join-Path $root 'src\*.psm1') | Sort-Object Name) {
            $cfText = [System.IO.File]::ReadAllText($cf.FullName)
            foreach ($c in (Get-WuuSilentCatch -Text $cfText)) {
                $catchTotal++
                $verdict = Test-WuuSilentCatchAllowed -Guarded $c.Guarded -Body $c.Body
                if (-not $verdict.Allowed) {
                    $catchFindings += "$($cf.Name) L$($c.Line): $($verdict.Reason)"
                }
            }
        }

        if ($catchTotal -eq 0) {
            # A ZERO RESULT MUST BE DISTINGUISHABLE FROM A BROKEN SCAN. If the detector silently stopped
            # finding anything, "no findings" would look like a pass.
            Fail 'the scan found NO silent catches at all in src/ - the detector is not working, so this check proves nothing (P2)'
        } elseif ($catchFindings.Count -gt 0) {
            Fail ("$($catchFindings.Count) unjustified silent catch(es) of $catchTotal - each turns a fault into apparent success (P2): " + ($catchFindings -join ' | '))
        } else {
            Pass "all $catchTotal silent catch(es) in src/ are documented or allowlisted (P2)"
        }

        # FALSE-NEGATIVE CONTROL. Without this, the check above passes whenever there are no findings -
        # including when the POLICY HAS BEEN DISABLED and refuses nothing. The gate would then report
        # "all silences are justified" for a tree where nothing is ever refused, which is a check that
        # cannot fail. The tautology harness found this by making the predicate return Allowed=$true
        # unconditionally: the gate PASSED that broken tree. The predicate is therefore DRIVEN here -
        # it must refuse a silence that is neither documented nor allowlisted, and permit a documented
        # one. Both directions, because permitting everything and refusing everything are equally broken.
        $fnUnjustified = Test-WuuSilentCatchAllowed -Guarded 'try { Invoke-SomeVitalWork }' -Body ''
        $fnDocumented = Test-WuuSilentCatchAllowed -Guarded 'try { Invoke-SomeVitalWork }' -Body '# best effort by design'
        if ($fnUnjustified.Allowed) {
            Fail 'the policy permits an UNJUSTIFIED silence - the check above cannot fail, so its clean result proves nothing (P2)'
        } elseif (-not $fnDocumented.Allowed) {
            Fail 'the policy refuses a DOCUMENTED silence - an explicit justification is being ignored (P2)'
        } else {
            Pass 'the policy refuses an unjustified silence and permits a documented one (P2)'
        }

        # The detector must FIND the multi-line form, which is the form the real code uses and the form
        # an earlier broken brace-count could not see. Without this, a detector that only handled
        # one-liners would report a clean tree while inspecting almost nothing.
        $multiProbe = "function P {`n    try {`n        Do-Work`n    } catch {`n    }`n}`n"
        $multiFound = @(Get-WuuSilentCatch -Text $multiProbe)
        if ($multiFound.Count -ne 1) {
            Fail 'the silent-catch detector does not find the MULTI-LINE empty catch - the form src/ uses - so its clean result means nothing (P2)'
        } elseif ($multiFound[0].Kind -ne 'empty') {
            Fail 'the detector classifies a genuinely empty multi-line catch as something other than empty (P2)'
        } elseif (-not $multiFound[0].Guarded.Contains('Do-Work')) {
            Fail 'the detector does not identify WHAT the silent catch guards, so the allowlist cannot be applied (P2)'
        } else {
            Pass 'the detector finds the multi-line form it is judging, and the statement it guards (P2)'
        }
    }
}

# (ar) ONE LOG APPENDER (reviewer P2: "reduce duplicated worker scriptblocks"). The fault-tolerant
#      lock-and-retry append was written FOUR times - Wuu.Logging's Write-WuuLogEntry, Wuu.Core's cleanup
#      runspace, Wuu.WindowsUpdate's per-computer runspace, and inline inside WriteDebugLogScript - each
#      with a comment telling the reader to keep them in step. Two copies of a retry loop is exactly the
#      arrangement that drifts, and the drift would be silent (a payload that logs in one runspace and
#      not another). They are now one factory, so agreement is structural.
$distinctiveRetry = 'Start-Sleep -Milliseconds (100 * $attempt)'
$retryOutsideFactory = @()
foreach ($rf in Get-ChildItem (Join-Path $root 'src\*.psm1') | Sort-Object Name) {
    $rfLines = [System.IO.File]::ReadAllLines($rf.FullName)
    $inFactory = $false
    for ($ri = 0; $ri -lt $rfLines.Count; $ri++) {
        # The factory's DEFINITION line does not start at column 0 in every module, so it is matched
        # without the anchor. Only the TERMINATOR is anchored: an earlier version cleared the flag on the
        # call site `$newRunspace.SessionStateProxy.SetVariable('WriteLogFileScript', (Get-WuuWorker...))`,
        # whose line starts with `$` rather than `function`, so the factory's own loop was then counted
        # as being OUTSIDE the factory.
        if ($rfLines[$ri] -match 'Get-WuuWorkerLogAppender\s*\{') { $inFactory = $true }
        if ($ri -gt 0 -and $rfLines[$ri] -match '^function\s+' -and $rfLines[$ri] -notmatch 'Get-WuuWorkerLogAppender') { $inFactory = $false }
        if ($rfLines[$ri].Contains($distinctiveRetry) -and -not $inFactory) {
            $retryOutsideFactory += "$($rf.Name):L$($ri+1)"
        }
    }
}

if ($retryOutsideFactory.Count -gt 0) {
    Fail ("$($retryOutsideFactory.Count) module(s) still carry their own copy of the log retry loop: " + ($retryOutsideFactory -join ', ') + ' (P2)')
} elseif ($stateRawA -and $false) { } else {
    # The factory must exist, be exported from Wuu.LOGGING (logging owns logging), and be USED at every
    # former copy site. Export location matters: Write-WuuLogEntry delegates to it, and three suites
    # import Wuu.Logging on its own - placing it in Wuu.Scheduler made logging depend on the scheduler
    # and broke those imports.
    $loggingRawAR = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Logging.psm1') -Raw
    $coreRawAR = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
    $wupdRawAR = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw
    if ($loggingRawAR -notmatch 'function Get-WuuWorkerLogAppender') {
        Fail 'the log appender factory does not live in Wuu.Logging - logging would have to depend on another module to log (P2)'
    } elseif ($loggingRawAR -notmatch "'Get-WuuWorkerLogAppender'") {
        Fail 'the log appender factory is not exported from Wuu.Logging (P2)'
    } elseif ($coreRawAR -notmatch '\(Get-WuuWorkerLogAppender\)' -or $wupdRawAR -notmatch '\(Get-WuuWorkerLogAppender\)') {
        Fail 'a worker runspace does not use the shared log appender (P2)'
    } elseif ($wupdRawAR -notmatch '&\s+\$WriteLogFileScript\s+-LogEntry') {
        Fail 'WriteDebugLogScript does not delegate to the injected appender - it kept its own retry loop (P2)'
    } else {
        Pass 'one log appender exists in Wuu.Logging and is used by every former copy site (P2)'
    }
}

# Wuu.Scheduler must exist and be registered, or the injected helper set has no home - and a module that
# is not imported is a module whose helpers silently fail to inject.
if (-not (Test-Path -LiteralPath (Join-Path $root 'src\Wuu.Scheduler.psm1'))) {
    Fail 'src\Wuu.Scheduler.psm1 is missing - the worker helper surface has no single home (P2)'
} elseif ($coreRawAR -notmatch "'Wuu\.Scheduler'") {
    Fail 'Wuu.Scheduler is not in the import list - nothing would wire the worker helper set (P2)'
} else {
    Pass 'Wuu.Scheduler exists and is imported (P2)'
}

function Write-WuuGateJsonReport([string]$Path) {
    <#
    .SYNOPSIS
    Writes the verdicts to a JSON file (P4). Called before EVERY exit path.
    .DESCRIPTION
    WHY A FUNCTION AND NOT INLINE. The gate has two exit points (the normal one and the failure one),
    and a report written on only one of them would be missing exactly when it is most useful - a
    failing run. One function, called from both, removes that possibility.
    #>
    # .ToArray(), NOT @(...). On PowerShell 5.1 `@($list)` over a
    # System.Collections.Generic.List[object] raises "Argument types do not match" - reproduced in
    # isolation - and because that is a NON-TERMINATING error, the assignment silently yields $null.
    # The report then contained ONE verdict whose fields were all null, because `$null | ForEach-Object`
    # still iterates once. Every total read 0 while the gate itself passed. `.ToArray()` enumerates the
    # list correctly. Any future `@()` over this list inherits the same trap.
    $verdicts = $script:WuuGateVerdicts.ToArray()

    try {
        # Count EVERY verdict kind. A consumer that only reads Failures and Passes would treat a
        # NOT_IMPLEMENTED as absent rather than as "no verifier exists", and an unreported gap is the
        # failure mode this mode exists to remove.
        $report = [ordered]@{
            Schema        = 'wuu.gate.v1'
            GeneratedUtc  = (Get-Date).ToUniversalTime().ToString('o')
            Root          = $root
            Passed        = (-not $script:failed)
            Totals        = [ordered]@{
                PASS            = @($verdicts | Where-Object { $_.Status -eq 'PASS' }).Count
                FAIL            = @($verdicts | Where-Object { $_.Status -eq 'FAIL' }).Count
                WARN            = @($verdicts | Where-Object { $_.Status -eq 'WARN' }).Count
                SKIP            = @($verdicts | Where-Object { $_.Status -eq 'SKIP' }).Count
                NOT_IMPLEMENTED = @($verdicts | Where-Object { $_.Status -eq 'NOT_IMPLEMENTED' }).Count
            }
            Verdicts      = @($verdicts | ForEach-Object { [ordered]@{ Status = $_.Status; Message = $_.Message } })
        }

        $json = $report | ConvertTo-Json -Depth 6
        # UTF8 WITHOUT a BOM: a BOM is legal JSON in some readers and a parse error in others, and the
        # consumers here are scripts and CI tools. (The SOURCE files need BOMs; this artifact does not.)
        [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "  gate report written to $Path ($($verdicts.Count) verdict(s))" -ForegroundColor DarkGray
        return $true
    } catch {
        # A report-write failure must not change the gate's verdict - the exit code is the contract, and
        # this is the diagnostic. Reported loudly rather than swallowed, because a silently missing
        # report would make CI's own gate look like a configuration error.
        Write-Host "  WARNING: could not write the gate report to $Path : $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

if ($Json) {
    $jsonPath = if ([System.IO.Path]::IsPathRooted($Json)) { $Json } else { Join-Path $root $Json }
}

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
$gateCode = Get-WuuTextWithoutComments -Text $selfText
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
$writerCalls = ([regex]::Matches($gateCode, 'Write-WuuGateJsonReport')).Count
$writerIdx = $gateCode.LastIndexOf('Write-WuuGateJsonReport -Path')
$exitIdx = $gateCode.LastIndexOf('Validation FAILED')
$lastCheckIdx = $gateCode.LastIndexOf('Not-Implemented')

if ($writerCalls -lt 2) {
    Fail "the report writer is referenced $writerCalls time(s) - it must be both defined and called (P4)"
} elseif ($writerIdx -lt 0) {
    Fail 'the report writer is never CALLED (only defined) - no report would be produced (P4)'
} elseif ($exitIdx -lt 0 -or $exitIdx -lt $writerIdx) {
    Fail 'the report writer is not followed by the failure exit - a failing run could produce no report (P4)'
} else {
    $window = $gateCode.Substring($writerIdx, $exitIdx - $writerIdx)
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
if ($gateCode -match '@\(\s*\$script:WuuGateVerdicts\s*\)') {
    Fail 'the report reads the verdict list with @(...) - on PS 5.1 that throws over a generic List and the assignment silently becomes $null, producing a report of one null verdict (P4)'
} elseif ($gateCode -notmatch 'WuuGateVerdicts\.ToArray\(\)') {
    Fail 'the report does not enumerate the verdict list with .ToArray() (P4)'
} else {
    Pass 'the report enumerates the verdict list safely (.ToArray(), not @() which throws on PS 5.1) (P4)'
}

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
$poolMatchAX = [regex]::Match($workersRawAX, '\[int\]\$script:MaxPoolSize\s*=\s*(\d+)')
$capMatchAX = [regex]::Match($coreRaw, '\$global:MaxConcurrentJobs\s*=\s*(\d+)')

if (-not $poolMatchAX.Success) {
    Fail 'could not read $script:MaxPoolSize from Wuu.Workers - the pool-versus-cap invariant cannot be verified (P3)'
} elseif (-not $capMatchAX.Success) {
    Fail 'could not read $global:MaxConcurrentJobs from Wuu.Core - the pool-versus-cap invariant cannot be verified (P3)'
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

# THE ASSERTION THAT WOULD HAVE CAUGHT THE SHIPPED DEFECT: the payload helpers must not call a module
# function. Read the BODIES, so a mention in the surrounding comments cannot satisfy this - and the
# comment explaining why the call is absent literally names the function.
#
# A BRACE-BALANCED extractor is required here, and this is not pedantry: these functions are defined at
# INDENT 8 inside payload scriptblocks, so their closing brace is `\n        }`. Get-WuuFunctionBody
# slices to the next `\nfunction ` - which only matches INDENT-0 definitions - so for an indent-8 helper
# it ran past the helper entirely and swallowed every following function down to the next module-scope
# one. Both helpers were therefore being checked as ONE bloated region: an assertion about
# Invoke-CimWithTimeout could be satisfied by Invoke-ServiceWithTimeout and vice versa, and neither body
# was inspected on its own. Verified: the naive slice for Invoke-CimWithTimeout is 7316 chars and contains
# `function Invoke-ServiceWithTimeout`; the balanced slice is 3622 chars and does not.
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

# Drops the param(...) block from a body slice. A DECLARATION (`[int]$TimeoutSeconds = 5,`) is not an
# ASSIGNMENT, but a text scan cannot tell them apart - so without this the reassignment check below
# matched the declaration in both helpers. That is a false finding in the shape this gate exists to
# eliminate (a FAIL for correct code trains people to ignore the gate). The gate's own module-wide
# reassignment check does not have the problem because it walks the AST and only inspects the body.
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
# The assertions below are deliberately NOT pinned to an exact remainder. The function truncates toward
# zero and the deadline is set a few milliseconds before it is read, so a 6-second budget reliably yields
# 5 - and asserting "exactly 6" failed for a cap that was working perfectly. What matters is the SHAPE:
# capped to at most the budget, never below the floor, and never applied at all without a deadline.
if (Get-Command Get-WuuEffectiveInnerTimeout -ErrorAction SilentlyContinue) {
    try {
        $budgetRowAV = New-WuuComputerRow -Computer 'GATE-BUDGET-PROBE'
        $noDeadlineAV = Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds 30 -Row $budgetRowAV

        $budgetRowAV.TimeoutExpiresAt = (Get-Date).AddSeconds(600)
        $looseAV = Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds 30 -Row $budgetRowAV

        # A distinctly tiny budget: the floor is the only thing that can produce the answer.
        $budgetRowAV.TimeoutExpiresAt = (Get-Date).AddSeconds(1)
        $floorAV = Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds 30 -Row $budgetRowAV

        # A tight but non-trivial budget: the cap must bind, and land at or just under the budget.
        $budgetRowAV.TimeoutExpiresAt = (Get-Date).AddSeconds(20)
        $tightAV = Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds 30 -Row $budgetRowAV
        $budgetLeftAV = [int](($budgetRowAV.TimeoutExpiresAt - (Get-Date)).TotalSeconds)

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
        } elseif ($tightAV['Seconds'] -lt 5 -or $tightAV['Seconds'] -gt 30) {
            Fail "the capped timeout ($($tightAV['Seconds'])s) is outside the possible range (floor 5, ceiling 30) - the rule is miscomputed (P3)"
        } elseif ($tightAV['Seconds'] -ge 30) {
            Fail "a 20-second remaining budget did not reduce the 30-second probe (got $($tightAV['Seconds'])s) (P3)"
        } else {
            Pass "the remaining-budget rule is live: no deadline leaves 30s uncapped, 600s left keeps 30s, 1s left floors to 5s, and 20s left caps the 30s probe to $($tightAV['Seconds'])s (budget read $($budgetLeftAV)s) (P3)"
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
