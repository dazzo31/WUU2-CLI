#Requires -Version 5.1
<#
.SYNOPSIS
Localhost test for Invoke-WuuRemoteTask (the PsExec replacement). Requires elevation.
.DESCRIPTION
Runs a trivial script as a SYSTEM scheduled task via a DCOM CIM session and verifies:
  1. Result/Count/RebootRequired come back from the registry state
  2. The progress callback fires
  3. Script errors surface as Success=$false with the message
  4. No \WUU2\ task or HKLM\SOFTWARE\WUU2\Jobs\<RunId> key is left behind
  5. The worker-runspace injection pattern (unbound scriptblock copy) works
Exit code 0 = all pass, 1 = failure.
#>
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$failures = @()
function Assert-True([bool]$Condition, [string]$Name) {
    if ($Condition) {
        Write-Host "PASS: $Name" -ForegroundColor Green
    } else {
        Write-Host "FAIL: $Name" -ForegroundColor Red
        $script:failures += $Name
    }
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Exit 0 with a SKIP marker: a suite that COULD NOT RUN has not failed, and exiting 1 here made
    # every non-elevated CI run report a spurious failure (observed in the per-suite harness).
    # Test-ComputerBusy and Test-AutoSettings use the marker instead; this now matches them.
    Write-Host "SKIP: must run elevated (registers a SYSTEM scheduled task)" -ForegroundColor Yellow
    exit 0
}

Import-Module (Join-Path $RepoRoot "src\Wuu.Logging.psm1") -Global -ErrorAction Stop
Import-Module (Join-Path $RepoRoot "src\Wuu.Workers.psm1") -Global -ErrorAction Stop
Import-Module (Join-Path $RepoRoot "src\Wuu.Remote.psm1") -Global -ErrorAction Stop

$okScript = Join-Path $env:TEMP "WuuRemoteTaskTest_ok.ps1"
$failScript = Join-Path $env:TEMP "WuuRemoteTaskTest_fail.ps1"
Set-Content -Path $okScript -Value @'
$regPath = "HKLM:\SOFTWARE\WUU2\Jobs\$RunId"
New-Item -Path $regPath -Force | Out-Null
Set-ItemProperty -Path $regPath -Name State -Value (@{ Phase = 'Downloading'; Current = 1; Total = 2; Title = 'Test update' } | ConvertTo-Json -Compress)
Start-Sleep -Seconds 8
Set-ItemProperty -Path $regPath -Name State -Value (@{ Phase = 'Done'; Result = 'Success'; Count = 2; Total = 2; RebootRequired = $true } | ConvertTo-Json -Compress)
exit 2
'@
Set-Content -Path $failScript -Value @'
$regPath = "HKLM:\SOFTWARE\WUU2\Jobs\$RunId"
New-Item -Path $regPath -Force | Out-Null
Set-ItemProperty -Path $regPath -Name State -Value (@{ Phase = 'Done'; Result = 'Error'; ErrorMessage = 'simulated failure' } | ConvertTo-Json -Compress)
exit 9999
'@

try {
    $progress = [System.Collections.ArrayList]::new()
    $r = Invoke-WuuRemoteTask -ComputerName localhost -ScriptPath $okScript -Operation 'Test' -PollSeconds 2 -ProgressCallback { param($p) [void]$progress.Add($p) }
    Assert-True ($r.Success -and $r.Count -eq 2 -and $r.RebootRequired) "Success result read from registry (Count=$($r.Count), Reboot=$($r.RebootRequired), Exit=$($r.ExitCode))"
    Assert-True (@($progress | Where-Object { $_.Phase -eq 'Downloading' }).Count -gt 0) "Progress callback received Downloading state ($($progress.Count) callbacks)"

    $f = Invoke-WuuRemoteTask -ComputerName localhost -ScriptPath $failScript -Operation 'Test' -PollSeconds 2
    Assert-True ((-not $f.Success) -and $f.Error -eq 'simulated failure') "Script error surfaces (Error='$($f.Error)', Exit=$($f.ExitCode))"

    # Worker-runspace pattern: unbound copy executed in an isolated runspace
    $injected = [scriptblock]::Create((Get-Command Invoke-WuuRemoteTask -CommandType Function).ScriptBlock.ToString())
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $rs.SessionStateProxy.SetVariable('InvokeRemoteTaskScript', $injected)
    $ps = [powershell]::Create().AddScript({ param($path) & $InvokeRemoteTaskScript -ComputerName localhost -ScriptPath $path -Operation 'Test' -PollSeconds 2 }).AddArgument($okScript)
    $ps.Runspace = $rs
    $w = @($ps.Invoke()) | Select-Object -Last 1
    $ps.Dispose(); $rs.Dispose()
    Assert-True ($w -and $w.Success -and $w.Count -eq 2) "Injected copy works in isolated runspace"

    $leftTasks = @(Get-ScheduledTask -TaskPath '\WUU2\' -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'WUU2_Test_*' })
    Assert-True ($leftTasks.Count -eq 0) "No leftover WUU2_Test tasks ($($leftTasks.Count))"
    $leftKeys = @(Get-ChildItem 'HKLM:\SOFTWARE\WUU2\Jobs' -ErrorAction SilentlyContinue)
    Assert-True ($leftKeys.Count -eq 0) "No leftover job registry keys ($($leftKeys.Count))"
} finally {
    Remove-Item $okScript, $failScript -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) FAILURE(S)" -ForegroundColor Red
    exit 1
}
Write-Host "`nALL PASS" -ForegroundColor Green
exit 0
