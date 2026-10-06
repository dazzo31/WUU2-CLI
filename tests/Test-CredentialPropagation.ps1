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
         actually change a remote machine - is given a credential in every remote case;
      6. live and mocked probe failures (C3 / G3): unverified custom credential reports
         Verified = false, preserves probe error text, enforces no-fallback, and throws on use.
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
#
# SLICE THE COMMENT-STRIPPED SOURCE, not the raw file. Several checks below slice a payload or a
# function body by regex, and a comment quoting the syntax it is slicing is then captured as the
# opening line of the slice. That is not hypothetical: rewriting Wuu.Core's module header to explain
# where the payloads live made the sibling suite report the payloads branching on
# $UseCustomCredentials when they do not. Stripping first makes this suite immune to prose generally,
# rather than to the one phrasing that happened to trip it.
$coreCode = (([regex]::Replace($coreRaw, '(?s)<#.*?#>', '') -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
$supBody = [regex]::Match($coreCode, '\$DownloadUpdates = \{[\s\S]*?\n\}').Value
if (-not $supBody) { $supBody = $coreCode }

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

# (b) The local-machine rule: custom credentials must NOT be applied to the local host, where the
#     process token is already the right principal (and passing credentials to local DCOM is rejected).
#
#     PHASE 1 MOVED THIS RULE. It used to be duplicated as an inline guard at both remote-task call
#     sites; it now lives once, in the resolver, which both payloads call unconditionally. Asserting
#     the old duplicated form would forbid the single-decision design, so the assertion is now about
#     the RULE EXISTING IN ONE PLACE - which is what actually prevents custom credentials reaching the
#     local host.
$guards = ([regex]::Matches($coreRaw, "UseCustomCredentials -and \`$Computer\.computer -ne 'localhost'")).Count
$resolverHasLocalRule = [bool]($wupdRaw -match "\`$isLocal = \(\`$ComputerName -eq 'localhost' -or \`$ComputerName -eq \`$env:COMPUTERNAME\)")
if ($guards -eq 0 -and $resolverHasLocalRule) {
    Ok 'the local-machine rule exists in the resolver only (no duplicated guard at the call sites)'
} elseif ($guards -ge 2) {
    Ok "the local-machine rule is enforced at both call sites ($guards guards)"
} else {
    Bad "the local-machine rule is neither centralised nor present at the call sites - custom credentials could reach the local host"
}

# (c) PHASE 1: the runspace resolver uses the configured custom credential, and there is NO fallback
#     branch. This block used to ASSERT the fallback ("falls back to default credentials", "caches the
#     default-credentials outcome") - i.e. it encoded the very defect Phase 1 removes, so it was
#     rewritten rather than deleted. What matters now is the opposite: no default probe exists, and
#     the cache cannot record one.
$rsResolver = [regex]::Match($wupdRaw, "SetVariable\('GetRemoteCredentialsScript', \[scriptblock\]::Create\(\{([\s\S]*?)\n        \}\.ToString\(\)\)\)").Groups[1].Value
$rsCode = (($rsResolver -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
if ($rsCode -match "-ArgumentList @\(\`$ComputerName, \`$cred\)") {
    Ok 'the runspace resolver probes with the CONFIGURED custom credential'
} else {
    Bad 'the runspace resolver does not use the configured custom credential'
}
if ($rsCode -match "-ArgumentList @\(\`$ComputerName, \`$null\)") {
    Bad 'the runspace resolver STILL probes the default identity - the Phase 1 fallback defect is back'
} else {
    Ok 'the runspace resolver has NO default-identity probe (no silent fallback)'
}
if ($rsCode -match "CredentialCache\[\`$ComputerName\] = \`$null") {
    Bad "the resolver still records a 'use default' cache entry, so a fallback can occur"
} else {
    Ok "the cache cannot record a 'use default' outcome (only a verified custom credential is cached)"
}
# The resolver must throw when the custom credential is unusable - a return would be indistinguishable
# from "no custom credential configured".
if ($rsCode -match 'No fallback is attempted' -and $rsCode -match 'throw') {
    Ok 'the runspace resolver throws (with no-fallback wording) instead of returning a usable value'
} else {
    Bad 'the runspace resolver does not throw on an unusable custom credential'
}

# (d) The module-side and runspace-side resolvers must agree. They are duplicated because the worker
#     runspace cannot call module functions, so the risk is DRIFT between the two.
#
#     PHASE 1 makes this a real differential rather than a pair of regexes: the two implementations
#     are driven on identical inputs (and a stubbed probe) and their verdicts compared. The structural
#     check that used to sit here asserted the fallback ORDER ("custom, then default"), which no longer
#     exists - and a regex pair could not detect the failure mode that actually matters, which is one
#     copy falling back while the other does not.
$diffSuite = Join-Path $root 'tests\Test-CredentialDeterminism.ps1'
if (Test-Path -LiteralPath $diffSuite) {
    $diffOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $diffSuite 2>&1
    $diffFailures = @($diffOut | Where-Object { $_ -match '^FAIL' })
    $agreesRunspaceSide = [bool](@($diffOut | Where-Object { $_ -match 'CORE ASSERTION \(runspace side\)' }).Count -ge 1)
    if ($diffFailures.Count -eq 0 -and $agreesRunspaceSide) {
        Ok 'the module-side and runspace-side resolvers agree, including no-fallback on both (differential in Test-CredentialDeterminism)'
    } else {
        Bad "the resolvers are not verified to agree ($($diffFailures.Count) differential failure(s))"
    }
} else {
    Bad 'Test-CredentialDeterminism.ps1 is missing - nothing verifies that the two resolvers agree'
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

# (g) End-to-end credential verification probe failure (C3 / G3)
# Exercises Resolve-WuuOperationCredential and Get-RemoteCredentials against a real failing
# probe through the exported Invoke-CimWithTimeout (without mocking), verifying that
# verification failure is truthfully reported and silent fallback is impossible.
$global:UseCustomCredentials = $true
$badSec = ConvertTo-SecureString 'invalid-password-test' -AsPlainText -Force
$global:CustomCredentials = New-Object System.Management.Automation.PSCredential('CONTOSO\nonexistent-user', $badSec)
$global:CredentialCache = @{}

$resFail = Resolve-WuuOperationCredential -ComputerName localhost -Verify -TimeoutSeconds 5
if ($resFail.Verified -eq $false) {
    Ok 'end-to-end: rejected credential reports Verified = false through exported Invoke-CimWithTimeout'
} else {
    Bad "end-to-end: rejected credential reported Verified = $($resFail.Verified)"
}
if ($resFail.Mode -eq 'Custom' -and $resFail.Credential.UserName -eq 'CONTOSO\nonexistent-user') {
    Ok 'end-to-end: Mode remains Custom and identity is preserved (no fallback)'
} else {
    Bad "end-to-end: Mode or identity altered: Mode='$($resFail.Mode)'"
}
if ($resFail.Reason -match 'no fallback attempted') {
    Ok "end-to-end: Reason explicitly records no fallback attempted: '$($resFail.Reason)'"
} else {
    Bad "end-to-end: Reason missing no-fallback clause: '$($resFail.Reason)'"
}
if ($resFail.Error -ne '') {
    Ok "end-to-end: Error captured from probe failure: '$($resFail.Error)'"
} else {
    Bad 'end-to-end: Error was empty despite probe failure'
}

$threwGetRemote = $false
$getRemoteMsg = ''
try {
    $null = Get-RemoteCredentials -ComputerName localhost -Operation 'test-op'
} catch {
    $threwGetRemote = $true
    $getRemoteMsg = $_.Exception.Message
}
if ($threwGetRemote -and $getRemoteMsg -match 'cannot be used') {
    Ok 'end-to-end: Get-RemoteCredentials throws on unverified custom credential'
} else {
    Bad "end-to-end: Get-RemoteCredentials failed to throw: msg='$getRemoteMsg'"
}

# (h) Mocked probe failure test (G3 / C3)
# Exercises Resolve-WuuOperationCredential and Get-RemoteCredentials end-to-end with a mock
# Invoke-CimWithTimeout that explicitly returns a non-timeout probe failure (e.g. E_ACCESSDENIED),
# proving that the failure hashtable is preserved, Verified is set to $false, no fallback is attempted,
# and Get-RemoteCredentials refuses the unverified identity with a fatal throw.
$credMod = Get-Module Wuu.Credentials
& $credMod {
    function script:Invoke-CimWithTimeout {
        param([string]$ComputerName, [string]$ClassName, [string]$Operation, $Credential, [int]$TimeoutSeconds, $ComputerRow)
        return @{ Success = $false; Error = '0x80070005 (E_ACCESSDENIED)'; Result = $null }
    }
}

try {
    $global:UseCustomCredentials = $true
    $mockSec = ConvertTo-SecureString 'mock-pass' -AsPlainText -Force
    $global:CustomCredentials = New-Object System.Management.Automation.PSCredential('CONTOSO\mock-admin', $mockSec)
    $global:CredentialCache = @{}

    $mockResolved = Resolve-WuuOperationCredential -ComputerName 'SRV-MOCK-PROBE' -Verify -TimeoutSeconds 5
    if ($mockResolved.Verified -eq $false) {
        Ok 'mock G3: mocked probe failure reports Verified = false'
    } else {
        Bad "mock G3: mocked probe failure reported Verified = $($mockResolved.Verified)"
    }
    if ($mockResolved.Error -eq '0x80070005 (E_ACCESSDENIED)') {
        Ok 'mock G3: mocked probe failure preserves exact error text'
    } else {
        Bad "mock G3: error text mismatch: '$($mockResolved.Error)'"
    }
    if ($mockResolved.Reason -match 'no fallback attempted') {
        Ok "mock G3: reason contains 'no fallback attempted' clause ($($mockResolved.Reason))"
    } else {
        Bad "mock G3: reason missing no-fallback clause: '$($mockResolved.Reason)'"
    }
    if ($mockResolved.Mode -eq 'Custom' -and $mockResolved.Credential.UserName -eq 'CONTOSO\mock-admin') {
        Ok 'mock G3: credential mode remains Custom and identity is preserved'
    } else {
        Bad "mock G3: credential mode or identity changed: Mode='$($mockResolved.Mode)'"
    }

    $mockThrew = $false
    $mockThrewMsg = ''
    try {
        $null = Get-RemoteCredentials -ComputerName 'SRV-MOCK-PROBE' -Operation 'install'
    } catch {
        $mockThrew = $true
        $mockThrewMsg = $_.Exception.Message
    }
    if ($mockThrew -and $mockThrewMsg -match 'cannot be used.*0x80070005') {
        Ok 'mock G3: Get-RemoteCredentials throws on mocked verification failure and preserves error'
    } else {
        Bad "mock G3: Get-RemoteCredentials failed to throw expected message: '$mockThrewMsg'"
    }
} finally {
    & $credMod { Remove-Item function:Invoke-CimWithTimeout -ErrorAction SilentlyContinue }
    $global:UseCustomCredentials = $false
    $global:CustomCredentials = $null
    $global:CredentialCache = @{}
}

# Clean up test credential state
$global:UseCustomCredentials = $false
$global:CustomCredentials = $null
$global:CredentialCache = @{}
try { Close-WuuWorkerPool } catch { }

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'Test-CredentialPropagation.ps1: ALL PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host "Test-CredentialPropagation.ps1: $fail FAILURE(S)" -ForegroundColor Red
    exit 1
}
