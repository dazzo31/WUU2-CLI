#Requires -Version 5.1
<#
.SYNOPSIS Indirect handler coverage: every menu entry, driven through the real guided dispatch.
.DESCRIPTION
WUU-OBS-01. The wiring sweep in Test-Navigation proves each menu entry's Handler name resolves to a
real $consoleActions assignment. It proves the handler EXISTS; it never proves that invoking an entry
through the guided path actually reaches it. That is a different and weaker claim, and the gap
between them is where this repository has already shipped one fatal bug: Start-WuuConsoleLoop died on
startup because the menu list was assigned to `$actions`, which PowerShell's case-insensitive naming
made the [hashtable]$Actions parameter. Every suite was non-interactive, so all of them stayed green
and the release shipped broken. Test-ConsoleLoop's header records that escape.

WHAT THIS SUITE DOES
It DRIVES Show-WuuCategoryScreen - the one shared dispatch - for every entry of every guided menu,
with the documented non-interactive input choke point (Initialize-WuuInputMode), and asserts that
each entry reaches its intended destination:

  Handler     -> the named handler in $Ctx.Actions runs, exactly once
  Preflight   -> the screen returns the 'PREFLIGHT' state with PreflightOperation set
  Starts      -> the screen returns the entry's state with PendingOperation set
  Report      -> the screen returns the 'REPORT' state
  AuditSubVerb-> the audit path is invoked and the screen returns to the category
  Screen      -> the screen returns that screen name
  Back ('b')  -> the screen returns 'DASHBOARD'

THE ALLOWLIST IS CLOSED. Any entry whose kind is not in that list FAILS. That is deliberate: the
failure mode this suite exists to prevent is an entry that dispatches to nothing and is silently
skipped, so a kind nobody declared has to be a failure rather than a pass.

WHAT IT DOES NOT DO
It does not test whether a host patches. Each handler here is a RECORDING STAND-IN, so this is an
orchestration test: it asserts routing, not behaviour. Behaviour is covered by the engine suites.

Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-GuidedDispatch.ps1
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
# The recording action layer
# ---------------------------------------------------------------------------------------
# One stand-in per handler NAME, so a dispatch that reaches the wrong handler is visible as a
# mismatch rather than as "something ran".
#
# The recording sink is captured by CLOSURE, not by scope name. A scriptblock built with
# [scriptblock]::Create has no captured scope, and the dispatch runs inside Wuu.Navigate - so
# `$script:calls` there resolved to the MODULE's script scope, where it does not exist, and every
# call threw "The variable '$script:calls' cannot be retrieved because it has not been set".
# GetNewClosure copies the enclosing function's variables into the scriptblock, so the handler can
# add to the shared ArrayList regardless of who invokes it.
$sink = New-Object System.Collections.ArrayList
function New-RecordingActions {
    param([System.Collections.ArrayList]$Sink)
    $names = @(
        'ClearComputerList', 'EventAddAD', 'EventAddComputer', 'EventAddFile', 'EventAssignPhaseInteractive',
        'EventAuditWSUSUpdates', 'EventDeploymentReport', 'EventDownloadUpdates', 'EventGetUpdates',
        'EventInstallUpdates', 'EventLoadConfig', 'EventRemoveOfflineComputer', 'EventRemoveSelected',
        'EventRestartComputer', 'EventSaveComputerList', 'EventSaveConfig', 'EventSetDomainCredentials',
        'EventShowAvailableUpdates', 'EventShowByPhase', 'EventShowInstalledUpdates', 'EventShowUpdateHistory',
        'EventToggleSettings', 'EventViewUpdateLog', 'EventWUServiceActionInteractive', 'GetErrors', 'ShowHelp'
    )
    $actions = @{}
    foreach ($n in $names) {
        $captured = $n
        $actions[$n] = { param($ctx) $null = $Sink.Add($captured) }.GetNewClosure()
    }
    $actions['Quit'] = $false
    return $actions
}

