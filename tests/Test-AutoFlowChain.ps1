#Requires -Version 5.1
<#
.SYNOPSIS Regression test: the Auto Download/Install follow-up chain.
.DESCRIPTION Verifies the fix for "auto download/install does nothing":
  - Start-PendingUpdateCheck consumes an item's PendingOp and starts exactly ONE job.
  - Start-UpdateCheckJob -Op composes the right op chain in ONE pipeline. Payload stubs
    append a marker to a shared file (worker runspaces can write files but cannot see the
    test's in-memory variables), proving WHICH AddScript calls executed and their order:
        Check            -> GET
        Download         -> DOWNLOAD:Download
        InstallAndRecheck-> INSTALL, RESTART, GET
        AutoFlow         -> DOWNLOAD:AutoFlow, INSTALL, RESTART, GET
  Production payloads update the GUI via the UI-thread dispatcher (not the pipeline stream),
  so a file ledger is the faithful signal here; pipeline stdout only carries the last
  script's return value and cannot prove execution.
  Uses a REAL worker runspace (New-ComputerRunspace), exactly as production composes it.
Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-AutoFlowChain.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

# Shared marker file the worker-runspace payload stubs append to.
$markerFile = Join-Path $env:TEMP ("WUU_autoflow_markers_{0}.log" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType File -Path $markerFile -Force | Out-Null

# --- Stub UI state (no-op dispatcher so dispatcher actions run inline) ------------------
$global:uiHash = [hashtable]::Synchronized(@{})
$fakeItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$noOpDispatcher = New-Object PSObject
$null = Add-Member -InputObject $noOpDispatcher -MemberType ScriptMethod -Name Invoke -Value { param($priority, $action) & $action } -Force
$global:uiHash.ListView = [pscustomobject]@{ Items = $fakeItems; Dispatcher = $noOpDispatcher }
$global:uiHash.AutoInstallCheckBox = [pscustomobject]@{ IsChecked = $true }
$global:uiHash.AutoRebootCheckBox  = [pscustomobject]@{ IsChecked = $false }

$global:jobs = [system.collections.arraylist]::Synchronized((New-Object System.Collections.ArrayList))
$global:backgroundProcessing = [hashtable]::Synchronized(@{ Suspended = $false })
$global:MaxConcurrentJobs = 10
$global:LogPath = Join-Path $env:TEMP 'WUU_test_autoflow.log'
$global:LogLock = New-Object Object
$global:EnableDebugLogging = $false
$global:searchTimeout = 5
$global:sessionTimeout = 5
$global:rebootCheckTimeout = 5
$global:updatesHash = [hashtable]::Synchronized(@{})
$global:performanceHash = [hashtable]::Synchronized(@{})
$global:errorSuggestionsHash = New-WuuErrorSuggestions
$global:ConfigPaths = @{ DownloadScript = 'unused'; InstallScript = 'unused' }
$global:UseCustomCredentials = $false
$global:CustomCredentials = $null
$global:CredentialCache = @{}
$global:PerformanceThreshold = @{ CPUPercent = 80; MemoryMB = 1024; NetworkLatencyMs = 1000 }
$global:EnableEnhancedErrorHandling = $false

# --- Recording payload stubs: append "NAME:arg" to the marker file --------------------
# (path is literal inside the scriptblock text so the worker runspace needs no injection;
#  payloads that take an arg emit it after a colon, others emit just the name)
$mkA = { param($name) [scriptblock]::Create(("param(`$ComputerItem, `$Op) Add-Content -Path '{0}' -Value ('{1}:' + `$Op)" -f $markerFile, $name)) }
$mkN = { param($name) [scriptblock]::Create(("param(`$ComputerItem, `$Op) Add-Content -Path '{0}' -Value '{1}'" -f $markerFile, $name)) }
$payloadGet      = $mkN.Invoke('GET')      | Select-Object -First 1
$payloadDownload = $mkA.Invoke('DOWNLOAD') | Select-Object -First 1
$payloadInstall  = $mkN.Invoke('INSTALL')  | Select-Object -First 1
$payloadRestart  = $mkA.Invoke('RESTART')  | Select-Object -First 1

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
    GetUpdates                  = $payloadGet
    DownloadUpdates             = $payloadDownload
    InstallUpdates              = $payloadInstall
    RestartComputer             = $payloadRestart
    BackgroundProcessing        = $global:backgroundProcessing
    CredDialogXamlPath          = Join-Path $root 'ui\CredentialDialog.xaml'
}

$fail = $false

function Invoke-OpChain {
    param([string]$PendingOp, [string[]]$Expected)
    # Fresh marker file per op so ordering is unambiguous
    Set-Content -Path $markerFile -Value $null

    $item = New-Object PSObject -Property @{
        Computer = 'localhost'; Phase = 'Phase 1'; Pending = $true
        PendingOp = $PendingOp; Runspace = $null; Status = 'test'
    }
    $fakeItems.Add($item)
    Start-PendingUpdateCheck

    if ($global:jobs.Count -ne 1) {
        Write-Host ("FAIL [{0}]: expected exactly 1 job, got {1}" -f $PendingOp, $global:jobs.Count) -ForegroundColor Red
        $script:fail = $true; return
    }
    $job = $global:jobs[0]
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $job.Runspace.IsCompleted -and $sw.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 100 }
    try { $job.PowerShell.EndInvoke($job.Runspace) | Out-Null } catch { Write-Host ("FAIL [{0}]: EndInvoke threw: {1}" -f $PendingOp, $_.Exception.Message) -ForegroundColor Red; $script:fail = $true }

    $global:jobs.Remove($job)
    try { $job.PowerShell.Dispose() } catch { $null = $_ }
    if ($item.Runspace) { try { $item.Runspace.Close(); $item.Runspace.Dispose() } catch { $null = $_ } }
    $fakeItems.Remove($item)

    $got = @((Get-Content $markerFile) | Where-Object { $_ })
    $match = ($got.Count -eq $Expected.Count)
    if ($match) { for ($i = 0; $i -lt $Expected.Count; $i++) { if ($got[$i] -ne $Expected[$i]) { $match = $false } } }
    if ($match) {
        Write-Host ("PASS [{0}]: chain executed -> {1}; PendingOp cleared={2}; Pending={3}" -f $PendingOp, ($got -join ' | '), $item.PendingOp, $item.Pending) -ForegroundColor Green
    } else {
        Write-Host ("FAIL [{0}]: expected [{1}] got [{2}]" -f $PendingOp, ($Expected -join ', '), ($got -join ', ')) -ForegroundColor Red
        $script:fail = $true
    }
}

Invoke-OpChain $null                  @('GET')
Invoke-OpChain 'Download'             @('DOWNLOAD:Download')
Invoke-OpChain 'InstallAndRecheck'    @('INSTALL', 'RESTART:True', 'GET')
Invoke-OpChain 'AutoFlow'             @('DOWNLOAD:AutoFlow', 'INSTALL', 'RESTART:True', 'GET')

Remove-Item $markerFile -Force -ErrorAction SilentlyContinue

if ($fail) { Write-Host 'SOME CHECKS FAILED' -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS' -ForegroundColor Cyan }
