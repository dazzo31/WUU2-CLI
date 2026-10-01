# Test: the pool-versus-cap invariant (P3 close-out).
#
# WHY THIS SUITE EXISTS
# ---------------------
# This was a REAL defect that had shipped and that nothing detected, not a hypothetical:
#
#   src\Wuu.Core.psm1:245    $global:MaxConcurrentJobs = 10
#   src\Wuu.Workers.psm1     [int]$script:MaxPoolSize    = 8
#
# Bounded probes (WMI/CIM/service/ping) are dispatched from INSIDE the per-computer worker runspaces,
# and at most $MaxConcurrentJobs of those run at once. The pool is therefore the thing that must run
# them - so a pool SMALLER than the cap means (cap - pool) admitted operations have probes that can
# never start. The failure is silent in a specific and nasty way: the cap has already counted those
# operations as RUNNING, so there is no refusal to record and no error to log. The probe simply sits
# queued, and from the operator's side it presents as a SLOW HOST - so the investigation goes to the
# host, which is not the problem.
#
# HOW THE GAP SURVIVED: the two modules contradicted each other in writing. Wuu.Workers' comment said
# capacity "must comfortably exceed" the cap while setting a value BELOW it; Wuu.State's description
# of the cap said it was "NOT a bound on the worker pool (Wuu.Workers sizes its own pool separately)".
# Neither statement was checked, and prose cannot fail a build. This suite and the gate block now
# enforce the relationship, and the values are aligned at 10.
#
# This suite asserts:
#   1. THE SOURCE VALUES: pool >= cap, read from the shipped files - so reverting either number fails
#      here as well as at the gate
#   2. the rule at its boundary: equal is compatible, larger is compatible-but-unnecessary, smaller is
#      NOT compatible, and an unknown cap is never compatible
#   3. the unsafe verdict names the CONSEQUENCE, so a failure is actionable without re-deriving it
#   4. the shipped function returns the verdict the shipped values should produce
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-PoolCompatibility.ps1
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

'=== 1. THE SHIPPED VALUES satisfy the invariant ==='
# Read from the SOURCE, not from the imported module. A module-scoped $script: value cannot be read from
# outside, and reading the file is also what makes reverting a number fail HERE rather than only at the
# gate - the two checks are independent, which is what a tautology proof requires.
$poolSource = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Workers.psm1'))
$coreSource = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Core.psm1'))

$poolMatch = [regex]::Match($poolSource, '\[int\]\$script:MaxPoolSize\s*=\s*(\d+)')
$capMatch = [regex]::Match($coreSource, '\$global:MaxConcurrentJobs\s*=\s*(\d+)')
Assert-True $poolMatch.Success 'the pool size is readable from Wuu.Workers source'
Assert-True $capMatch.Success 'the concurrency cap is readable from Wuu.Core source'

$sourcePool = if ($poolMatch.Success) { [int]$poolMatch.Groups[1].Value } else { -1 }
$sourceCap = if ($capMatch.Success) { [int]$capMatch.Groups[1].Value } else { -1 }

Assert-True ($sourceCap -gt 0) "the concurrency cap is a positive number ($sourceCap)"
Assert-True ($sourcePool -ge $sourceCap) "SHIPPED: the pool ($sourcePool) is not smaller than the cap ($sourceCap)"
# Named explicitly, because this is the exact defect that shipped: 8 vs 10.
Assert-True ($sourcePool -ge 10) "the pool is at least the 10 the cap admits (was 8, which could not probe)"

# The predicate must agree with the values read from source. If these two ever disagree, one of them is
# reading the wrong thing and the suite would otherwise be asserting a number nobody enforces.
$live = Test-PoolCompatibility -MaxConcurrentJobs $sourceCap
Assert-Equal $live.PoolSize $sourcePool 'the predicate reports the same pool size as the source declares'
Assert-True $live.Compatible "the predicate agrees the shipped configuration ($sourcePool pool, $sourceCap cap) is compatible"

'=== 2. the rule at its boundary ==='
# Equal is the MINIMUM that works: a job's probes are sequential, so it holds at most one slot at a
# time and a pool of exactly the cap runs every admitted job's next probe with nothing waiting.
$equal = Test-PoolCompatibility -MaxConcurrentJobs $sourcePool
Assert-True $equal.Compatible 'cap EQUAL to the pool is compatible (the minimum that works)'
Assert-False $equal.Unnecessary 'and is not reported as unnecessary - it is exactly sufficient'

# A larger pool is unused capacity, not a fault: reported so it is visible, but it must not fail a
# release, or the check would be wrong in the direction that costs nothing.
$smaller = Test-PoolCompatibility -MaxConcurrentJobs ($sourcePool - 1)
Assert-True $smaller.Compatible 'a cap smaller than the pool is compatible'
Assert-True $smaller.Unnecessary 'and is flagged as unnecessary capacity rather than failing'

# THE DIRECTION THAT MATTERS. One over the pool is enough to strand a probe.
$unsafe = Test-PoolCompatibility -MaxConcurrentJobs ($sourcePool + 1)
Assert-False $unsafe.Compatible 'a cap LARGER than the pool is NOT compatible'
Assert-False $unsafe.Unnecessary 'and is not excused as unused capacity'

# An unknown cap must not read as safe - "cannot judge" is not "fine".
$unknown = Test-PoolCompatibility
Assert-False $unknown.Compatible 'an unknown cap (0) is NOT reported as compatible'
Assert-True ($unknown.Reason -like '*cannot be judged*') "and says so ($($unknown.Reason))"

# Negative input must behave like unknown rather than wrapping into a false positive.
Assert-False (Test-PoolCompatibility -MaxConcurrentJobs -5).Compatible 'a negative cap is not compatible'

'=== 3. the unsafe verdict names the CONSEQUENCE ==='
# "8 < 10" is not actionable. The next person to read this failure needs the symptom, because the
# symptom is what they will have seen: a slow host.
$why = (Test-PoolCompatibility -MaxConcurrentJobs ($sourcePool + 4)).Reason
Assert-True ($why -like '*probes that can never start*') "the verdict explains that probes cannot start ($why)"
Assert-True ($why -like '*counted as running*') 'and that the operations are already counted as running'
Assert-True ($why -like '*no refusal and no error*') 'and that nothing is refused or logged - so the failure is silent'
Assert-True ($why -like '*slow host*') 'and names the symptom an operator would actually see'

'=== 4. the predicate never throws, whatever it is handed ==='
# It is driven from the release gate and from a status render, so it must survive any input.
$threw = $false
foreach ($input in @(0, 1, -1, 100, [int]::MaxValue)) {
    try { $null = Test-PoolCompatibility -MaxConcurrentJobs $input } catch { $threw = $true }
}
Assert-False $threw 'no input made the predicate throw'

''
if ($failures.Count -eq 0) {
    Write-Host "ALL PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FAILURES: {0}" -f $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
