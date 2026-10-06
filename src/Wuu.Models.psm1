#Requires -Version 5.1
<#
.DESCRIPTION
Synchronized state collections and the error-suggestion catalog.
#>

function New-WuuState {
    # Synchronized collections shared between the UI thread and worker runspaces.
    @{
        # UiHash REMOVED: it was the GUI ListView and its checkbox members, created empty in this
        # edition and read by nothing - the console renders from the state store. Dead wiring implies a
        # dependency that does not exist, so it is not merely unused, it is misleading. (Grep every
        # $uiHash site before adding one back: they are all comments or assignments.)
        Jobs                 = [system.collections.arraylist]::Synchronized((New-Object System.Collections.ArrayList))
        JobCleanup           = [hashtable]::Synchronized(@{})
        UpdatesHash          = [hashtable]::Synchronized(@{})
        PerformanceHash      = [hashtable]::Synchronized(@{})
        ErrorSuggestions     = $null   # filled by New-WuuErrorSuggestions
        BackgroundProcessing = [hashtable]::Synchronized(@{ Suspended = $false })
    }
}

function New-WuuErrorSuggestions {
    param()
    [hashtable]::Synchronized(@{
        '800706ba' = @{
            Description = 'RPC server is unavailable'
            Suggestions = @(
                'Check if Windows Firewall is blocking RPC traffic',
                'Verify Remote Registry service is running',
                'Ensure RPC service is started',
                'Check network connectivity between computers'
            )
            AutoFix = $true
        }
        '80070005' = @{
            Description = 'Access denied'
            Suggestions = @(
                'Run as administrator',
                'Check user account permissions',
                'Verify UAC settings',
                'Ensure account has administrative rights on target computer'
            )
            AutoFix = $false
        }
        '800706be' = @{
            Description = 'Remote procedure call failed'
            Suggestions = @(
                'Restart RPC service on target computer',
                'Check if target computer is overloaded',
                'Verify network stability',
                'Try operation again after a few minutes'
            )
            AutoFix = $true
        }
        'not responding to ping' = @{
            Description = 'Computer is not reachable on the network'
            Suggestions = @(
                'Verify the computer name is correct',
                'Check if the computer is powered on',
                'Ensure network cables are connected',
                'Verify firewall settings allow ICMP ping',
                'Try using IP address instead of computer name'
            )
            AutoFix = $false
        }
        'not reachable' = @{
            Description = 'Computer is not accessible via network'
            Suggestions = @(
                'Verify the computer name is correct',
                'Check if the computer is powered on',
                'Ensure network connectivity',
                'Verify DNS resolution is working',
                'Check firewall settings'
            )
            AutoFix = $false
        }
        'WMI is not accessible' = @{
            Description = 'WMI/CIM service is not responding'
            Suggestions = @(
                'Verify WMI service is running on target computer',
                'Check Windows Firewall WMI exceptions',
                'Ensure proper credentials are provided',
                'Try using alternate authentication method'
            )
            AutoFix = $false
        }
        'name resolution' = @{
            Description = 'DNS name resolution failed'
            Suggestions = @(
                'Check DNS server configuration',
                'Verify computer name spelling',
                'Try using IP address instead',
                'Check network connectivity to DNS server'
            )
            AutoFix = $false
        }
        'timeout' = @{
            Description = 'Operation timed out'
            Suggestions = @(
                'Check network connectivity',
                'Verify target computer is responsive',
                'Increase timeout settings if needed',
                'Try again later when network is less busy'
            )
            AutoFix = $false
        }
        'timed out' = @{
            Description = 'Operation timed out'
            Suggestions = @(
                'Check network connectivity',
                'Verify target computer is responsive',
                'Increase timeout settings if needed',
                'Try again later when network is less busy'
            )
            AutoFix = $false
        }
    })
}

function Get-WuuErrorSuggestions {
    param([string]$ErrorMessage)

    $suggestions = New-WuuErrorSuggestions
    foreach ($errorCode in $suggestions.Keys) {
        if ($ErrorMessage -match $errorCode) {
            return $suggestions[$errorCode]
        }
    }

    return @{
        Description = 'Unknown error'
        Suggestions = @('Check Windows Event Logs for more details', 'Verify network connectivity', 'Try the operation again')
        AutoFix = $false
    }
}

Export-ModuleMember -Function @('New-WuuState','New-WuuErrorSuggestions','Get-WuuErrorSuggestions')