# Test: the global concurrency cap at the submission point (hardening brief SS4 / invariant 8.6).
#
# WHY THIS SUITE EXISTS
# ---------------------
# The cap used to be applied in exactly ONE place: the scheduler tick (`Start-PendingUpdateCheck`).
# Every console handler calls the submission point (`Start-UpdateCheckJob`) DIRECTLY, in a loop, so
# on that path the cap was never consulted:
#
#     .BeginInvoke() bypasses the per-computer gate AND the global MaxConcurrentJobs cap
#
# The per-computer gate (8.1) bounds each computer to one operation, but it says nothing about how
# many computers run at once. So `-All check` over a large estate could start one pipeline per
# computer with no ceiling. The only `MaxConcurrentJobs` mention inside the submission point was a
# COMMENT, and the validator had no gate for the cap at all.
#
# This suite drives the REAL submission point directly - the exploit path - and asserts the cap holds
# there, not merely in the scheduler. It also asserts the cap is not a NO-OP, because a gate that
# refuses everything would pass a "never exceeds the cap" test while breaking the product.
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-ConcurrencyCap.ps1
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$failures = @()
function Assert-True($Condition, $Name) {
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host ("FAIL: {0}" -f $Name) -ForegroundColor Red; $script:failures += $Name }
}
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -eq "$Expected") { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host ("FAIL: {0} - expected '{1}', got '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red; $script:failures += $Name }
}

# ---------------------------------------------------------------------------------------
# 1. the predicate in isolation
# ---------------------------------------------------------------------------------------
Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

$empty = [System.Collections.ArrayList]::new()
Assert-True (Test-WuuConcurrencyAvailable -Jobs $empty -MaxConcurrentJobs 3) '1. capacity available when nothing is in flight'
$empty.Add(1) | Out-Null; $empty.Add(2) | Out-Null
Assert-True (Test-WuuConcurrencyAvailable -Jobs $empty -MaxConcurrentJobs 3) '1. capacity available below the cap'
$empty.Add(3) | Out-Null
Assert-True (-not (Test-WuuConcurrencyAvailable -Jobs $empty -MaxConcurrentJobs 3)) '1. capacity refused AT the cap'
$empty.Add(4) | Out-Null
Assert-True (-not (Test-WuuConcurrencyAvailable -Jobs $empty -MaxConcurrentJobs 3)) '1. capacity refused above the cap'

Assert-True (-not (Test-WuuConcurrencyAvailable -Jobs $null -MaxConcurrentJobs 5)) '1. a missing job list fails closed'
Assert-True (-not (Test-WuuConcurrencyAvailable -Jobs $empty -MaxConcurrentJobs 0)) '1. a cap of 0 refuses (a misconfigured cap stops work rather than removing the limit)'
Assert-True (-not (Test-WuuConcurrencyAvailable -Jobs $empty -MaxConcurrentJobs -1)) '1. a negative cap refuses'

# The predicate must agree with the scheduler's own inline test, or the two admission paths would
# disagree about the same estate. The scheduler breaks when `$jobs.Count -ge $MaxConcurrentJobs`.
$agree = $true
foreach ($count in 0..6) {
    foreach ($cap in @(1, 2, 3, 5, 10)) {
        $list = [System.Collections.ArrayList]::new()
        if ($count -gt 0) { 1..$count | ForEach-Object { $list.Add($_) | Out-Null } }
        $mine = Test-WuuConcurrencyAvailable -Jobs $list -MaxConcurrentJobs $cap
        $schedulerAdmits = -not ($list.Count -ge $cap)
        if ($mine -ne $schedulerAdmits) { $agree = $false }
    }
}
Assert-True $agree '1. the predicate agrees with the scheduler tick condition at every count and cap (35 combinations)'

# ---------------------------------------------------------------------------------------
# 2. drive the REAL submission point directly - the path the cap was missing on
# ---------------------------------------------------------------------------------------
$stateStore = New-WuuStateStore
$global:jobs = [system.collections.arraylist]::Synchronized((New-Object System.Collections.ArrayList))
$global:backgroundProcessing = [hashtable]::Synchronized(@{ Suspended = $false })
$global:MaxConcurrentJobs = 2
$global:LogPath = Join-Path $env:TEMP 'WUU_test_cap.log'
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
$global:CredentialEpoch = 0

# One FILE per event, in a directory - not one appended file. Two payloads run concurrently by
# design here, and `Add-Content` from two runspaces/processes has NO interlock: the appends can
# interleave inside a single line, so the timestamp parse is corrupted and the derived peak is wrong.
# That produced a FLAKE (peak 3 with a cap of 2) which looked exactly like a cap violation. A unique
# file per event cannot interleave, and the event is reconstructed from the filename plus one line.
$markerDir = Join-Path $env:TEMP ("WUU_cap_{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $markerDir -Force | Out-Null

function Get-MarkerEvents([string]$Dir) {
    $events = @()
    foreach ($f in @(Get-ChildItem $Dir -Filter '*.evt' -ErrorAction SilentlyContinue)) {
        $name = [IO.Path]::GetFileNameWithoutExtension($f.Name)   # <computer>.<kind>.<ticks>
        $parts = $name -split '\.'
        if ($parts.Count -ne 3) { continue }
        $events += [pscustomobject]@{ Computer = $parts[0]; Kind = $parts[1]; At = [long]$parts[2] }
    }
    return @($events | Sort-Object At)
}

# Payload stub: records enter/exit so overlap can be proven from timestamps (the payload runs in an
# isolated runspace and cannot share state). Slow enough that the cap is exercised, not raced past.
$getUpdatesPayload = [scriptblock]::Create(@"
param(`$ComputerItem)
`$k = [string]`$ComputerItem.Computer
`$t1 = [DateTime]::UtcNow.Ticks
Set-Content -Path (Join-Path '$markerDir' (`"`$k.enter.`$t1.evt`")) -Value `$t1
Start-Sleep -Milliseconds 700
`$t2 = [DateTime]::UtcNow.Ticks
Set-Content -Path (Join-Path '$markerDir' (`"`$k.exit.`$t2.evt`")) -Value `$t2
"@)

Initialize-WuuWindowsUpdateContext -Context @{
    StateStore                  = $stateStore
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
    MaxConcurrentJobs           = 2
    GetUpdates                  = $getUpdatesPayload
    BackgroundProcessing        = $global:backgroundProcessing
}

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

# Six idle computers, NONE of them Pending - the direct-submission path a console handler takes.
$rows = @()
foreach ($n in 1..6) {
    $r = New-WuuComputerRow -Computer ("CAP0{0}" -f $n)
    $r.Pending = $false; $r.PendingOp = $null; $r.Runspace = $null
    Add-WuuComputerRow -Store $stateStore -Row $r | Out-Null
    $rows += $r
}

# The exploit: submit directly, in a loop, exactly as a console handler does.
$admitted = 0; $deferred = 0
foreach ($r in $rows) {
    if (Start-UpdateCheckJob -ComputerItem $r -Op 'Check') { $admitted++ } else { $deferred++ }
}

Assert-Equal $admitted 2 '2. a direct loop over 6 computers admits exactly MaxConcurrentJobs=2 (the cap holds on the exploit path)'
Assert-Equal $deferred 4 '2. the other 4 are refused rather than started'
Assert-Equal $global:jobs.Count 2 "2. in-flight count equals the cap (got $($global:jobs.Count))"

# A refused row must NOT be left busy. If the cap check ran AFTER OpState was set, the computer would
# be permanently unschedulable - a worse failure than the missing cap it was fixing.
$stuck = @($rows | Where-Object { $_.OpState -eq 'Running' -and $global:jobs.Computer -notcontains $_.Computer })
Assert-Equal $stuck.Count 0 "2. no refused row is left 'Running' (a refusal must not mark the computer busy)"
$deferredRows = @($rows | Where-Object { $_.OpState -ne 'Running' })
Assert-Equal $deferredRows.Count 4 '2. the refused rows remain Idle, so they can be admitted later'

# ---------------------------------------------------------------------------------------
# 3. the cap is not a no-op: the estate eventually drains, still never exceeding the cap
# ---------------------------------------------------------------------------------------
# Each computer is submitted AT MOST ONCE. The first version of this loop re-submitted every
# non-Running row on every iteration, so rows ran ~24 times each (142 runs for 6 computers) - which
# made the "nothing was starved" assertion nearly vacuous, since a run count of 6 was reached in the
# first iteration whatever happened. Tracking admission explicitly is what makes "all 6 ran" mean
# "all 6 were admitted under the cap", not "the loop was busy".
$submitted = @{}
$maxObserved = $global:jobs.Count
# The marker is shared with section 2, where 2 computers were admitted and ran. Counting the DELTA
# for this section is what makes the assertion precise: without it the expected count is 8 (2 + 6)
# rather than 6, and asserting 6 would be wrong in a way that looks like a real failure.
$runsBefore = @(Get-MarkerEvents -Dir $markerDir | Where-Object { $_.Kind -eq 'enter' }).Count
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 60) {
    foreach ($r in $rows) {
        if (-not $submitted.ContainsKey($r.Computer) -and $r.OpState -ne 'Running') {
            if (Start-UpdateCheckJob -ComputerItem $r -Op 'Check') { $submitted[$r.Computer] = $true }
        }
    }
    if ($global:jobs.Count -gt $maxObserved) { $maxObserved = $global:jobs.Count }
    Complete-Jobs $stateStore
    if ($global:jobs.Count -gt $maxObserved) { $maxObserved = $global:jobs.Count }
    if ($submitted.Count -eq 6 -and $global:jobs.Count -eq 0) { break }
    Start-Sleep -Milliseconds 80
}

$enters = @(Get-MarkerEvents -Dir $markerDir | Where-Object { $_.Kind -eq 'enter' }).Count
$runsThisSection = $enters - $runsBefore
Assert-True ($maxObserved -le 2) "3. the cap was never exceeded across the whole run (max observed $maxObserved)"
Assert-True ($submitted.Count -eq 6) "3. all 6 computers were ADMITTED, not starved (admitted $($submitted.Count)/6)"
Assert-Equal $runsThisSection 6 "3. exactly one run per admitted computer - the cap throttled admission, it did not drop or duplicate work"
Assert-True (@($rows | Where-Object { $_.OpState -eq 'Idle' }).Count -eq 6) '3. every admitted operation settled and released its computer'

# Proven from enter/exit timestamps: at no instant did more than 2 operations overlap.
# A cap of 2 means at most 2 `enter` events may be outstanding at once. Walk them in time order.
$events = Get-MarkerEvents -Dir $markerDir
$concurrent = 0; $peak = 0
foreach ($e in $events) {
    if ($e.Kind -eq 'enter') { $concurrent++; if ($concurrent -gt $peak) { $peak = $concurrent } }
    else { $concurrent-- }
}
Assert-True ($peak -le 2) "3. peak SIMULTANEOUS operations never exceeded the cap (peak $peak, from enter/exit timestamps)"
Assert-Equal ($events | Where-Object { $_.Kind -eq 'exit' }).Count $enters '3. every enter has a matching exit (no payload was killed mid-run, which would corrupt the peak)'

# ---------------------------------------------------------------------------------------
# 4. the scheduler path still respects the cap (both admission paths agree)
# ---------------------------------------------------------------------------------------
$stateStore2 = New-WuuStateStore
$global:jobs = [system.collections.arraylist]::Synchronized((New-Object System.Collections.ArrayList))
Initialize-WuuWindowsUpdateContext -Context @{
    StateStore = $stateStore2; Jobs = $global:jobs
    UpdatesHash = $global:updatesHash; PerformanceHash = $global:performanceHash
    ErrorSuggestions = $global:errorSuggestionsHash; Path = $PWD.Path
    LogPath = $global:LogPath; LogLock = $global:LogLock
    EnableDebugLogging = $false; EnableEnhancedErrorHandling = $false
    UseCustomCredentials = $false; CustomCredentials = $null; CredentialCache = $global:CredentialCache
    PerformanceThreshold = $global:PerformanceThreshold; ConfigPaths = $global:ConfigPaths
    SearchTimeout = 5; SessionTimeout = 5; RebootCheckTimeout = 5
    MaxConcurrentJobs = 2; GetUpdates = $getUpdatesPayload
    BackgroundProcessing = $global:backgroundProcessing
}
foreach ($n in 1..5) {
    $r = New-WuuComputerRow -Computer ("SCH0{0}" -f $n)
    $r.Pending = $true; $r.Runspace = $null
    Add-WuuComputerRow -Store $stateStore2 -Row $r | Out-Null
}
Start-PendingUpdateCheck
Assert-Equal $global:jobs.Count 2 '4. the scheduler tick honours the same cap from the same context value'
Complete-Jobs $stateStore2

# ---------------------------------------------------------------------------------------
Write-Host ''
if ($failures.Count) {
    Write-Host ("RESULT: {0} assertion(s) FAILED" -f $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'ALL PASS - the global concurrency cap is enforced at the submission point (SS4 / 8.6)' -ForegroundColor Green
exit 0
