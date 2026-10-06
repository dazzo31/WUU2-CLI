#Requires -Version 5.1
<#
.DESCRIPTION
Bounded remote WMI/CIM and service operations with hard timeouts.
#>

function Test-WuuManagementEndpoint {
    <#
    .SYNOPSIS Whether the management endpoint WUU actually depends on answers (hardening brief SS7).
    .DESCRIPTION
    "Online" for this tool means "the endpoint I need is reachable", not "ICMP answers". Windows
    Firewall blocks inbound echo by default, so a perfectly healthy domain server can fail a ping -
    which is why ping is no longer used for any state transition in this codebase.

    WHAT IT DELIBERATELY DOES NOT DO
    --------------------------------
    It does not open a WUA session. An earlier attempt at this
    ([activator]::CreateInstance([type]::GetTypeFromProgID('Microsoft.Update.Session', $Name))) is the
    thing that made the reboot-wait loop unreliable: creating a WUA session against a host that is
    still shutting down can block far longer than the surrounding timeout plumbing controls, because
    the DCOM call itself stalls rather than the wrapper.

    So it asks the same question with two signals that are cheap and CANNOT hang:
      1. name resolution - a stale DNS entry is the most common reason a probe fails for ever, and it
         is worth reporting separately from "the host is down";
      2. a bounded TCP connect to the RPC endpoint mapper, which is what the DCOM/CIM calls depend
         on. A connect has a hard timeout, so the caller cannot be blocked by it.

    Returns a hashtable, not a boolean, so a caller can distinguish "not resolvable" from "resolves
    but no endpoint" - different operator actions. It is an ONLINE indicator; its negation is a
    strong offline signal. The reboot path re-verifies with the real management probe before
    declaring success.
    #>
    param([Parameter(Mandatory)][string]$ComputerName)

    $result = [ordered]@{
        Computer    = $ComputerName
        Resolves    = $false
        Endpoint    = $false
        ResolvedIps = @()
        Reason      = ''
    }

    # 1. Name resolution.
    try {
        $ips = @([System.Net.Dns]::GetHostAddresses($ComputerName) | ForEach-Object { $_.IPAddressToString })
        $result.ResolvedIps = $ips
        $result.Resolves = $true
    } catch {
        $result.Reason = "name not resolvable: $($_.Exception.Message)"
        return $result
    }

    # 2. RPC endpoint mapper - a bounded connect cannot hang the caller.
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($ComputerName, $global:EndpointProbePort)
        $answered = $iar.AsyncWaitHandle.WaitOne($global:EndpointProbeTimeoutMs, $false)
        if ($answered) {
            try { $client.EndConnect($iar); $result.Endpoint = $true }
            catch { $result.Reason = "connect refused/failed: $($_.Exception.Message)" }
        } else {
            $result.Reason = "no response within $($global:EndpointProbeTimeoutMs)ms"
        }
    } catch {
        $result.Reason = "endpoint probe failed: $($_.Exception.Message)"
    } finally {
        if ($client) { try { $client.Close(); $client.Dispose() } catch { } }
    }

    return $result
}

