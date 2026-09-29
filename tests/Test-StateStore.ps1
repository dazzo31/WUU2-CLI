#Requires -Version 5.1
<#
.SYNOPSIS Phase 1 test: the presentation-agnostic state store works headlessly and
a REAL isolated worker runspace can update it (the keystone contract).
.DESCRIPTION
Proves:
  1. Wuu.State imports WITHOUT any WPF assembly loaded (no PresentationFramework).
  2. Row create / add / find / remove / colour work.
  3. An isolated runspace (same topology as New-ComputerRunspace, which cannot see
     module functions) can mutate a row's properties and call $store.Touch() to
     signal a redraw - this is the replacement for Dispatcher.Invoke + Refresh.
  4. The revision counter increments so a renderer knows to redraw.
Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-StateStore.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$fail = $false
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail = $true }
function Pass($m) { Write-Host "PASS: $m" -ForegroundColor Green }

# 1. Import with NO WPF
Import-Module (Join-Path $root 'src\Wuu.State.psm1') -Force
$wpf = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'PresentationFramework' }
if ($wpf) { Fail 'PresentationFramework is loaded (should not be after importing Wuu.State)' }
else { Pass 'Wuu.State imports with no WPF assembly loaded' }

# 2. Store + row lifecycle
$store = New-WuuStateStore
# NOTE: an empty ArrayList/hashtable is FALSY in PowerShell - test for $null, not truthiness.
if ($null -eq $store.Rows -or $null -eq $store.ByName) { Fail 'store missing Rows/ByName' }
elseif ($store.Rows.Count -ne 0) { Fail 'new store should be empty' }
else { Pass 'store created (empty, Rows/ByName present)' }

$row = New-WuuComputerRow -Computer 'SRV01'
if ($row.Computer -ne 'SRV01' -or $row.Pending -ne $true -or $row.Phase -ne 'Phase 1') { Fail 'row contract wrong' }
else { Pass 'row created with full property contract' }
# Property contract: every documented property must exist (rows throw on assigning undefined props)
$required = 'State','StateTimestamp','StateSource','Computer','Phase','Available','Downloaded',
            'InstallErrors','Status','RebootRequired','UpdatesStatus','Runspace','Pending','PendingOp',
            'TimeoutExpiresAt','TimeoutSource','RetryCount','RetryAt','Color','Revision',
            # SS5/SS8 additions: the per-op deadline (read by the cleanup loop), the op name that makes
            # a per-op budget possible, the liveness heartbeat, and the workflow-state predicate.
            'OpState','OpStartedAt','OpName','LastHeartbeatAt','Heartbeats','CheckConcluded',
            'ConnectivityFailures','LastConnectivityError'
$missing = @()
foreach ($p in $required) { if (-not $row.PSObject.Properties[$p]) { $missing += $p } }
if ($missing.Count) { Fail ("row missing properties: " + ($missing -join ', ')) } else { Pass "row has all $($required.Count) contract properties" }

Add-WuuComputerRow -Store $store -Row $row | Out-Null
if ($store.Rows.Count -ne 1) { Fail 'row not added' } else { Pass 'row added' }

$found = Get-WuuComputerRow -Store $store -Computer 'srv01'   # case-insensitive
if (-not $found -or $found.Computer -ne 'SRV01') { Fail 'case-insensitive lookup failed' } else { Pass 'case-insensitive lookup works' }

# duplicate add replaces
$row2 = New-WuuComputerRow -Computer 'SRV01'
Add-WuuComputerRow -Store $store -Row $row2 | Out-Null
if ($store.Rows.Count -ne 1 -or $store.ByName['srv01'] -ne $row2) { Fail 'duplicate add did not replace' } else { Pass 'duplicate add replaces existing row' }

# colour by name (no WPF brush)
Set-WuuComputerRowColor -Row $row2 -Color 'Error'
if ($row2.Color -ne 'Error') { Fail 'colour not set' } else { Pass 'colour set by name (no WPF Brush)' }

$revBefore = $store.Revision

# 3. ISOLATED WORKER RUNSPACE updates the store - the keystone contract.
#    Mirrors New-ComputerRunspace topology: fresh ISS, UseNewThread, STA, no module functions.
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$iss.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
$rs = [runspacefactory]::CreateRunspace($iss)
$rs.ApartmentState = 'STA'
$rs.Open()
$rs.SessionStateProxy.SetVariable('store', $store)
$rs.SessionStateProxy.SetVariable('target', 'SRV01')

