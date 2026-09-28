#Requires -Version 5.1
<#
.DESCRIPTION
Credential handling: DPAPI helpers, dialogs, cache/probe, encrypted computer-list config.
#>

function Protect-Credential {
    param([System.Security.SecureString]$SecurePassword)
    
    try {
        # Convert SecureString to encrypted standard string using DPAPI
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
        $PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        
        # Encrypt using DPAPI (user-specific, requires same user context to decrypt)
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainPassword)
        $ProtectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $Bytes, 
            $null, 
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        
        return [Convert]::ToBase64String($ProtectedBytes)
    } catch {
        Write-DebugLog "Failed to protect credential: $($_.Exception.Message)" -Level 'ERROR'
        return $null
    }
}

function Unprotect-Credential {
    param([string]$ProtectedBase64)
    
    try {
        # Decrypt using DPAPI
        $ProtectedBytes = [Convert]::FromBase64String($ProtectedBase64)
        $PlainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $ProtectedBytes, 
            $null, 
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $PlainPassword = [System.Text.Encoding]::UTF8.GetString($PlainBytes)
        
        # Convert back to SecureString
        $SecurePassword = ConvertTo-SecureString $PlainPassword -AsPlainText -Force
        return $SecurePassword
    } catch {
        Write-DebugLog "Failed to unprotect credential: $($_.Exception.Message)" -Level 'ERROR'
        return $null
    }
}

function Get-RemoteCredentials {
    param(
        [string]$ComputerName,
        [string]$Operation = 'WMI access'
    )
    
    try {
        # Check cache first (runtime only, never persisted)
        if ($global:CredentialCache.ContainsKey($ComputerName)) {
            Write-DebugLog "Using cached credentials for $ComputerName" -Level 'DEBUG'
            return $global:CredentialCache[$ComputerName]
        }
        
        # Try custom configured credentials first if enabled
        if ($global:UseCustomCredentials -and $global:CustomCredentials) {
            try {
                Write-DebugLog "Testing custom credentials for $ComputerName" -Level 'DEBUG'
                # Use helper function for credential test
                $wmiResult = Invoke-CimWithTimeout -ComputerName $ComputerName -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 5 -Credential $global:CustomCredentials -Operation 'Custom credential test'
                
                if ($wmiResult.Success) {
                    # Custom credentials work, cache them (runtime cache only)
                    Write-DebugLog "Custom credentials successful for $ComputerName, caching" -Level 'INFO'
                    $global:CredentialCache[$ComputerName] = $global:CustomCredentials
                    return $global:CustomCredentials
                } else {
                    Write-DebugLog "Custom credentials failed for $ComputerName : $($wmiResult.Error)" -Level 'WARN'
                }
            } catch {
                Write-DebugLog "Custom credentials test failed for $ComputerName : $($_.Exception.Message)" -Level 'WARN'
            }
        }
        
        # Custom credentials failed or not configured, try default credentials
        try {
            Write-DebugLog "Testing default credentials for $ComputerName" -Level 'DEBUG'
            # Use helper function for default credential test
            $wmiResult = Invoke-CimWithTimeout -ComputerName $ComputerName -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 5 -Operation 'Default credential test'
            
            if ($wmiResult.Success) {
                # Default credentials work, cache success (runtime cache only)
                Write-DebugLog "Default credentials successful for $ComputerName, caching" -Level 'INFO'
                $global:CredentialCache[$ComputerName] = $null  # null means use default credentials
                return $null
            } else {
                Write-DebugLog "Default credentials failed for $ComputerName : $($wmiResult.Error)" -Level 'WARN'
            }
        } catch {
            Write-DebugLog "Default credentials test failed for $ComputerName : $($_.Exception.Message)" -Level 'WARN'
        }
        
        # Both failed - return null to indicate auth failure
        # Caller will handle the error appropriately
        Write-DebugLog "All credential tests failed for $ComputerName - returning null" -Level 'WARN'
        return $null
        
    } catch {
        Write-DebugLog "Error in Get-RemoteCredentials for $ComputerName : $($_.Exception.Message)" -Level 'ERROR'
        return $null
    }
}

function Show-PasswordPrompt {
    <#
    .SYNOPSIS Console password prompt (was a WPF PasswordBox dialog).
    .DESCRIPTION Returns a SecureString, or $null if cancelled/empty - the same contract
    the WPF version had, so callers need no change. Read-Host -AsSecureString keeps the
    password off the screen and out of the transcript.
    #>
    param(
        [string]$Title = "Password Required",
        [string]$Message = "Enter password:"
    )
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor White
    if ($Message) { Write-Host "  $Message" -ForegroundColor Gray }
    try {
        $sec = Read-Host -Prompt "  Password" -AsSecureString
    } catch {
        Write-ErrorLog "Secure password prompt unavailable: $($_.Exception.Message)"
        return $null
    }
    if ($null -eq $sec -or $sec.Length -eq 0) { return $null }
    return $sec
}

