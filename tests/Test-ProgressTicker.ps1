#Requires -Version 5.1
<#
.SYNOPSIS Live progress ticker: derivation, formatting, and the invariant that it cannot mutate state.
.DESCRIPTION
The ticker is a single line rendered while operations are in flight:

    [Active: N | Queued: N | Succeeded: N | Failed: N | Elapsed: mm:ss]

It is OBSERVATIONAL. The instruction set is explicit that it must never decide whether an operation
is dead, timed out or should be cancelled - the outer deadline is the sole authority for that (SS21).
A display that could end an operation would be a second, invisible state machine, so the most
important assertion here is that calling the ticker leaves the store byte-for-byte unchanged.

WHAT IS PROVEN
  1. counts and elapsed are derived from the store's own fields - Running/Queued for activity, the
     terminal-state declaration for outcomes, OperationId/OpStartedAt for elapsed;
  2. a timeout is counted inside Failed, and the breakdown survives in the object;
  3. elapsed formatting: mm:ss, h:mm:ss past an hour, truncation rather than rounding, '--:--' when
     nothing is being timed, and never a negative duration under clock skew;
  4. the idle line is $null, so a caller cannot repaint over a prompt with "nothing happening";
  5. THE TICKER CANNOT MUTATE STATE - asserted on the AST of every shipped ticker function, so a
     future edit that adds a cancellation, a retry or a scheduler call fails here.

No test sleeps to observe a clock: -Now is injected, which is also why the parameter exists.
Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-ProgressTicker.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$fail = $false
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail = $true }
function Pass($m) { Write-Host "PASS: $m" -ForegroundColor Green }
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -eq "$Expected") { Pass $Name }
    else { Fail ("{0} - expected '{1}', got '{2}'" -f $Name, $Expected, $Actual) }
}

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force -DisableNameChecking
Import-WuuModules -WuuRoot $root
$global:EnableDebugLogging = $false

# ---------------------------------------------------------------------------------------
# 0. The state vocabulary the ticker reads, straight from its single declaration
# ---------------------------------------------------------------------------------------
$outcomeMap = Get-WuuTerminalOutcomeMap
if ($outcomeMap.Count -lt 3) { Fail "the terminal-state declaration looks wrong ($($outcomeMap.Count) entries)" }
else { Pass "terminal-state declaration read ($($outcomeMap.Count) states)" }
Assert-Equal ([string]$outcomeMap['Complete']) 'Success' 'Complete is declared as Success'
Assert-Equal ([string]$outcomeMap['Error']) 'Failed' 'Error is declared as Failed'
Assert-Equal ([string]$outcomeMap['Timeout']) 'TimedOut' 'Timeout is declared as TimedOut'

function New-TickStore {
    $store = New-WuuStateStore
    return $store
}
function Add-TickRow($store, $computer, $state, $opState, $opId, $started) {
    $row = New-WuuComputerRow -Computer $computer
    if ($null -ne $state) { $row.State = $state }
    if ($null -ne $opState) { $row.OpState = $opState }
    if ($null -ne $opId) { $row.OperationId = $opId }
    if ($null -ne $started) { $row.OpStartedAt = $started }
    Add-WuuComputerRow -Store $store -Row $row | Out-Null
}

$t0 = [datetime]'2026-10-03T10:00:00'

# ---------------------------------------------------------------------------------------
# 1. Nothing in flight -> nothing to say
# ---------------------------------------------------------------------------------------
$emptyStore = New-TickStore
Add-TickRow $emptyStore 'IDLE01' 'Queued' 'Idle' $null $null
$p = Get-WuuOperationProgress -Store $emptyStore -Now $t0
Assert-Equal $p.Active 0 'an idle row is not active'
Assert-Equal $p.Queued 0 'an idle row (OpState=Idle) is not queued either - OpState, not State, is the activity field'
Assert-Equal $p.Total 1 'the row is still counted in the fleet total'
Assert-Equal (Format-WuuProgressTicker -Progress $p) '' 'idle: the ticker renders nothing (so a prompt is never repainted)'
$line = Format-WuuProgressTicker -Progress $p
if ($null -ne $line) { Fail "the idle ticker returned '$line' instead of `$null" } else { Pass 'idle: the ticker returns $null rather than an empty string' }

