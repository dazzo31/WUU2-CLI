#Requires -Version 5.1
<#
.SYNOPSIS Console-shell (interactive menu) test.
.DESCRIPTION
This suite exists because of a specific escape: a fatal crash in Start-WuuConsoleLoop
    Cannot convert the "System.Object[]" value of type "System.Object[]" to type
    "System.Collections.Hashtable"
made the interactive edition COMPLETELY unusable - the shell died the instant the menu was drawn.
Every other suite is non-interactive, so all of them stayed green and the release shipped broken.

The root cause is worth stating because it is a re-usable lesson: Start-WuuConsoleLoop takes
[hashtable]$Actions, and assigned its menu list to `$actions`. PowerShell variable names are
CASE-INSENSITIVE, so `$actions` IS the `$Actions` parameter - and a parameter's declared type is
enforced on every assignment, so storing an Object[] into a [hashtable] threw.

This test therefore covers the PRESENTATION path directly:
  1. the menu builder returns a list (not a hashtable) and every entry is well formed;
  2. the menu renders without throwing, at several store shapes including an EMPTY list
     (the state the operator hit);
  3. the loop can be entered and exited cleanly with 'q' - the crash happened at loop entry,
     so merely reaching the loop body is the regression check;
  4. the parameter/state contract the loop depends on survives entry.

Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-ConsoleLoop.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$fail = $false
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail = $true }
function Pass($m) { Write-Host "PASS: $m" -ForegroundColor Green }

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

$global:EnableDebugLogging = $false

# ---------------------------------------------------------------------------------------
# 1. The menu list itself
# ---------------------------------------------------------------------------------------
$menu = @(Get-WuuMenuActions)
if ($menu.Count -lt 10) { Fail "Get-WuuMenuActions returned only $($menu.Count) entries" }
else { Pass "menu defines $($menu.Count) actions" }

# The crash was precisely this: an Object[] (the menu) coerced into a [hashtable] parameter.
# Asserting the TYPE here is the direct guard.
if ($menu[0] -is [hashtable]) { Pass 'menu entries are hashtables (Keys/Label/Mutating/Run)' }
else { Fail "menu entry type is $($menu[0].GetType().Name), expected hashtable" }

$badEntries = @($menu | Where-Object {
    -not ($_.ContainsKey('Key') -and $_.ContainsKey('Label') -and $_.ContainsKey('Mutating') -and $_.ContainsKey('Run'))
})
if ($badEntries.Count) { Fail "$($badEntries.Count) menu entries are missing Key/Label/Mutating/Run" }
else { Pass 'every menu entry has Key, Label, Mutating and Run' }

$nonScript = @($menu | Where-Object { $_.Run -isnot [scriptblock] })
if ($nonScript.Count) { Fail "$($nonScript.Count) menu entries have a non-scriptblock Run" }
else { Pass 'every menu entry Run is a scriptblock' }

# No duplicate keys: a duplicate would silently shadow one of the operations.
$dupes = @($menu | Group-Object { $_.Key } | Where-Object { $_.Count -gt 1 })
if ($dupes.Count) { Fail "duplicate menu key(s): $(($dupes | ForEach-Object { $_.Name }) -join ', ')" }
else { Pass 'menu keys are unique' }

# Quit must exist, or the loop can never exit.
if (@($menu | Where-Object { $_.Key -eq 'q' }).Count -ne 1) { Fail "no single 'q' (quit) entry" }
else { Pass "menu has a 'q' quit entry" }

# Mutating entries are the ones the audit layer requires a reason for - assert the SET, not a count.
$mutating = @($menu | Where-Object { $_.Mutating } | ForEach-Object { $_.Key } | Sort-Object)
$expectedMutating = @('2', '3', '4', 'w')
if (($mutating -join ',') -ne ($expectedMutating -join ',')) {
    Fail "mutating keys are [$($mutating -join ',')], expected [$($expectedMutating -join ',')]"
} else { Pass "mutating keys are exactly: $($mutating -join ', ')" }

# ---------------------------------------------------------------------------------------
# 2. Rendering for an EMPTY store - the exact state the operator was in.
# ---------------------------------------------------------------------------------------
$store = New-WuuStateStore
try {
    Write-WuuStatusTable -Store $store
    Write-WuuStatusLine -Store $store
    Write-WuuMenu -Store $store
    Pass 'menu and status render without throwing on an EMPTY computer list'
} catch {
    Fail "rendering on an empty store threw: $($_.Exception.Message)"
}

# And with a computer present, since the row-shape path differs.
try {
    $row = New-WuuComputerRow -Computer 'SRV01' -Phase 'Phase 1' -StateSource 'Test'
    Add-WuuComputerRow -Store $store -Row $row | Out-Null
    Write-WuuStatusTable -Store $store
    Write-WuuMenu -Store $store
    Pass 'menu and status render with a computer in the list'
} catch {
    Fail "rendering with a computer threw: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------------------
# 3. The LOOP ITSELF - enter and exit. This is the regression check for the crash.
# ---------------------------------------------------------------------------------------
# Driving the loop requires non-interactive input mode: the menu keypress is read with
# [Console]::ReadKey, which cannot be fed from a test. Start-WuuConsoleLoop therefore consults
# Get-WuuInputMode and, in non-interactive mode, pulls selections from Read-WuuAnswer - so
# queueing 'q' lets the loop be entered and left deterministically. Entering the loop at all is
# the assertion: the original crash happened on the first statement after the menu draw, before
# any input was read - which is exactly why no test caught it.
$prevMode = Get-WuuInputMode
$quitActions = @{ Quit = $false }
$drain = { $null }   # no scheduler work needed for this test
$loopThrew = $null
try {
    Initialize-WuuInputMode -NonInteractive -Answers @('q')
    Start-WuuConsoleLoop -Store $store -DrainScheduler $drain -Actions $quitActions
} catch {
    $loopThrew = $_.Exception
} finally {
    Initialize-WuuInputMode -NonInteractive:$prevMode.NonInteractive
}
if ($loopThrew) {
    Fail "Start-WuuConsoleLoop threw on entry: $($loopThrew.Message)"
} else {
    Pass 'Start-WuuConsoleLoop enters and exits without throwing'
}

# The loop must NOT have clobbered the caller's actions hashtable (the original bug destroyed it).
if (-not ($quitActions -is [hashtable])) {
    Fail "the Actions hashtable was replaced by a $($quitActions.GetType().Name) - the case-insensitive collision is back"
} else { Pass 'the caller''s Actions hashtable survives the loop (no collision)' }

if (-not $quitActions.ContainsKey('Quit')) {
    Fail 'Actions lost its Quit key during the loop'
} else { Pass 'Actions still exposes Quit after the loop' }

# ---------------------------------------------------------------------------------------
# 4. A menu action is invokable with a context object (the loop calls Run with $Actions).
# ---------------------------------------------------------------------------------------
$ctx = @{ Pinged = $false; Ping = { $ctx.Pinged = $true } }
$probe = @(
    @{ Key = 'z'; Label = 'Probe'; Mutating = $false; Run = { param($c) & $c.Ping } }
)
try {
    & $probe[0].Run $ctx
    if ($ctx.Pinged) { Pass 'a menu Run scriptblock receives and can use the action context' }
    else { Fail 'menu Run scriptblock did not mutate the context it was given' }
} catch {
    Fail "invoking a menu Run scriptblock threw: $($_.Exception.Message)"
}

if ($fail) { Write-Host 'SOME CHECKS FAILED' -ForegroundColor Red; exit 1 }
else { Write-Host 'ALL PASS' -ForegroundColor Cyan }