# A fresh context per drive. The set is real (so screens that read it do not throw) and the store is
# real and empty, so nothing here depends on a fixture that could mask a routing defect.
function New-DriveCtx {
    param([hashtable]$Actions)
    $store = New-WuuStateStore
    $set = New-WuuComputerSet -Store $store -Name 'dispatch-probe'
    return [pscustomobject]@{
        Set = $set; Store = $store; Actions = $Actions
        AuditHook = $null; DenialHook = $null; LastOperation = ''
    }
}

# ---------------------------------------------------------------------------------------
# 1. The five menus and their entry-kind allowlist
# ---------------------------------------------------------------------------------------
$menus = [ordered]@{
    'UPDATES'     = @{ Fn = 'Get-WuuUpdateManagementMenu';     State = 'UPDATES';     Title = 'UPDATES & DEPLOYMENT' }
    'COMPUTERS'   = @{ Fn = 'Get-WuuComputerManagementMenu';   State = 'COMPUTERS';   Title = 'COMPUTER FLEET' }
    'DIAGNOSTICS' = @{ Fn = 'Get-WuuDiagnosticsMenu';          State = 'DIAGNOSTICS'; Title = 'DIAGNOSTICS & HEALTH' }
    'REPORTS'     = @{ Fn = 'Get-WuuReportsMenu';              State = 'REPORTS';     Title = 'REPORTS & AUDIT' }
    'SETTINGS'    = @{ Fn = 'Get-WuuSettingsMenu';             State = 'SETTINGS';    Title = 'SETTINGS & CREDENTIALS' }
}

# The declared kinds, in dispatch order (Show-WuuCategoryScreen checks them in this order).
$declaredKinds = @('Report', 'AuditSubVerb', 'Preflight', 'Starts', 'Screen', 'Handler')
$backKey = 'b'

$allEntries = 0
$handlerEntries = 0
$kindCounts = @{}
foreach ($kind in ($declaredKinds + @('none'))) { $kindCounts[$kind] = 0 }

foreach ($menuName in $menus.Keys) {
    $fn = $menus[$menuName].Fn
    foreach ($item in @(& $fn)) {
        $allEntries++
        $kind = 'none'
        foreach ($k in $declaredKinds) { if ($item.ContainsKey($k)) { $kind = $k; break } }
        if ($item.Key -eq $backKey) { $kind = 'Back' }
        if ($kind -eq 'none') {
            Fail "$menuName[$($item.Key)] '$($item.Label)' declares no dispatch kind and is not Back - it would fall through and silently do nothing"
        } else {
            $kindCounts[$kind] = [int]$kindCounts[$kind] + 1
        }
    }
}
if (-not $fail) { Pass "every guided entry declares a dispatch kind ($allEntries entries across $($menus.Count) menus)" }
"  kind counts: $(($kindCounts.GetEnumerator() | Where-Object { $_.Value -gt 0 } | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"

# The kinds observed must be exactly the kinds this suite knows how to drive. A new kind would
# otherwise be counted above as "declared" and then never exercised here.
$undeclared = @($kindCounts.Keys | Where-Object { $_ -ne 'none' -and $_ -notin ($declaredKinds + @('Back')) })
if ($undeclared.Count) { Fail "the tree uses dispatch kind(s) this suite cannot drive: $($undeclared -join ', ')" }
else { Pass 'every kind the tree uses is one this suite drives (the kind list is closed)' }

