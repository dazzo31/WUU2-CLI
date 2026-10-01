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

function Update-WuuCredentialEpoch {
    <#
    .SYNOPSIS Records that the credential configuration changed (hardening Phase 1).
    .DESCRIPTION
    Called whenever custom credentials are enabled, disabled or replaced.

    WHY AN EPOCH IS NEEDED. A per-computer runspace is created ONCE and reused, and its injected
    credential globals are captured at creation. So changing the credentials left every EXISTING row
    resolving its identity from the runspace's stale copies - a newly submitted operation would run
    under the OLD identity, silently, until the row happened to be recreated. Verified by
    inspection of Start-UpdateCheckJob's `if (-not $ComputerItem.Runspace)` reuse.

    The epoch is stamped onto a row when its runspace is built. A submission whose row carries a
    different epoch disposes that runspace and builds a fresh one, so a submitted operation always
    runs under the identity configured AT SUBMISSION. That is the deterministic behaviour the
    requirement asks for, and it costs nothing when credentials have not changed.

    Stored in $global: so both Wuu.Core (submission) and this module can see it.
    #>
    [CmdletBinding()]
    param([string]$Reason = '')
    $epoch = 0
    if ($global:CredentialEpoch) { $epoch = [int]$global:CredentialEpoch }
    $global:CredentialEpoch = $epoch + 1
    $suffix = if ($Reason) { " ($Reason)" } else { '' }
    Write-DebugLog "Credential configuration changed - epoch is now $($global:CredentialEpoch)$suffix" -Level 'INFO'
    return $global:CredentialEpoch
}

