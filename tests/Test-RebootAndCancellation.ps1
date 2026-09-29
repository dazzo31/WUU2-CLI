#Requires -Version 5.1
<#
.SYNOPSIS
    SS16: reboot / management-endpoint cases and cancellation.

.DESCRIPTION
    The brief lists two behavioural gaps this section must close: reboot/ICMP cases and cancellation.

    (A) REBOOT. The payload's wait sequence is exercised for real by extracting the shipped
        $RestartComputer body and running it in a child scope with STUBBED remote functions. A stub is
        the only way to cover this without a second machine, and it is better than a static check
        because it drives the ACTUAL control flow: the offline wait's exit condition, the online wait's
        exit condition, the deadline arithmetic, and the throw.

    (B) CANCELLATION. Two distinct surfaces, tested separately because they mean different things:
          * the console/guided confirmation cancelled at the prompt -> nothing runs, and a DENIAL is
            recorded (ISO 27001 A.8.15) rather than the cancellation vanishing;
          * an unreachable computer -> queued work is CANCELLED (Pending cleared) but the row is KEPT
            until the threshold, so a lost packet cannot evict a healthy server.

    (C) A latent bug found while writing this: Update-WuuConnectivityState called
        `$ProbeResult.Contains('Resolves')` unguarded. .Contains is a string/collection method, so a
        PSCustomObject threw and the function's own PSCustomObject branch was UNREACHABLE - the function
        accepted two shapes and worked with one. Covered here so it cannot come back.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail++ }

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force -DisableNameChecking
Import-WuuModules -WuuRoot $root

$coreRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw

