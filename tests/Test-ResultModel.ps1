# Test: the command result model (instructions SS33/SS34).
#
# WHY THIS SUITE EXISTS
# ---------------------
# SS33 asks for ONE structured result per command, from which the human output and the JSON both derive.
# The defect it closes is concrete: `-Json` was emitted from two unrelated places, each hand-building its
# own object. Two shapes mean a consumer has to know which one it was handed, and adding a field to one
# does nothing for the other.
#
# SS34 makes the JSON an API. That is what makes this suite a CONTRACT test rather than a unit test: the
# field names are published in docs/EXIT_CODES.md, so RENAMING one is a breaking change to an automation
# interface. The suite asserts the documented names exist, and separately that the additions are additive.
#
# This suite asserts:
#   1. the documented JSON fields are present, with their documented names and meanings
#   2. the counts agree with the PER-TARGET VERDICTS the exit code is computed from - so the headline
#      and the exit code cannot disagree about what "failed" means
#   3. 'outstanding' uses the documented predicate (Running OR Pending), NOT a redefinition
#   4. a still-running target is never counted as a failure
#   5. the JSON round-trips, every field survives, and Computers is always iterable
#   6. the schema version is present and stable
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-ResultModel.ps1
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force -DisableNameChecking
Import-WuuModules -WuuRoot $root