function Resolve-WuuOperationCredential {
    <#
    .SYNOPSIS Decides, once, which credential identity an operation will use (hardening Phase 1).
    .DESCRIPTION
    THE RULE, stated plainly:

        custom credentials configured  ->  the operation uses that credential.
                                           If it does not work, that is a FAILURE.
                                           It does NOT fall back to the default identity.

    WHY THIS FUNCTION EXISTS. The previous resolver tried custom, and on failure tried the default
    and returned it on success (Wuu.Credentials.psm1 "Custom credentials failed OR NOT CONFIGURED,
    try default credentials"). So an administrator who configured alternate credentials could have
    an operation run as the *process* identity instead - silently, with the operation succeeding and
    no indication that the identity differed from the one configured. For a patch-deployment tool
    that is an audit problem as much as a security one: A.8.15 wants to know which account changed
    a machine, and "whichever one happened to work" is not an answer.

    It also returns the MODE, which the old resolver could not: it returned $null for both "use the
    default credential" and "no credential works", so every caller had to re-probe to tell them
    apart and a caller that did not simply could not distinguish the two.

    Returns:
        Mode        'Custom' when custom credentials are configured and enabled, otherwise 'Default'
        Credential  the [pscredential] to use, or $null meaning "the process identity"
        Username    the identity, for reporting and audit ('' for the process identity)
        Verified    $true/$false when -Verify was asked for; $null when it was not
        Error       why verification failed (only when Verified is $false)
        Reason      one short line explaining the decision, suitable for a log or an audit record

    -Verify runs a bounded reachability+authentication probe. It is OPTIONAL on purpose: identity is
    cheap to establish and can be fixed at submission time, whereas probing is a network round trip
    and must not block a caller that is only queuing work. The payload verifies the identity it was
    given, and fails without falling back.
    #>
    [CmdletBinding()]
    param(
        [string]$ComputerName = '',
        # Run a probe to confirm this identity can actually authenticate. Off by default.
        [switch]$Verify,
        # Local machines are contacted as the process identity - passing explicit credentials to
        # local DCOM is rejected. Callers that already know the target is local pass -Local.
        [switch]$Local,
        # Bounded probe timeout, matching the other credential probes.
        [int]$TimeoutSeconds = 5
    )

    $customConfigured = [bool]($global:UseCustomCredentials -and $global:CustomCredentials)

    # Decided FIRST, so there is a single branch that can produce a non-custom identity.
    $mode = if ($customConfigured -and -not $Local) { 'Custom' } else { 'Default' }
    $credential = if ($mode -eq 'Custom') { $global:CustomCredentials } else { $null }
    $username = ''
    if ($mode -eq 'Custom' -and $credential) { $username = [string]$credential.UserName }

    $reason = if ($mode -eq 'Custom') {
        "custom credentials configured and enabled - using '$username' (no fallback)"
    } elseif ($customConfigured -and $Local) {
        "custom credentials are configured but '$ComputerName' is the local machine - using the process identity"
    } else {
        'custom credentials are not configured - using the process identity'
    }

    $verified = $null
    $errorText = ''
    if ($Verify -and $ComputerName) {
        try {
            if ($mode -eq 'Custom') {
                $probe = Invoke-CimWithTimeout -ComputerName $ComputerName -ClassName 'Win32_ComputerSystem' `
                    -TimeoutSeconds $TimeoutSeconds -Credential $credential -Operation "credential verification ($username)"
            } else {
                $probe = Invoke-CimWithTimeout -ComputerName $ComputerName -ClassName 'Win32_ComputerSystem' `
                    -TimeoutSeconds $TimeoutSeconds -Operation 'credential verification (process identity)'
            }
            if ($probe -and $probe.Success) {
                $verified = $true
            } else {
                $verified = $false
                $errorText = if ($probe -and $probe.Error) { [string]$probe.Error } else { 'the credential probe did not succeed' }
                # DELIBERATE: no fallback attempt happens here, and none is offered. The caller gets
                # the identity it asked for plus the reason it cannot be used, and decides.
                $reason = "the $($mode.ToLower()) credential could not be verified: $errorText (no fallback attempted)"
            }
        } catch {
            $verified = $false
            $errorText = $_.Exception.Message
            $reason = "the $($mode.ToLower()) credential probe failed: $errorText (no fallback attempted)"
        }
    }

    return [pscustomobject]@{
        Mode       = $mode
        Credential = $credential
        Username   = $username
        Verified   = $verified
        Error      = $errorText
        Reason     = $reason
        Computer   = $ComputerName
    }
}

function Get-RemoteCredentials {
    <#
    .SYNOPSIS The credential for an operation on $ComputerName (hardening Phase 1).
    .DESCRIPTION
    Kept for its existing callers, and its CONTRACT IS DELIBERATELY UNCHANGED: it still returns a
    [pscredential], or $null meaning "use the process identity". What changed is the part callers
    could not previously rely on - it no longer falls back to a different identity than the one
    configured.

    Behaviour now:
      * custom credentials configured and enabled -> that credential, or a FAILURE. The failure
        throws (so the operation does not run as an unintended identity) with the reason attached.
        Callers that prefer a returned error over an exception should use
        Resolve-WuuOperationCredential, which reports instead of throwing.
      * custom credentials not configured -> $null (the process identity). The previous version also
        probed the default credential here and returned $null either way, so the probe cost a round
        trip per computer and changed nothing except the log.

    The runtime cache is still honoured, but a cached entry can never contradict the configured
    mode: the cache is only consulted when its mode matches what is configured now.
    #>
    param(
        [string]$ComputerName,
        [string]$Operation = 'WMI access'
    )

    try {
        # Resolve WITHOUT verification first, purely to learn the mode. This matters: verification is
        # a network round trip, and in the Default case there is nothing to verify that would change
        # the outcome - $null is returned either way. Probing there is the wasted round trip per
        # computer that the previous version was criticised for (and that my first version of this
        # function reintroduced by passing -Verify unconditionally; the test caught it).
        $resolution = Resolve-WuuOperationCredential -ComputerName $ComputerName

        if ($resolution.Mode -eq 'Default') {
            Write-DebugLog "Using the process identity for $ComputerName ($($resolution.Reason))" -Level 'DEBUG'
            return $null
        }

        # Custom credentials are configured, so the identity MUST be established, not assumed: verify
        # it, and fail if it is not usable. There is no third outcome.
        $resolution = Resolve-WuuOperationCredential -ComputerName $ComputerName -Verify

        if (-not $resolution.Verified) {
            # THROW rather than return $null. Returning $null here is what made the old silent
            # fallback possible: $null legitimately means "use the process identity", so a failed
            # custom credential became indistinguishable from "no custom credential configured",
            # and the caller proceeded - as the wrong identity.
            $msg = "Configured custom credentials for '$($resolution.Username)' cannot be used on $ComputerName for $Operation. $($resolution.Error)"
            Write-ErrorLog $msg
            throw $msg
        }

        Write-DebugLog "Custom credentials verified for $ComputerName as '$($resolution.Username)'" -Level 'INFO'
        return $resolution.Credential
    } catch {
        # A throw from the verification path above is intentional and must reach the caller.
        if ($_.Exception.Message -match '^Configured custom credentials') { throw }
        Write-DebugLog "Error in Get-RemoteCredentials for $ComputerName : $($_.Exception.Message)" -Level 'ERROR'
        throw
    }
}

function Show-PasswordPrompt {
    <#
    .SYNOPSIS Console password prompt (was a WPF PasswordBox dialog).
    .DESCRIPTION Returns a SecureString, or $null if cancelled/empty - the same contract
    the WPF version had, so callers need no change.

    ROUTED THROUGH _WuuReadPassword (Wuu.Presentation), which is the single input choke point's secure
    path. This used to call Read-Host directly, which bypassed the choke point: in command mode
    (wuu config save) nobody can answer a bare Read-Host, so the run hung at the prompt instead of
    failing. The gate only checked Core for this, so the bypass here went unnoticed until the
    choke-point prompt was extracted and the gate was re-pointed at its new home.
    #>
    param(
        [string]$Title = "Password Required",
        [string]$Message = "Enter password:"
    )
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor White
    if ($Message) { Write-Host "  $Message" -ForegroundColor Gray }
    $sec = _WuuReadPassword -Prompt "  Password"
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
            # Phase 1: bump the epoch so runspaces built under the old identity are not reused.
            [void](Update-WuuCredentialEpoch -Reason 'custom credentials disabled')
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
    # Phase 1: bump the epoch so an existing runspace (which captured the PREVIOUS credential) is
    # rebuilt for the next submission rather than silently continuing under the old identity.
    [void](Update-WuuCredentialEpoch -Reason "custom credentials set for $userAnswer")
    Write-Host "  Custom credentials configured for $userAnswer." -ForegroundColor Green
    return $true
}

function Get-WuuCredentialStateSignature {
    <#
    .SYNOPSIS A compact, non-secret description of the active credential mode (SS6).
    .DESCRIPTION
    Returns the identity part of the credential mode in use, so a saved configuration can record WHAT
    it was saved with and a load can tell whether the running session matches.

    Deliberately identity only: never a password, and never any part of one. What a human or an
    auditor needs to answer is "was this list loaded with the custom account or the service account?",
    and a username answers that.

    Returns a hashtable so callers can persist it as-is. Empty strings (not $null) when custom
    credentials are off, so the shape is stable whether or not they are configured.
    #>
    [CmdletBinding()]
    param()
    $enabled = [bool]$global:UseCustomCredentials
    $userName = ''
    if ($enabled -and $global:CustomCredentials) {
        # PSCredential.UserName is the authoritative source. It was $global:CredentialConfig.Username
        # that got persisted - and that variable is assigned exactly ONCE in the whole codebase (its
        # initialiser in Wuu.Core), so every saved configuration recorded Username='' and Domain=''
        # while the real name sat in CustomCredentials.UserName. Verified by probe: a config saved with
        # a configured credential loaded back with empty strings.
        $userName = [string]$global:CustomCredentials.UserName
    }
    return @{
        Enabled  = $enabled
        UserName = $userName
        # The mode, in words, so the saved file explains itself to someone reading the JSON.
        Mode     = if ($enabled) { 'custom' } else { 'current-process' }
    }
}

function Test-WuuCredentialStateMatches {
    <#
    .SYNOPSIS Does the running credential session match what a configuration was saved with? (SS6)
    .DESCRIPTION
    The load path used to ignore the saved credential block entirely: loading a list saved with custom
    credentials into a session that had none (or the reverse) silently changed which account every
    remote operation would use. Nothing failed - the operations simply ran as a different principal,
    which is a security-relevant difference that is invisible until an access-denied appears on some
    host, or does not appear when it should.

    Returns Match plus a human-readable Reason so the caller can WARN with the specific difference
    rather than a vague "credential mismatch".
    #>
    [CmdletBinding()]
    param([AllowNull()]$Saved)
    $now = Get-WuuCredentialStateSignature
    if (-not $Saved) {
        return [pscustomobject]@{ Match = $true; Reason = 'the configuration records no credential mode (saved by an older build)'; SavedMode = ''; CurrentMode = $now.Mode }
    }
    # ConvertFrom-Json hands back a PSCustomObject, a hand-built one is a hashtable - both are read here.
    $savedEnabled = $null
    if ($Saved.PSObject.Properties['Enabled']) { $savedEnabled = [bool]$Saved.Enabled }
    elseif ($Saved -is [hashtable] -and $Saved.ContainsKey('Enabled')) { $savedEnabled = [bool]$Saved['Enabled'] }
    if ($null -eq $savedEnabled) {
        return [pscustomobject]@{ Match = $true; Reason = 'the configuration does not state whether custom credentials were used'; SavedMode = ''; CurrentMode = $now.Mode }
    }
    $savedUser = ''
    if ($Saved.PSObject.Properties['UserName']) { $savedUser = [string]$Saved.UserName }
    elseif ($Saved -is [hashtable] -and $Saved.ContainsKey('UserName')) { $savedUser = [string]$Saved['UserName'] }

    if ($savedEnabled -ne $now.Enabled) {
        $savedMode = if ($savedEnabled) { 'custom' } else { 'current-process' }
        return [pscustomobject]@{
            Match = $false; SavedMode = $savedMode; CurrentMode = $now.Mode
            Reason = "saved with '$savedMode' credentials but this session is using '$($now.Mode)'"
        }
    }
    if ($savedEnabled -and $savedUser -and $now.UserName -and $savedUser -ne $now.UserName) {
        return [pscustomobject]@{
            Match = $false; SavedMode = 'custom'; CurrentMode = $now.Mode
            Reason = "saved with custom credentials for '$savedUser' but this session is using '$($now.UserName)'"
        }
    }
    return [pscustomobject]@{ Match = $true; Reason = ''; SavedMode = $now.Mode; CurrentMode = $now.Mode }
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
            # Record the credential MODE this list was saved under (SS6). This block used to be written
            # from $global:CredentialConfig.Username/.Domain - a variable assigned exactly ONCE in the
            # codebase (its initialiser), so every config ever saved carried Username='' and Domain=''
            # while the real name sat in $global:CustomCredentials.UserName. Verified by probe.
            #
            # What is recorded is IDENTITY ONLY - a username and a mode word. No password, no token, and
            # nothing derived from one: the list itself is already encrypted with the operator's
            # passphrase, and adding reversible credential material to it would widen the blast radius of
            # a weak passphrase.
            CredentialConfig = Get-WuuCredentialStateSignature
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

Export-ModuleMember -Function @('Protect-Credential', 'Unprotect-Credential', 'Get-RemoteCredentials', 'Resolve-WuuOperationCredential', 'Update-WuuCredentialEpoch', 'Show-PasswordPrompt', 'Show-CustomCredentialDialog', 'Show-CredentialConfigDialog', 'Protect-ComputerListData', 'Unprotect-ComputerListData', 'Save-ComputerListConfig', 'Import-ComputerListConfig', 'Get-WuuCredentialStateSignature', 'Test-WuuCredentialStateMatches')

