#Requires -Version 5.1
<#
.DESCRIPTION
Credential handling: DPAPI helpers, dialogs, cache/probe, encrypted computer-list config.
#>

# The name a computer list has when the operator did not choose one. A config file holds several named
# lists; a v1 (legacy single-list) file is read AS this name, so "my list" keeps working with no
# migration step and no surprise for an operator who never asked for multiple lists.
$script:WuuDefaultListName = 'default'

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

function Test-WuuPasswordMatch {
    <#
    .SYNOPSIS Compares two passwords. The rule behind the confirm field, in one place so it can be driven.
    .DESCRIPTION
    -ceq, NOT -eq. PowerShell's -eq is case-INSENSITIVE by default, so "Password1" and "password1"
    compare EQUAL and a real typo passes the check - which is exactly the mistake the confirm field
    exists to catch. The values are read back through Marshal because a SecureString holds no raw text
    to compare and .Length counts characters, so a trailing space that differs still matches by length.
    #>
    param(
        [AllowNull()][System.Security.SecureString]$First,
        [AllowNull()][System.Security.SecureString]$Second
    )
    if ($null -eq $First -and $null -eq $Second) { return $true }
    if ($null -eq $First -or $null -eq $Second) { return $false }
    $b1 = [IntPtr]::Zero; $b2 = [IntPtr]::Zero
    try {
        $b1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($First)
        $b2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Second)
        $plain1 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b1)
        $plain2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b2)
        return ($plain1 -ceq $plain2)
    } finally {
        if ($b1 -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1) }
        if ($b2 -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2) }
    }
}

