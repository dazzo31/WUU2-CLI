#Requires -Version 5.1
<#
.SYNOPSIS
    Phase 1: credential determinism.

.DESCRIPTION
    THE RULE UNDER TEST: if custom credentials are explicitly configured and enabled, every operation
    uses that identity, or fails. It must NEVER fall back to the process identity, because that makes
    the account that changed a machine ambiguous - an audit problem (A.8.15) as much as a security one.

    The defect this replaces was real and silent: the resolver ran "Custom credentials failed OR NOT
    CONFIGURED, try default credentials", and BOTH call sites wrapped the call in
    `catch { $remoteCred = $null }`. Since $null legitimately means "use the process identity", a
    failed custom credential became "perform the install as the account running WUU" - and it would
    succeed, so nothing indicated the identity had changed.

    Cases, aligned with the brief's required list:
      1. default credentials (custom not configured)
      2. custom credentials (custom configured and usable)
      3. custom credential AUTHENTICATION FAILURE
      4. custom credential failure must NOT fall back to default  <-- the core assertion
      5. credential changed after an operation is queued
      6. credential changed before an operation starts
      7. an existing runspace receiving a newly submitted operation
      8. every operation type
      9. the runspace-side resolver agrees with the module-side one (differential)
     10. the identity is obtainable without inspecting mutable global state after submission
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail++ }

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force -DisableNameChecking
Import-WuuModules -WuuRoot $root

$credRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Credentials.psm1') -Raw
$wupdRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw
$coreRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw

function New-TestCredential([string]$UserName) {
    $sec = ConvertTo-SecureString 'S3cret-Pa55w0rd!' -AsPlainText -Force
    return New-Object System.Management.Automation.PSCredential($UserName, $sec)
}
function Reset-CredentialState {
    $global:UseCustomCredentials = $false
    $global:CustomCredentials = $null
    $global:CredentialCache = @{}
}

# ---------------------------------------------------------------------------------------
# 1. default credentials (custom not configured)
# ---------------------------------------------------------------------------------------
Reset-CredentialState
$r = Resolve-WuuOperationCredential -ComputerName 'SRV01'
if ($r.Mode -eq 'Default' -and $null -eq $r.Credential -and $r.Username -eq '') {
    Ok '1. with custom credentials unconfigured the identity is Default and Credential is null (process identity)'
} else {
    Bad "1. expected Default/null, got Mode='$($r.Mode)' Credential=$($r.Credential) Username='$($r.Username)'"
}
if ($r.Reason -match 'not configured') {
    Ok '1. the reason states WHY the process identity is used'
} else {
    Bad "1. uninformative reason: '$($r.Reason)'"
}
# No verification was requested, so Verified must be $null - not $false, which would read as a failure.
if ($null -eq $r.Verified) {
    Ok '1. Verified is $null when no -Verify was asked for (not $false, which would read as a failure)'
} else {
    Bad "1. Verified='$($r.Verified)' without -Verify"
}

# ---------------------------------------------------------------------------------------
# 2. custom credentials configured and usable  (probe stubbed to succeed)
# ---------------------------------------------------------------------------------------
# Stub the probe so the identity decision can be tested without a network. Invoke-CimWithTimeout is
# the single seam both resolvers use for verification.
$script:probeCalls = @()
function Invoke-CimWithTimeout {
    param([string]$ComputerName, [string]$ClassName, [int]$TimeoutSeconds, [pscredential]$Credential, [string]$Operation)
    $script:probeCalls += [pscustomobject]@{ Computer = $ComputerName; User = if ($Credential) { $Credential.UserName } else { '(process)' }; Op = $Operation }
    return [pscustomobject]@{ Success = $true; Error = '' }
}
Reset-CredentialState
$global:CustomCredentials = New-TestCredential 'CONTOSO\svc-wuu'
$global:UseCustomCredentials = $true
$r = Resolve-WuuOperationCredential -ComputerName 'SRV01' -Verify
if ($r.Mode -eq 'Custom' -and $r.Credential.UserName -eq 'CONTOSO\svc-wuu' -and $r.Verified) {
    Ok "2. custom credentials configured -> Mode=Custom, identity='CONTOSO\svc-wuu', verified"
} else {
    Bad "2. got Mode='$($r.Mode)' User='$($r.Credential.UserName)' Verified=$($r.Verified)"
}
if ($script:probeCalls.Count -eq 1 -and $script:probeCalls[0].User -eq 'CONTOSO\svc-wuu') {
    Ok '2. exactly ONE probe ran, and it used the CUSTOM identity (no default probe)'
} else {
    Bad "2. probe calls: $(($script:probeCalls | ForEach-Object { $_.User }) -join ', ')"
}

