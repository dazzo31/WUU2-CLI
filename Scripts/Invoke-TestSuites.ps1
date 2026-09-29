#Requires -Version 5.1
<#
.SYNOPSIS
Runs every applicable test suite and FAILS if any suite fails.

.DESCRIPTION
The repository has no Pester dependency: each suite is a plain .ps1 that prints PASS:/FAIL: lines and
exits 0 or 1. That is deliberate and stays. What was missing is AGGREGATION, and the absence had three
concrete consequences - all of them "looks green when it is not":

  1. The documented workflow was a bare `Get-ChildItem | ForEach-Object { powershell.exe -File ... }`
     loop. It prints each suite's output but **discards every exit code**, so a CI job running it
     exits 0 no matter how many suites failed.
  2. `Test-ModuleImport.ps1` reported a missing required command by printing `MISSING <cmd>` in RED and
     then exiting 0. A scripted runner recorded it as a pass.
  3. `SKIP` and `PASS` were indistinguishable to any caller that only looked at the exit code. A
     skipped suite (Test-RemoteTask needs elevation) is not a failure, but it is also not coverage -
     and conflating the two hides regressions behind an environment limitation.

This runner fixes all three: it captures each process's exit code, classifies SKIP separately from
PASS, imposes a per-suite TIMEOUT (one hung suite must not stall the run - `Test-DragResize` hangs by
design), and returns nonzero if any suite failed. Exit codes: 0 = all applicable suites passed,
1 = at least one suite failed, 2 = the run could not be completed (e.g. no suites found).

WHY A TIMEOUT IS PART OF THE CONTRACT
A hung suite is worse than a failed one: CI blocks until the job's own limit kills it, and the output
is lost. Each suite is started as its own process and killed on a deadline, and a killed suite is
reported as TIMEOUT, which is a FAILURE - the suite did not prove what it claims to prove.

.PARAMETER TimeoutSeconds
Per-suite timeout. Default 300 (5 minutes). Raise it for a deliberately slow suite rather than
removing the bound.

.PARAMETER Suite
One or more suite filenames or paths to run instead of the whole set. Useful locally.

.PARAMETER IncludeExcluded
Include the GUI-edition leftovers that are excluded by default (Test-ColumnResize, Test-DragResize).
They are NOT part of the CLI validation path; DragResize hangs on a blocking dispatcher pump.

.PARAMETER Json
Emit a machine-readable summary as the last line, for CI to parse.

.EXAMPLE
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Invoke-TestSuites.ps1

