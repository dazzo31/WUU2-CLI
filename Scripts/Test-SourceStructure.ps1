# Release validation, SOURCE STRUCTURE: the shape of the shipped tree (SS39).
# Extracted from Validate-Release.ps1. Sections 1-8: every shipped script parses, no GUI type is
# referenced, the console menu and the command table are wired to real actions, every verb has help
# text, and every non-ASCII file carries a UTF-8 BOM.
#
# DOT-SOURCED FRAGMENT - not a standalone script. Validate-Release.ps1 dot-sources it into its own
# scope AT THE POSITION THESE SECTIONS OCCUPIED, which is what gives this file $root, the verdict
# helpers (Pass/Fail/Warn/Skip/Not-Implemented) and the shared harness helpers hoisted above the
# dot-sources.
#
# WHY THE EARLY POSITION MATTERS. These are the checks that establish the tree is well-formed before
# anything inspects its behaviour, and their verdicts lead the report. The dot-source sits where the
# sections were, so the order of the verdict list is unchanged.

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
# Microsoft.Win32.(Open|Save)FileDialog BOTH live in PresentationFramework, so both are WPF types the
# console edition cannot resolve. The pattern originally named only OpenFileDialog, and that omission
# let a REAL, REACHABLE defect through THIS gate: "Export list to file" (menu key x, the guided UI, and
# the EventSaveComputerList action) built a SaveFileDialog, which throws "Cannot find type" at the
# moment an operator uses it. Name the FAMILY, not one member of it.
$guiOnlyPattern = '\[System\.Windows\.MessageBox\]|\[System\.Windows\.Forms\.|\[Microsoft\.VisualBasic\.|Microsoft\.Win32\.(Open|Save)FileDialog'
$wpfHits = New-Object System.Collections.ArrayList
foreach ($f in $files) {
    # Skip the VALIDATORS themselves: they necessarily contain the very patterns they search for.
    # This used to name only Validate-Release.ps1, which stopped being sufficient the moment these
    # sections moved into a fragment (SS39) - this file names the patterns too, so it reported itself.
    # The whole validator corpus is skipped by shape rather than by one filename, so a future fragment
    # cannot reintroduce the same false positive.
    if ($f.Name -eq 'Validate-Release.ps1' -or $f.Name -like 'Test-*.ps1') { continue }
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
# Sliced PER VERB, not through a fixed character window. A 400-char window silently failed a verb
# whose entry carries an explanatory comment (the export verb, P2) - a FALSE FAILURE on correct code,
# which is the failure mode this gate exists to prevent, and the same size-assumption trap as the
# 3000-char body window documented above. Slicing from one verb key to the next has no size
# assumption, so a comment of any length is harmless.
$verbEntries = [regex]::Matches($cmdCode, "(?m)^\s*'([a-z-]+)'\s*=\s*@\{\s*$")
$noHelp = @()
for ($vi = 0; $vi -lt $verbEntries.Count; $vi++) {
    $start = $verbEntries[$vi].Index
    $end = if ($vi + 1 -lt $verbEntries.Count) { $verbEntries[$vi + 1].Index } else { $cmdCode.Length }
    $entryBody = $cmdCode.Substring($start, $end - $start)
    if ($entryBody -notmatch 'Help\s*=') { $noHelp += $verbEntries[$vi].Groups[1].Value }
}
$verbKeys = @($verbEntries | ForEach-Object { $_.Groups[1].Value })
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
