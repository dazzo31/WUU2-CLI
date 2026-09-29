#Requires -Version 5.1
<#
.SYNOPSIS Regression test: the "stuck at Initializing..." path (timer -> Start-PendingUpdateCheck).
.DESCRIPTION Imports the real modules, builds a minimal UI state (observable collection +
fake item), initializes the WindowsUpdate context exactly like Start-WuuApplication does,
and asserts Start-PendingUpdateCheck drains a Pending item into $jobs via Start-UpdateCheckJob.
Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-PendingDrain.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

# Import exactly like the real entry point (WUU.ps1 -> Wuu.Core -> Start-WuuApplication):
# importing the modules directly into this session would MASK cross-module visibility
# bugs (the exact class of bug this test guards against).
Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

# Cross-module visibility probe: Wuu.WindowsUpdate functions must resolve Wuu.Logging
# exports at call time (this is what failed at runtime and froze items).
$probe = Get-Command Write-InfoLog -ErrorAction SilentlyContinue
if (-not $probe) { Write-Host 'FAIL: Write-InfoLog not resolvable after Import-WuuModules' -ForegroundColor Red; exit 1 }
Write-Host 'PASS: cross-module command resolution (Write-InfoLog visible)' -ForegroundColor Green

# The queue now lives in the STATE STORE. This test used to hand-build a fake `uiHash.ListView`
# with an ObservableCollection and then assert the drain worked - which is exactly the object the
# PRODUCTION code was missing (nothing in src/ ever assigns a ListView; $uiHash is an empty
# hashtable). So the suite passed for two releases while Start-PendingUpdateCheck was a no-op in
# the real app: an operation queued by auto-download was never started, Phase-E retries were never
# promoted, and phase gating never applied to queued items.
#
# A test that supplies the object under test's dependencies FROM ITSELF cannot fail the way the app
# can. It now drives the same store the console uses.
$stateStore = New-WuuStateStore
$global:jobs = [system.collections.arraylist]::Synchronized((New-Object System.Collections.ArrayList))
$global:backgroundProcessing = [hashtable]::Synchronized(@{ Suspended = $false })
$global:MaxConcurrentJobs = 10
$global:LogPath = Join-Path $env:TEMP 'WUU_test_pendingdrain.log'
$global:LogLock = New-Object Object
$global:EnableDebugLogging = $true   # surface the real Start-UpdateCheckJob catch error
$global:searchTimeout = 300
$global:sessionTimeout = 30
$global:rebootCheckTimeout = 60
$global:LogPath = Join-Path $env:TEMP 'WUU_test_pendingdrain.log'

# The fake computer item: Pending=$true so Start-PendingUpdateCheck must pick it up.
# A real $GetUpdates payload is injected so Start-UpdateCheckJob exercises the real path.
$global:updatesHash = [hashtable]::Synchronized(@{})
$global:performanceHash = [hashtable]::Synchronized(@{})
$global:errorSuggestionsHash = New-WuuErrorSuggestions
$global:ConfigPaths = @{ DownloadScript='unused'; InstallScript='unused' }
$global:UseCustomCredentials = $false
$global:CustomCredentials = $null
$global:CredentialCache = @{}
$global:PerformanceThreshold = @{ CPUPercent = 80; MemoryMB = 1024; NetworkLatencyMs = 1000 }
$global:EnableEnhancedErrorHandling = $false

$row = New-WuuComputerRow -Computer 'localhost' -Phase 'Phase 1'
$row.Pending = $true
$row.Status = 'Initializing...'
$row.Runspace = $null
Add-WuuComputerRow -Store $stateStore -Row $row | Out-Null
$item = $row

$getUpdatesPayload = { param($ComputerItem) 'payload-ran' }

Initialize-WuuWindowsUpdateContext -Context @{
    # UiHash is deliberately NOT supplied: the console edition has no GUI state, and passing a
    # populated one here is what hid the defect this suite now guards against.
    StateStore                  = $stateStore
    Jobs                        = $global:jobs
    UpdatesHash                 = $global:updatesHash
    PerformanceHash             = $global:performanceHash
    ErrorSuggestions            = $global:errorSuggestionsHash
    Path                        = $PWD.Path
    LogPath                     = $global:LogPath
    LogLock                     = $global:LogLock
    EnableDebugLogging          = $false
    EnableEnhancedErrorHandling = $false
    UseCustomCredentials        = $false
    CustomCredentials           = $null
    CredentialCache             = $global:CredentialCache
    PerformanceThreshold        = $global:PerformanceThreshold
    ConfigPaths                 = $global:ConfigPaths
    SearchTimeout               = $global:searchTimeout
    SessionTimeout              = $global:sessionTimeout
    RebootCheckTimeout          = $global:rebootCheckTimeout
    MaxConcurrentJobs           = $global:MaxConcurrentJobs
    GetUpdates                  = $getUpdatesPayload
    BackgroundProcessing        = $global:backgroundProcessing
}

