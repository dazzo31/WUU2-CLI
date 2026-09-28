#Requires -Version 5.1
<#
.SYNOPSIS Regression test: cross-module command resolution inside module functions.
.DESCRIPTION Reproduces the exact runtime failure class from 2026-09-18: New-ComputerRunspace
(Wuu.WindowsUpdate) calling Write-InfoLog (Wuu.Logging) must resolve when imports go
through Wuu.Core's Import-WuuModules (the real app topology). Before the -Global fix,
module session-state isolation made the call fail and killed every timer tick.
Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-CrossModuleResolution.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

# REAL topology: entry -> Core -> Import-WuuModules (-Global)
Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

# Global state New-ComputerRunspace reads
$global:LogPath = Join-Path $env:TEMP 'WUU_xmod_test.log'
$global:LogLock = New-Object Object
$global:EnableDebugLogging = $true
$global:UseCustomCredentials = $false
$global:CustomCredentials = $null
$global:CredentialCache = @{}

# The call that failed at runtime: module fn -> cross-module logging
$item = New-Object PSObject -Property @{ Computer='localhost'; Phase='Phase 1'; Pending=$true; Runspace=$null; Status='Initializing...' }
Initialize-WuuWindowsUpdateContext -Context @{
    UiHash = [hashtable]::Synchronized(@{})
    Jobs = [system.collections.arraylist]::Synchronized((New-Object System.Collections.ArrayList))
    UpdatesHash = [hashtable]::Synchronized(@{})
    PerformanceHash = [hashtable]::Synchronized(@{})
    ErrorSuggestions = (New-WuuErrorSuggestions)
    Path = $root
    LogPath = $global:LogPath
    LogLock = $global:LogLock
    EnableDebugLogging = $true
    EnableEnhancedErrorHandling = $false
    UseCustomCredentials = $false
    CustomCredentials = $null
    CredentialCache = $global:CredentialCache
    PerformanceThreshold = @{}
    ConfigPaths = @{}
    SearchTimeout = 300
    SessionTimeout = 30
    RebootCheckTimeout = 60
    MaxConcurrentJobs = 10
    GetUpdates = { param($ComputerItem) 'payload-ran' }
    BackgroundProcessing = [hashtable]::Synchronized(@{ Suspended = $false })
}

# Must not throw; proves Write-InfoLog resolves inside the Wuu.WindowsUpdate function.
# Assign like Start-UpdateCheckJob does - New-ComputerRunspace RETURNS the runspace.
try {
    $item.Runspace = New-ComputerRunspace -ComputerItem $item -ErrorAction Stop
} catch {
    Write-Host ("FAIL: New-ComputerRunspace threw: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

if ($item.Runspace) {
    Write-Host 'PASS: New-ComputerRunspace succeeded - cross-module Write-InfoLog resolved' -ForegroundColor Green
    # Verify the log line actually landed (logging executed, not silently skipped)
    $logged = Select-String -Path $global:LogPath -Pattern 'Creating runspace for computer: localhost'
    if ($logged) { Write-Host 'PASS: Write-InfoLog entry landed in the debug log' -ForegroundColor Green }
    else { Write-Host 'FAIL: no log entry - logging silently skipped' -ForegroundColor Red; exit 1 }

    # Pool injection check: the worker runspace must carry WuuWorkerPool +
    # InvokePooledScript (SetVariable'd by New-ComputerRunspace) and they must
    # WORK there - the exact path GetRemoteCredentialsScript's probes take.
    $poolCheckPs = [powershell]::Create()
    $poolCheckPs.Runspace = $item.Runspace
    [void]$poolCheckPs.AddScript({
        $probe = {
            param($ComputerName)
            if ($ComputerName -eq 'localhost') { @{ Success = $true } } else { @{ Success = $false } }
        }
        & $InvokePooledScript -Pool $WuuWorkerPool -ScriptBlock $probe `
            -ArgumentList @('localhost') -TimeoutSeconds 8 -OperationName 'pool-injection-check'
    })
    $poolHandle = $poolCheckPs.BeginInvoke()
    if ($poolHandle.AsyncWaitHandle.WaitOne([System.TimeSpan]::FromSeconds(15))) {
        $poolOut = $poolCheckPs.EndInvoke($poolHandle)
        if ($poolOut -and $poolOut.Count -gt 0 -and $poolOut[0].Success -and $poolOut[0].Result.Success) {
            Write-Host 'PASS: injected WuuWorkerPool + InvokePooledScript work inside worker runspace' -ForegroundColor Green
        } else {
            Write-Host 'FAIL: injected pool variables present but probe returned failure' -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host 'FAIL: pool injection check timed out in worker runspace' -ForegroundColor Red
        exit 1
    }
    try { $poolCheckPs.Dispose() } catch { }

    $item.Runspace.Close(); $item.Runspace.Dispose()
    Write-Host 'ALL PASS' -ForegroundColor Cyan
} else {
    Write-Host 'FAIL: runspace not created' -ForegroundColor Red
    exit 1
}