.EXAMPLE
# One suite, with a longer deadline
$r = .\Scripts\Invoke-TestSuites.ps1 -Suite Test-RemoteTask.ps1 -TimeoutSeconds 900
#>
[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 300,
    [string[]]$Suite = @(),
    [switch]$IncludeExcluded,
    [switch]$Json,
    # Passed through so the runner can be invoked from the release gate without changing behaviour.
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# Suites that are NOT part of the CLI validation path. Named explicitly (rather than a pattern) so
# that adding a suite cannot silently exclude it, and so removing one is a visible diff.
$excludedSuites = @('Test-ColumnResize.ps1', 'Test-DragResize.ps1')

if ($Suite.Count -gt 0) {
    $suites = @()
    foreach ($s in $Suite) {
        if (Test-Path $s) { $suites += (Resolve-Path $s).Path }
        elseif (Test-Path (Join-Path $root "tests\$s")) { $suites += (Join-Path $root "tests\$s") }
        else { Write-Error "Suite not found: $s"; exit 2 }
    }
} else {
    $pattern = if ($IncludeExcluded) { 'Test-*.ps1' } else { 'Test-*.ps1' }
    $suites = @(Get-ChildItem (Join-Path $root "tests\$pattern") -ErrorAction Stop |
        Where-Object { $IncludeExcluded -or $_.Name -notin $excludedSuites } |
        Sort-Object Name |
        Select-Object -ExpandProperty FullName)
}

if ($suites.Count -eq 0) {
    Write-Host 'No test suites found.' -ForegroundColor Red
    exit 2
}

function Write-Line([string]$Text, $Color) {
    if ($Quiet) { return }
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}

Write-Line ''
Write-Line ("Running {0} suite(s), {1}s per suite (excluded: {2})" -f $suites.Count, $TimeoutSeconds, $(if ($IncludeExcluded) { 'none' } else { $excludedSuites -join ', ' })) -Color Cyan
Write-Line ('-' * 96)

$results = @()
$failedSuites = @()

foreach ($file in $suites) {
    $name = Split-Path $file -Leaf

    # Start each suite as its OWN process so a hang or a parse error cannot take the runner with it,
    # and so the exit code is observable (the old inline loop discarded it).
    #
    # [System.Diagnostics.Process] DIRECTLY, not Start-Process -PassThru. Measured on this host:
    # `Start-Process -NoNewWindow -PassThru` returns an object whose ExitCode stays EMPTY even after
    # WaitForExit() and Refresh() - so the first version of this runner reported `exit=` for every
    # suite and classified all of them as failures. The framework type populates ExitCode correctly,
    # and supports a bounded wait plus a process-tree kill.
    $timedOut = $false
    $exitCode = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        # -STA is required: the suites assert STA-sensitive behaviour (clipboard/COM paths).
        $psi.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f $file
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()

        # Read asynchronously so a chatty suite cannot fill the pipe buffer and deadlock the child
        # while this thread is blocked in WaitForExit.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            # Kill the PROCESS TREE: a suite may have spawned worker runspaces or child shells.
            try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch { }
            try { $proc.Kill() } catch { }
            [void]$proc.WaitForExit(10000)
        }

        $stdout = ''
        $stderr = ''
        try { if ($stdoutTask) { $stdout = $stdoutTask.Result } } catch { }
        try { if ($stderrTask) { $stderr = $stderrTask.Result } } catch { }
        if (-not $timedOut) { try { $exitCode = $proc.ExitCode } catch { $exitCode = $null } }
    } catch {
        Write-Line ("  {0,-34} ERROR launching: {1}" -f $name, $_.Exception.Message) -Color Red
        $results += [pscustomobject]@{ Suite = $name; Status = 'ERROR'; ExitCode = $null; Passed = 0; Failed = 0; Seconds = 0; Detail = $_.Exception.Message }
        $failedSuites += $name
        if ($proc) { try { $proc.Dispose() } catch { } }
        continue
    } finally {
        $sw.Stop()
        if ($proc) { try { $proc.Dispose() } catch { } }
    }

    # Count assertions. `PASS:` and `FAIL:` are the documented contract; some suites use a different
    # prefix (`PASS [key]:`, `PASS A:`) and are counted by their own `RESULT:` line instead - see the
    # note in docs\TESTING.md. Counting only the canonical prefix under-reports, it does not misjudge.
    $passCount = 0; $failCount = 0
    try {
        if ($stdout) {
            $passCount = ([regex]::Matches($stdout, '(?m)^PASS:')).Count
            $failCount = ([regex]::Matches($stdout, '(?m)^FAIL:')).Count
        }
    } catch { }

    # A skip is NOT a failure, but it is not coverage either: it is recorded separately so a green run
    # cannot be read as "everything was exercised". Test-RemoteTask skips without elevation by design.
    $isSkip = [bool]($stdout -match '(?m)^SKIP:')
    $status = if ($timedOut) { 'TIMEOUT' }
    elseif ($exitCode -eq 0 -and $failCount -eq 0) { if ($isSkip) { 'SKIP' } else { 'PASS' } }
    else { 'FAIL' }

    if ($status -in @('FAIL', 'TIMEOUT', 'ERROR')) { $failedSuites += $name }

    $color = switch ($status) {
        'PASS' { 'Green' }
        'SKIP' { 'DarkGray' }
        'TIMEOUT' { 'Magenta' }
        default { 'Red' }
    }
    $detail = if ($status -eq 'TIMEOUT') { "killed after ${TimeoutSeconds}s" } else { "exit=$exitCode" }
    Write-Line ("  {0,-8} {1,-34} {2,-12} pass={3,-4} fail={4,-4} {5:N1}s" -f $status, $name, $detail, $passCount, $failCount, $sw.Elapsed.TotalSeconds) -Color $color

    # Surface the first FAIL line, so a CI log shows the reason without opening the suites.
    if ($status -in @('FAIL', 'TIMEOUT')) {
        $firstFail = ([regex]::Match($stdout, '(?m)^FAIL:.*$')).Value
        if ($firstFail) { Write-Line ("           -> {0}" -f $firstFail.Trim()) -Color Red }
        if (-not $firstFail -and $stderr) {
            $firstErr = ($stderr -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
            if ($firstErr) { Write-Line ("           -> stderr: {0}" -f $firstErr.Trim()) -Color Red }
        }
    }

    $results += [pscustomobject]@{
        Suite = $name; Status = $status; ExitCode = $exitCode
        Passed = $passCount; Failed = $failCount
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); Detail = $detail
    }
}

Write-Line ('-' * 96)
$nPass = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
$nSkip = @($results | Where-Object { $_.Status -eq 'SKIP' }).Count
$nFail = @($results | Where-Object { $_.Status -in @('FAIL', 'TIMEOUT', 'ERROR') }).Count
$totalPass = ($results | Measure-Object -Property Passed -Sum).Sum
$totalFail = ($results | Measure-Object -Property Failed -Sum).Sum

Write-Line ("SUITES: {0} run | {1} pass | {2} skip | {3} FAIL" -f $results.Count, $nPass, $nSkip, $nFail) -Color $(if ($nFail) { 'Red' } else { 'Green' })
Write-Line ("ASSERTIONS: {0} pass | {1} fail" -f $totalPass, $totalFail) -Color $(if ($totalFail) { 'Red' } else { 'Green' })
if ($nSkip) {
    Write-Line ("  note: {0} suite(s) SKIPPED - a skip is not a failure, but it is not coverage either" -f $nSkip) -Color DarkGray
    $results | Where-Object { $_.Status -eq 'SKIP' } | ForEach-Object { Write-Line ("        {0}" -f $_.Suite) -Color DarkGray }
}
if ($nFail) {
    Write-Line ("  FAILED: {0}" -f ($failedSuites -join ', ')) -Color Red
}

if ($Json) {
    $summary = [pscustomobject]@{
        Suites = $results.Count; Passed = $nPass; Skipped = $nSkip; Failed = $nFail
        AssertionsPassed = $totalPass; AssertionsFailed = $totalFail
        FailedSuites = $failedSuites; Results = $results
    }
    # Last line only, so a caller can take the tail without parsing the whole log.
    Write-Output ("SUMMARY_JSON " + ($summary | ConvertTo-Json -Compress -Depth 4))
}

Write-Line ''
if ($nFail) {
    Write-Line ("TEST RUN FAILED ({0} suite(s))" -f $nFail) -Color Red
    exit 1
}
Write-Line 'ALL SUITES PASSED' -Color Green
exit 0