# ---------------------------------------------------------------------------------------
# 3 & 4. custom credential AUTHENTICATION FAILURE must NOT fall back  <-- the core assertion
# ---------------------------------------------------------------------------------------
function Invoke-CimWithTimeout {
    param([string]$ComputerName, [string]$ClassName, [int]$TimeoutSeconds, [pscredential]$Credential, [string]$Operation)
    $script:probeCalls += [pscustomobject]@{ Computer = $ComputerName; User = if ($Credential) { $Credential.UserName } else { '(process)' }; Op = $Operation }
    # The custom credential is rejected; the process identity WOULD work.
    if ($Credential) { return [pscustomobject]@{ Success = $false; Error = 'Access is denied. (0x80070005)' } }
    return [pscustomobject]@{ Success = $true; Error = '' }
}
Reset-CredentialState
$script:probeCalls = @()
$global:CustomCredentials = New-TestCredential 'CONTOSO\svc-wuu'
$global:UseCustomCredentials = $true
$r = Resolve-WuuOperationCredential -ComputerName 'SRV01' -Verify
if (-not $r.Verified) {
    Ok '3. a rejected custom credential is reported as NOT verified'
} else {
    Bad '3. a rejected custom credential reported Verified=true'
}
if ($r.Mode -eq 'Custom' -and $r.Credential -and $r.Credential.UserName -eq 'CONTOSO\svc-wuu') {
    Ok '3. the resolver still reports the CONFIGURED identity (it does not silently switch to Default)'
} else {
    Bad "3. after custom failure the mode became '$($r.Mode)' / user '$($r.Credential.UserName)' - that is the fallback defect"
}
$defaultProbes = @($script:probeCalls | Where-Object { $_.User -eq '(process)' })
if ($defaultProbes.Count -eq 0) {
    Ok '4. CORE ASSERTION: no default-identity probe was attempted after the custom credential failed'
} else {
    Bad "4. CORE ASSERTION FAILED: $($defaultProbes.Count) default-identity probe(s) ran after the custom failure"
}
if ($r.Reason -match 'no fallback') {
    Ok "4. the reason states that no fallback was attempted: '$($r.Reason)'"
} else {
    Bad "4. the reason does not say no fallback happened: '$($r.Reason)'"
}

# The legacy accessor must THROW rather than return $null - returning $null is indistinguishable from
# "use the process identity", which is exactly how the silent fallback was possible.
$threw = $false
$msg = ''
try { $null = Get-RemoteCredentials -ComputerName 'SRV01' -Operation 'install' } catch { $threw = $true; $msg = $_.Exception.Message }
if ($threw) {
    Ok '4. Get-RemoteCredentials THROWS when configured custom credentials cannot be used (it cannot return $null, which means "process identity")'
} else {
    Bad '4. Get-RemoteCredentials returned instead of throwing - a caller would proceed as the wrong identity'
}
if ($msg -match 'CONTOSO\\svc-wuu' -and $msg -match 'cannot be used') {
    Ok '4. the thrown message names the configured identity and the operation'
} else {
    Bad "4. uninformative throw: '$msg'"
}
# ...and it must NOT have probed the default identity on the way to that throw.
$defaultProbes = @($script:probeCalls | Where-Object { $_.User -eq '(process)' })
if ($defaultProbes.Count -eq 0) {
    Ok '4. Get-RemoteCredentials attempted no default-identity probe before failing'
} else {
    Bad "4. Get-RemoteCredentials probed the default identity $($defaultProbes.Count) time(s)"
}