function Confirm-WuuPasswordPrompt {
    <#
    .SYNOPSIS Asks an operator to retype a password they are about to save with (the confirm field).
    .DESCRIPTION
    TYPING A NEW PASSPHRASE TWICE, and refusing on a mismatch, is the only defence against the failure
    this prompt exists to prevent: the file is encrypted as a unit with one passphrase shared by every
    list in it, so a single mistyped character produces a file that opens with neither entry - and a
    file the operator cannot identify, holding lists they can no longer read, is indistinguishable from
    an empty one the next time they load.

    SKIPS ITSELF WHEN IT CANNOT MEAN ANYTHING, and says which case it was. The check is only a check if
    the operator is choosing a passphrase, so it is skipped - rather than guessed at - when the run is
    not an interactive terminal (a scripted run cannot retype anything, and a prompt nobody can answer
    must not be reached), when the file already exists (that passphrase is not being chosen, it is being
    proved, and opening the file below is what proves it), or when there is no password to confirm.

    Each skip returns before any prompting, so a caller can ask its question and get a truthful answer
    without ever blocking - which is also what makes those paths testable.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][System.Security.SecureString]$Password,
        # Whether the target file already exists. The caller decides, because only the caller knows
        # which file it is about to write.
        [switch]$ExistingFile
    )

    if ((Get-WuuInputMode).NonInteractive) {
        return @{ Confirmed = $true; Skipped = $true; Reason = 'not an interactive terminal' }
    }
    if ($ExistingFile) {
        return @{ Confirmed = $true; Skipped = $true; Reason = 'the file exists, so the passphrase is proved by opening it, not chosen' }
    }
    if ($null -eq $Password) {
        return @{ Confirmed = $true; Skipped = $true; Reason = 'there is no passphrase to confirm' }
    }

    Write-Host ""
    $retyped = $null
    try {
        $retyped = _WuuReadPassword -Prompt "  Confirm Password"
    } catch {
        # A confirm prompt must never be the thing that breaks a save. If the console cannot read a
        # second time the save proceeds - the operator still has the password they just typed, and
        # blocking a save on the absence of a check is worse than saving without it and saying so.
        Write-WarningLog "Password confirmation was unavailable: $($_.Exception.Message)"
        return @{ Confirmed = $true; Skipped = $true; Reason = 'the confirm prompt could not be read' }
    }

    $confirmed = Test-WuuPasswordMatch -First $Password -Second $retyped
    if (-not $confirmed) {
        Write-Host "  The two passwords do not match - nothing has been saved." -ForegroundColor Yellow
    }
    return @{ Confirmed = $confirmed; Skipped = $false; Reason = '' }
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
    <#
    .SYNOPSIS
    Saves ONE NAMED computer list into the shared encrypted config file.
    .DESCRIPTION
    THE FILE HOLDS MANY LISTS; THIS CALL WRITES ONE OF THEM.

    WHY THE WHOLE FILE IS DECRYPTED TO ADD A LIST. Lists share a single file, and the file is encrypted
    as a unit, so adding or replacing one list means reading the others out and writing them back. That
    has a consequence the caller must be told about rather than surprised by: EVERY LIST IN THE FILE
    SHARES ONE PASSPHRASE, because there is only one ciphertext. A passphrase that cannot open the file
    cannot add to it, and that is reported (`WrongPassword`) instead of being treated as "no lists yet" -
    silently overwriting five lists because the operator mistyped one character would be the worst
    failure this feature could have.

    BACKWARD COMPATIBLE IN BOTH DIRECTIONS. A v1 file (the legacy single-list shape) is read as a list
    whose name is the default, and the next save writes v2. Nothing is migrated ahead of time, nothing is
    renamed, and the operator's only copy is never rewritten by merely opening the tool.

    Returns a hashtable, never a bare boolean, because "saved", "wrong passphrase" and "unreadable" are
    three different things and the caller reports each differently.
    #>
    param(
        [array]$ComputerList,
        [string]$ConfigPath,
        [SecureString]$Password,
        [string]$ListName = '',
        [switch]$AllowOverwrite
    )

    $resolvedName = if ([string]::IsNullOrWhiteSpace($ListName)) { $script:WuuDefaultListName } else { $ListName.Trim() }

    try {
        # Read what is already there, so the other lists survive this write.
        $existingLists = New-Object System.Collections.ArrayList
        $readNote = ''
        if (Test-Path -LiteralPath $ConfigPath) {
            $read = Read-WuuConfigFile -ConfigPath $ConfigPath -Password $Password
            if (-not $read.Success) {
                return @{ Success = $false; WrongPassword = [bool]$read.WrongPassword; Error = $read.Error }
            }
            foreach ($l in $read.Lists) { [void]$existingLists.Add($l) }
            $readNote = $read.Note
        }

        # Refuse to replace a different list of the same name unless asked. An operator saving "prod"
        # twice should be told they are replacing it, not discover it later.
        $collision = $null
        foreach ($l in $existingLists) { if ([string]$l.Name -ceq $resolvedName) { $collision = $l } }
        if ($collision -and -not $AllowOverwrite) {
            return @{ Success = $false; WrongPassword = $false; Exists = $true
                Error = "a list named '$resolvedName' already exists in this file ($(@($collision.Computers).Count) computer(s)); pass -AllowOverwrite to replace it"
            }
        }

        # Build the replacement list, keeping the order the operator had.
        $newList = @{
            Name         = $resolvedName
            SavedDate    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            ComputerCount = @($ComputerList).Count
            Computers    = @($ComputerList | ForEach-Object {
                    @{
                        Computer = $_.Computer
                        Phase    = if ($_.Phase) { $_.Phase } else { 'Phase 1' }
                        # Only the name and the phase are saved - every other column is transient.
                    }
                })
            # Record the credential MODE this list was saved under (SS6). Identity ONLY - a username and
            # a mode word. No password and nothing derived from one: the file is already encrypted with the
            # operator's passphrase, and adding reversible credential material would widen the blast
            # radius of a weak one.
            CredentialConfig = Get-WuuCredentialStateSignature
        }

        $merged = New-Object System.Collections.ArrayList
        foreach ($l in $existingLists) {
            if ([string]$l.Name -ceq $resolvedName) { [void]$merged.Add($newList) } else { [void]$merged.Add($l) }
        }
        $replaced = $false
        foreach ($l in $existingLists) { if ([string]$l.Name -ceq $resolvedName) { $replaced = $true } }
        if (-not $replaced) { [void]$merged.Add($newList) }

        $config = @{
            Schema    = 'wuu.computerlist.v2'
            SavedDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            Lists     = @($merged)
        }

        $write = Write-WuuConfigFile -ConfigPath $ConfigPath -Config $config -Password $Password
        if (-not $write.Success) { return @{ Success = $false; WrongPassword = $false; Error = $write.Error } }

        return @{ Success = $true; WrongPassword = $false; ListName = $resolvedName; Replaced = $replaced
            ListCount = @($merged).Count; Note = $readNote; Error = $null }
    } catch {
        return @{ Success = $false; WrongPassword = $false; Error = $_.Exception.Message }
    }
}

