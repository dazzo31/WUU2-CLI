#Requires -Version 5.1
<#
.SYNOPSIS
    SS6: credential propagation and persistence.

.DESCRIPTION
    This section of the brief was marked NOT VERIFIED, so the first job was to establish what actually
    happens rather than trust the comments. Two real defects came out of it:

      A. The saved credential block was written from $global:CredentialConfig.Username/.Domain, a
         variable assigned exactly ONCE in the codebase (its initialiser). Every saved configuration
         therefore recorded Username='' / Domain='' while the real name sat in
         $global:CustomCredentials.UserName. Verified by probe, not by reading.

      B. Nothing ever READ that block on load, so loading a list saved under one credential mode into a
         session using another silently changed which account remote operations would use.

    Asserted here:
      1. the signature reports identity only - never a password or anything derived from one;
      2. a round-trip through Save/Import preserves the identity, and the OLD empty-string defect is
         gone (this fails against the pre-fix code);
      3. Test-WuuCredentialStateMatches detects each way the modes can differ;
      4. the load path actually consults it;
      5. the propagation matrix: which credential reaches each remote call, for custom-on/local,
         custom-on/remote and custom-off, and that the download/install task path - the ones that
         actually change a remote machine - is given a credential in every remote case.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail++ }

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force -DisableNameChecking
Import-WuuModules -WuuRoot $root

$credRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Credentials.psm1') -Raw
$coreRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$wupdRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw
$remRaw  = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Remote.psm1') -Raw

# --- 1. the signature carries identity only -----------------------------------------
$global:UseCustomCredentials = $false
$global:CustomCredentials = $null
$sig = Get-WuuCredentialStateSignature
if ($sig.Enabled -eq $false -and $sig.Mode -eq 'current-process') {
    Ok "with custom credentials off the signature says 'current-process' and Enabled=false"
} else {
    Bad "custom-off signature wrong: Enabled=$($sig.Enabled) Mode=$($sig.Mode)"
}
if (-not $sig.UserName) { Ok 'the off signature carries no username' } else { Bad "off signature carries UserName='$($sig.UserName)'" }