# ---------------------------------------------------------------------------------------
# 2. One active, and the elapsed clock
# ---------------------------------------------------------------------------------------
$oneStore = New-TickStore
Add-TickRow $oneStore 'SRV01' 'Installing' 'Running' 'op-111111111111' $t0.AddMinutes(-3).AddSeconds(-7)
$p = Get-WuuOperationProgress -Store $oneStore -Now $t0
Assert-Equal $p.Active 1 'Running counts as Active'
Assert-Equal $p.Queued 0 'Running is not also counted as Queued'
Assert-Equal (Format-WuuProgressTicker -Progress $p) '[Active: 1 | Queued: 0 | Succeeded: 0 | Failed: 0 | Elapsed: 03:07]' 'one active operation renders the documented line with elapsed from OpStartedAt'

# ---------------------------------------------------------------------------------------
# 3. Multiple, mixed - and Running vs Queued kept apart
# ---------------------------------------------------------------------------------------
$mixStore = New-TickStore
Add-TickRow $mixStore 'SRV01' 'Downloading' 'Running' 'op-aaaaaaaaaaaa' $t0.AddMinutes(-2)
Add-TickRow $mixStore 'SRV02' 'Checking'    'Running' 'op-bbbbbbbbbbbb' $t0.AddMinutes(-2)
Add-TickRow $mixStore 'SRV03' 'Queued'      'Queued'  'op-cccccccccccc' $null
Add-TickRow $mixStore 'SRV04' 'Complete'    'Idle'    'op-dddddddddddd' $t0.AddMinutes(-9)
Add-TickRow $mixStore 'SRV05' 'Error'       'Idle'    'op-eeeeeeeeeeee' $t0.AddMinutes(-9)
Add-TickRow $mixStore 'SRV06' 'Timeout'     'Idle'    'op-ffffffffffff' $t0.AddMinutes(-9)
$p = Get-WuuOperationProgress -Store $mixStore -Now $t0
Assert-Equal $p.Active 2 'two Running rows count as Active'
Assert-Equal $p.Queued 1 'a Queued OpState counts as Queued, not Active'
Assert-Equal $p.Succeeded 1 'Complete counts as Succeeded (from the outcome map)'
Assert-Equal $p.Failed 1 'Error counts as Failed'
Assert-Equal $p.TimedOut 1 'Timeout counts as TimedOut, and is reported separately in the object'
Assert-Equal (Format-WuuProgressTicker -Progress $p) '[Active: 2 | Queued: 1 | Succeeded: 1 | Failed: 2 | Elapsed: 09:00]' 'a timeout is folded into Failed in the LINE, and elapsed is measured from the EARLIEST start'

# ---------------------------------------------------------------------------------------
# 4. Elapsed formatting
# ---------------------------------------------------------------------------------------
Assert-Equal (Format-WuuElapsed -Elapsed ([timespan]::FromSeconds(7))) '00:07' 'elapsed under a minute is mm:ss'
Assert-Equal (Format-WuuElapsed -Elapsed ([timespan]::FromSeconds(127))) '02:07' 'elapsed minutes are zero-padded'
Assert-Equal (Format-WuuElapsed -Elapsed ([timespan]::FromSeconds(3661))) '1:01:01' 'elapsed past an hour widens to h:mm:ss'
Assert-Equal (Format-WuuElapsed -Elapsed $null) '--:--' 'a missing span renders --:--, NOT 00:00 - "not timed" is not "just started"'
Assert-Equal (Format-WuuElapsed -Elapsed ([timespan]::FromSeconds(-5))) '00:00' 'a negative span clamps to 00:00 rather than rendering a negative time'
Assert-Equal (Format-WuuElapsed -Elapsed ([timespan]::FromSeconds(59.9))) '00:59' 'the span is TRUNCATED, not rounded, so the line never shows a time later than the clock'

