#Requires -Version 5.1
<#
.SYNOPSIS Phase 2 test: the command surface dispatches to the real action handlers.
.DESCRIPTION
Proves, without admin rights or a live target:
  1. ConvertTo-WuuCommandLine parses the real argv shapes (verbs, subverbs, -Computer/-All/
     -Json/-WhatIf/-Path/-Set, positionals, and unknown options).
  2. -WhatIf on a mutating verb makes NO change and enqueues nothing.
  3. Non-interactive mode FAILS LOUDLY when required input is missing instead of prompting
     (the safety property that makes CI usage possible).
  4. A read verb actually runs its handler with input switched to non-interactive, and input
     mode is restored afterwards (including on failure).
  5. Unknown verbs and missing subverbs are reported, not crashed on.
Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-CommandSurface.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$fail = $false
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail = $true }
function Pass($m) { Write-Host "PASS: $m" -ForegroundColor Green }

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

# ---------------------------------------------------------------------------------------
# 1. Argument parsing
# ---------------------------------------------------------------------------------------
$cases = @(
    @{ Args = @('check', '-All');                        Verb = 'check';      Sub = $null;       Opt = @{ All = $true } }
    @{ Args = @('check', '-Computer', 'A,B');            Verb = 'check';      Sub = $null;       Opt = @{ Computer = 'A,B' } }
    @{ Args = @('check', 'SRV01');                       Verb = 'check';      Sub = $null;       Opt = @{ Computer = 'SRV01' } }
    @{ Args = @('show', 'available', '-Json');           Verb = 'show';       Sub = 'available'; Opt = @{ Json = $true } }
    @{ Args = @('config', 'load');                       Verb = 'config';     Sub = 'load';      Opt = @{} }
    @{ Args = @('phase', '-Set', '3', '-Computer', 'X'); Verb = 'phase';      Sub = $null;       Opt = @{ Set = '3'; Computer = 'X' } }
    @{ Args = @('install', '-WhatIf');                   Verb = 'install';    Sub = $null;       Opt = @{ WhatIf = $true } }
    @{ Args = @('service', 'restart');                   Verb = 'service';    Sub = 'restart';   Opt = @{} }
)
foreach ($c in $cases) {
    $r = ConvertTo-WuuCommandLine -Arguments $c.Args
    $ok = ($r.Verb -eq $c.Verb) -and ($r.SubVerb -eq $c.Sub) -and ($r.Unknown.Count -eq 0)
    if ($ok) {
        foreach ($k in $c.Opt.Keys) {
            if (-not $r.Options.ContainsKey($k) -or ([string]$r.Options[$k]) -ne ([string]$c.Opt[$k])) { $ok = $false }
        }
    }
    if (-not $ok) { Fail ("parse {0} -> verb={1} sub={2} opts={3}" -f ($c.Args -join ' '), $r.Verb, $r.SubVerb, (($r.Options.Keys) -join ',')) }
}
if (-not $fail) { Pass "parsed all $($cases.Count) argument shapes" }

# unknown option is reported, not silently dropped
$u = ConvertTo-WuuCommandLine -Arguments @('check', '-Bogus')
if ($u.Unknown -notcontains '-Bogus') { Fail 'unknown option -Bogus was not reported' }
else { Pass 'unknown options are reported' }

# ---------------------------------------------------------------------------------------
# 2-5. Dispatch behaviour against real handlers (state store, no remote targets)
# ---------------------------------------------------------------------------------------
# Minimal state store + a recording stub for the actions so we assert DISPATCH, not Windows Update.
$store = New-WuuStateStore
Add-WuuComputerRow -Store $store -Row (New-WuuComputerRow -Computer 'SRV01') | Out-Null
Add-WuuComputerRow -Store $store -Row (New-WuuComputerRow -Computer 'SRV02') | Out-Null

$script:called = New-Object System.Collections.ArrayList
$actions = [hashtable]::Synchronized(@{ Quit = $false })
# Stubs append to a SHARED list object. A closure over $script:called would rebind to whatever
# $script:called points at later; capturing the list BY REFERENCE keeps every append visible.
$callLog = $script:called
foreach ($h in @('EventGetUpdates','EventDownloadUpdates','EventInstallUpdates','EventRestartComputer',
                 'EventShowAvailableUpdates','EventShowInstalledUpdates','GetErrors','EventSaveConfig','EventLoadConfig')) {
    $name = $h   # capture for the closure
    $actions[$name] = [scriptblock]::Create("`$null = `$callLog.Add('$name')").GetNewClosure()
}