function Write-WuuConfigFile {
    <#
    .SYNOPSIS Encrypts and writes a config document (SS: computer-list storage). Shared by every writer.
    .DESCRIPTION One place, so the file's encryption and encoding cannot differ between the paths that
    write it. UTF8 WITHOUT a BOM: the payload is a base64-ish encrypted string, and a BOM becomes part of
    the first line a reader must strip.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][SecureString]$Password
    )
    try {
        $dir = Split-Path -Parent $ConfigPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop }
        $jsonData = $Config | ConvertTo-Json -Depth 6
        $encryptResult = Protect-ComputerListData -Data $jsonData -Password $Password
        if (-not $encryptResult.Success) { throw "Encryption failed: $($encryptResult.Error)" }
        [System.IO.File]::WriteAllText($ConfigPath, $encryptResult.Data, (New-Object System.Text.UTF8Encoding($false)))
        return @{ Success = $true; Error = $null }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Read-WuuConfigFile {
    <#
    .SYNOPSIS Decrypts a config document and returns its LISTS, whatever schema version it is.
    .DESCRIPTION
    ONE READER FOR BOTH SHAPES, so no caller has to know which it is holding:

      v2  { Schema = 'wuu.computerlist.v2'; Lists = [ { Name; Computers; ... }, ... ] }
      v1  { SavedDate; ComputerCount; Computers = [ ... ]; CredentialConfig }   <- the legacy single list

    A v1 file becomes ONE list named `$script:WuuDefaultListName`, which is what the operator has always
    called it in practice ("my list"). It is NOT rewritten on read: merely opening the tool must never
    modify the operator's only copy, and a v1 file is upgraded only when they next save.

    Distinguishes a WRONG PASSPHRASE from an unreadable file, because the first is a typo an operator
    fixes and the second is a problem. The underlying decrypt error is the only signal available, so it
    is pattern-matched once, here, rather than at every call site.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][AllowNull()][SecureString]$Password
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return @{ Success = $false; Lists = @(); WrongPassword = $false
            Error = "configuration file not found: $ConfigPath"; Note = '' }
    }

    try {
        $encryptedData = [System.IO.File]::ReadAllText($ConfigPath)
        $decryptResult = Unprotect-ComputerListData -EncryptedData $encryptedData -Password $Password
        if (-not $decryptResult.Success) {
            $msg = [string]$decryptResult.Error
            # The AES/SecureString layer reports a bad key as an invalid padding/format error. Naming it
            # "wrong passphrase" is what lets the caller say something actionable instead of relaying a
            # cryptographic message to an operator who only mistyped.
            $wrong = ($msg -match 'padding|invalid|corrupt|key|length|format') -and
                ($msg -notmatch 'file not found|being used by another process')
            return @{ Success = $false; Lists = @(); WrongPassword = $wrong; Error = "decryption failed: $msg"; Note = '' }
        }

        $config = $decryptResult.Data | ConvertFrom-Json
        $lists = New-Object System.Collections.ArrayList
        $note = ''

        $isV2 = ($config.PSObject.Properties['Lists'])
        if ($isV2) {
            foreach ($l in @($config.Lists)) {
                if ($null -eq $l) { continue }
                [void]$lists.Add([pscustomobject]@{
                        Name             = $(if ($l.PSObject.Properties['Name'] -and $l.Name) { [string]$l.Name } else { $script:WuuDefaultListName })
                        SavedDate        = $(if ($l.PSObject.Properties['SavedDate']) { [string]$l.SavedDate } else { '' })
                        ComputerCount    = @($l.Computers).Count
                        Computers        = @($l.Computers)
                        CredentialConfig = $(if ($l.PSObject.Properties['CredentialConfig']) { $l.CredentialConfig } else { $null })
                    })
            }
            if ($lists.Count -eq 0) { $note = 'the configuration file holds no lists yet'; }
        } else {
            # v1: the legacy single list. Treated as a list named for the default, and NOT rewritten.
            [void]$lists.Add([pscustomobject]@{
                    Name             = $script:WuuDefaultListName
                    SavedDate        = $(if ($config.PSObject.Properties['SavedDate']) { [string]$config.SavedDate } else { '' })
                    ComputerCount    = @($config.Computers).Count
                    Computers        = @($config.Computers)
                    CredentialConfig = $(if ($config.PSObject.Properties['CredentialConfig']) { $config.CredentialConfig } else { $null })
                })
            $note = "this file uses the older single-list format; it is read as the '$($script:WuuDefaultListName)' list and will be upgraded the next time you save"
        }

        return @{ Success = $true; Lists = @($lists.ToArray()); WrongPassword = $false; Error = $null; Note = $note
            IsLegacy = (-not $isV2)
        }
    } catch {
        return @{ Success = $false; Lists = @(); WrongPassword = $false; Error = $_.Exception.Message; Note = '' }
    }
}

function Get-WuuComputerListNames {
    <#
    .SYNOPSIS The list names held in a config file, for an onscreen chooser. Never throws.
    .DESCRIPTION
    Returns @() when the file is missing or the passphrase will not open it, so a caller can present
    "nothing to load" rather than an error. Never throws: this drives a menu, and a menu that crashes on
    a stale file is worse than one that reports an empty result.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][AllowNull()][SecureString]$Password
    )
    $read = Read-WuuConfigFile -ConfigPath $ConfigPath -Password $Password
    if (-not $read.Success) { return @() }
    return @($read.Lists | ForEach-Object { [string]$_.Name })
}