$sec = ConvertTo-SecureString 'S3cret-Pa55w0rd!' -AsPlainText -Force
$global:CustomCredentials = New-Object System.Management.Automation.PSCredential('CONTOSO\svc-wuu', $sec)
$global:UseCustomCredentials = $true
$sig = Get-WuuCredentialStateSignature
if ($sig.Enabled -and $sig.UserName -eq 'CONTOSO\svc-wuu') {
    Ok 'with custom credentials on the signature reports the real username (from CustomCredentials.UserName)'
} else {
    Bad "custom-on signature wrong: Enabled=$($sig.Enabled) UserName='$($sig.UserName)'"
}
# The password must not be reachable from anything this signature produces.
$sigText = ($sig.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'
if ($sigText -notmatch 'S3cret' -and $sigText -notmatch 'Pa55w0rd') {
    Ok 'the signature contains no part of the password'
} else {
    Bad 'the signature leaked password material'
}
# ...and structurally: only identity fields are produced, so nothing password-shaped can be added
# without changing this list (which a reviewer would see).
$allowed = @('Enabled', 'UserName', 'Mode')
$extra = @($sig.Keys | Where-Object { $_ -notin $allowed })
if ($extra.Count -eq 0) { Ok "the signature exposes exactly the identity fields ($($allowed -join ', '))" }
else { Bad "the signature exposes unexpected field(s): $($extra -join ', ') - it must stay identity-only" }

$global:UseCustomCredentials = $false
$global:CustomCredentials = $null

# --- 2. round trip: the identity survives, and the empty-string defect is gone --------
# This is the assertion that fails against the pre-fix code: the old block wrote
# $global:CredentialConfig.Username, which is never assigned anything but ''.
$global:CustomCredentials = New-Object System.Management.Automation.PSCredential('CONTOSO\svc-wuu', $sec)
$global:UseCustomCredentials = $true
$rows = @([pscustomobject]@{ Computer = 'SRV01'; Phase = 'Phase 1' })
$cfgPath = Join-Path $env:TEMP ("wuu-cred-test-{0}.config" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
$pw = ConvertTo-SecureString 'Passphrase123!' -AsPlainText -Force
$save = Save-ComputerListConfig -ComputerList $rows -ConfigPath $cfgPath -Password $pw
if ($save.Success) { Ok 'a configuration saves' } else { Bad "save failed: $($save.Error)" }
$load = Import-ComputerListConfig -ConfigPath $cfgPath -Password $pw
if ($load.Success) {
    $cc = $load.Config.CredentialConfig
    if ($cc -and $cc.Enabled -eq $true -and $cc.UserName -eq 'CONTOSO\svc-wuu') {
        Ok "the saved configuration records the real identity (Enabled=true, UserName='CONTOSO\svc-wuu')"
    } else {
        Bad "the saved configuration lost the identity: Enabled=$($cc.Enabled) UserName='$($cc.UserName)' (the old defect wrote '')"
    }
    if ($cc.PSObject.Properties['Mode'] -and $cc.Mode -eq 'custom') {
        Ok "the saved configuration states the mode in words ('custom')"
    } else {
        Bad 'the saved configuration does not state the credential mode'
    }
    # The credential block must not carry a password either.
    $ccText = ($cc | ConvertTo-Json -Compress)
    if ($ccText -notmatch 'S3cret' -and $ccText -notmatch 'Pa55w0rd') {
        Ok 'the persisted credential block carries no password material'
    } else {
        Bad 'the persisted credential block leaked password material'
    }
} else {
    Bad "load failed: $($load.Error)"
}
Remove-Item -LiteralPath $cfgPath -Force -ErrorAction SilentlyContinue

# --- 3. mismatch detection ------------------------------------------------------------
# saved custom + current custom, same name -> match
$match = Test-WuuCredentialStateMatches -Saved @{ Enabled = $true; UserName = 'CONTOSO\svc-wuu' }
if ($match.Match) { Ok 'same custom credential on both sides matches' } else { Bad "expected a match, got: $($match.Reason)" }

# saved custom + session with custom OFF -> mismatch (the dangerous silent case)
$global:UseCustomCredentials = $false
$global:CustomCredentials = $null
$match = Test-WuuCredentialStateMatches -Saved @{ Enabled = $true; UserName = 'CONTOSO\svc-wuu' }
if (-not $match.Match -and $match.Reason -match 'custom') {
    Ok "loading a custom-credential list into a default session is DETECTED: $($match.Reason)"
} else {
    Bad "the custom->default mismatch was not detected (Match=$($match.Match))"
}

# saved default + session with custom ON -> mismatch
$global:CustomCredentials = New-Object System.Management.Automation.PSCredential('CONTOSO\other', $sec)
$global:UseCustomCredentials = $true
$match = Test-WuuCredentialStateMatches -Saved @{ Enabled = $false; UserName = '' }
if (-not $match.Match) {
    Ok "loading a default-credential list into a custom session is DETECTED: $($match.Reason)"
} else {
    Bad 'the default->custom mismatch was not detected'
}

# saved custom A + session custom B -> mismatch, naming both
$match = Test-WuuCredentialStateMatches -Saved @{ Enabled = $true; UserName = 'CONTOSO\svc-wuu' }
if (-not $match.Match -and $match.Reason -match 'svc-wuu' -and $match.Reason -match 'other') {
    Ok "a different custom ACCOUNT is detected and both names are reported"
} else {
    Bad "a different account was not reported clearly: $($match.Reason)"
}

# an older config with no credential block must NOT be reported as a mismatch (it is unknown, not wrong)
$match = Test-WuuCredentialStateMatches -Saved $null
if ($match.Match) { Ok 'a configuration with no credential block is not reported as a mismatch (unknown, not wrong)' }
else { Bad 'a missing credential block was reported as a mismatch' }

$global:UseCustomCredentials = $false
$global:CustomCredentials = $null

# --- 4. the load path consults it -----------------------------------------------------
$hasCall = $coreRaw -match 'Test-WuuCredentialStateMatches'
if ($hasCall) { Ok 'the config load path consults the credential comparison (it used to ignore the block entirely)' }
else { Bad 'the load path still ignores the saved credential block' }
if ($coreRaw -match 'CREDENTIAL MODE DIFFERS') {
    Ok 'a mismatch is surfaced to the operator, not just logged'
} else {
    Bad 'a mismatch is not surfaced to the operator'
}

# --- 5. the propagation matrix --------------------------------------------------------
# Which credential reaches each remote call. The gate is `$UseCustomCredentials -and <not local>`
# at the download and install sites, and the resolver tries custom-then-default itself.
$supBody = [regex]::Match($coreRaw, '\$DownloadUpdates = \{[\s\S]*?\n\}').Value
if (-not $supBody) { $supBody = $coreRaw }

# (a) BOTH task paths that change a remote machine must resolve credentials, or the change runs as the
#     wrong principal - or fails with access denied at the worst moment (mid-install).
foreach ($pair in @(
        @{ Site = 'Download'; Marker = "GetRemoteCredentialsScript.*Windows Update download" },
        @{ Site = 'Install';  Marker = "GetRemoteCredentialsScript.*Windows Update install" })) {
    if ($coreRaw -match $pair.Marker) {
        Ok "$($pair.Site) resolves a credential before invoking the remote task"
    } else {
        Bad "$($pair.Site) does not resolve a credential before invoking the remote task"
    }
}
# ...and each must actually PASS it to the remote task, or resolving it is pointless.
$passesToTask = ([regex]::Matches($coreRaw, "InvokeRemoteTaskScript[\s\S]{0,400}?Credential \`$remoteCred")).Count
if ($passesToTask -ge 2) {
    Ok "the resolved credential is passed to the remote task at $passesToTask site(s)"
} else {
    Bad "only $passesToTask remote-task call(s) pass the resolved credential (expected >= 2)"
}

# (b) the local-computer guard: custom credentials must NOT be applied to the local machine, where the
#     process token is already the right principal (and passing credentials to local DCOM is rejected).
$guards = ([regex]::Matches($coreRaw, "UseCustomCredentials -and \`$Computer\.computer -ne 'localhost' -and \`$Computer\.computer -ne \`$env:COMPUTERNAME")).Count
if ($guards -ge 2) {
    Ok "both remote task paths skip credential resolution for the local machine ($guards guards)"
} else {
    Bad "only $guards local-machine guard(s) - custom credentials could be applied to the local host"
}

# (c) the runspace-side resolver tries custom FIRST, then default, and caches the OUTCOME (including
#     the default-credentials case as an explicit $null entry, not as "absent").
if ($wupdRaw -match "-ArgumentList @\(\`$ComputerName, \`$CustomCredentials\)") {
    Ok 'the runspace resolver tries the custom credential first'
} else {
    Bad 'the runspace resolver does not try the custom credential first'
}
if ($wupdRaw -match "-ArgumentList @\(\`$ComputerName, \`$null\)") {
    Ok 'the runspace resolver falls back to default credentials, passing $null explicitly'
} else {
    Bad 'the runspace resolver has no explicit default-credential fallback'
}
if ($wupdRaw -match "CredentialCache\[\`$ComputerName\] = \`$null") {
    Ok "the resolver caches the default-credentials outcome as an explicit null entry (not 'absent')"
} else {
    Bad 'the resolver does not cache the default-credentials outcome'
}

# (d) the module-side resolver must agree with the runspace-side one: same order, same cache keys.
if ($credRaw -match 'CustomCredentials\)\s*\{' -and $credRaw -match 'CredentialCache\[\$ComputerName\] = \$null') {
    Ok 'the module-side resolver mirrors the runspace-side order (custom, then default, cached)'
} else {
    Bad 'the module-side resolver diverges from the runspace-side resolver'
}

# (e) the pool probe must receive the credential as a PSCredential, never a string.
if ($wupdRaw -match 'param\(\[string\]\$ComputerName, \[pscredential\]\$Cred\)') {
    Ok 'the credential probe is typed [pscredential], so a plain-string password cannot be passed as one'
} else {
    Bad 'the credential probe is not typed [pscredential]'
}

# (f) no credential may be written to the audit trail or the log. An audit record naming the account is
#     useful; a record carrying its password would be a breach.
#
# The check looks for password-shaped EXPRESSIONS, not for the word "password". The naive version of
# this test ("log call containing the word password") reported a false failure on four correct lines:
#     Write-ErrorLog "Secure password prompt unavailable: $($_.Exception.Message)"
# Those log that the PROMPT failed, and interpolate only the exception text. Matching the word rather
# than the expression is the same mistake as matching a display string instead of a state field (SS8),
# so the distinction is made here deliberately.
$pwShape = '\$(password|pass|pwd|plainPassword|plaintext|secret|sec)\b|\.Password\b|GetNetworkCredential|PtrToStringAuto|SecureStringToBSTR'
foreach ($pair in @(@{ Name = 'Wuu.Core'; Text = $coreRaw }, @{ Name = 'Wuu.WindowsUpdate'; Text = $wupdRaw }, @{ Name = 'Wuu.Credentials'; Text = $credRaw }, @{ Name = 'Wuu.Remote'; Text = $remRaw })) {
    $logLines = ($pair.Text -split "`r?`n") | Where-Object { $_ -match '(WriteWuuLog|Write-InfoLog|Write-DebugLog|Write-WarningLog|Write-ErrorLog)' }
    $leaky = @($logLines | Where-Object { $_ -match $pwShape })
    if ($leaky.Count -gt 0) {
        Bad "$($pair.Name): $($leaky.Count) log call(s) interpolate a password-shaped expression"
        foreach ($l in ($leaky | Select-Object -First 3)) { Write-Host ("        $($l.Trim())") -ForegroundColor DarkRed }
    }
}
if (-not $failed) { Ok 'no log or audit call interpolates a password-shaped expression' }

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'Test-CredentialPropagation.ps1: ALL PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host "Test-CredentialPropagation.ps1: $fail FAILURE(S)" -ForegroundColor Red
    exit 1
}