function Show-CustomCredentialDialog {
    <#
    .SYNOPSIS Console credential prompt (was the WPF CredentialDialog.xaml dialog).
    .DESCRIPTION Collects domain\username + password and optionally probes the target, then
    returns a PSCredential or $null on cancel - the same contract as the WPF version.
    The password is never echoed and never written to the transcript.
    #>
    param(
        [string]$Message = "Enter your credentials",
        [string]$Username = "",
        [string]$Title = "Credentials Required"
    )
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor White
    if ($Message) { Write-Host "  $Message" -ForegroundColor Gray }

    $userAnswer = Read-Host "  Username (domain\user)" $(if ($Username) { "[$Username]" } else { "" })
    if ([string]::IsNullOrWhiteSpace($userAnswer)) { $userAnswer = $Username }
    if ([string]::IsNullOrWhiteSpace($userAnswer)) {
        Write-Host "  No username supplied." -ForegroundColor Yellow
        return $null
    }

    try {
        $sec = Read-Host -Prompt "  Password" -AsSecureString
    } catch {
        Write-ErrorLog "Secure password prompt unavailable: $($_.Exception.Message)"
        return $null
    }
    if ($null -eq $sec -or $sec.Length -eq 0) { return $null }

    New-Object System.Management.Automation.PSCredential($userAnswer, $sec)
}