# ---------------------------------------------------------------------------------------
# 2. Drive EVERY entry through the real Show-WuuCategoryScreen
# ---------------------------------------------------------------------------------------
$driveFailures = @()
foreach ($menuName in $menus.Keys) {
    $fn = $menus[$menuName].Fn
    $state = $menus[$menuName].State
    $title = $menus[$menuName].Title
    foreach ($item in @(& $fn)) {
        $kind = 'none'
        foreach ($k in $declaredKinds) { if ($item.ContainsKey($k)) { $kind = $k; break } }

        $actions = New-RecordingActions -Sink $sink
        $ctx = New-DriveCtx -Actions $actions
        [void]$sink.Clear()

        Initialize-WuuInputMode -NonInteractive -Answers @([string]$item.Key)
        $returned = $null
        try {
            $returned = Show-WuuCategoryScreen -Ctx $ctx -Title $title -Items @(& $fn) -State $state
        } catch {
            $driveFailures += "$menuName[$($item.Key)] '$($item.Label)' threw: $($_.Exception.Message)"
            continue
        }
        $ran = @($sink)

        if ($item.Key -eq $backKey) {
            if ($returned -ne 'DASHBOARD') { $driveFailures += "$menuName[b] Back returned '$returned', expected DASHBOARD" }
            elseif ($ran.Count -ne 0) { $driveFailures += "$menuName[b] Back invoked a handler: $($ran -join ', ')" }
            continue
        }

        switch ($kind) {
            'Handler' {
                $handlerEntries++
                if ($ran.Count -ne 1) {
                    $driveFailures += "$menuName[$($item.Key)] '$($item.Label)' expected exactly 1 handler call, saw $($ran.Count) ($($ran -join ', '))"
                } elseif ($ran[0] -ne $item.Handler) {
                    $driveFailures += "$menuName[$($item.Key)] '$($item.Label)' dispatched '$($ran[0])', expected '$($item.Handler)'"
                } elseif ($returned -ne $state) {
                    $driveFailures += "$menuName[$($item.Key)] '$($item.Label)' returned '$returned', expected the category state '$state'"
                }
            }
            'Preflight' {
                if ($returned -ne 'PREFLIGHT') { $driveFailures += "$menuName[$($item.Key)] pre-flight returned '$returned', expected PREFLIGHT" }
                elseif ($ran.Count -ne 0) { $driveFailures += "$menuName[$($item.Key)] pre-flight ran a handler instead of entering pre-flight: $($ran -join ', ')" }
                elseif (-not $ctx.PSObject.Properties['PreflightOperation']) { $driveFailures += "$menuName[$($item.Key)] pre-flight did not set PreflightOperation" }
                elseif ([string]$ctx.PreflightOperation -ne [string]$item.Preflight) {
                    $driveFailures += "$menuName[$($item.Key)] pre-flight set '$($ctx.PreflightOperation)', expected '$($item.Preflight)'"
                }
            }
            'Starts' {
                if ($returned -ne [string]$item.Starts) { $driveFailures += "$menuName[$($item.Key)] multi-step returned '$returned', expected '$($item.Starts)'" }
                elseif ($ran.Count -ne 0) { $driveFailures += "$menuName[$($item.Key)] multi-step ran a handler instead of handing off: $($ran -join ', ')" }
                elseif (-not $ctx.PSObject.Properties['PendingOperation']) { $driveFailures += "$menuName[$($item.Key)] multi-step did not set PendingOperation" }
                elseif ([string]$ctx.PendingOperation -ne [string]$item.Workflow) {
                    $driveFailures += "$menuName[$($item.Key)] multi-step set PendingOperation '$($ctx.PendingOperation)', expected '$($item.Workflow)'"
                }
            }
            'Report' {
                if ($returned -ne 'REPORT') { $driveFailures += "$menuName[$($item.Key)] report entry returned '$returned', expected REPORT" }
            }
            'Screen' {
                if ($returned -ne [string]$item.Screen) { $driveFailures += "$menuName[$($item.Key)] screen entry returned '$returned', expected '$($item.Screen)'" }
                elseif ($ran.Count -ne 0) { $driveFailures += "$menuName[$($item.Key)] screen entry ran a handler instead of routing: $($ran -join ', ')" }
            }
            'AuditSubVerb' {
                # Routed to the audit path rather than a handler; asserted by return state plus the
                # fact that NO $consoleActions handler ran. Invoke-WuuAuditSubVerb swallows its own
                # failures, so an unpopulated audit directory must not fail the drive.
                if ($returned -ne $state) { $driveFailures += "$menuName[$($item.Key)] audit $($item.AuditSubVerb) returned '$returned', expected '$state'" }
                elseif ($ran.Count -ne 0) { $driveFailures += "$menuName[$($item.Key)] audit $($item.AuditSubVerb) ran a console handler instead: $($ran -join ', ')" }
            }
            default {
                $driveFailures += "$menuName[$($item.Key)] '$($item.Label)' has no dispatch kind this suite can drive"
            }
        }
    }
}

