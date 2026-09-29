# Test: connectivity classification does not evict inventory on a single failure (SS12),
# and the management-endpoint probe is non-hanging and honest about WHY it failed (SS7).
#
# WHY THIS SUITE EXISTS
# ---------------------
# $RemoveOfflineComputer used ONE `Test-Connection -Count 1` and DELETED the row when it failed. So a
# single lost ICMP packet - or simply a host with inbound echo blocked, which is the Windows Firewall
# default - removed a healthy server from the managed set, after which it silently stopped being
# patched. The same one-packet signal was also load-bearing for reboot state.
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-ConnectivityClassification.ps1
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

$failures = @()
function Assert-True($Condition, $Name) {
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host "FAIL: $Name" -ForegroundColor Red; $script:failures += $Name }
}
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -eq "$Expected") { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host "FAIL: $Name - expected '$Expected', got '$Actual'" -ForegroundColor Red; $script:failures += $Name }
}

# --- 1. The probe is non-hanging and reports WHY it failed -------------------------------------
# A host that cannot exist: must fail fast with a reason, never block.
$sw = [Diagnostics.Stopwatch]::StartNew()
$unresolvable = Test-WuuManagementEndpoint -ComputerName 'WUU-DOES-NOT-EXIST-000000'
$sw.Stop()
Assert-True ($sw.Elapsed.TotalSeconds -lt 15) "the probe returns quickly for an unresolvable host ($([math]::Round($sw.Elapsed.TotalSeconds,1))s)"
Assert-Equal $unresolvable.Resolves $false 'an unresolvable host reports Resolves=false'
Assert-Equal $unresolvable.Endpoint $false 'an unresolvable host reports Endpoint=false'
Assert-True (-not [string]::IsNullOrWhiteSpace($unresolvable.Reason)) "the probe says WHY it failed ('$($unresolvable.Reason)')"
Assert-Equal $unresolvable.Computer 'WUU-DOES-NOT-EXIST-000000' 'the probe echoes the computer it tested'

# The distinction matters: "not resolvable" is a different operator action from "resolves but no
# endpoint". One result object must be able to express both. Checked against ResolvedIps, which
# EXISTS on a hashtable even when empty - PSObject.Properties does not list hashtable keys, which is
# why an earlier version of this assertion failed for the wrong reason.
Assert-True ($unresolvable.Contains('ResolvedIps')) 'the probe reports resolved addresses separately'

# A resolvable host: exercises the TCP path rather than the DNS path.
$localhostProbe = Test-WuuManagementEndpoint -ComputerName 'localhost'
Assert-Equal $localhostProbe.Resolves $true 'a resolvable host reports Resolves=true'
Assert-True ($localhostProbe.ResolvedIps.Count -ge 1) 'resolved addresses are captured'

# --- 2. The classification decision, driven directly -------------------------------------------
# Update-WuuConnectivityState holds the decision so it can be tested without a network, a runspace or
# a scheduler. An earlier version of this suite tried to invoke the worker payload instead, which is
# unreachable from a test scope - so the assertions silently proved nothing.
$store = New-WuuStateStore
$global:ConnectivityFailuresBeforeRemoval = 2
$updatesHashLocal = [hashtable]::Synchronized(@{})

$row = New-WuuComputerRow -Computer 'C1'
Add-WuuComputerRow -Store $store -Row $row | Out-Null
$updatesHashLocal['c1'] = 'update-list'

# (a) UNREACHABLE, below the threshold -> kept, recorded, NOT deleted.
$down = @{ Resolves = $false; Endpoint = $false; Reason = 'no response within 3000ms' }
$v1 = Update-WuuConnectivityState -Row $row -ProbeResult $down -Store $store -UpdatesHash $updatesHashLocal -FailuresBeforeRemoval 2
Assert-Equal $v1.Action 'kept' 'one failed probe is classified as kept (SS12)'
Assert-Equal (@(Get-WuuComputerRow -Store $store).Count) 1 'ONE failed probe does NOT remove the computer'
Assert-Equal $row.ConnectivityFailures 1 'the failure is recorded'
Assert-Equal $row.State 'Offline' 'an unreachable computer is marked Offline, not deleted'
Assert-Equal $row.LastConnectivityError 'no response within 3000ms' 'the reason is recorded on the row'
Assert-True ($row.Status -match 'kept in the set') 'the status explains that the computer was kept'
Assert-Equal $row.Pending $false 'a queued request is cancelled for an unreachable host (scheduler will not spin)'

