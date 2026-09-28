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

if ($failed) { Write-Host "`nValidation FAILED" -ForegroundColor Red; exit 1 }
else { Write-Host "`nAll validation checks passed" -ForegroundColor Cyan }