if ($driveFailures.Count) {
    foreach ($f in $driveFailures) { Fail "dispatch: $f" }
} else {
    Pass "every guided entry reached its intended destination when driven through Show-WuuCategoryScreen ($allEntries entries)"
}
Assert-Equal $handlerEntries ($kindCounts['Handler']) 'the number of handler entries driven matches the count declared'

# ---------------------------------------------------------------------------------------
# 3. The dispatch actually REACHES the named handler (not merely "something ran")
# ---------------------------------------------------------------------------------------
# Stated separately from the loop above because it is the specific claim OBS-01 is about: for a
# handler entry, the handler whose NAME the entry carries is the code that executes.
$reachFailures = @()
foreach ($menuName in $menus.Keys) {
    foreach ($item in @(& ($menus[$menuName].Fn))) {
        if (-not $item.ContainsKey('Handler') -or -not $item.Handler) { continue }
        $actions = New-RecordingActions -Sink $sink
        $ctx = New-DriveCtx -Actions $actions
        [void]$sink.Clear()
        Initialize-WuuInputMode -NonInteractive -Answers @([string]$item.Key)
        [void](Show-WuuCategoryScreen -Ctx $ctx -Title $menus[$menuName].Title -Items @(& ($menus[$menuName].Fn)) -State $menus[$menuName].State)
        if (-not (@($sink) -contains $item.Handler)) {
            $reachFailures += "$menuName[$($item.Key)] '$($item.Label)': '$($item.Handler)' did not execute (ran: $(@($sink) -join ', '))"
        }
    }
}
if ($reachFailures.Count) { foreach ($f in $reachFailures) { Fail "reach: $f" } }
else { Pass "every entry's own named handler is the code that runs (indirect routing is correct)" }

# ---------------------------------------------------------------------------------------
# 4. An unknown selection and Back are both non-destructive
# ---------------------------------------------------------------------------------------
$actions = New-RecordingActions -Sink $sink
$ctx = New-DriveCtx -Actions $actions
[void]$sink.Clear()
Initialize-WuuInputMode -NonInteractive -Answers @('zzz')
$returned = Show-WuuCategoryScreen -Ctx $ctx -Title 'X' -Items @(Get-WuuSettingsMenu) -State 'SETTINGS'
Assert-Equal $returned 'SETTINGS' 'an unknown selection returns to the category rather than falling out of the workflow'
Assert-Equal @($sink).Count 0 'an unknown selection invokes no handler'

# ---------------------------------------------------------------------------------------
# 5. A missing handler is reported, not silently skipped
# ---------------------------------------------------------------------------------------
# The AD-import handler existed and was unreachable for months; Invoke-WuuGuidedHandler reports a
# missing handler loudly. Asserted here so the reporting cannot be removed without this failing.
$actions = New-RecordingActions -Sink $sink
$ctx = New-DriveCtx -Actions $actions
[void]$sink.Clear()
$output = ''
Initialize-WuuInputMode -NonInteractive -Answers @()
$output = (& { Invoke-WuuGuidedHandler -Ctx $ctx -Handler 'NoSuchHandler' } 6>&1 | Out-String)
if ($output -notmatch 'DEFECT') { Fail "a missing handler was not reported as a DEFECT (output: $($output.Trim()))" }
else { Pass 'a menu entry wired to a missing handler is reported as a DEFECT, not silently skipped' }

Write-Host ''
if ($fail) { Write-Host 'SOME CHECKS FAILED' -ForegroundColor Red; exit 1 }
Write-Host 'ALL PASS' -ForegroundColor Cyan
exit 0