function Show-CredentialConfigDialog {
    <#
    .SYNOPSIS Console credential configuration (was a 195-line WPF dialog).
    .DESCRIPTION
    Contract preserved exactly, because callers depend on it:
      * sets $global:UseCustomCredentials and $global:CustomCredentials
      * returns $true when custom credentials were configured, $false when disabled/cancelled
    Offers the same optional connectivity Test the dialog had, so a wrong password is caught
    before it is stored. The password is read with -AsSecureString and never echoed.
    #>
    param()

    Write-Host ""
    Write-Host "  Configure Remote Credentials" -ForegroundColor White
    Write-Host "  ------------------------------------------------------------------" -ForegroundColor DarkGray
    $current = if ($global:UseCustomCredentials) { "enabled" } else { "disabled" }
    Write-Host "  Currently: $current" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [1] Enable custom credentials"
    Write-Host "  [2] Disable custom credentials (use the account running WUU)"
    Write-Host "  [0] Cancel"
    $choice = Read-Host "  Choice"

    switch ($choice.Trim()) {
        "1" { }   # continue to credential entry
        "2" {
            $global:UseCustomCredentials = $false
            $global:CustomCredentials = $null
            Write-Host "  Custom credentials disabled." -ForegroundColor Green
            return $false
        }
        default {
            Write-Host "  Cancelled." -ForegroundColor Yellow
            return $false
        }
    }

    $userAnswer = Read-Host "  Username (domain\user)"
    if ([string]::IsNullOrWhiteSpace($userAnswer)) {
        Write-Host "  No username supplied - leaving credentials unchanged." -ForegroundColor Yellow
        return $false
    }
    try {
        $sec = Read-Host -Prompt "  Password" -AsSecureString
    } catch {
        Write-ErrorLog "Secure password prompt unavailable: $($_.Exception.Message)"
        return $false
    }
    if ($null -eq $sec -or $sec.Length -eq 0) {
        Write-Host "  No password supplied - leaving credentials unchanged." -ForegroundColor Yellow
        return $false
    }

    $cred = New-Object System.Management.Automation.PSCredential($userAnswer, $sec)

    # Optional connectivity probe (the dialog had a Test button).
    $testTarget = Read-Host "  Test against which computer? (Enter to skip the test)"
    if (-not [string]::IsNullOrWhiteSpace($testTarget)) {
        Write-Host "  Testing..." -ForegroundColor Gray
        try {
            $testSession = $null
            try {
                $testSession = New-CimSession -ComputerName $testTarget.Trim() -Credential $cred `
                    -SessionOption (New-CimSessionOption -Protocol DCOM) -ErrorAction Stop
                $null = Get-CimInstance -CimSession $testSession -ClassName Win32_ComputerSystem -ErrorAction Stop
                Write-Host "  Credentials test successful." -ForegroundColor Green
            } finally {
                if ($testSession) { Remove-CimSession -CimSession $testSession -ErrorAction SilentlyContinue }
            }
        } catch {
            Write-Host "  Credentials test FAILED: $($_.Exception.Message)" -ForegroundColor Red
            if (-not (Read-WuuYesNo -Prompt "Save them anyway?" -Default $false)) {
                Write-Host "  Not saved." -ForegroundColor Yellow
                return $false
            }
        }
    }

    $global:CustomCredentials = $cred
    $global:UseCustomCredentials = $true
    Write-Host "  Custom credentials configured for $userAnswer." -ForegroundColor Green
    return $true
}

function Protect-ComputerListData {
    param(
        [string]$Data,
        [SecureString]$Password
    )
    
    try {
        # Convert SecureString password to byte array for encryption key
        $passwordBSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $passwordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($passwordBSTR)
        
        # Create a 256-bit key from the password
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $key = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($passwordPlain))
        
        # Convert data to SecureString without using -AsPlainText
        $secureData = New-Object System.Security.SecureString
        foreach ($ch in $Data.ToCharArray()) { $secureData.AppendChar($ch) }
        $secureData.MakeReadOnly()
        
        # Encrypt the data using the key
        $encryptedData = $secureData | ConvertFrom-SecureString -Key $key
        
        # Clean up
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordBSTR)
        $sha256.Dispose()
        
        return @{ Success = $true; Data = $encryptedData; Error = $null }
    } catch {
        return @{ Success = $false; Data = $null; Error = $_.Exception.Message }
    }
}

function Unprotect-ComputerListData {
    param(
        [string]$EncryptedData,
        [SecureString]$Password
    )
    
    try {
        # Convert SecureString password to byte array for decryption key
        $passwordBSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $passwordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($passwordBSTR)
        
        # Create a 256-bit key from the password
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $key = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($passwordPlain))
        
        # Decrypt the data
        $secureData = $EncryptedData | ConvertTo-SecureString -Key $key
        
        # Convert back to plain text (free the BSTR holding the decrypted plaintext)
        $dataBSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureData)
        $plainText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($dataBSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($dataBSTR)
        
        # Clean up
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordBSTR)
        $sha256.Dispose()
        
        return @{ Success = $true; Data = $plainText; Error = $null }
    } catch {
        return @{ Success = $false; Data = $null; Error = $_.Exception.Message }
    }
}

function Save-ComputerListConfig {
    param(
        [array]$ComputerList,
        [string]$ConfigPath,
        [SecureString]$Password
    )
    
    try {
        # Create configuration object
        $config = @{
            SavedDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            ComputerCount = $ComputerList.Count
            Computers = $ComputerList | ForEach-Object {
                @{
                    Computer = $_.Computer
                    Phase = if ($_.Phase) { $_.Phase } else { "Phase 1" }
                    # Only save computer name and phase - all other status data is temporary
                }
            }
            # Save credential configuration if custom credentials are used
            CredentialConfig = if ($global:UseCustomCredentials) {
                @{
                    Username = $global:CredentialConfig.Username
                    Domain = $global:CredentialConfig.Domain
                }
            } else {
                $null
            }
        }
        
        # Convert to JSON
        $jsonData = $config | ConvertTo-Json -Depth 4
        
        # Encrypt the data
        $encryptResult = Protect-ComputerListData -Data $jsonData -Password $Password
        
        if (-not $encryptResult.Success) {
            throw "Encryption failed: $($encryptResult.Error)"
        }
        
        # Save to file
        $encryptResult.Data | Out-File -FilePath $ConfigPath -Encoding UTF8 -Force
        
        return @{ Success = $true; Error = $null }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Import-ComputerListConfig {
    param(
        [string]$ConfigPath,
        [SecureString]$Password
    )
    
    try {
        if (-not (Test-Path -Path $ConfigPath)) {
            throw "Configuration file not found: $ConfigPath"
        }
        
        # Read encrypted data
        $encryptedData = Get-Content -Path $ConfigPath -Raw
        
        # Decrypt the data
        $decryptResult = Unprotect-ComputerListData -EncryptedData $encryptedData -Password $Password
        
        if (-not $decryptResult.Success) {
            throw "Decryption failed: $($decryptResult.Error)"
        }
        
        # Parse JSON
        $config = $decryptResult.Data | ConvertFrom-Json
        
        return @{ Success = $true; Config = $config; Error = $null }
    } catch {
        return @{ Success = $false; Config = $null; Error = $_.Exception.Message }
    }
}

Export-ModuleMember -Function @('Protect-Credential', 'Unprotect-Credential', 'Get-RemoteCredentials', 'Show-PasswordPrompt', 'Show-CustomCredentialDialog', 'Show-CredentialConfigDialog', 'Protect-ComputerListData', 'Unprotect-ComputerListData', 'Save-ComputerListConfig', 'Import-ComputerListConfig')

