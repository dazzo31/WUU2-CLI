# Test: the phase failure policy (hardening brief SS9).
#
# WHY THIS MATTERS
# ----------------
# Phase gating used to be inert (it read a null Listview), and when it was repaired the only failure
# behaviour in the code was `continue` past errored/timed-out computers - i.e. ContinueOnFailure was
# the ONLY policy, hard-coded, with nothing in the UI or the audit trail saying so. A failed canary
# therefore permitted the next phase silently.
#
# This suite pins the three policies and, critically, that the DEFAULT is the blocking one.
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-PhaseFailurePolicy.ps1
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

$failures = @()
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -eq "$Expected") { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host ("FAIL: {0} - expected '{1}', got '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red; $script:failures += $Name }
}

# --- 1. The default is the SAFE policy ---------------------------------------------------------
$fresh = New-WuuStateStore
Assert-Equal $fresh.Settings['PhaseFailurePolicy'] 'BlockOnFailure' 'a new store defaults to BlockOnFailure (safety first)'

# An unrecognised policy must BLOCK. An unknown policy is a configuration error, and the safe response
# in a patching tool is to stop rather than proceed past a failed canary.
$errRow = New-WuuComputerRow -Computer 'E1'
$errRow.UpdatesStatus = 'Error'; $errRow.State = 'Error'
Assert-Equal (Test-WuuPhaseFailureBlocks -Row $errRow -Policy 'Nonsense') $true 'an unknown policy blocks (fails safe)'
Assert-Equal (Test-WuuPhaseFailureBlocks -Row $errRow -Policy '') $true 'an empty policy blocks (fails safe)'

# --- 2. Per-row decision table -----------------------------------------------------------------
$ok = New-WuuComputerRow -Computer 'OK1'
$ok.UpdatesStatus = 'All updates installed'; $ok.State = 'Complete'
foreach ($p in @('BlockOnFailure', 'ContinueOnTimeout', 'ContinueOnFailure')) {
    Assert-Equal (Test-WuuPhaseFailureBlocks -Row $ok -Policy $p) $false "a successful row never blocks ($p)"
}

$failed = New-WuuComputerRow -Computer 'F1'
$failed.UpdatesStatus = 'Error'; $failed.State = 'Error'
Assert-Equal (Test-WuuPhaseFailureBlocks -Row $failed -Policy 'BlockOnFailure') $true 'BlockOnFailure: a failed row blocks'
Assert-Equal (Test-WuuPhaseFailureBlocks -Row $failed -Policy 'ContinueOnTimeout') $true 'ContinueOnTimeout: a failed row STILL blocks (only timeouts are tolerated)'
Assert-Equal (Test-WuuPhaseFailureBlocks -Row $failed -Policy 'ContinueOnFailure') $false 'ContinueOnFailure: a failed row does not block'

$timed = New-WuuComputerRow -Computer 'T1'
$timed.UpdatesStatus = 'Timeout'; $timed.State = 'Timeout'
Assert-Equal (Test-WuuPhaseFailureBlocks -Row $timed -Policy 'BlockOnFailure') $true 'BlockOnFailure: a timed-out row blocks'
Assert-Equal (Test-WuuPhaseFailureBlocks -Row $timed -Policy 'ContinueOnTimeout') $false 'ContinueOnTimeout: a timed-out row does not block'
Assert-Equal (Test-WuuPhaseFailureBlocks -Row $timed -Policy 'ContinueOnFailure') $false 'ContinueOnFailure: a timed-out row does not block'

# Both signals must be honoured. The payloads write UpdatesStatus and the timeout paths write State,
# so a row that is failed via only one of them must still be seen as failed - relying on one signal is
# how a failed computer can look "settled but fine".
$stateOnly = New-WuuComputerRow -Computer 'S1'
$stateOnly.State = 'Error'                       # UpdatesStatus left at its default
Assert-Equal (Test-WuuPhaseFailureBlocks -Row $stateOnly -Policy 'BlockOnFailure') $true 'failure detected from State alone'
$statusOnly = New-WuuComputerRow -Computer 'S2'
$statusOnly.UpdatesStatus = 'Error'              # State left at its default
Assert-Equal (Test-WuuPhaseFailureBlocks -Row $statusOnly -Policy 'BlockOnFailure') $true 'failure detected from UpdatesStatus alone'

# Null tolerance (called in a loop).
Assert-Equal (Test-WuuPhaseFailureBlocks -Row $null -Policy 'BlockOnFailure') $false '$null row does not block (no throw)'

# --- 3. Through the REAL phase gate ------------------------------------------------------------
# The policy must actually change what Test-PhaseCompletion decides, or it is decoration.
$store = New-WuuStateStore
$global:LogPath = Join-Path $env:TEMP 'WUU_test_phasepolicy.log'
$global:LogLock = New-Object Object
$global:EnableDebugLogging = $false
$global:jobs = [system.collections.arraylist]::Synchronized((New-Object System.Collections.ArrayList))
$global:backgroundProcessing = [hashtable]::Synchronized(@{ Suspended = $false })

Initialize-WuuWindowsUpdateContext -Context @{
    StateStore = $store; Jobs = $global:jobs
    UpdatesHash = [hashtable]::Synchronized(@{}); PerformanceHash = [hashtable]::Synchronized(@{})
    ErrorSuggestions = New-WuuErrorSuggestions; Path = $PWD.Path
    LogPath = $global:LogPath; LogLock = $global:LogLock
    EnableDebugLogging = $false; EnableEnhancedErrorHandling = $false
    UseCustomCredentials = $false; CustomCredentials = $null; CredentialCache = @{}
    PerformanceThreshold = @{ CPUPercent = 80; MemoryMB = 1024; NetworkLatencyMs = 1000 }
    ConfigPaths = @{ DownloadScript = 'unused'; InstallScript = 'unused' }
    SearchTimeout = 5; SessionTimeout = 5; RebootCheckTimeout = 5
    MaxConcurrentJobs = 10; GetUpdates = { }; BackgroundProcessing = $global:backgroundProcessing
}

# A canary (Phase 1) with one success and one failure, and a Phase 2 that must be gated on it.
$c1 = New-WuuComputerRow -Computer 'CANARY-OK' -Phase 'Phase 1'
$c1.UpdatesStatus = 'All updates installed'; $c1.State = 'Complete'; $c1.Pending = $false
Add-WuuComputerRow -Store $store -Row $c1 | Out-Null
$c2 = New-WuuComputerRow -Computer 'CANARY-BAD' -Phase 'Phase 1'
$c2.UpdatesStatus = 'Error'; $c2.State = 'Error'; $c2.Pending = $false
Add-WuuComputerRow -Store $store -Row $c2 | Out-Null
$p2row = New-WuuComputerRow -Computer 'P2-1' -Phase 'Phase 2'
$p2row.Pending = $false
Add-WuuComputerRow -Store $store -Row $p2row | Out-Null

# Default: the failed canary must block Phase 2.
Assert-Equal (Test-PhaseReady -Phase 'Phase 2') $false 'DEFAULT: a failed Phase 1 blocks Phase 2 (this is the fix)'

# The blocking is specifically the failure policy, not some other condition: switching policy alone
# must unblock it while every row state stays identical.
Set-WuuPhaseFailurePolicy -Store $store -Policy 'ContinueOnFailure'
Assert-Equal (Test-PhaseCompletion -Phase 'Phase 1') $true 'ContinueOnFailure: Phase 1 is considered complete despite the failure'
Assert-Equal (Test-PhaseReady -Phase 'Phase 2') $true 'ContinueOnFailure: Phase 2 is permitted'

Set-WuuPhaseFailurePolicy -Store $store -Policy 'BlockOnFailure'
Assert-Equal (Test-PhaseCompletion -Phase 'Phase 1') $false 'BlockOnFailure: Phase 1 is NOT complete while a canary has failed'
Assert-Equal (Test-PhaseReady -Phase 'Phase 2') $false 'BlockOnFailure: Phase 2 is blocked again'

# ContinueOnTimeout must still block on a genuine FAILURE...
Set-WuuPhaseFailurePolicy -Store $store -Policy 'ContinueOnTimeout'
Assert-Equal (Test-PhaseCompletion -Phase 'Phase 1') $false 'ContinueOnTimeout: a hard failure still blocks'

# ...but not on a timeout.
$c2.UpdatesStatus = 'Timeout'; $c2.State = 'Timeout'
Assert-Equal (Test-PhaseCompletion -Phase 'Phase 1') $true 'ContinueOnTimeout: a timeout does not block'

# --- 4. The policy is validated ----------------------------------------------------------------
$threw = $false
try { Set-WuuPhaseFailurePolicy -Store $store -Policy 'Whatever' } catch { $threw = $true }
Assert-Equal $threw $true 'Set-WuuPhaseFailurePolicy rejects an invalid policy'

# --- 5. A phase with computers still working is never "complete" -------------------------------
# Independent of the failure policy - this is the property the null-Listview bug destroyed.
$workStore = New-WuuStateStore
Initialize-WuuWindowsUpdateContext -Context @{
    StateStore = $workStore; Jobs = $global:jobs
    UpdatesHash = [hashtable]::Synchronized(@{}); PerformanceHash = [hashtable]::Synchronized(@{})
    ErrorSuggestions = New-WuuErrorSuggestions; Path = $PWD.Path
    LogPath = $global:LogPath; LogLock = $global:LogLock
    EnableDebugLogging = $false; EnableEnhancedErrorHandling = $false
    UseCustomCredentials = $false; CustomCredentials = $null; CredentialCache = @{}
    PerformanceThreshold = @{ CPUPercent = 80; MemoryMB = 1024; NetworkLatencyMs = 1000 }
    ConfigPaths = @{ DownloadScript = 'unused'; InstallScript = 'unused' }
    SearchTimeout = 5; SessionTimeout = 5; RebootCheckTimeout = 5
    MaxConcurrentJobs = 10; GetUpdates = { }; BackgroundProcessing = $global:backgroundProcessing
}
$busy = New-WuuComputerRow -Computer 'BUSY1' -Phase 'Phase 1'
$busy.Pending = $true
Add-WuuComputerRow -Store $workStore -Row $busy | Out-Null
Assert-Equal (Test-PhaseCompletion -Phase 'Phase 1') $false 'a phase with a queued computer is not complete'

$busy.Pending = $false; $busy.Available = 3
Assert-Equal (Test-PhaseCompletion -Phase 'Phase 1') $false 'a phase with updates still outstanding is not complete'

$busy.Available = 0; $busy.Downloaded = 0; $busy.RebootRequired = $false
# SS8: the DISPLAY string is no longer the predicate. This assertion used to flip the row to complete
# by setting UpdatesStatus alone - i.e. it encoded the very defect SS8 removes, so it kept passing
# while the gate read a status message. A row settles as "checked, nothing outstanding" via the
# WORKFLOW fields; UpdatesStatus is still set because production sets both together.
$busy.State = 'Complete'; $busy.CheckConcluded = $false; $busy.UpdatesStatus = 'All updates installed'
Assert-Equal (Test-PhaseCompletion -Phase 'Phase 1') $true 'a phase whose computers all settled successfully IS complete'

Assert-Equal (Test-PhaseCompletion -Phase 'Phase 4') $true 'an empty phase is complete (does not block)'

Write-Host ''
if ($failures.Count) {
    Write-Host ("SOME CHECKS FAILED ({0}): {1}" -f $failures.Count, ($failures -join '; ')) -ForegroundColor Red
    exit 1
}
Write-Host 'ALL PASS' -ForegroundColor Cyan
