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

# Minimal UI state. A no-op Dispatcher stub lets Start-UpdateCheckJob's catch path
# (which we are not exercising) complete without a real WPF control.
$global:uiHash = [hashtable]::Synchronized(@{})
$fakeItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$noOpDispatcher = New-Object PSObject
$null = Add-Member -InputObject $noOpDispatcher -MemberType ScriptMethod -Name Invoke -Value { param($priority, $action) & $action } -Force
$global:uiHash.ListView = [pscustomobject]@{ Items = $fakeItems; Dispatcher = $noOpDispatcher }
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

$item = New-Object PSObject -Property @{ Computer = 'localhost'; Phase = 'Phase 1'; Pending = $true; Runspace = $null; Status = 'Initializing...' }
$fakeItems.Add($item)

$getUpdatesPayload = { param($ComputerItem) 'payload-ran' }

Initialize-WuuWindowsUpdateContext -Context @{
    UiHash                      = $global:uiHash
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

$fail = $false

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
$item2 = New-Object PSObject -Property @{ Computer = 'localhost'; Phase = 'Phase 1'; Pending = $true; Runspace = $null; Status = 'Initializing...' }
$fakeItems.Add($item2)
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