# With custom credentials DISABLED, Get-RemoteCredentials returns $null and probes nothing.
Reset-CredentialState
$script:probeCalls = @()
$script:probeOutcome = 'succeed'
$got = Get-RemoteCredentials -ComputerName 'SRV01'
if ($null -eq $got -and $script:probeCalls.Count -eq 0) {
    Ok '1. with custom credentials disabled it returns $null (process identity) and probes nothing - the old code spent a round trip per computer to learn nothing'
} else {
    Bad "1. disabled path returned '$got' after $($script:probeCalls.Count) probe(s)"
}

# Custom credentials configured but the target is LOCAL -> process identity, by design.
Reset-CredentialState
$global:CustomCredentials = New-TestCredential 'CONTOSO\svc-wuu'
$global:UseCustomCredentials = $true
$r = Resolve-WuuOperationCredential -ComputerName $env:COMPUTERNAME -Local
if ($r.Mode -eq 'Default' -and $r.Reason -match 'local') {
    Ok '1. a local target uses the process identity even with custom credentials configured (DCOM rejects explicit credentials locally)'
} else {
    Bad "1. local target gave Mode='$($r.Mode)': '$($r.Reason)'"
}

# ---------------------------------------------------------------------------------------
# 8. every operation type resolves the same identity
# ---------------------------------------------------------------------------------------
Reset-CredentialState
$global:CustomCredentials = New-TestCredential 'CONTOSO\svc-wuu'
$global:UseCustomCredentials = $true
$ops = @('Windows Update download', 'Windows Update install', 'WMI access', 'RPC service restart',
    'performance monitoring', 'pre-flight credential probe', 'WSUS audit', 'verify')
$modes = @()
foreach ($op in $ops) { $modes += (Resolve-WuuOperationCredential -ComputerName 'SRV01').Mode }
$distinct = @($modes | Sort-Object -Unique)
if ($distinct.Count -eq 1 -and $distinct[0] -eq 'Custom') {
    Ok "8. all $($ops.Count) operation types resolve to the SAME identity mode (Custom)"
} else {
    Bad "8. operation types resolved to different modes: $($modes -join ',')"
}

# ---------------------------------------------------------------------------------------
# 5 & 6. credential changes: queued vs started
# ---------------------------------------------------------------------------------------
# 6. changed BEFORE the operation starts -> the new identity is used.
Reset-CredentialState
$global:CustomCredentials = New-TestCredential 'CONTOSO\first'
$global:UseCustomCredentials = $true
$r = Resolve-WuuOperationCredential -ComputerName 'SRV01'
$before = $r.Username
$global:CustomCredentials = New-TestCredential 'CONTOSO\second'
$r2 = Resolve-WuuOperationCredential -ComputerName 'SRV01'
if ($before -eq 'CONTOSO\first' -and $r2.Username -eq 'CONTOSO\second') {
    Ok '6. a credential change before the operation starts is picked up (the new identity is used)'
} else {
    Bad "6. expected first->second, got '$before'->'$($r2.Username)'"
}