# Single source of truth for this suite's verdict. Declared ONCE, before anything can set it -
# assigning $fail=$false after the guard below would silently erase its failure.
$fail = $false

# --- Guard: no SHIPPED source may read a GUI control member -----------------------------------
# This is the assertion that would have caught the real defect. The drain test above is only
# meaningful if production code and the test agree on where the queue lives; the two had silently
# diverged, and the test hid it by building the missing object itself.
#
# Comments MUST be stripped with the tokenizer, not a '#.*$' regex or a "starts with #" test. The
# modules carry block comments (<# ... #>) and doc blocks that quote these very member names when
# explaining the migration - a naive filter flags all eight of them, and a '#.*$' regex additionally
# eats '#' inside strings and subexpressions (the false-positive class Validate-Release.ps1
# documents). PSParser knows what a comment is.
$srcFiles = @(Get-ChildItem (Join-Path $root 'src') -Filter *.psm1)
$guiReads = @()
foreach ($f in $srcFiles) {
    $tkErrs = $null
    $tokens = [System.Management.Automation.PSParser]::Tokenize((Get-Content $f.FullName -Raw), [ref]$tkErrs)
    foreach ($t in $tokens) {
        if ($t.Type -eq 'Comment') { continue }
        if ($t.Content -match '\$uiHash\.\w*(List[Vv]iew|CheckBox|TextBox|Menu)') {
            $guiReads += ("{0}: {1}" -f $f.Name, $t.Content)
        }
    }
}
if ($guiReads.Count) {
    Write-Host ('FAIL: shipped source reads a GUI control member ({0}):' -f $guiReads.Count) -ForegroundColor Red
    $guiReads | ForEach-Object { Write-Host ("    {0}" -f $_) -ForegroundColor Red }
    $fail = $true
} else {
    Write-Host 'PASS: no shipped source reads a GUI control member (queue lives in the state store)' -ForegroundColor Green
}

# BEFORE the fix: $script:WuuCtx was never initialized -> Start-PendingUpdateCheck no-ops.
Start-PendingUpdateCheck
if ($global:jobs.Count -eq 0) {
    Write-Host 'FAIL: Start-PendingUpdateCheck drained nothing into $jobs (item stuck at Initializing)' -ForegroundColor Red
    $fail = $true
} else {
    Write-Host ("PASS: job started - {0} job(s) in queue, item Pending={1}" -f $global:jobs.Count, $item.Pending) -ForegroundColor Green
}

# Cleanup: stop and dispose the job PowerShell + close the created runspace
foreach ($j in @($global:jobs)) {
    try { $j.PowerShell.Stop() } catch { $null = $_ }
    try { $j.PowerShell.Dispose() } catch { $null = $_ }
    if ($item.Runspace) {
        try { $item.Runspace.Close() } catch { $null = $_ }
        try { $item.Runspace.Dispose() } catch { $null = $_ }
    }
    $global:jobs.Remove($j)
}

# Drain a second item to prove the path is repeatable (phase gating sees no blockers)
$item2 = New-WuuComputerRow -Computer 'localhost2' -Phase 'Phase 1'
$item2.Pending = $true
$item2.Status = 'Initializing...'
Add-WuuComputerRow -Store $stateStore -Row $item2 | Out-Null
Start-PendingUpdateCheck
if ($global:jobs.Count -ge 1) {
    Write-Host ("PASS: second drain works - {0} job(s)" -f $global:jobs.Count) -ForegroundColor Green
    foreach ($j in @($global:jobs)) {
        try { $j.PowerShell.Stop() } catch { $null = $_ }
        try { $j.PowerShell.Dispose() } catch { $null = $_ }
        if ($item2.Runspace) { try { $item2.Runspace.Close(); $item2.Runspace.Dispose() } catch { $null = $_ } }
        $global:jobs.Remove($j)
    }
} else {
    Write-Head 'FAIL: second drain empty'
    $fail = $true
}

if ($fail) { exit 1 } else { Write-Host 'ALL PASS' -ForegroundColor Cyan }