function Invoke-CimWithTimeout {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,
        
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]$ClassName = 'Win32_ComputerSystem',
        
        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 5,
        
        [Parameter(Mandatory=$false)]
        [PSCredential]$Credential = $null,
        
        [Parameter(Mandatory=$false)]
        [string]$Operation = 'CIM operation'
    )
    
    try {
        # Pool-based bounded execution (was Start-Job - one child process per probe).
        # The inner scriptblock is UNCHANGED: DCOM session logic and [pscredential]
        # typing preserved exactly - only the bounding mechanism is replaced.
        $cimResult = Invoke-WithPoolTimeout -ScriptBlock {
            # $Cred is always a PSCredential (or $null for default credentials) -
            # typed so a plain-string password can never be passed as a credential.
            # NOTE: PS 5.1's Get-CimInstance has NO -Credential parameter; alternate
            # credentials must go through New-CimSession (DCOM to match the old
            # Get-WmiObject behavior) and Get-CimInstance -CimSession.
            # DCOM for BOTH paths: Get-CimInstance -ComputerName implies WinRM/WSMAN, which
            # fails on hosts without a WinRM listener even though DCOM/WMI works (legacy
            # Get-WmiObject used DCOM) - such hosts were misreported as WMI timeouts.
            param([string]$ComputerName, [string]$ClassName, [pscredential]$Cred)
            $cimSession = $null
            try {
                $sessionArgs = @{ ComputerName = $ComputerName; SessionOption = (New-CimSessionOption -Protocol DCOM) }
                if ($Cred) { $sessionArgs['Credential'] = $Cred }
                $cimSession = New-CimSession @sessionArgs -ErrorAction Stop
                $result = Get-CimInstance -CimSession $cimSession -ClassName $ClassName -ErrorAction Stop
                return @{ Success = $true; Result = $result }
            } catch {
                return @{ Success = $false; Error = $_.Exception.Message }
            } finally {
                if ($cimSession) { Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue }
            }
        } -ArgumentList @($ComputerName, $ClassName, $Credential) -TimeoutSeconds $TimeoutSeconds -OperationName $Operation
        
        if ($cimResult.Success) {
            $inner = $cimResult.Result
            if ($inner -and $inner.Success) {
                return @{ Success = $true; Result = $inner.Result }
            }
            $errorMsg = if ($inner -and $inner.Error) { $inner.Error } else { 'Unknown error' }
        } else {
            $errorMsg = $cimResult.Error
        }

        # Recovery hook for RPC-class errors (0x800706ba, 0x800706be)
        $hresult = $null
        if ($errorMsg -match '0x([0-9A-Fa-f]{8})') {
            try { $hresult = [Convert]::ToInt32($matches[1], 16) } catch { }
        }
        if ($hresult -eq 0x800706ba -or $hresult -eq 0x800706be) {
            try {
                $recoverySucceeded = Invoke-AutoRecovery -ComputerName $ComputerName -ErrorCode $errorMsg -ErrorAction SilentlyContinue
                if ($recoverySucceeded) {
                    Start-Sleep -Seconds 2   # brief pause before retry
                    # Retry once after recovery
                    $retryResult = Invoke-WithPoolTimeout -ScriptBlock {
                        param([string]$ComputerName, [string]$ClassName, [pscredential]$Cred)
                        $cimSession = $null
                        try {
                            $sessionArgs = @{ ComputerName = $ComputerName; SessionOption = (New-CimSessionOption -Protocol DCOM) }
                            if ($Cred) { $sessionArgs['Credential'] = $Cred }
                            $cimSession = New-CimSession @sessionArgs -ErrorAction Stop
                            $result = Get-CimInstance -CimSession $cimSession -ClassName $ClassName -ErrorAction Stop
                            return @{ Success = $true; Result = $result }
                        } catch {
                            return @{ Success = $false; Error = $_.Exception.Message }
                        } finally {
                            if ($cimSession) { Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue }
                        }
                    } -ArgumentList @($ComputerName, $ClassName, $Credential) -TimeoutSeconds $TimeoutSeconds -OperationName "$Operation (post-recovery retry)"

                    if ($retryResult.Success) {
                        $retryInner = $retryResult.Result
                        if ($retryInner -and $retryInner.Success) {
                            return @{ Success = $true; Result = $retryInner.Result; RecoveredAfterRpcError = $true }
                        }
                        if ($retryInner -and $retryInner.Error) {
                            $errorMsg = $retryInner.Error
                        }
                    } elseif ($retryResult.Error) {
                        $errorMsg = $retryResult.Error
                    }
                    # Fall through to failure if retry also failed
                }
            } catch {
                # Recovery itself failed - fall through to original error
            }
        }
        return @{ Success = $false; Error = $errorMsg }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Invoke-ServiceWithTimeout {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,
        
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]$ServiceName = 'wuauserv',
        
        [Parameter(Mandatory=$false)]
        [ValidateSet('Check', 'Start', 'Stop', 'Restart')]
        [string]$Action = 'Check',
        
        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 5,
        
        [Parameter(Mandatory=$false)]
        [ValidateRange(0, 60)]
        [int]$PostActionDelay = 5
    )
    
    try {
        # Pool-based bounded execution (was Start-Job - one child process per probe).
        # The inner scriptblock is UNCHANGED - only the bounding mechanism is replaced.
        $serviceResult = Invoke-WithPoolTimeout -ScriptBlock {
            param($ComputerName, $ServiceName, $Action, $Delay)
            try {
                $service = Get-Service -Name $ServiceName -ComputerName $ComputerName -ErrorAction Stop
                
                switch ($Action) {
                    'Start' {
                        $service | Start-Service -ErrorAction Stop
                        Start-Sleep -Seconds $Delay
                        $service = Get-Service -Name $ServiceName -ComputerName $ComputerName -ErrorAction Stop
                        $success = ($service.Status -eq 'Running')
                    }
                    'Stop' {
                        $service | Stop-Service -ErrorAction Stop
                        Start-Sleep -Seconds $Delay
                        $service = Get-Service -Name $ServiceName -ComputerName $ComputerName -ErrorAction Stop
                        $success = ($service.Status -eq 'Stopped')
                    }
                    'Restart' {
                        $service | Restart-Service -ErrorAction Stop
                        Start-Sleep -Seconds $Delay
                        $service = Get-Service -Name $ServiceName -ComputerName $ComputerName -ErrorAction Stop
                        $success = ($service.Status -eq 'Running')
                    }
                    default { # Check
                        $success = $true
                    }
                }
                
                if ($service) {
                    return @{ Success = $success; Service = $service; Status = $service.Status }
                } else {
                    return @{ Success = $false; Error = "Service not found or inaccessible" }
                }
            } catch {
                return @{ Success = $false; Error = $_.Exception.Message }
            }
        } -ArgumentList @($ComputerName, $ServiceName, $Action, $PostActionDelay) -TimeoutSeconds $TimeoutSeconds -OperationName "Service $Action"
        
        if ($serviceResult.Success) {
            if ($serviceResult.Result) {
                return $serviceResult.Result
            } else {
                return @{ Success = $false; Error = 'No result returned from job' }
            }
        } else {
            return @{ Success = $false; Error = $serviceResult.Error }
        }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Test-SystemDependencies {
    param([string]$ComputerName)
    
    $dependencies = @{
        'RPC' = $false
        'WinRM' = $false
        'WindowsUpdate' = $false
        'RemoteRegistry' = $false
    }
    
    try {
        # Test RPC with timeout and credential handling
        # Pool-based bounded execution (was Start-Job - one child process per probe).
        $rpcResult = Invoke-WithPoolTimeout -ScriptBlock { 
            param($comp, [bool]$useCustomCreds, [PSCredential]$customCreds, [hashtable]$credCache)
            
            # Guard mirrors GetRemoteCredentialsScript: app initializes the cache,
            # but a probe must never crash on a $null cache (crash = false negative).
            if (-not $credCache) { $credCache = @{} }
            
            # Helper function to test credentials
            function Test-RemoteCredentials {
                param([string]$computerName, [PSCredential]$credential)
                try {
                    if ($credential) {
                        $cimSessionOptions = New-CimSessionOption -Protocol DCOM
                        $cimSession = New-CimSession -ComputerName $computerName -SessionOption $cimSessionOptions -Credential $credential -ErrorAction Stop
                        $result = Get-CimInstance -CimSession $cimSession -ClassName Win32_ComputerSystem -ErrorAction Stop
                        Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
                        return $result
                    } else {
                        if ($computerName -eq 'localhost' -or $computerName -eq $env:COMPUTERNAME) {
                            return Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
                        } else {
                            $cimSessionOptions = New-CimSessionOption -Protocol DCOM
                            $cimSession = New-CimSession -ComputerName $computerName -SessionOption $cimSessionOptions -ErrorAction Stop
                            $result = Get-CimInstance -CimSession $cimSession -ClassName Win32_ComputerSystem -ErrorAction Stop
                            Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
                            return $result
                        }
                    }
                } catch {
                    return $null
                }
            }
            
            # Credential resolution mirrors GetRemoteCredentialsScript (the app's
            # real model): cache hit -> custom -> default. The old parameter names
            # ($script:UseDomainCredentials/$script:AlternateCredentials) were NEVER
            # defined after the module split - this exported function silently
            # reported RPC unreachable for every machine if anyone called it.
            # Check if we have cached credentials for this computer
            if ($credCache.ContainsKey($comp)) {
                $result = Test-RemoteCredentials -computerName $comp -credential $credCache[$comp]
                if ($result) { return $result }
            }
            
            # Try custom credentials if configured
            if ($useCustomCreds -and $customCreds) {
                $result = Test-RemoteCredentials -computerName $comp -credential $customCreds
                if ($result) { return $result }
            }
            
            # Fall back to default credentials
            $result = Test-RemoteCredentials -computerName $comp -credential $null
            if ($result) { return $result }
            
            return $null
        } -ArgumentList @($ComputerName, [bool]$global:UseCustomCredentials, $global:CustomCredentials, $global:CredentialCache) -TimeoutSeconds 10 -OperationName 'RPC dependency probe'
        if ($rpcResult.Success -and $rpcResult.Result) {
            $dependencies['RPC'] = $true
        }
        
        # Test services with timeout
        if ($dependencies['RPC']) {
            $svcResult = Invoke-WithPoolTimeout -ScriptBlock { 
                param($comp) 
                try {
                    if ($comp -eq 'localhost' -or $comp -eq $env:COMPUTERNAME) {
                        $services = Get-Service -Name 'wuauserv', 'RemoteRegistry' -ErrorAction Stop
                    } else {
                        $services = Invoke-Command -ComputerName $comp -ScriptBlock {
                            Get-Service -Name 'wuauserv', 'RemoteRegistry' -ErrorAction Stop
                        } -ErrorAction Stop
                    }
                    return $services
                } catch {
                    return $null
                }
            } -ArgumentList $ComputerName -TimeoutSeconds 10 -OperationName 'Service dependency check'
            
            $services = if ($svcResult.Success) { $svcResult.Result } else { $null }
            if ($services) {
                $wuService = $services | Where-Object { $_.Name -eq 'wuauserv' }
                $regService = $services | Where-Object { $_.Name -eq 'RemoteRegistry' }
                
                $dependencies['WindowsUpdate'] = $wuService -and $wuService.Status -eq 'Running'
                $dependencies['RemoteRegistry'] = $regService -and $regService.Status -eq 'Running'
            }
        }
        
        return $dependencies
    } catch {
        # Return false dependencies if any error occurs
        return $dependencies
    }
}

function Invoke-WithTimeout {
    param(
        [ScriptBlock]$ScriptBlock,
        [int]$TimeoutSeconds = 300,
        [string]$OperationName = 'Operation',
        [object]$ArgumentList = $null
    )
    
    try {
        # Pool-based bounded execution (was a polled Start-Job loop).
        # No callers in the codebase today, but the contract is preserved
        # exactly in case future code (or the exported name) is used.
        return Invoke-WithPoolTimeout -ScriptBlock $ScriptBlock `
            -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds `
            -OperationName $OperationName
    } catch {
        return @{ Success = $false; Result = $null; Error = "$OperationName error: $($_.Exception.Message)" }
    }
}

function Invoke-WuuRemoteTask {
    <#
    .SYNOPSIS
    Runs a script on a remote computer as SYSTEM via a one-off scheduled task over a DCOM CIM session.
    WUA download/install refuse remote callers, so the work must run on the target.
    The script reports progress/result as JSON in HKLM\SOFTWARE\WUU2\Jobs\<RunId>\State (read via StdRegProv).
    Injected into worker runspaces as text - built-in cmdlets only.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$Operation,
        [pscredential]$Credential = $null,
        [scriptblock]$ProgressCallback = $null,
        [int]$TimeoutMinutes = 240,
        [int]$PollSeconds = 5
    )

    $runId = [guid]::NewGuid().ToString('N')
    $taskPath = '\WUU2\'
    $taskName = "WUU2_${Operation}_$runId"
    $jobsKey = 'SOFTWARE\WUU2\Jobs'
    $hklm = [uint32]2147483650
    $cim = $null
    $registered = $false

    $readState = {
        param([string]$Id)
        try {
            $r = Invoke-CimMethod -CimSession $cim -Namespace 'root/default' -ClassName 'StdRegProv' -MethodName 'GetStringValue' `
                -Arguments @{ hDefKey = $hklm; sSubKeyName = "$jobsKey\$Id"; sValueName = 'State' } -ErrorAction Stop
            if ($r.ReturnValue -eq 0 -and $r.sValue) { return ($r.sValue | ConvertFrom-Json) }
        } catch { }
        return $null
    }
    $removeState = {
        param([string]$Id)
        try {
            [void](Invoke-CimMethod -CimSession $cim -Namespace 'root/default' -ClassName 'StdRegProv' -MethodName 'DeleteKey' `
                -Arguments @{ hDefKey = $hklm; sSubKeyName = "$jobsKey\$Id" } -ErrorAction Stop)
        } catch {
            # Best-effort cleanup of the job's registry key. The key may already be absent, and the host
            # may have gone away mid-call. The caller treats the removal as done either way, so there is
            # no recovery to attempt and nothing for the caller to act on.
        }
    }

    try {
        $sessionArgs = @{ ComputerName = $ComputerName; SessionOption = (New-CimSessionOption -Protocol Dcom); OperationTimeoutSec = 60 }
        if ($Credential) { $sessionArgs['Credential'] = $Credential }
        $cim = New-CimSession @sessionArgs -ErrorAction Stop

        # Remove leftovers from runs whose controller died (e.g. GUI closed mid-install)
        $orphanCutoff = (Get-Date).AddMinutes(-($TimeoutMinutes + 30))
        foreach ($old in @(Get-ScheduledTask -CimSession $cim -TaskPath $taskPath -ErrorAction SilentlyContinue)) {
            if ($old.State -eq 'Running') { continue }
            $oldInfo = Get-ScheduledTaskInfo -CimSession $cim -TaskName $old.TaskName -TaskPath $taskPath -ErrorAction SilentlyContinue
            if (-not $oldInfo -or -not $oldInfo.LastRunTime -or $oldInfo.LastRunTime -gt $orphanCutoff) { continue }
            Unregister-ScheduledTask -CimSession $cim -TaskName $old.TaskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
            & $removeState ($old.TaskName -replace '^.*_', '')
        }

        $scriptText = "`$RunId = '$runId'`r`n" + (Get-Content -Path $ScriptPath -Raw -ErrorAction Stop)
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptText))
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Minutes $TimeoutMinutes)

        Register-ScheduledTask -CimSession $cim -TaskName $taskName -TaskPath $taskPath -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        $registered = $true
        Start-ScheduledTask -CimSession $cim -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
        $startedAt = Get-Date
        $deadline = $startedAt.AddMinutes($TimeoutMinutes + 5)

        while ($true) {
            Start-Sleep -Seconds $PollSeconds
            $state = & $readState $runId
            if ($state -and $ProgressCallback) { try { $null = & $ProgressCallback $state } catch { } }

            $task = Get-ScheduledTask -CimSession $cim -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
            if ((Get-Date) -gt $deadline) {
                throw "Remote $Operation task on $ComputerName timed out after $TimeoutMinutes minutes"
            }
            if ($task.State -eq 'Running' -or $task.State -eq 'Queued') { continue }

            # 0x41303 = task has not run yet; allow the scheduler a minute to pick it up
            $info = Get-ScheduledTaskInfo -CimSession $cim -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
            if ($info.LastTaskResult -eq 0x41303 -and ((Get-Date) - $startedAt).TotalSeconds -lt 60) { continue }
            break
        }

        $state = & $readState $runId
        $exitCode = [int64]$info.LastTaskResult
        if ($state -and $state.Result -eq 'Success') {
            return @{ Success = $true; Count = [int]$state.Count; Total = [int]$state.Total; RebootRequired = [bool]$state.RebootRequired; ExitCode = $exitCode; Error = $null }
        }
        $errorCount = if ($state -and $state.Count) { [int]$state.Count } else { 0 }
        $totalCount = if ($state -and $state.Total) { [int]$state.Total } else { 0 }
        $rebootReq = if ($state -and $state.RebootRequired) { [bool]$state.RebootRequired } else { $false }
        $errorText = if ($state -and $state.ErrorMessage) { $state.ErrorMessage } else { "Remote $Operation task ended without a result (task result 0x{0:X})" -f $exitCode }
        return @{ Success = $false; Count = $errorCount; Total = $totalCount; RebootRequired = $rebootReq; ExitCode = $exitCode; Error = $errorText }
    } finally {
        if ($cim) {
            if ($registered) {
                Unregister-ScheduledTask -CimSession $cim -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
            }
            & $removeState $runId
            Remove-CimSession -CimSession $cim -ErrorAction SilentlyContinue
        }
    }
}

Export-ModuleMember -Function @('Invoke-CimWithTimeout', 'Invoke-ServiceWithTimeout', 'Test-SystemDependencies', 'Invoke-WithTimeout', 'Invoke-WuuRemoteTask', 'Test-WuuManagementEndpoint')