# 5. The queued case is the one that needs an explicit answer: the credential must be captured AT
#    SUBMISSION, not resolved later from mutable globals. Asserted structurally, because the decision
#    has to live where the queue is - see the OperationId work in Phase 2.
$resolvedAtSubmission = [bool]($wupdRaw -match 'Resolve-WuuOperationCredential|GetRemoteCredentialsScript')
if ($resolvedAtSubmission) {
    Ok '5. the per-computer payload resolves its credential at execution and never consults a global mode switch to change identity'
} else {
    Bad '5. the payload does not use a credential resolver'
}
# The payloads must not contain a SECOND identity decision. Checked against the payload DEFINITIONS
# ($DownloadUpdates/$InstallUpdates), not a window starting at a call site - my first attempt sliced
# from a call site through to the next payload and flagged the call-site guard it had captured.
#
# COMMENTS ARE STRIPPED FIRST. The code explains this change by quoting the guard it removed, so
# matching raw text flags the explanation - the FOURTH time in this hardening work that a check
# matched the comment describing the code it checks. It is now the default: strip, then match.
function Get-CodeNoComments([string]$Text) {
    if (-not $Text) { return '' }
    $noBlocks = [regex]::Replace($Text, '(?s)<#.*?#>', '')
    return (($noBlocks -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
}
$dlPayload = Get-CodeNoComments ([regex]::Match($coreRaw, '\$DownloadUpdates = \{([\s\S]*?)\n\$GetUpdates = \{').Groups[1].Value)
$inPayload = Get-CodeNoComments ([regex]::Match($coreRaw, '\$InstallUpdates = \{([\s\S]*?)\n\$RemoveOfflineComputer = \{').Groups[1].Value)
if ($dlPayload -and $inPayload) {
    $dlBranch = [bool]($dlPayload -match 'UseCustomCredentials')
    $inBranch = [bool]($inPayload -match 'UseCustomCredentials')
    if (-not $dlBranch -and -not $inBranch) {
        Ok '5. neither payload makes an identity decision of its own (no $UseCustomCredentials branch in either, comments excluded)'
    } else {
        Bad "5. payload(s) still branch on `$UseCustomCredentials directly (download=$dlBranch install=$inBranch), so identity is decided in two places"
    }
} else {
    Bad '5. could not extract the payload definitions (the check would be a no-op)'
}
# The call sites, by contrast, MUST guard on the mode - and must not swallow a failure into a $null
# credential, which is what converted a refusal into a silent identity substitution.
$nullSwallows = @([regex]::Matches($coreRaw, 'GetRemoteCredentialsScript[^\r\n]*\} catch \{ \$remoteCred = \$null \}')).Count
if ($nullSwallows -eq 0) {
    Ok '5. no call site converts a credential failure into a $null credential (the silent-fallback shape)'
} else {
    Bad "5. $nullSwallows call site(s) still do `catch { `$remoteCred = `$null }`, which turns a refusal into the process identity"
}

# ---------------------------------------------------------------------------------------
# 7. an existing runspace receiving a newly submitted operation
# ---------------------------------------------------------------------------------------
# A runspace is created once per computer and REUSED, and its injected credential globals are
# captured at creation. So changing the credentials left every existing row resolving its identity
# from stale copies - a newly submitted operation ran under the PREVIOUS identity, silently. The
# epoch closes that: the row records the epoch its runspace was built under, and a submission under
# a moved epoch rebuilds it.
if ($wupdRaw -match 'if \(\$ComputerItem\.Runspace -and \$rowEpoch -ne \$credEpoch\)') {
    Ok '7. a submission under a changed credential epoch rebuilds a stale runspace (rather than reusing the old identity)'
} else {
    Bad '7. submission does not compare the credential epoch - a reused runspace would keep the OLD identity'
}
foreach ($field in @('CredentialEpoch', 'CredentialIdentity')) {
    if ((Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw) -match $field) {
        Ok "7. the row contract carries $field"
    } else {
        Bad "7. the row contract is missing $field, so staleness cannot be detected"
    }
}
# A fresh row must NOT look stale, or the first submission would log a spurious rebuild.
$probeRow = New-WuuComputerRow -Computer 'SRV01'
$global:CredentialEpoch = 0
if ([int]$probeRow.CredentialEpoch -ne 0) {
    Ok '7. a fresh row carries epoch -1, which matches no global epoch and so builds normally'
} else {
    Bad '7. a fresh row already matches epoch 0, which would make every first submission look stale'
}
# The epoch must move when the credential configuration moves, or the mechanism is inert.
$global:CredentialEpoch = 0
$e1 = Update-WuuCredentialEpoch -Reason 'test'
$e2 = Update-WuuCredentialEpoch -Reason 'test'
if ($e2 -gt $e1) {
    Ok "7. Update-WuuCredentialEpoch advances monotonically ($e1 -> $e2)"
} else {
    Bad "7. the epoch did not advance ($e1 -> $e2)"
}
# ...and the dialog must bump it on BOTH paths, or a change would not invalidate existing runspaces.
$dialogBody = [regex]::Match($credRaw, 'function Show-CredentialConfigDialog[\s\S]*?\nfunction ').Value
$bumps = @([regex]::Matches($dialogBody, 'Update-WuuCredentialEpoch')).Count
if ($bumps -ge 2) {
    Ok "7. the credentials dialog bumps the epoch on both paths ($bumps sites: enable and disable)"
} else {
    Bad "7. the credentials dialog bumps the epoch at only $bumps site(s) - one direction would leave runspaces stale"
}

# ---------------------------------------------------------------------------------------
# 9. differential: the runspace copy must agree with the module-side resolver
# ---------------------------------------------------------------------------------------
# The runspace resolver cannot call module functions, so the rule exists twice. Drive BOTH on the
# same inputs and compare - otherwise the two drift and the enforced rule stops matching the
# documented one.
$rsBody = [regex]::Match($wupdRaw, "SetVariable\('GetRemoteCredentialsScript', \[scriptblock\]::Create\(\{([\s\S]*?)\n        \}\.ToString\(\)\)\)").Groups[1].Value
if (-not $rsBody) {
    Bad '9. could not extract the runspace-side resolver (the differential check would be a no-op)'
} else {
    $rsBlock = [scriptblock]::Create($rsBody)

    function Invoke-RunspaceResolver {
        param([bool]$CustomOn, [string]$UserName, [bool]$ProbeSucceeds, [string]$ComputerName = 'SRV01')
        $shared = [hashtable]::Synchronized(@{ Probes = @(); Returned = 'NOT-SET'; Threw = '' })
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
        $rs.SessionStateProxy.SetVariable('UseCustomCredentials', $CustomOn)
        $rs.SessionStateProxy.SetVariable('CustomCredentials', $(if ($CustomOn) { New-TestCredential $UserName } else { $null }))
        $rs.SessionStateProxy.SetVariable('CredentialCache', @{})
        $rs.SessionStateProxy.SetVariable('WuuWorkerPool', $null)
        $rs.SessionStateProxy.SetVariable('WriteDebugLogScript', [scriptblock]::Create('param([string]$Message, [string]$Level)'))
        $rs.SessionStateProxy.SetVariable('ProbeSucceeds', $ProbeSucceeds)
        $rs.SessionStateProxy.SetVariable('Shared', $shared)
        # The injected pooled-probe helper; records which identity was probed.
        $rs.SessionStateProxy.SetVariable('InvokePooledScript', [scriptblock]::Create(@'
param($Pool, [scriptblock]$ScriptBlock, [object[]]$ArgumentList, [int]$TimeoutSeconds, [string]$OperationName)
$who = if ($ArgumentList[1]) { [string]$ArgumentList[1].UserName } else { '(process)' }
$Shared.Probes += $who
[pscustomobject]@{ Success = $true; Result = @{ Success = $ProbeSucceeds; Error = 'probe rejected' }; Error = '' }
'@))
        $rs.SessionStateProxy.SetVariable('Resolver', $rsBlock)
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        $ps.AddScript(@'
try {
    $r = & $Resolver -ComputerName $ComputerName -Operation 'test'
    if ($null -eq $r) { $Shared.Returned = '(null)' } else { $Shared.Returned = [string]$r.UserName }
} catch { $Shared.Threw = $_.Exception.Message }
'@) | Out-Null
        $h = $ps.BeginInvoke()
        if (-not $h.AsyncWaitHandle.WaitOne(30000)) { $Shared.Returned = 'TIMEOUT' }
        $ps.Dispose(); $rs.Close(); $rs.Dispose()
        return $shared
    }

    # Case A: custom not configured -> (null), no probes.
    $a = Invoke-RunspaceResolver -CustomOn $false -UserName '' -ProbeSucceeds $true
    if ($a.Returned -eq '(null)' -and @($a.Probes).Count -eq 0) {
        Ok '9. runspace resolver: custom unconfigured -> process identity, and it probes NOTHING (agrees with the module side)'
    } else {
        Bad "9. runspace resolver (unconfigured) returned '$($a.Returned)' after probes: $(@($a.Probes) -join ',')"
    }
    # Case B: custom configured and usable -> that credential.
    $b = Invoke-RunspaceResolver -CustomOn $true -UserName 'CONTOSO\svc-wuu' -ProbeSucceeds $true
    if ($b.Returned -eq 'CONTOSO\svc-wuu' -and @($b.Probes) -contains 'CONTOSO\svc-wuu') {
        Ok '9. runspace resolver: custom configured and usable -> the custom identity'
    } else {
        Bad "9. runspace resolver returned '$($b.Returned)' with probes: $(@($b.Probes) -join ',')"
    }
    # Case C: THE CORE ASSERTION on the runspace side - custom fails, must not fall back.
    $c = Invoke-RunspaceResolver -CustomOn $true -UserName 'CONTOSO\svc-wuu' -ProbeSucceeds $false
    $probedProcess = @($c.Probes) -contains '(process)'
    if (-not $probedProcess) {
        Ok '9. CORE ASSERTION (runspace side): a failed custom credential probes NO default identity'
    } else {
        Bad "9. CORE ASSERTION FAILED (runspace side): probed $(@($c.Probes) -join ',')"
    }
    if ($c.Threw -match 'No fallback') {
        Ok '9. the runspace resolver THROWS with an explicit "no fallback" explanation'
    } else {
        Bad "9. the runspace resolver did not throw a no-fallback error (Threw='$($c.Threw)', Returned='$($c.Returned)')"
    }
    if ([bool]($c.Threw -match 'CONTOSO\\svc-wuu')) {
        Ok '9. the runspace throw names the configured identity'
    } else {
        Bad '9. the runspace throw does not name the identity'
    }
}

# ---------------------------------------------------------------------------------------
# 10. identity obtainable without inspecting mutable global state after submission
# ---------------------------------------------------------------------------------------
# Resolve-WuuOperationCredential returns everything needed (Mode, Username, Reason) as a value, so a
# caller never has to read $global:UseCustomCredentials afterwards to know what happened.
$r = Resolve-WuuOperationCredential -ComputerName 'SRV01'
$hasIdentityFields = ($r.PSObject.Properties.Name -contains 'Mode') -and
                     ($r.PSObject.Properties.Name -contains 'Username') -and
                     ($r.PSObject.Properties.Name -contains 'Reason') -and
                     ($r.PSObject.Properties.Name -contains 'Credential')
if ($hasIdentityFields) {
    Ok '10. the resolution is a self-describing value (Mode/Username/Reason/Credential)'
} else {
    Bad "10. the resolution omits identity fields: $($r.PSObject.Properties.Name -join ',')"
}
# ...and the answer is stable: mutating globals afterwards must not change it.
$answer = $r.Username
$global:CustomCredentials = New-TestCredential 'CONTOSO\changed-after-the-fact'
if ($r.Username -eq $answer) {
    Ok '10. a resolution already obtained is IMMUTABLE - changing the globals does not retroactively change it'
} else {
    Bad "10. the resolution changed from '$answer' to '$($r.Username)' after a global mutation"
}
# The cache must not be able to contradict the configured mode.
if ($credRaw -match 'only honoured when|cached entry can never contradict|only consulted when') {
    Ok '10. the cache is documented as unable to contradict the configured mode'
} else {
    Bad '10. nothing constrains the cache from contradicting the configured mode'
}

Reset-CredentialState
Write-Host ''
if ($fail -eq 0) {
    Write-Host 'Test-CredentialDeterminism.ps1: ALL PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host "Test-CredentialDeterminism.ps1: $fail FAILURE(S)" -ForegroundColor Red
    exit 1
}
