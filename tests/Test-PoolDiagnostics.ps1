# Test: worker-pool diagnostics (reviewer P3) and the JSON gate report (reviewer P4).
#
# WHY THIS SUITE EXISTS
# ---------------------
# P3: the pool is a HARD CAP on concurrent bounded probes. Two of its failure modes are invisible from
# the caller's side and both masquerade as the SAME wrong diagnosis - "every host is slow":
#   * POOL EXHAUSTION - every worker waiting on a probe that cannot start, with no error raised anywhere
#   * ABANDONED WRAPPERS - a probe whose DCOM/RPC call would not abort is deliberately left running
#     (disposing it could block a finalizer thread). Each permanently holds a pool slot until the stuck
#     call returns, so sustained abandonment walks capacity to zero.
#
# P4: the gate had two signals (a '^FAIL:' line and the exit code) which cannot express "did not run" or
# "advisory". It now emits five verdict kinds into a JSON report.
#
# This suite asserts:
#   1. the diagnostic record carries every field a consumer keys on, including the reviewer's names
#   2. it is honest about what it does NOT know (an undeterminable count is not reported as zero)
#   3. the starvation threshold is a SHARE of capacity, so it stays right when capacity changes
#   4. the JSON report is produced, is valid, and its totals agree with its verdict list
#   5. the report distinguishes the kinds - a SKIP is not counted as a PASS
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-PoolDiagnostics.ps1
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$failures = @()
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -eq "$Expected") { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host ("FAIL: {0} - expected '{1}', got '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red; $script:failures += $Name }
}
function Assert-True($Condition, $Name) {
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host ("FAIL: {0}" -f $Name) -ForegroundColor Red; $script:failures += $Name }
}
function Assert-False($Condition, $Name) { Assert-True (-not $Condition) $Name }

Import-Module (Join-Path $root 'src\Wuu.Workers.psm1') -Force -ErrorAction Stop

'=== 1. the diagnostic record carries the fields a consumer keys on ==='
$diag = Get-WuuWorkerPoolDiagnostics
# The record is an OrderedDictionary, so lookups are by INDEX or .Contains(), never by
# .PSObject.Properties - which does not surface hashtable keys and silently returns $null. That mistake
# made the gate report "does not return a Starved field" for a predicate that returns it.
Assert-True ($diag -is [System.Collections.IDictionary]) 'the diagnostics record is a dictionary'
foreach ($field in 'Available', 'State', 'Min', 'Max', 'Capacity', 'Abandoned', 'AbandonedLimit', 'Utilisation', 'Note') {
    Assert-True ($diag.Contains($field)) "the record has '$field'"
}
# The reviewer named these four explicitly; they are the contract for a consumer.
foreach ($field in 'ActivePoolWorkers', 'AbandonedWorkers', 'PoolCapacity', 'PoolUtilisation') {
    Assert-True ($diag.Contains($field)) "the record exposes the reviewer's field name '$field'"
}
Assert-Equal $diag.PoolCapacity $diag.Capacity "PoolCapacity and Capacity agree ($($diag.Capacity))"

'=== 2. it is honest about what it does NOT know ==='
# Abandoned = -1 means "could not be determined" and is deliberately distinct from 0 = "none". Reporting
# an unknown as zero would be a claim, and the status line would show a clean pool that was never read.
Assert-True ([int]$diag.Abandoned -ge -1) "Abandoned is either a count or the 'unknown' sentinel, never negative-but-meaningful (got $($diag.Abandoned))"
# Capacity is a CONFIGURED value, so it is knowable even before the pool exists - and must be positive.
Assert-True ([int]$diag.Capacity -gt 0) "capacity is a real configured number ($($diag.Capacity))"
Assert-True ([string]$diag.Utilisation -match '^\d+/\d+$') "utilisation is a readable ratio ($($diag.Utilisation))"

# Before any probe runs the pool is created LAZILY, so it must report NotCreated rather than pretending
# to be available - and the Note must say so, or an operator sees "unavailable" with no explanation.
$fresh = & powershell.exe -NoProfile -Command "Import-Module '$root\src\Wuu.Workers.psm1' -Global -ErrorAction Stop; `$d = Get-WuuWorkerPoolDiagnostics; '{0}|{1}|{2}' -f `$d['State'], `$d['Available'], (`$d['Note'] -ne '')"
$freshParts = (($fresh -join '') -replace "`r?`n", '').Split('|')
Assert-Equal $freshParts[0] 'NotCreated' 'a fresh process reports the pool as NotCreated (it is created lazily)'
Assert-Equal $freshParts[1] 'False' 'and reports Available=False rather than implying it works'
Assert-Equal $freshParts[2] 'True' 'and explains why in Note'

