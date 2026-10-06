#Requires -Version 5.1
<#
.SYNOPSIS
Regression test for the pool migration of Wuu.Remote.psm1 helpers.
.DESCRIPTION
Mirrors the app's import topology. Verifies against localhost:
  1. Invoke-CimWithTimeout returns real CIM data (Win32_ComputerSystem)
  2. Invoke-ServiceWithTimeout checks wuauserv status
  3. Test-SystemDependencies probes localhost successfully
  4. Hard timeout path fires on unreachable host (timeout error, Result null)
  5. Non-timeout probe failure reports Success = $false, preserves error, Result null (C1/C5/G1)
  6. Pool reuse across helpers (sequential calls share one pool)
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

# Import in app order: Logging first (log functions), then Remote (uses pool),
# then Workers (pool provider) - Workers must precede any module calling it.
Import-Module (Join-Path $RepoRoot "src\Wuu.Logging.psm1") -Global -ErrorAction Stop
Import-Module (Join-Path $RepoRoot "src\Wuu.Workers.psm1") -Global -ErrorAction Stop
Import-Module (Join-Path $RepoRoot "src\Wuu.Remote.psm1") -Global -ErrorAction Stop

# 1. CIM helper with real data
$cim = Invoke-CimWithTimeout -ComputerName localhost -ClassName Win32_ComputerSystem -TimeoutSeconds 15
Assert-True ($cim.Success -and $cim.Result) "CIM helper returns Win32_ComputerSystem data ($($cim.Result.Name))"

# 2. Service helper
$svc = Invoke-ServiceWithTimeout -ComputerName localhost -ServiceName wuauserv -Action Check -TimeoutSeconds 15
Assert-True ($svc.Success) "Service helper checks wuauserv (status: $($svc.Status))"

# 3. System dependencies probe
$deps = Test-SystemDependencies -ComputerName localhost
Assert-True ($deps['RPC']) 'dependency probe reports RPC reachable on localhost'

# 4. Hard timeout path (192.0.2.1 is TEST-NET, guaranteed non-routable)
# Disentangled from probe failure (C5): assert timeout failure, timeout message, and Result null separately.
$timeoutTest = Invoke-CimWithTimeout -ComputerName '192.0.2.1' -TimeoutSeconds 3
Assert-True (-not $timeoutTest.Success) 'hard timeout reports Success = $false'
Assert-True ($timeoutTest.Error -like '*timed out*') "hard timeout error identifies timeout ($($timeoutTest.Error))"
Assert-True ($null -eq $timeoutTest.Result) 'hard timeout leaves Result null'

# 5. Non-timeout probe failure (C1 / C5 / G1): invalid class reports Success = $false with error
# Exercises the inner failure unwrap path that timeout tests cannot reach.
$badClass = Invoke-CimWithTimeout -ComputerName localhost -ClassName 'NoSuchClass_RemoteHelpersTest' -TimeoutSeconds 10
Assert-True (-not $badClass.Success) 'non-timeout probe failure reports Success = $false (not masked by pool success)'
Assert-True ($badClass.Error -like '*Invalid class*') "non-timeout probe failure preserves error text ($($badClass.Error))"
Assert-True ($null -eq $badClass.Result) 'non-timeout probe failure leaves Result null (does not leak inner hashtable)'
Assert-True ($badClass -is [System.Collections.IDictionary]) 'helper returns standard result dictionary on probe failure'

# 6. Pool reuse - all helpers share the single module pool
$pool1 = Get-WuuWorkerPool
$null = Invoke-CimWithTimeout -ComputerName localhost -ClassName Win32_OperatingSystem -TimeoutSeconds 15
$null = Invoke-ServiceWithTimeout -ComputerName localhost -ServiceName wuauserv -Action Check -TimeoutSeconds 15
$pool2 = Get-WuuWorkerPool
Assert-True ($pool1.InstanceId -eq $pool2.InstanceId) 'pool is reused across helpers (single instance)'

Close-WuuWorkerPool
if ($failures.Count -eq 0) {
    Write-Host 'ALL PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($failures.Count) FAILURE(S)" -ForegroundColor Red
    exit 1
}