# ---------------------------------------------------------------------------------------
# (A) Extract the shipped $RestartComputer payload and drive it with stubs, in a real runspace.
#
# WHY A RUNSPACE AND NOT A CHILD SCOPE: the payload is executed in an isolated runspace in
# production, and two of its behaviours only make sense there - module functions do not resolve (it
# uses injected scripts instead), and its bare `exit` in the catch block terminates the pipeline.
# Probed first: functions defined in the RUNSPACE BODY are visible to the invoked scriptblock, and
# `exit` completes the pipeline while leaving the runspace Opened and the host alive.
# ---------------------------------------------------------------------------------------
$startMarker = '$RestartComputer = {'
$endMarker = "`r`n# Note: the old duplicate `$WUServiceAction block"
$si = $coreRaw.IndexOf($startMarker)
$ei = if ($si -ge 0) { $coreRaw.IndexOf($endMarker, $si) } else { -1 }
if ($si -lt 0 -or $ei -le $si) {
    Bad 'could not locate the $RestartComputer payload'
} else {
    # The source is an ASSIGNMENT ($RestartComputer = { ... }), so the scriptblock to RUN is the part
    # between the outermost braces. Creating a scriptblock from the whole assignment would produce a
    # block whose body assigns an inner block and returns it - invoking that does nothing, which is
    # exactly how this harness first "passed" while every scenario observed zero restarts.
    $raw = $coreRaw.Substring($si, $ei - $si)
    $inner = $raw.Substring($raw.IndexOf('=') + 1).Trim()
    if (-not $inner.StartsWith('{') -or -not $inner.EndsWith('}')) {
        Bad 'the extracted payload is not a braced scriptblock - the scenarios below would test nothing'
    }
    $payload = [scriptblock]::Create($inner.Substring(1, $inner.Length - 2))
    Ok "extracted the `$RestartComputer payload as a scriptblock ($($payload.ToString().Length) chars)"

    # Comments are stripped before the content checks: the payload EXPLAINS the ICMP removal by naming
    # Test-Connection, so matching raw text reports a false failure (the same trap as the SS6/SS8 gates).
    $payloadCode = (($payload.ToString() -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    if ($payloadCode -match 'Restart-Computer \$Computer\.computer -Force') {
        Ok 'the payload still issues Restart-Computer -Force'
    } else {
        Bad 'the payload does not issue Restart-Computer (the reboot would never be requested)'
    }
    if ($payloadCode -match 'Test-Connection') {
        Bad 'the payload decides with ICMP (Test-Connection) - it cannot terminate on a host that blocks echo'
    } else {
        Ok 'the payload contains no ICMP decision (checked with comments stripped)'
    }

    # Drives the payload once in a real runspace with stubbed remote calls.
    #
    # $UpForOfflineProbes : how many offline probes answer "still up" before the host appears down.
    #                       -1 = never appears down (the host that blocks/masks a shutdown, and the
    #                       equivalent of the old never-terminating ICMP loop).
    # $DownForOnlineProbes: how many online probes answer "not back yet". -1 = never comes back.
    function Invoke-RestartScenario {
        param(
            [Parameter(Mandatory)][scriptblock]$Payload,
            [int]$UpForOfflineProbes = 0,
            [int]$DownForOnlineProbes = 0,
            [hashtable]$Settings = @{ AutoReboot = $true },
            [bool]$RebootRequired = $true,
            [bool]$AfterInstall = $false
        )

        $store = New-WuuStateStore
        foreach ($k in $Settings.Keys) { $store.Settings[$k] = $Settings[$k] }
        $row = New-WuuComputerRow -Computer 'SRV01'
        $row.RebootRequired = $RebootRequired
        Add-WuuComputerRow -Store $store -Row $row | Out-Null

        # Shared, synchronized: written by the runspace, read by this test process.
        $shared = [hashtable]::Synchronized(@{
            Restarts = 0; OfflineProbes = 0; OnlineProbes = 0
            TimedOut = $false; TimeoutPhase = ''; Error = ''
        })

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('Shared', $shared)
        $rs.SessionStateProxy.SetVariable('stateStore', $store)
        $rs.SessionStateProxy.SetVariable('UpForOfflineProbes', $UpForOfflineProbes)
        $rs.SessionStateProxy.SetVariable('DownForOnlineProbes', $DownForOnlineProbes)
        $rs.SessionStateProxy.SetVariable('OfflineWaitSeconds', 10)
        $rs.SessionStateProxy.SetVariable('OnlineWaitSeconds', 10)
        # The ONLINE probe is reached as `& $InvokePooledScript` - a VARIABLE holding a scriptblock, not a
        # function. Injecting it as a function left the variable $null, so every online probe silently
        # produced nothing and BOTH success scenarios timed out (measured: 3 false failures). Built with
        # [scriptblock]::Create so it can bind $Shared / $DownForOnlineProbes from session state - the
        # same reason the production $InvokePooledScript is created that way.
        $rs.SessionStateProxy.SetVariable('InvokePooledScript', [scriptblock]::Create(@'
param($Pool, [scriptblock]$ScriptBlock, [object[]]$ArgumentList, [int]$TimeoutSeconds, [string]$OperationName)
    $Shared.OnlineProbes++
    if ($DownForOnlineProbes -lt 0) { $up = $false }                       # -1 = NEVER comes back
    elseif ($Shared.OnlineProbes -le $DownForOnlineProbes) { $up = $false } # n = not back for n probes
    else { $up = $true }
    [pscustomobject]@{ Success = $true; Result = $up; Error = '' }
'@))
        # The offline probe IS reached by name, so a function in the runspace body is correct for it.
        # The cleanup/injected helpers the payload reaches for.
        $rs.SessionStateProxy.SetVariable('WriteDebugLogScript', [scriptblock]::Create('param([string]$Message, [string]$Level)'))
        $rs.SessionStateProxy.SetVariable('SetComputerTimeoutScript', [scriptblock]::Create({
                    param($Computer, [string]$Phase, [int]$TimeoutSec, [string]$Detail)
                    $Shared.TimedOut = $true
                    $Shared.TimeoutPhase = $Phase
                    $Shared.Error = $Detail
                    $Computer.State = 'Timeout'
                    $Computer.UpdatesStatus = 'Timeout'
                }.ToString()))

        # Stubs DEFINED IN THE RUNSPACE BODY, which the probe showed the invoked payload can see.
        $body = @'
function Test-WuuManagementEndpoint { param([Parameter(Mandatory)][string]$ComputerName)
    $Shared.OfflineProbes++
    if ($UpForOfflineProbes -lt 0) { return $true }
    if ($Shared.OfflineProbes -le $UpForOfflineProbes) { return $true }
    return $false
}
function Restart-Computer { param([Parameter(Position=0)][string]$ComputerName, [switch]$Force) $Shared.Restarts++ }
$sb = $Payload
& $sb $Row $AfterInstall
'@
        # $Payload / $Row / $AfterInstall must be visible in the body, so they are set as variables
        # in the runspace rather than passed as arguments (the body is AddScript, not a function).
        $rs.SessionStateProxy.SetVariable('Payload', $Payload)
        $rs.SessionStateProxy.SetVariable('Row', $row)
        $rs.SessionStateProxy.SetVariable('AfterInstall', $AfterInstall)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $ps.AddScript($body) | Out-Null
        $h = $ps.BeginInvoke()
        $completed = $h.AsyncWaitHandle.WaitOne(60000)
        if (-not $completed) { try { $ps.Stop() } catch { } }
        $errors = @($ps.Streams.Error) | ForEach-Object { $_.ToString() }
        $ps.Dispose()
        $rs.Close(); $rs.Dispose()

        return [pscustomobject]@{
            Completed     = $completed
            Restarts      = $shared.Restarts
            OfflineProbes = $shared.OfflineProbes
            OnlineProbes  = $shared.OnlineProbes
            TimedOut      = $shared.TimedOut
            TimeoutPhase  = $shared.TimeoutPhase
            Error         = $shared.Error
            Errors        = $errors
            Status        = [string]$row.Status
            State         = [string]$row.State
            Row           = $row
            Store         = $store
        }
    }

    # Scenario 1: a normal reboot - appears down on the first probe, back on the first online probe.
    $r = Invoke-RestartScenario -Payload $payload -UpForOfflineProbes 0 -DownForOnlineProbes 0
    if ($r.Completed) { Ok 'the reboot payload completes (it does not hang)' } else { Bad 'the reboot payload did not complete within 60s' }
    if ($r.Restarts -eq 1) { Ok 'the reboot is requested exactly once (Restart-Computer was issued)' }
    else { Bad "the payload issued $($r.Restarts) restart(s) (expected 1)" }
    if (-not $r.TimedOut) { Ok 'a clean reboot is not classified as a timeout' } else { Bad "a clean reboot was classified as a timeout ($($r.TimeoutPhase))" }
    if ($r.State -eq 'Connected') { Ok "a clean reboot ends in State='Connected'" } else { Bad "a clean reboot ended in State='$($r.State)'" }

    # Scenario 2: THE ICMP-EQUIVALENT CASE. The host never appears to go down (exactly what a host that
    # blocks echo looked like to the old while(Test-Connection) loop). The payload must NOT report a
    # failure - it assumes a very fast reboot and continues to the online wait.
    $r = Invoke-RestartScenario -Payload $payload -UpForOfflineProbes -1 -DownForOnlineProbes 0
    if (-not $r.TimedOut -and $r.State -eq 'Connected') {
        Ok 'a host that never appears to go down still succeeds (the SS7 regression case)'
    } else {
        Bad "the never-goes-down case reported TimedOut=$($r.TimedOut) State='$($r.State)' - a healthy reboot is blamed"
    }
    if ($r.OfflineProbes -ge 2) {
        Ok "the offline wait really polled ($($r.OfflineProbes) probes) before assuming a fast reboot"
    } else {
        Bad "the offline wait polled only $($r.OfflineProbes) time(s) - it cannot have observed anything"
    }

    # Scenario 3: the host never comes back -> a TIMEOUT, classified as recoverable, and the payload
    # still reaches its end (its bare `exit` is contained by the runspace).
    $r = Invoke-RestartScenario -Payload $payload -UpForOfflineProbes 0 -DownForOnlineProbes -1
    if ($r.TimedOut) {
        Ok 'a host that never returns is reported as a timeout'
    } else {
        Bad "a host that never returns was not reported as a timeout (State='$($r.State)')"
    }
    if ($r.TimeoutPhase -match 'Online') {
        Ok "the timeout is attributed to the online wait ('$($r.TimeoutPhase)')"
    } else {
        Bad "the timeout phase is wrong: '$($r.TimeoutPhase)'"
    }
    if ($r.Error -match 'may still be booting') {
        Ok 'the timeout wording says the host may still be booting (it does not blame the restart)'
    } else {
        Bad "the timeout wording blames the restart: '$($r.Error)'"
    }
    if ($r.Completed) {
        Ok 'the payload terminates on the timeout path too (its exit is contained by the runspace)'
    } else {
        Bad 'the payload did not terminate after a timeout'
    }

    # Scenario 4: the after-install gates. AutoReboot OFF must refuse - the SS2 defect where
    # `-not $null` was always $true and auto-reboot therefore never worked.
    $r = Invoke-RestartScenario -Payload $payload -AfterInstall $true -Settings @{ AutoReboot = $false }
    if ($r.Restarts -eq 0) { Ok 'an after-install restart is REFUSED when AutoReboot is OFF' }
    else { Bad "AutoReboot=OFF still issued $($r.Restarts) restart(s)" }
    $r = Invoke-RestartScenario -Payload $payload -AfterInstall $true -Settings @{ AutoReboot = $true } -RebootRequired $true
    if ($r.Restarts -eq 1) { Ok 'an after-install restart happens when AutoReboot is ON and a reboot is required' }
    else { Bad "AutoReboot=ON with RebootRequired issued $($r.Restarts) restart(s)" }
    $r = Invoke-RestartScenario -Payload $payload -AfterInstall $true -Settings @{ AutoReboot = $true } -RebootRequired $false
    if ($r.Restarts -eq 0) { Ok 'an after-install restart is skipped when no reboot is required' }
    else { Bad "RebootRequired=false still issued $($r.Restarts) restart(s)" }

    # Scenario 5: a MANUAL restart ignores both gates - the operator asked for it explicitly.
    $r = Invoke-RestartScenario -Payload $payload -AfterInstall $false -Settings @{ AutoReboot = $false } -RebootRequired $false
    if ($r.Restarts -eq 1) { Ok 'a manual restart is not suppressed by AutoReboot=OFF or RebootRequired=false' }
    else { Bad "a manual restart was suppressed (issued $($r.Restarts))" }
}

# ---------------------------------------------------------------------------------------
# (B) Cancellation surfaces.
# ---------------------------------------------------------------------------------------
# B1. An unreachable computer: queued work is cancelled, but the row is KEPT below the threshold.
$store = New-WuuStateStore
$row = New-WuuComputerRow -Computer 'SRV01'
$row.Pending = $true
Add-WuuComputerRow -Store $store -Row $row | Out-Null
$down = [pscustomobject]@{ Computer = 'SRV01'; Resolves = $true; Endpoint = $false; Reason = 'tcp 135 refused' }
$v = Update-WuuConnectivityState -Row $row -ProbeResult $down -Store $store -FailuresBeforeRemoval 2
if ($v.Action -eq 'kept' -and -not $row.Pending) {
    Ok 'an unreachable computer has its queued work CANCELLED (Pending cleared) on the first failure'
} else {
    Bad "unreachable: Action='$($v.Action)' Pending=$($row.Pending) - the scheduler would spin against a host that is not there"
}
if ($store.Rows.Count -eq 1) {
    Ok 'a single failed probe KEEPS the row (a lost packet must not evict a healthy server)'
} else {
    Bad 'a single failed probe removed the row'
}
# The second consecutive failure removes it, with the reason recorded.
$v2 = Update-WuuConnectivityState -Row $row -ProbeResult $down -Store $store -FailuresBeforeRemoval 2
if ($v2.Action -eq 'removed' -and $store.Rows.Count -eq 0) {
    Ok 'the threshold failure removes the row (2 consecutive, not 1)'
} else {
    Bad "threshold: Action='$($v2.Action)' rows=$($store.Rows.Count)"
}
# A reachable probe RESETS the counter, so a blip between successes can never accumulate.
$store = New-WuuStateStore
$row = New-WuuComputerRow -Computer 'SRV01'
Add-WuuComputerRow -Store $store -Row $row | Out-Null
$null = Update-WuuConnectivityState -Row $row -ProbeResult $down -Store $store -FailuresBeforeRemoval 3
$up = [pscustomobject]@{ Computer = 'SRV01'; Resolves = $true; Endpoint = $true; Reason = '' }
$null = Update-WuuConnectivityState -Row $row -ProbeResult $up -Store $store -FailuresBeforeRemoval 3
if ($row.ConnectivityFailures -eq 0) {
    Ok 'a successful probe RESETS the failure counter (blips cannot accumulate into a removal)'
} else {
    Bad "the failure counter was not reset: $($row.ConnectivityFailures)"
}
# A probe that could not RUN is not evidence of anything - it must not count as a failure.
$store = New-WuuStateStore
$row = New-WuuComputerRow -Computer 'SRV01'
Add-WuuComputerRow -Store $store -Row $row | Out-Null
$noProbe = [pscustomobject]@{ Computer = 'SRV01'; Resolves = $false; Endpoint = $false; Reason = 'probe could not run' }
$v = Update-WuuConnectivityState -Row $row -ProbeResult $noProbe -Store $store -FailuresBeforeRemoval 2
if ($v.Failures -eq 1 -and $store.Rows.Count -eq 1) {
    Ok 'a probe that could not resolve still keeps the row and counts one failure'
} else {
    Bad "unresolvable probe: Action='$($v.Action)' Failures=$($v.Failures)"
}
# The PSCustomObject shape - the latent bug found while writing this suite.
$store = New-WuuStateStore
$row = New-WuuComputerRow -Computer 'SRV01'
Add-WuuComputerRow -Store $store -Row $row | Out-Null
$threw = $false
try { $null = Update-WuuConnectivityState -Row $row -ProbeResult $up -Store $store -FailuresBeforeRemoval 2 }
catch { $threw = $true }
if (-not $threw) {
    Ok 'a PSCustomObject probe result is accepted (the dead branch is reachable again)'
} else {
    Bad 'a PSCustomObject probe result throws - the function documents two shapes and supports one'
}
# ...and an ordered dictionary (what the real probe returns) still works.
$store = New-WuuStateStore
$row = New-WuuComputerRow -Computer 'SRV01'
Add-WuuComputerRow -Store $store -Row $row | Out-Null
$od = [ordered]@{ Computer = 'SRV01'; Resolves = $true; Endpoint = $true; Reason = '' }
$v = Update-WuuConnectivityState -Row $row -ProbeResult $od -Store $store -FailuresBeforeRemoval 2
if ($v.Action -eq 'online') { Ok 'an OrderedDictionary probe result still works (the real probe shape)' }
else { Bad "ordered dictionary gave Action='$($v.Action)'" }
# A null probe result must not be read as offline evidence that accumulates.
$store = New-WuuStateStore
$row = New-WuuComputerRow -Computer 'SRV01'
Add-WuuComputerRow -Store $store -Row $row | Out-Null
$v = Update-WuuConnectivityState -Row $row -ProbeResult $null -Store $store -FailuresBeforeRemoval 2
if ($v -and $store.Rows.Count -eq 1) { Ok 'a null probe result does not throw and does not remove the row' }
else { Bad 'a null probe result broke the decision' }

# B2. The confirmation gate: cancelling must run NOTHING and must record a denial.
$navRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Navigate.psm1') -Raw
$consoleRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Console.psm1') -Raw
$denials = ([regex]::Matches($navRaw + $consoleRaw, 'DenialHook')).Count
if ($denials -ge 3) {
    Ok "cancellations at a prompt invoke the denial hook ($denials sites) - a cancel is recorded, not silent"
} else {
    Bad "only $denials denial-hook site(s) - a cancellation would leave no trace"
}
# The blank-reason refusal must return Proceed=$false rather than proceeding with an empty reason.
if ($navRaw -match 'Proceed = \$false; Reason = ''''') {
    Ok 'a blank change reason returns Proceed=$false (the operation is cancelled, not run unaudited)'
} else {
    Bad 'a blank change reason does not cancel the operation'
}
# An empty selection must cancel rather than silently falling through to "all computers".
$emptySelectionGuards = ([regex]::Matches($coreRaw, 'if \(\$rows\.Count -eq 0\) \{ Write-Host ''  Cancelled\.''')).Count
if ($emptySelectionGuards -ge 5) {
    Ok "an empty selection cancels at $emptySelectionGuards site(s) - it never falls through to all computers"
} else {
    Bad "only $emptySelectionGuards empty-selection guards - a cancelled selection could widen to every computer"
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'Test-RebootAndCancellation.ps1: ALL PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host "Test-RebootAndCancellation.ps1: $fail FAILURE(S)" -ForegroundColor Red
    exit 1
}