$failures = @()
function Ok($m) { Write-Host "PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:failures += $m }
function Assert-True($cond, $m) { if ($cond) { Ok $m } else { Bad $m } }
function Assert-Equal($a, $b, $m) {
    if ("$a" -ceq "$b") { Ok $m } else { Bad ("$m (expected '$b', got '$a')") }
}

# ---------------------------------------------------------------------------------------
# 1. the documented JSON contract is intact
# ---------------------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 1. the documented contract (docs/EXIT_CODES.md) is preserved ===' -ForegroundColor Cyan

$doc = Get-Content -LiteralPath (Join-Path $root 'docs\EXIT_CODES.md') -Raw
# The documented shape, read from the doc itself so this suite fails if either side drifts alone.
$docFields = [regex]::Matches($doc, '"(\w+)":') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
Assert-True ($docFields.Count -ge 4) "the doc publishes a JSON shape ($($docFields.Count) field(s): $($docFields -join ', '))"

$store = New-WuuStateStore
$row = New-WuuComputerRow -Computer 'RM1'
Add-WuuComputerRow -Store $store -Row $row | Out-Null
$counts = Get-WuuCommandCounts -Rows @($row)
$res = New-WuuCommandResult -Command 'check' -Ok $true -ExitCode 0 -Counts $counts -Computers @()
foreach ($f in $docFields) {
    Assert-True ($null -ne $res.PSObject.Properties[$f]) "the result carries the documented field '$f'"
}

# ---------------------------------------------------------------------------------------
# 2. the counts agree with the verdicts the exit code uses
# ---------------------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 2. counts agree with the per-target verdicts ===' -ForegroundColor Cyan

$s = New-WuuStateStore
function Add-OutcomeRow([string]$name, [string]$state, [string]$upd, [string]$opState, [bool]$pending, [int]$refused) {
    $r = New-WuuComputerRow -Computer $name
    $r.State = $state; $r.UpdatesStatus = $upd; $r.OpState = $opState; $r.Pending = $pending
    $r.RefusedCount = $refused
    Add-WuuComputerRow -Store $s -Row $r | Out-Null
    return $r
}
$rows = @(
    (Add-OutcomeRow 'OK1'  'Complete' 'Up to date'   'Idle'    $false 0)
    (Add-OutcomeRow 'OK2'  'Complete' 'Up to date'   'Idle'    $false 0)
    (Add-OutcomeRow 'FAIL1' 'Error'   'Failed'       'Idle'    $false 0)
    (Add-OutcomeRow 'TO1'  'Timeout'  'Timed out'    'Idle'    $false 0)
    (Add-OutcomeRow 'RUN1' 'Running'  'Downloading'  'Running' $false 0)
    (Add-OutcomeRow 'QUE1' 'Queued'   'Initializing' 'Idle'    $true  0)
    (Add-OutcomeRow 'REF1' 'Queued'   'Initializing' 'Idle'    $true  2)
)
$c = Get-WuuCommandCounts -Rows $rows

Assert-Equal $c['requested'] 7 'requested counts every selected target'
Assert-Equal $c['completed'] 2 'completed counts the settled successes'
Assert-Equal $c['failed'] 1 'failed counts the settled failures'
Assert-Equal $c['timedOut'] 1 'timedOut counts the settled timeouts'
Assert-Equal $c['refused'] 1 'refused is read from the row refusal record'

# The aggregate the EXIT CODE uses must tell the same story as the counts.
$agg = Get-WuuAggregateOutcome -Rows $rows
Assert-Equal $agg 'PartialSuccess' 'a mix of settled success and failure is PartialSuccess (exit 4)'
Assert-True ($c['completed'] -gt 0 -and $c['failed'] -gt 0) 'the counts show the same mix the aggregate reports'

# ---------------------------------------------------------------------------------------
# 3. 'outstanding' uses the DOCUMENTED predicate, not a redefinition
# ---------------------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 3. outstanding matches the published predicate ===' -ForegroundColor Cyan
# The published definition: OpState='Running' OR Pending. Three rows qualify (RUN1, QUE1, REF1).
$expectedOutstanding = @($rows | Where-Object { ($_.OpState -eq 'Running') -or [bool]$_.Pending }).Count
Assert-Equal $c['outstanding'] $expectedOutstanding "outstanding uses the documented Running-or-Pending predicate ($expectedOutstanding)"
# SS33's finer split is ADDITIVE: started + queued accounts for the same set, without replacing it.
Assert-Equal ($c['started'] + $c['queued']) $c['outstanding'] 'started + queued partition exactly the outstanding set (the split is additive)'
Assert-Equal $c['started'] 1 'only a RUNNING target has started'
Assert-True ($c['queued'] -ge 1) 'a Pending-but-not-admitted target is queued, not started'

# ---------------------------------------------------------------------------------------
# 4. an unsettled target is never a failure
# ---------------------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 4. still-running targets are not failures ===' -ForegroundColor Cyan
Assert-Equal (Get-WuuTargetOutcome -Row $rows[4]) 'Unknown' 'a running target has an Unknown verdict, not Failed'
$runningOnly = @($rows[4], $rows[5])
$cRunning = Get-WuuCommandCounts -Rows $runningOnly
Assert-Equal $cRunning['failed'] 0 'a set of unstarted targets reports zero failures'
Assert-Equal $cRunning['completed'] 0 'a set of unstarted targets reports zero completions'
Assert-Equal $cRunning['outstanding'] 2 'both unstarted targets are outstanding'
Assert-Equal (Get-WuuAggregateOutcome -Rows $runningOnly) 'Unknown' 'an unsettled set aggregates to Unknown, so the caller keeps its code'

# ---------------------------------------------------------------------------------------
# 5. JSON round-trip, and Computers is always iterable
# ---------------------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 5. the JSON round-trips and Computers is iterable ===' -ForegroundColor Cyan
$res2 = New-WuuCommandResult -Command 'install' -Ok $true -ExitCode 4 -Completed $false -Outstanding 2 -Counts $c -Computers @($rows[0])
$json = Format-WuuResultJson -Result $res2
$parsed = $null
try { $parsed = $json | ConvertFrom-Json } catch { Bad "the result JSON does not parse: $($_.Exception.Message)" }
if ($parsed) {
    Assert-Equal $parsed.Command 'install' 'the JSON carries the command'
    Assert-Equal $parsed.ExitCode 4 'the JSON carries the exit code'
    Assert-Equal $parsed.Status 'PartialSuccess' 'the JSON carries the exit-code NAME, so it is readable without a lookup'
    Assert-Equal $parsed.CompletedCount 2 'the JSON carries the per-status counts'
    Assert-True ($parsed.PSObject.Properties['Computers']) 'the JSON carries Computers'
    # Iterability is what a consumer depends on; a single-element collection must not unwrap to a scalar.
    $iter = @($parsed.Computers)
    Assert-True ($iter.Count -ge 1) "Computers is iterable ($($iter.Count) element(s)) even with one target"
}

# An EMPTY target set must also render, with the field present.
$resEmpty = New-WuuCommandResult -Command 'export' -Ok $true -ExitCode 0 -Counts (Get-WuuCommandCounts -Rows @()) -Computers @()
$parsedEmpty = (Format-WuuResultJson -Result $resEmpty) | ConvertFrom-Json
Assert-True ($parsedEmpty.PSObject.Properties['Computers']) 'Computers is present even when empty (a vanishing field is one a consumer crashes on)'

# ---------------------------------------------------------------------------------------
# 6. the schema version
# ---------------------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 6. the schema version is present and stable ===' -ForegroundColor Cyan
Assert-True ($null -ne $res.PSObject.Properties['SchemaVersion']) 'the result declares a schema version (SS34)'
Assert-Equal $res.SchemaVersion (Get-WuuResultSchemaVersion) 'the result stamps the module schema version, so the two cannot drift'
Assert-True ([int]$res.SchemaVersion -ge 1) "the schema version is a positive number ($($res.SchemaVersion))"

# The two renderings must read the SAME object - the defect was two hand-built shapes.
Write-Host ''
Write-Host '=== 7. both renderings derive from one result object ===' -ForegroundColor Cyan
$coreSource = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Core.psm1'))
Assert-True ($coreSource -match 'New-WuuCommandResult') 'Core builds a result object'
Assert-True ($coreSource -match 'Format-WuuResultJson') 'Core renders its -Json through the model, not by hand'
Assert-True ($coreSource -notmatch "(?s)Computers\s*=\s*`$snapshot.*ConvertTo-Json") 'Core no longer hand-builds the JSON object'

# ---------------------------------------------------------------------------------------
Write-Host ''
if ($failures.Count) {
    Write-Host ("SOME CHECKS FAILED ({0}): {1}" -f $failures.Count, ($failures -join '; ')) -ForegroundColor Red
    exit 1
}
Write-Host 'Test-ResultModel.ps1: ALL PASS' -ForegroundColor Green
