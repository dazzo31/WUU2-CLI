# Test: the scheduler executes operations SERIALLY per computer and respects the global limit.
#
# WHY THIS SUITE EXISTS (SS3/SS4 of the hardening brief)
# ------------------------------------------------------
# Test-ComputerBusy verifies the gate in isolation. THIS suite verifies the behaviour it produces
# through the REAL scheduler, which was previously a no-op and, once repaired, could easily have been
# made to skip every row for ever by treating the Pending flag as "busy".
#
# It pins four things that are easy to break by "simplifying" the scheduler:
#   1. a queued operation actually starts and completes (the queue is not dead);
#   2. a computer with an operation in flight is not submitted to again;
#   3. the refused request is NOT lost - it stays queued and runs once the computer is free;
#   4. the scheduler path respects the global MaxConcurrentJobs cap.
#
# CONCURRENCY IS DERIVED FROM LOG TIMESTAMPS, NOT SHARED STATE. The payload runs in an ISOLATED
# runspace, so it cannot see a caller's variables - passing a shared hashtable in and mutating it
# from the worker silently does nothing (the first version of this test did exactly that and reported
# a false failure). A literal log path written from inside the worker is the only channel, and the
# overlap is computed from the enter/exit ticks afterwards.
#
# EACH WORKER OWNS ITS OWN LOG FILE (one per computer). A single shared file is NOT safe to append to
# from more than one runspace: Add-Content is open/append/close, so two writers interleave and the
# loser's whole line is lost. Measured: 770 of 800 lines lost with two concurrent writers, 0 of 400
# with one. This suite used one shared file and flaked roughly 1 run in 16. Per-computer files remove
# the contention by construction, because the scheduler allows at most one operation per computer.
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-SchedulerSerialization.ps1
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

$stateStore = New-WuuStateStore
$global:jobs = [system.collections.arraylist]::Synchronized((New-Object System.Collections.ArrayList))
$global:backgroundProcessing = [hashtable]::Synchronized(@{ Suspended = $false })
$global:MaxConcurrentJobs = 10
$global:LogPath = Join-Path $env:TEMP 'WUU_test_schedserial.log'
$global:LogLock = New-Object Object
$global:EnableDebugLogging = $false
$global:searchTimeout = 5; $global:sessionTimeout = 5; $global:rebootCheckTimeout = 5
$global:updatesHash = [hashtable]::Synchronized(@{})
$global:performanceHash = [hashtable]::Synchronized(@{})
$global:errorSuggestionsHash = New-WuuErrorSuggestions
$global:ConfigPaths = @{ DownloadScript = 'unused'; InstallScript = 'unused' }
$global:UseCustomCredentials = $false; $global:CustomCredentials = $null; $global:CredentialCache = @{}
$global:PerformanceThreshold = @{ CPUPercent = 80; MemoryMB = 1024; NetworkLatencyMs = 1000 }
$global:EnableEnhancedErrorHandling = $false