# (b) A REACHABLE probe clears the failure count, so blips cannot accumulate towards removal.
$up = @{ Resolves = $true; Endpoint = $true; Reason = '' }
$v2 = Update-WuuConnectivityState -Row $row -ProbeResult $up -Store $store -UpdatesHash $updatesHashLocal -FailuresBeforeRemoval 2
Assert-Equal $v2.Action 'online' 'a reachable probe classifies as online'
Assert-Equal $row.ConnectivityFailures 0 'a recovered computer has its failure count RESET (blips cannot accumulate)'
Assert-Equal $row.LastConnectivityError '' 'the stale error is cleared on recovery'
Assert-Equal $row.State 'Connected' 'a reachable computer is marked Connected'

# (c) REACHABLE then UNREACHABLE twice -> the threshold removes it (pruning still works).
$null = Update-WuuConnectivityState -Row $row -ProbeResult $down -Store $store -UpdatesHash $updatesHashLocal -FailuresBeforeRemoval 2
$v3 = Update-WuuConnectivityState -Row $row -ProbeResult $down -Store $store -UpdatesHash $updatesHashLocal -FailuresBeforeRemoval 2
Assert-Equal $v3.Action 'removed' 'repeated failure at the threshold IS removed (the feature still works)'
Assert-Equal (@(Get-WuuComputerRow -Store $store).Count) 0 'the row is gone after the threshold'

# (d) A probe that could not RUN is not evidence of anything. "Cannot tell" must never be treated as
# offline, or an unprobed fleet looks dead - the same false-alarm class as the pre-flight offline count.
$unknownRow = New-WuuComputerRow -Computer 'C2'
Add-WuuComputerRow -Store $store -Row $unknownRow | Out-Null
$v4 = Update-WuuConnectivityState -Row $unknownRow -ProbeResult $null -Store $store -UpdatesHash $updatesHashLocal -FailuresBeforeRemoval 2
Assert-Equal $v4.Action 'kept' 'a missing probe result does not remove the computer'
Assert-Equal $unknownRow.State 'Offline' 'a missing probe result reports unreachable-and-kept, not deleted'

# (e) Null tolerance - called in loops.
$nullRowVerdict = Update-WuuConnectivityState -Row $null -ProbeResult $up -Store $store
Assert-Equal $nullRowVerdict.Action 'skip' '$null row is handled (no throw)'

# --- 3. ICMP must no longer be the signal ------------------------------------------------------
# Checked against COMMENT-STRIPPED source. Matching raw text is a false positive here: the migration
# comments quote "Test-Connection" deliberately when explaining what was removed, which is exactly the
# trap the validator's own gates document. (Checked with the tokenizer for the same reason.)
function Get-WuuCodeOnly([string]$Path) {
    $tkErr = $null
    $tokens = [System.Management.Automation.PSParser]::Tokenize((Get-Content $Path -Raw), [ref]$tkErr)
    $sb = New-Object System.Text.StringBuilder
    foreach ($t in $tokens) { if ($t.Type -ne 'Comment') { [void]$sb.Append($t.Content).Append(' ') } }
    return $sb.ToString()
}
$coreCodeOnly = Get-WuuCodeOnly (Join-Path $root 'src\Wuu.Core.psm1')

# The connectivity payload and the reboot wait must not DECIDE with ICMP.
$offlineIdx = $coreCodeOnly.IndexOf('RemoveOfflineComputer =')
$offlineBody = $coreCodeOnly.Substring($offlineIdx, [Math]::Min(2500, $coreCodeOnly.Length - $offlineIdx))
Assert-True ($offlineBody -notmatch 'Test-Connection') 'the connectivity payload no longer decides with Test-Connection'
Assert-True ($offlineBody -match 'Test-WuuManagementEndpoint') 'the connectivity payload uses the management endpoint probe'

$restartIdx = $coreCodeOnly.IndexOf('RestartComputer =')
$restartBody = $coreCodeOnly.Substring($restartIdx, [Math]::Min(7000, $coreCodeOnly.Length - $restartIdx))
Assert-True ($restartBody -notmatch 'Test-Connection') 'the reboot wait no longer uses ICMP at all'
Assert-True ($restartBody -match 'Test-WuuManagementEndpoint') 'the reboot wait uses the management endpoint probe'
Assert-True ($restartBody -match 'Restart-Computer') 'the reboot wait still ISSUES the restart (it was accidentally dropped once)'

Write-Host ''
if ($failures.Count) {
    Write-Host ("SOME CHECKS FAILED ({0}): {1}" -f $failures.Count, ($failures -join '; ')) -ForegroundColor Red
    exit 1
}
Write-Host 'ALL PASS' -ForegroundColor Cyan