$payload = {
    # Worker CANNOT call Add-WuuComputerRow/Get-WuuComputerRow (module functions).
    # Production workers resolve the row from the store's own synchronized hashtable.
    $r = $store.ByName['srv01']
    if (-not $r) { return 'ROW-NOT-FOUND' }
    $r.Status = 'Downloading 3 Updates (250MB).'
    $r.State = 'Downloading'
    $r.UpdatesStatus = 'Updates required'
    $store.Touch()          # redraw signal - replaces Items.Refresh()
    return 'OK'
}
$ps = [powershell]::Create().AddScript($payload)
$ps.Runspace = $rs
$h = $ps.BeginInvoke()
$out = $ps.EndInvoke($h)
$err = @($ps.Streams.Error)
$ps.Dispose(); $rs.Close(); $rs.Dispose()

if (@($out)[0] -ne 'OK') { Fail ("worker could not update store: " + (@($out) -join '|')) }
elseif ($err.Count) { Fail ("worker errored: " + ($err[0].Exception.Message)) }
else { Pass 'ISOLATED worker runspace mutated the row (module functions NOT needed)' }

if ($row2.Status -ne 'Downloading 3 Updates (250MB).' -or $row2.State -ne 'Downloading') {
    Fail "row not updated by worker (Status='$($row2.Status)' State='$($row2.State)')"
} else { Pass 'worker property writes landed on the live row' }

if ($store.Revision -le $revBefore) { Fail "Touch() did not bump Revision ($revBefore -> $($store.Revision))" }
else { Pass "Touch() bumped Revision ($revBefore -> $($store.Revision)) - renderer redraw signal works" }

# 4. Remove
$removed = Remove-WuuComputerRow -Store $store -Computer 'SRV01'
if (-not $removed -or $store.Rows.Count -ne 0) { Fail 'remove failed' } else { Pass 'remove works' }
if (Remove-WuuComputerRow -Store $store -Computer 'nope') { Fail 'remove of missing row returned true' } else { Pass 'remove of missing row returns false' }

# 5. Operator context (Phase 4 groundwork)
$op = New-WuuOperatorContext
if (-not $op.User -or -not $op.RunId -or -not $op.Machine) { Fail 'operator context incomplete' } else { Pass "operator context: $($op.User)@$($op.Machine) elevated=$($op.Elevated)" }

# 6. Settings + Status: the payload-facing replacement for the three Auto* checkboxes
#    and the StatusTextBox. Verified by grep that those are the ONLY $uiHash members
#    payloads need for behaviour (everything else is menu wiring / ListView chrome).
if ($store.Settings.AutoDownload -ne $false -or $store.Settings.AutoInstall -ne $false -or $store.Settings.AutoReboot -ne $false) {
    Fail 'settings should default to false'
} else { Pass 'settings default to false' }

Set-WuuSetting -Store $store -Name 'AutoDownload' -Value $true | Out-Null
Set-WuuSetting -Store $store -Name 'AutoInstall' -Value $true | Out-Null
if ($store.Settings.AutoDownload -ne $true -or $store.Settings.AutoInstall -ne $true) { Fail 'Set-WuuSetting did not persist' }
else { Pass 'Set-WuuSetting persists (AutoDownload/AutoInstall)' }

# invalid setting name must be rejected (ValidateSet)
$rejected = $false
try { Set-WuuSetting -Store $store -Name 'NotASetting' -Value $true | Out-Null } catch { $rejected = $true }
if (-not $rejected) { Fail 'invalid setting name was accepted' } else { Pass 'invalid setting name rejected' }

# Settings must be READABLE from an isolated worker runspace (payloads read them)
$store.SetStatus('test status from main')
$iss2 = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$iss2.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
$rs2 = [runspacefactory]::CreateRunspace($iss2); $rs2.ApartmentState='STA'; $rs2.Open()
$rs2.SessionStateProxy.SetVariable('store', $store)
$ps2 = [powershell]::Create().AddScript({
    # This is exactly what a payload does instead of reading a WPF checkbox
    $ad = $store.Settings.AutoDownload
    $ai = $store.Settings.AutoInstall
    $store.SetStatus('status written by worker')
    return "AD=$ad AI=$ai"
})
$ps2.Runspace = $rs2
$h2 = $ps2.BeginInvoke()
$out2 = @($ps2.EndInvoke($h2))
$ps2.Dispose(); $rs2.Close(); $rs2.Dispose()
if (@($out2)[0] -ne 'AD=True AI=True') { Fail ("worker could not read settings: " + (@($out2) -join '|')) }
else { Pass 'ISOLATED worker read Settings (replaces checkbox .IsChecked)' }
if ($store.Status -ne 'status written by worker') { Fail "worker SetStatus failed ('$($store.Status)')" }
else { Pass 'ISOLATED worker SetStatus works (replaces StatusTextBox.Text)' }

if ($fail) { Write-Host 'SOME CHECKS FAILED' -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS' -ForegroundColor Cyan }
