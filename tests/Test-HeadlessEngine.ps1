#Requires -Version 5.1
<#
.SYNOPSIS  Phase 1 acceptance test: the WUU engine loads and runs with NO WPF dependency.
.DESCRIPTION  This is the decisive Phase 1 gate. It proves the payload side of WUU is
presentation-free by asserting, in a fresh process:

  1. A WPF assembly is NOT loaded to begin with (baseline sanity).
  2. Importing the real module set via the real path (Import-WuuModules) does NOT load
     PresentationFramework/PresentationCore/WindowsBase. If any payload-facing module
     reached for WPF at import time, this fails.
  3. The real injected worker helper scriptblocks - SafeUpdateListViewItemScript,
     SetComputerStateScript, SetComputerTimeoutScript - extracted straight out of
     New-ComputerRunspace's source - execute inside a REAL isolated runspace and mutate
     the store, with no WPF loaded.
  4. A row can be added/read/updated entirely headlessly.

  Note the scope: the GUI *shell* (Start-WuuApplication) still loads XAML - that is removed
  when ui/ is deleted (Phase 1 final step). This test covers the engine/payload layer, which
  is what worker runspaces actually execute.
Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-HeadlessEngine.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$fail = $false
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail = $true }
function Pass($m) { Write-Host "PASS: $m" -ForegroundColor Green }
function Get-WpfLoaded {
    # System.Windows.Forms is included here because the CLI startup used to Add-Type it (and
    # Microsoft.VisualBasic) with no live caller - a hard startup failure waiting for a host that
    # lacks Forms. PresentationFramework was the only one asserted, so removing the two unused
    # entries was unverifiable by test. Microsoft.VisualBasic cannot be checked the same way (it is
    # a base-class-library assembly that may legitimately be loaded), so the ADD-TYPE list is what
    # guards it, via the validator.
    @([AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -in @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Windows.Forms') } |
        ForEach-Object { $_.GetName().Name })
}

# --- 1. Baseline: no WPF in this process ------------------------------------------------
$before = Get-WpfLoaded
if ($before.Count) { Fail ("WPF already loaded before we started: " + ($before -join ', ')) }
else { Pass 'baseline: no WPF assembly loaded in a fresh -NoProfile process' }

# --- 2. Real import path must not pull in WPF -------------------------------------------
Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

$afterImport = Get-WpfLoaded
if ($afterImport.Count) { Fail ("Import-WuuModules loaded WPF: " + ($afterImport -join ', ')) }
else { Pass 'Import-WuuModules loads the engine with NO WPF assembly' }

# stateStore was created at module scope by Wuu.Core; New-WuuStateStore must be available
if (-not (Get-Command New-WuuStateStore -ErrorAction SilentlyContinue)) { Fail 'New-WuuStateStore not exported' }
else { Pass 'Wuu.State exports the store factory' }

# --- 3. Extract the REAL injected helper scriptblocks from New-ComputerRunspace source ---
# Uses PowerShell's own tokenizer, NOT hand-rolled brace counting. Lesson learned: a naive
# brace/quote scanner treats an apostrophe inside a COMMENT ("the store's own table") as a
# string opener and then swallows the real closing brace, yielding a 19KB "scriptblock" that
# fails to parse. The tokenizer already knows comments and strings, so brace depth over the
# token stream is reliable. Each extracted block is then parse-checked, so a bad extraction
# fails loudly rather than testing a truncated scriptblock.
# Testing the shipping source (not a copy) means this fails if a helper regresses to WPF.
$wupdPath = Join-Path $root 'src\Wuu.WindowsUpdate.psm1'
$raw = Get-Content -LiteralPath $wupdPath -Raw
$errs = $null; $tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($wupdPath, [ref]$tokens, [ref]$errs)
if ($errs.Count) { Fail "Wuu.WindowsUpdate.psm1 has parse errors: $($errs[0].Message)" }

$tkErrs = $null
$allTokens = [System.Management.Automation.PSParser]::Tokenize($raw, [ref]$tkErrs)

function Get-ScriptBlockLiteralFromTokens {
    # Given the token index of a StringLiteral whose text is '<Name>Script', walk forward to
    # the '{' of the scriptblock literal and return its INNER TEXT (without the outer braces).
    #
    # CRITICAL: production uses `[scriptblock]::Create({ ... }.ToString())`, and ScriptBlock
    # .ToString() returns the BODY text without the enclosing braces. Feeding the braces into
    # [scriptblock]::Create produces a scriptblock whose body is a NESTED scriptblock literal,
    # so `& $helper` merely emits the helper's source text instead of running it - the helper
    # silently no-ops. (Observed: the worker printed the scriptblock source as output.)
    # Returning inner text matches production exactly.
    param([object[]]$Tokens, [int]$StringTokenIndex)
    $i = $StringTokenIndex + 1
    $openTok = $null
    while ($i -lt $Tokens.Count -and $i -lt ($StringTokenIndex + 12)) {
        if ($Tokens[$i].Type -eq 'GroupStart' -and ($Tokens[$i].Content -eq '{' -or $Tokens[$i].Content -eq '@{')) { $openTok = $Tokens[$i]; break }
        $i++
    }
    if (-not $openTok) { return $null }
    # NOTE: a hashtable literal opens with the token '@{' (GroupStart), not '{'. Counting only
    # GroupStart '{' makes '@{...}' look unbalanced: its '}' decrements a depth that was never
    # incremented, so the block ends early and fails to parse. Count both forms.
    $isOpen = { param($t) $t.Type -eq 'GroupStart' -and ($t.Content -eq '{' -or $t.Content -eq '@{') }
    $depth = 0
    for ($j = $i; $j -lt $Tokens.Count; $j++) {
        $t = $Tokens[$j]
        if (& $isOpen $t) { $depth++ }
        elseif ($t.Type -eq 'GroupEnd' -and $t.Content -eq '}') {
            $depth--
            if ($depth -eq 0) {
                $innerStart = $openTok.Start + $openTok.Length
                $innerLen = $t.Start - $innerStart
                return $raw.Substring($innerStart, $innerLen)
            }
        }
    }
    return $null
}

$helpers = @{}
for ($ti = 0; $ti -lt $allTokens.Count; $ti++) {
    $t = $allTokens[$ti]
    if ($t.Type -ne 'String' -or $t.Content -notmatch '^([A-Za-z]+Script)$') { continue }
    $name = $Matches[1]
    $lit = Get-ScriptBlockLiteralFromTokens -Tokens $allTokens -StringTokenIndex $ti
    if (-not $lit) { continue }
    $blkErrs = $null; $blkToks = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($lit, [ref]$blkToks, [ref]$blkErrs)
    if ($blkErrs.Count) { Fail "$name extracted but does not parse: $($blkErrs[0].Message)"; continue }
    $helpers[$name] = $lit
}

foreach ($name in 'SafeUpdateListViewItemScript', 'SetComputerStateScript', 'SetComputerTimeoutScript') {
    if (-not $helpers.ContainsKey($name)) { Fail "$name not extracted from source" }
}
if (-not $fail) { Pass "extracted real injected helpers from source via tokenizer ($($helpers.Count) total)" }

# Assert the payload-facing helpers are free of WPF/ListView coupling.
# Strip comments first: an explanatory "Was: ... [Brushes]::LightYellow" note is not coupling,
# and matching it would be a false positive (this bit us once).
foreach ($kv in $helpers.GetEnumerator()) {
    $code = ($kv.Value -split "`r?`n" | ForEach-Object { $_ -replace '#.*$', '' }) -join "`n"
    if ($code -match 'Dispatcher|Brushes\]::|ItemContainerGenerator|clientObservable|uiHash\.Listview') {
        Fail "$($kv.Key) still references WPF/ListView in CODE"
    }
}
if (-not $fail) { Pass 'no injected helper references Dispatcher/Brushes/ListView (comments excluded)' }

# --- 4. Run those real helpers in a REAL isolated runspace (New-ComputerRunspace topology)
$store = New-WuuStateStore
$row = New-WuuComputerRow -Computer 'SRV01'
Add-WuuComputerRow -Store $store -Row $row | Out-Null

$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$iss.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
$rs = [runspacefactory]::CreateRunspace($iss)
$rs.ApartmentState = 'STA'
$rs.Open()
# Exactly what New-ComputerRunspace injects for the payload side
$rs.SessionStateProxy.SetVariable('stateStore', $store)
$rs.SessionStateProxy.SetVariable('Computer', $row)
foreach ($kv in $helpers.GetEnumerator()) {
    $rs.SessionStateProxy.SetVariable($kv.Key, [scriptblock]::Create($kv.Value))
}

$script = @'
& $SafeUpdateListViewItemScript -ComputerName 'SRV01' -Properties @{ Status = 'Testing WMI connectivity...' }
& $SetComputerStateScript -Computer $Computer -State 'Downloading' -StatusDetail '(3 updates)'
& $SetComputerTimeoutScript -Computer $Computer -Phase 'Update Search' -TimeoutSec 30 -Detail 'search hung'
'helpers-completed'
'@
$ps = [powershell]::Create().AddScript($script)
$ps.Runspace = $rs
$h = $ps.BeginInvoke()
$out = @($ps.EndInvoke($h))
$workErrs = @($ps.Streams.Error)
$ps.Dispose(); $rs.Close(); $rs.Dispose()

if ($workErrs.Count) { Fail ("real helper in isolated runspace threw: " + $workErrs[0].Exception.Message) }
elseif (@($out) -notcontains 'helpers-completed') { Fail ("helpers did not complete; worker output: " + (@($out) -join ' | ')) }
else { Pass 'all 3 real injected helpers executed in an isolated runspace' }

if ($row.Color -ne 'Timeout') { Fail "SetComputerTimeoutScript did not set Color='Timeout' (got '$($row.Color)')" }
else { Pass "SetComputerTimeoutScript set Color='Timeout' (was [Brushes]::LightYellow)" }

if ($row.UpdatesStatus -ne 'Timeout' -or $row.State -ne 'Timeout') { Fail "timeout state not applied (UpdatesStatus='$($row.UpdatesStatus)' State='$($row.State)')" }
else { Pass 'timeout state applied to the live row' }

if ($row.Status -notmatch 'Timeout during Update Search after 30s') { Fail "status text wrong: '$($row.Status)'" }
else { Pass 'timeout status text correct' }

if ($store.Revision -lt 4) { Fail "Touch() not called by the helpers (Revision=$($store.Revision))" }
else { Pass "helpers bumped Revision to $($store.Revision) (redraw signal works)" }

# --- 5. Still no WPF after all of that -------------------------------------------------
$afterAll = Get-WpfLoaded
if ($afterAll.Count) { Fail ("WPF was loaded during the run: " + ($afterAll -join ', ')) }
else { Pass 'NO WPF assembly loaded after running the full helper set' }

if ($fail) { Write-Host 'SOME CHECKS FAILED' -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS' -ForegroundColor Cyan }