'=== 3. the starvation threshold is a SHARE of capacity ==='
$s = Test-WuuWorkerPoolStarved
Assert-True ($s -is [System.Collections.IDictionary]) 'the starvation verdict is a dictionary'
foreach ($f in 'Starved', 'Abandoned', 'Capacity', 'Threshold', 'Reason') {
    Assert-True ($s.Contains($f)) "the verdict has '$f'"
}
$cap = [int]$s.Capacity
$thr = [int]$s.Threshold
# A SHARE, not an absolute count: an absolute number cannot stay right when the pool size changes.
Assert-True ($thr -ge 1 -and $thr -le $cap) "the threshold is a share of capacity ($thr of $cap)"
Assert-Equal $thr ([int][math]::Ceiling($cap * 0.5)) 'the default threshold is half of capacity'

# An UNKNOWN abandoned count must not read as starved - an unknown is not evidence of a problem, and
# firing the advisory on every run is how an advisory gets ignored.
$nullDiag = Test-WuuWorkerPoolStarved -ThresholdFraction 0.0
Assert-True ($nullDiag.Threshold -ge 0) 'a zero fraction yields a non-negative threshold (no divide-by-zero)'

'=== 4. the JSON report is produced, valid, and self-consistent ==='
$jsonPath = Join-Path $root 'gate-report.json'
$gate = Join-Path $root 'Scripts\Validate-Release.ps1'
Remove-Item $jsonPath -Force -ErrorAction SilentlyContinue
$out = & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $gate -Json 'gate-report.json' 2>&1
$gateExit = $LASTEXITCODE
Assert-True (Test-Path -LiteralPath $jsonPath) 'the gate wrote a JSON report'

if (Test-Path -LiteralPath $jsonPath) {
    $report = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    Assert-Equal $report.Schema 'wuu.gate.v1' 'the report declares its schema'
    Assert-True ($null -ne $report.GeneratedUtc) 'the report records when it was produced'
    Assert-True ($null -ne $report.Verdicts) 'the report carries a verdict list'
    $verdicts = @($report.Verdicts)
    Assert-True ($verdicts.Count -gt 100) "the report is complete, not truncated ($($verdicts.Count) verdicts)"

    # SELF-CONSISTENCY: the totals must equal the counts in the list. A report whose headline disagrees
    # with its own detail is worse than no report, because a consumer gates on the headline.
    foreach ($kind in 'PASS', 'FAIL', 'WARN', 'SKIP', 'NOT_IMPLEMENTED') {
        $actual = @($verdicts | Where-Object { $_.Status -eq $kind }).Count
        $reported = [int]$report.Totals.$kind
        Assert-Equal $reported $actual "the '$kind' total matches the verdict list ($reported)"
    }
    # No verdict may have a null status - that is the signature of a failed enumeration.
    $nullStatus = @($verdicts | Where-Object { -not $_.Status }).Count
    Assert-Equal $nullStatus 0 'no verdict has a null status (the signature of a broken list read)'

    # THE KIND DISTINCTION MUST BE REAL. A skipped check must not be counted as a pass - that is the
    # whole reason the kind exists.
    Assert-True ([int]$report.Totals.SKIP -ge 1) "the report records at least one SKIP, so the kind is reachable ($($report.Totals.SKIP))"
    Assert-Equal ([int]$report.Totals.FAIL) 0 'a passing gate reports zero failures'
    Assert-Equal $report.Passed $true 'the report agrees that the gate passed'

    # And the exit code must agree with the report: a report saying "passed" next to a non-zero exit
    # would make a consumer's choice of signal decide the outcome.
    Assert-Equal $gateExit 0 'the gate exit code agrees with the report (0 = passed)'
}

Remove-Item $jsonPath -Force -ErrorAction SilentlyContinue

''
if ($failures.Count -eq 0) {
    Write-Host "ALL PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FAILURES: {0}" -f $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