# ---------------------------------------------------------------------------------------
# 5. Clock skew: a start in the future must not go negative
# ---------------------------------------------------------------------------------------
$skewStore = New-TickStore
Add-TickRow $skewStore 'SRV09' 'Installing' 'Running' 'op-999999999999' $t0.AddMinutes(5)
$p = Get-WuuOperationProgress -Store $skewStore -Now $t0
Assert-Equal (Format-WuuElapsed -Elapsed $p.Elapsed) '00:00' 'a start later than now clamps to 00:00 (clock skew cannot produce a negative elapsed)'

# ---------------------------------------------------------------------------------------
# 6. Malformed and missing fields fail SAFE (no throw, no invented state)
# ---------------------------------------------------------------------------------------
$oddStore = New-TickStore
Add-TickRow $oddStore 'SRV10' 'SomethingNew' 'Running' 'op-101010101010' $t0.AddMinutes(-1)
Add-TickRow $oddStore 'SRV11' $null $null $null $null
$threw = $null
try { $p = Get-WuuOperationProgress -Store $oddStore -Now $t0 } catch { $threw = $_ }
if ($threw) { Fail "an unknown State value threw: $($threw.Exception.Message)" }
else {
    Assert-Equal $p.Active 1 'an unknown State still counts as Active when it is Running'
    Assert-Equal $p.Succeeded 0 'an unknown State is not counted as a success'
    Assert-Equal $p.Failed 0 'an unknown State is not counted as a failure'
    Assert-Equal $p.Total 2 'a row with no fields at all is still counted in the total'
    Pass 'unknown and absent fields are ignored rather than invented'
}

# A null store must not throw (it is the ordinary result of not having initialised presentation).
$threw = $null
try { $p = Get-WuuOperationProgress -Store $null -Now $t0 } catch { $threw = $_ }
if ($threw) { Fail "a null store threw: $($threw.Exception.Message)" }
else { Assert-Equal $p.Active 0 'a null store reports zeroes rather than throwing' }

# ---------------------------------------------------------------------------------------
# 7. THE INVARIANT: the ticker cannot change operation state (SS20)
# ---------------------------------------------------------------------------------------
# A snapshot before and after, field by field. This is the assertion the instruction set cares
# about most: "prove the ticker cannot change operation state".
$snapStore = New-TickStore
Add-TickRow $snapStore 'SRV01' 'Installing' 'Running' 'op-abcdef123456' $t0.AddMinutes(-4)
Add-TickRow $snapStore 'SRV02' 'Queued'     'Queued'  'op-fedcba654321' $null
Add-TickRow $snapStore 'SRV03' 'Error'      'Idle'    'op-000000000000' $t0.AddMinutes(-8)

function Get-StoreFingerprint($store) {
    $parts = @()
    foreach ($r in @(Get-WuuComputerRow -Store $store)) {
        $vals = @()
        foreach ($prop in ($r.PSObject.Properties.Name | Sort-Object)) {
            $vals += ('{0}={1}' -f $prop, [string]$r.$prop)
        }
        $parts += ($vals -join ';')
    }
    return ($parts -join '|')
}

$before = Get-StoreFingerprint $snapStore
for ($i = 0; $i -lt 3; $i++) {
    [void](Get-WuuOperationProgress -Store $snapStore -Now $t0)
    [void](Format-WuuProgressTicker -Progress (Get-WuuOperationProgress -Store $snapStore -Now $t0))
    [void](Write-WuuProgressTicker -Store $snapStore -Now $t0)
}
$after = Get-StoreFingerprint $snapStore
if ($before -ceq $after) { Pass 'rendering the ticker three times leaves every row field unchanged (observational only)' }
else { Fail 'the ticker mutated state - a display that can end an operation is a second state machine' }