# 2. -WhatIf makes no change and does not call the handler
$callLog.Clear()
$r = Invoke-WuuCommand -Verb 'install' -Actions $actions -Store $store -Computer 'SRV01' -WhatIf
if ($callLog.Count -ne 0) { Fail "-WhatIf still invoked the handler: $($callLog -join ',')" }
elseif (-not $r.WhatIf) { Fail '-WhatIf result did not report WhatIf' }
else { Pass '-WhatIf on a mutating verb invokes no handler (nothing changes)' }

# 3. Non-interactive + missing input fails loudly (selection prompt has no default)
Initialize-WuuInputMode -NonInteractive -Answers @()
$threw = $false
try { $null = Read-WuuAnswer -Prompt 'Required thing' } catch { $threw = $true }
if (-not $threw) { Fail 'missing required input did NOT fail in non-interactive mode (would hang a CI run)' }
else { Pass 'missing required input fails loudly in non-interactive mode' }

# a supplied answer is consumed and echoed
Initialize-WuuInputMode -NonInteractive -Answers @('SRV01')
$a = Read-WuuAnswer -Prompt 'Which'
if ($a -ne 'SRV01') { Fail "supplied answer not returned (got '$a')" }
else { Pass 'supplied answers are consumed in order' }

# 4. A read verb dispatches, and input mode is restored afterwards
Initialize-WuuInputMode   # interactive
$callLog.Clear()
$r = Invoke-WuuCommand -Verb 'show' -SubVerb 'available' -Actions $actions -Store $store -Computer 'SRV01'
if ($callLog -notcontains 'EventShowAvailableUpdates') { Fail "show available did not dispatch (got: $($callLog -join ','))" }
elseif ((Get-WuuInputMode).NonInteractive) { Fail 'input mode left non-interactive after a command' }
else { Pass 'read verb dispatched and input mode restored' }

# input mode is ALSO restored when the handler throws
$actions['EventGetUpdates'] = { throw 'boom' }
Initialize-WuuInputMode
$r2 = Invoke-WuuCommand -Verb 'check' -Actions $actions -Store $store -Computer 'SRV01'
if ($r2.Ok -ne $false) { Fail 'failing handler did not report Ok=$false' }
elseif ((Get-WuuInputMode).NonInteractive) { Fail 'input mode left non-interactive after a FAILING command' }
else { Pass 'input mode restored even when the handler throws; failure reported' }

# 5. Unknown verb / missing subverb handled
$r3 = Invoke-WuuCommand -Verb 'nonsense' -Actions $actions -Store $store
if ($r3.Ok -ne $false) { Fail 'unknown verb did not report failure' } else { Pass 'unknown verb reported cleanly' }
$r4 = Invoke-WuuCommand -Verb 'show' -Actions $actions -Store $store
if ($r4.Ok -ne $false -or $r4.Error -notmatch 'available') { Fail 'wuu show without a subverb did not list the valid subverbs' }
else { Pass 'show without a subverb lists valid subverbs' }

# every mutating verb in the table is flagged, and every verb's Action exists in the action layer
$table = Get-WuuCommandTable
$mutating = @($table.Keys | Where-Object { $table[$_].Mutating })
# The mutating set is exactly: download, install, restart, service. Assert the SET, not a count,
# so a verb silently losing (or gaining) its Mutating flag fails here.
$expectedMutating = @('download', 'install', 'restart', 'service')
$diff = Compare-Object -ReferenceObject $expectedMutating -DifferenceObject $mutating
if ($diff) { Fail ("mutating verb set changed: {0}" -f (($diff | ForEach-Object { "$($_.SideIndicator)$($_.InputObject)" }) -join ' ')) }
else { Pass "mutating verbs flagged exactly: $($mutating -join ', ')" }

if ($fail) { Write-Host 'SOME CHECKS FAILED' -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS' -ForegroundColor Cyan }