$markerDir = Join-Path $env:TEMP ("WUU_sched_{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $markerDir -Force | Out-Null

# A worker that has just finished can still hold its file handle for a moment - the pipeline reports
# completion BEFORE the handle is released. A bare read then fails, and with -ErrorAction
# SilentlyContinue it yields an EMPTY result, which reads as "no payload ever ran". Every read goes
# through this retry helper so a transient lock cannot masquerade as a failed assertion.
function Get-MarkerLines {
    $all = @()
    foreach ($f in @(Get-ChildItem -Path $markerDir -Filter '*.log' -ErrorAction SilentlyContinue)) {
        for ($i = 1; $i -le 20; $i++) {
            try { $all += @([System.IO.File]::ReadAllLines($f.FullName)); break }
            catch { Start-Sleep -Milliseconds 50 }
        }
    }
    return @($all)
}
function Reset-Marker {
    foreach ($f in @(Get-ChildItem -Path $markerDir -Filter '*.log' -ErrorAction SilentlyContinue)) {
        for ($i = 1; $i -le 20; $i++) {
            try { Remove-Item $f.FullName -Force -ErrorAction Stop; break }
            catch { Start-Sleep -Milliseconds 50 }
        }
    }
}

# Payload stub: writes enter/exit ticks to a LITERAL directory (interpolated here, at creation time)
# in a file named for the computer it was handed, so no two workers share a path. It uses only the row
# it is handed, so it needs nothing injected into the worker runspace.
$getUpdatesPayload = [scriptblock]::Create(@"
param(`$ComputerItem)
`$k = [string]`$ComputerItem.Computer
`$f = Join-Path '$markerDir' "`$k.log"
Add-Content -Path `$f -Value ("enter|`$k|" + [DateTime]::UtcNow.Ticks)
Start-Sleep -Milliseconds 400
Add-Content -Path `$f -Value ("exit|`$k|" + [DateTime]::UtcNow.Ticks)
"@)

function Initialize-TestCtx($store, $maxConcurrent) {
    Initialize-WuuWindowsUpdateContext -Context @{
        StateStore                  = $store
        Jobs                        = $global:jobs
        UpdatesHash                 = $global:updatesHash
        PerformanceHash             = $global:performanceHash
        ErrorSuggestions            = $global:errorSuggestionsHash
        Path                        = $PWD.Path
        LogPath                     = $global:LogPath
        LogLock                     = $global:LogLock
        EnableDebugLogging          = $false
        EnableEnhancedErrorHandling = $false
        UseCustomCredentials        = $false
        CustomCredentials           = $null
        CredentialCache             = $global:CredentialCache
        PerformanceThreshold        = $global:PerformanceThreshold
        ConfigPaths                 = $global:ConfigPaths
        SearchTimeout               = $global:searchTimeout
        SessionTimeout              = $global:sessionTimeout
        RebootCheckTimeout          = $global:rebootCheckTimeout
        MaxConcurrentJobs           = $maxConcurrent
        GetUpdates                  = $getUpdatesPayload
        BackgroundProcessing        = $global:backgroundProcessing
    }
}

# Retire completed jobs exactly as the real cleanup loop does: EndInvoke, dispose, drop, and release
# the per-computer operation lock. The harness must do this or OpState never returns to Idle.
function Complete-Jobs($store) {
    foreach ($j in @($global:jobs)) {
        if ($j.Runspace -and $j.Runspace.IsCompleted) {
            try { $j.PowerShell.EndInvoke($j.Runspace) | Out-Null } catch { }
            try { $j.PowerShell.Dispose() } catch { }
            $global:jobs.Remove($j)
            $row = Get-WuuComputerRow -Store $store -Computer $j.Computer
            if ($row) { $row.OpState = 'Idle'; $row.OpStartedAt = $null }
        }
    }
}

Initialize-TestCtx $stateStore 10

# --- 1. A queued operation starts (the queue is not dead) -------------------------------------
$r1 = New-WuuComputerRow -Computer 'S1'
$r1.Pending = $true; $r1.PendingOp = $null; $r1.Runspace = $null
Add-WuuComputerRow -Store $stateStore -Row $r1 | Out-Null
Start-PendingUpdateCheck
Assert-True ($global:jobs.Count -eq 1) 'scheduler starts a queued operation (queue is not dead)'
Assert-True ($r1.OpState -eq 'Running') "submitting sets OpState=Running (got '$($r1.OpState)')"
Assert-True ((Test-WuuComputerBusy -Row $r1 -IgnorePending)) 'a computer with an op in flight is busy to the scheduler'

# --- 2. The SAME computer is not submitted to again while running ------------------------------
$r1.Pending = $true
Start-PendingUpdateCheck
Assert-True ($global:jobs.Count -eq 1) 'a second operation for a busy computer is NOT submitted'
Assert-True ($r1.Pending) 'the refused request stays Pending (not silently dropped)'

# --- 3. Let it settle, then confirm the deferred request runs ---------------------------------
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 25) {
    Start-PendingUpdateCheck
    Start-Sleep -Milliseconds 100
    Complete-Jobs $stateStore
    if ($global:jobs.Count -eq 0 -and -not $r1.Pending) { break }
}
Assert-True ($r1.OpState -eq 'Idle') "OpState is released once the operation settles (got '$($r1.OpState)')"

$lines = @(Get-MarkerLines)
$enters = @($lines | Where-Object { $_ -like 'enter|S1|*' }).Count
$exits = @($lines | Where-Object { $_ -like 'exit|S1|*' }).Count
Assert-True ($enters -ge 1) "the operation actually ran (payload entered $enters time(s))"
Assert-True ($exits -ge 1) "the operation completed (payload exited $exits time(s))"
Assert-True ($enters -ge 2) "the deferred request ran after the computer freed up (entered $enters time(s))"

# --- 4. Per-computer serialization, from the log ----------------------------------------------
# No two enter/exit intervals for the SAME computer may overlap. Computed from ticks so it does not
# depend on any shared state - the worker only wrote to a file.
function Get-PeakDepth([string]$computer) {
    $ev = @()
    foreach ($l in @(Get-MarkerLines)) {
        $p = $l -split '\|'
        if ($p.Count -eq 3 -and $p[1] -eq $computer) { $ev += [pscustomobject]@{ Kind = $p[0]; Tick = [long]$p[2] } }
    }
    $ev = @($ev | Sort-Object Tick)
    $depth = 0; $maxDepth = 0
    foreach ($e in $ev) {
        if ($e.Kind -eq 'enter') { $depth++; if ($depth -gt $maxDepth) { $maxDepth = $depth } }
        else { $depth-- }
    }
    return $maxDepth
}
Assert-True ((Get-PeakDepth 'S1') -le 1) "S1 never had two operations overlapping (peak depth $(Get-PeakDepth 'S1'))"

# --- 5. Global concurrency cap is respected by the scheduler path -----------------------------
$fleetStore = New-WuuStateStore
Reset-Marker
foreach ($n in 1..6) {
    $row = New-WuuComputerRow -Computer ("F$n")
    $row.Pending = $true; $row.Runspace = $null
    Add-WuuComputerRow -Store $fleetStore -Row $row | Out-Null
}
Initialize-TestCtx $fleetStore 2

# Tick repeatedly WITHOUT retiring jobs: the scheduler must stop at the cap even though 6 rows are
# pending. This is the assertion that proves the cap applies to the scheduler path.
foreach ($tick in 1..12) { Start-PendingUpdateCheck; Start-Sleep -Milliseconds 60 }
Assert-True ($global:jobs.Count -le 2) "scheduler never exceeds MaxConcurrentJobs=2 (running: $($global:jobs.Count))"
Assert-True ($global:jobs.Count -ge 1) 'the scheduler did start work under the cap (the cap is not a no-op)'

# --- 6. Every queued computer eventually runs --------------------------------------------------
$sw2 = [Diagnostics.Stopwatch]::StartNew()
while ($sw2.Elapsed.TotalSeconds -lt 30) {
    Start-PendingUpdateCheck; Start-Sleep -Milliseconds 100; Complete-Jobs $fleetStore
    $pendingLeft = @(Get-WuuComputerRow -Store $fleetStore | Where-Object { $_.Pending }).Count
    if ($global:jobs.Count -eq 0 -and $pendingLeft -eq 0) { break }
}
$fleetEnters = @(Get-MarkerLines | Where-Object { $_ -like 'enter|F*' }).Count
Assert-True ($fleetEnters -ge 6) "every queued computer eventually ran (entered $fleetEnters of 6)"
if ($fleetEnters -lt 6) {
    # DIAGNOSTIC. This assertion used to flake about 1 run in 16 with "entered 0 of 6" while the cap
    # assertion above PASSED - jobs existed but no payload line was found. That was the shared-marker
    # contention described in the header, not scheduler logic. The state is still dumped on failure so
    # that a genuine worker/runspace death - which would look identical from out here - is reportable
    # rather than guessed at.
    Write-Host '  DIAGNOSTIC: fleet jobs did not all run -' -ForegroundColor Yellow
    Write-Host ("    jobs.Count={0}  markerLines={1}" -f $global:jobs.Count, @(Get-MarkerLines).Count) -ForegroundColor Yellow
    foreach ($j in @($global:jobs)) {
        $rs = $j.Runspace
        $state = if ($rs) { [string]$rs.RunspaceStateInfo.State } else { '(none)' }
        $avail = if ($rs) { [string]$rs.RunspaceAvailability } else { '(none)' }
        # HadErrors on the PowerShell object is what distinguishes "still running" from "died".
        $had = $null
        try { $had = $j.PowerShell.HadErrors } catch { $had = '(unreadable)' }
        Write-Host ("    job {0,-6} runspace={1,-12} availability={2,-8} hadErrors={3}" -f $j.Computer, $state, $avail, $had) -ForegroundColor Yellow
    }
    $rowsLeft = @(Get-WuuComputerRow -Store $fleetStore)
    foreach ($r in $rowsLeft) {
        Write-Host ("    row {0,-6} Pending={1} OpState={2} OperationId={3}" -f $r.Computer, [bool]$r.Pending, $r.OpState, $r.OperationId) -ForegroundColor Yellow
    }
}

# Clean up.
foreach ($j in @($global:jobs)) { try { $j.PowerShell.Stop() } catch { }; try { $j.PowerShell.Dispose() } catch { } }
$global:jobs.Clear() | Out-Null
Remove-Item $markerDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($failures.Count) {
    Write-Host ("SOME CHECKS FAILED ({0}): {1}" -f $failures.Count, ($failures -join '; ')) -ForegroundColor Red
    exit 1
}
Write-Host 'ALL PASS' -ForegroundColor Cyan