function Import-ComputerListConfig {
    <#
    .SYNOPSIS
    Reads a config file and returns the lists it holds - all of them, or one named one.
    .DESCRIPTION
    Returns the LISTS rather than a flat computer array, because a file can now hold several and the
    caller has to choose. `-ListName` selects one; omitting it returns every list, and callers that only
    ever wanted the single legacy list still get it (as the default-named list) without knowing which
    format they are reading.

    `$Config` is kept as a FLAT VIEW of the selected list (SavedDate, ComputerCount, Computers,
    CredentialConfig) so existing callers keep working unchanged - the multi-list support is additive.
    When no name is given and several lists exist, `$Config` reflects the FIRST, and `$Lists` carries them
    all so a caller can prompt.
    #>
    param(
        [string]$ConfigPath,
        [SecureString]$Password,
        [string]$ListName = ''
    )

    $read = Read-WuuConfigFile -ConfigPath $ConfigPath -Password $Password
    if (-not $read.Success) {
        return @{ Success = $false; Config = $null; Lists = @(); WrongPassword = [bool]$read.WrongPassword; Error = $read.Error }
    }

    $selected = $read.Lists
    if (-not [string]::IsNullOrWhiteSpace($ListName)) {
        $wanted = $ListName.Trim()
        $hits = @($read.Lists | Where-Object { [string]$_.Name -ceq $wanted })
        if ($hits.Count -eq 0) {
            $available = @($read.Lists | ForEach-Object { [string]$_.Name }) -join ', '
            return @{ Success = $false; Config = $null; Lists = @(); WrongPassword = $false
                Error = "no list named '$wanted' in this file (it holds: $available)"
            }
        }
        $selected = @($hits[0])
    }

    $first = if (@($selected).Count -gt 0) { @($selected)[0] } else { $null }
    return @{
        Success       = $true
        Config        = $first
        Lists         = @($read.Lists)
        IsLegacy      = [bool]$read.IsLegacy
        Note          = $read.Note
        WrongPassword = $false
        Error         = $null
    }
}

function New-WuuComputerListPrompt {
    <#
    .SYNOPSIS Presents a numbered menu of list names and returns the chosen name (console edition).
    .DESCRIPTION
    THE ONSCREEN CHOOSER. Given the names in a file, it renders them and returns the operator's choice.
    Returns '' when they cancel, and the SINGLE name without asking when only one exists - a prompt with
    one option is friction with no decision in it.

    All input goes through Read-WuuAnswer (the project's single choke point), so this works in a scripted
    run: with -NonInteractive the queued answer or the -Default is used, and there is no way for it to
    block. A number, an exact name, or an unambiguous prefix are all accepted, because an operator
    reading a menu will type whichever of the three is in their head.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Names
    )

    $list = @($Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($list.Count -eq 0) { return '' }
    if ($list.Count -eq 1) {
        Write-Host ("  Only one list in this file: {0}" -f $list[0]) -ForegroundColor DarkGray
        return $list[0]
    }

    Write-Host ''
    Write-Host '  Saved computer lists:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $list.Count; $i++) {
        Write-Host ("    [{0}] {1}" -f ($i + 1), $list[$i])
    }
    $ans = Read-WuuAnswer -Prompt '  Load which list? (number or name, Enter to cancel)' -Default ''
    if ([string]::IsNullOrWhiteSpace($ans)) { return '' }
    $ans = ([string]$ans).Trim()

    if ($ans -match '^\d+$') {
        $idx = [int]$ans
        if ($idx -ge 1 -and $idx -le $list.Count) { return $list[$idx - 1] }
        Write-Host ("  No list numbered '{0}'." -f $ans) -ForegroundColor Yellow
        return ''
    }

    foreach ($n in $list) { if ($n -ceq $ans) { return $n } }
    $prefix = @($list | Where-Object { $_ -like "$ans*" })
    if ($prefix.Count -eq 1) { return $prefix[0] }
    if ($prefix.Count -gt 1) {
        Write-Host ("  '{0}' is ambiguous: {1}" -f $ans, ($prefix -join ', ')) -ForegroundColor Yellow
    } else {
        Write-Host ("  No list named '{0}'." -f $ans) -ForegroundColor Yellow
    }
    return ''
}

Export-ModuleMember -Function @('Protect-Credential', 'Unprotect-Credential', 'Get-RemoteCredentials', 'Resolve-WuuOperationCredential', 'Update-WuuCredentialEpoch', 'Show-PasswordPrompt', 'Confirm-WuuPasswordPrompt', 'Test-WuuPasswordMatch', 'Show-CustomCredentialDialog', 'Show-CredentialConfigDialog', 'Protect-ComputerListData', 'Unprotect-ComputerListData', 'Save-ComputerListConfig', 'Import-ComputerListConfig', 'Get-WuuComputerListNames', 'Read-WuuConfigFile', 'Write-WuuConfigFile', 'New-WuuComputerListPrompt', 'Get-WuuCredentialStateSignature', 'Test-WuuCredentialStateMatches')