# ...and structurally, because the behavioural check above can only catch what the current fixtures
# trigger. Asserted on the AST of the shipped functions so a future edit that adds a call to a
# state setter, the scheduler, or a cancellation fails here even if no fixture reaches it.
$presPath = Join-Path $root 'src\Wuu.Presentation.psm1'
$presAst = [System.Management.Automation.Language.Parser]::ParseFile($presPath, [ref]$null, [ref]$null)
$tickerFns = @('Get-WuuOperationProgress', 'Format-WuuElapsed', 'Format-WuuProgressTicker', 'Write-WuuProgressTicker')
$forbidden = @(
    'Update-WuuOperationState', 'Set-WuuOperationState', 'Set-WuuSetting', 'Set-WuuPendingOperation',
    'Start-UpdateCheckJob', 'Start-Job', 'Invoke-Command', 'New-PSSession', 'Start-Process',
    'Invoke-WuuRemoteTask', 'Remove-WuuComputerRow', 'Add-WuuComputerRow', 'Restart-WuuWorker',
    'Start-PendingUpdateCheck', 'Invoke-Expression'
)
foreach ($fnName in $tickerFns) {
    $fnAst = @($presAst.FindAll({
                param($x) ($x -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($x.Name -ceq $fnName)
            }, $true))
    if ($fnAst.Count -ne 1) { Fail "expected exactly 1 definition of $fnName, found $($fnAst.Count)"; continue }
    $called = @($fnAst[0].FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
    $present = @($forbidden | Where-Object { $called -contains $_ })
    if ($present.Count) { Fail "$fnName calls a state-changing or work-starting command: $($present -join ', ')" }
    else { Pass "$fnName invokes nothing that can change state or start work (checked on the AST)" }
}

# A row read is permitted and expected; a row WRITE is not. Stated separately so the failure names
# the hazard rather than only reporting an unrecognised command.
$writeCalls = @()
foreach ($fnName in $tickerFns) {
    $fnAst = @($presAst.FindAll({
                param($x) ($x -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($x.Name -ceq $fnName)
            }, $true))
    if (-not $fnAst.Count) { continue }
    foreach ($ast in $fnAst) {
        foreach ($cmd in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            if ($cmd.GetCommandName() -in @('Add-WuuComputerRow', 'Remove-WuuComputerRow', 'Update-WuuComputerRow')) {
                $writeCalls += "$fnName -> $($cmd.GetCommandName())"
            }
        }
    }
}
if ($writeCalls.Count) { Fail "a ticker function writes rows: $($writeCalls -join '; ')" }
else { Pass 'no ticker function adds, removes or updates a row' }

# ---------------------------------------------------------------------------------------
# 8. The loop renders it where no prompt can be disturbed
# ---------------------------------------------------------------------------------------
$consoleRaw = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Console.psm1'))
if ($consoleRaw -notmatch 'Write-WuuProgressTicker') {
    Fail 'the console loop never renders the ticker, so the feature would be unreachable'
} else { Pass 'the console loop renders the progress ticker' }

# The hook must sit immediately after the drain and BEFORE input is read. Anywhere else is either
# dead (after the action returns) or dangerous (while a prompt is open).
$loopBody = [regex]::Match($consoleRaw, '(?s)while \(-not \$Actions\.Quit\) \{(.*?)\n    \}').Groups[1].Value
$drainAt = $loopBody.IndexOf('& $DrainScheduler')
$tickAt = $loopBody.IndexOf('Write-WuuProgressTicker')
$readAt = $loopBody.IndexOf('Read-WuuAnswer')
if ($drainAt -lt 0 -or $tickAt -lt 0) { Fail 'could not locate the drain and the ticker hook in the loop body' }
elseif ($tickAt -lt $drainAt) { Fail 'the ticker is rendered BEFORE the drain, so it would report a fleet the scheduler has not ticked yet' }
elseif ($readAt -ge 0 -and $tickAt -gt $readAt) { Fail 'the ticker is rendered AFTER the input read, where it could repaint over a prompt' }
else { Pass 'the ticker is rendered after the scheduler drain and before input is read' }

Write-Host ''
if ($fail) { Write-Host 'SOME CHECKS FAILED' -ForegroundColor Red; exit 1 }
Write-Host 'ALL PASS' -ForegroundColor Cyan
exit 0
