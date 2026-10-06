#Requires -Version 5.1
<#
.SYNOPSIS Line-oriented horizontal ASCII rollout and phase charts test suite (CLI-CHART-01).
.DESCRIPTION
Validates:
  1. Format-WuuHorizontalBar: exact counts, proportional fill, zero total edge case, clamp on overflow.
  2. Format-WuuPhaseDistribution: independent category bars (Succeeded, Failed, TimedOut, Running, Queued, Unknown).
  3. Format-WuuFleetDistribution: fleet status derivation from state store.
  4. Write-WuuHorizontalChart and Write-WuuFleetDistributionChart: theme color resolution and NoColor safety.
  5. Format-WuuReportTable: outcome distribution and cause charts above detailed error tables.
  6. AST and line-orientation purity: no cursor repositioning, no ANSI escape sequences.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$fail = $false
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail = $true }
function Pass($m) { Write-Host "PASS: $m" -ForegroundColor Green }
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -eq "$Expected") { Pass $Name }
    else { Fail ("{0} - expected '{1}', got '{2}'" -f $Name, $Expected, $Actual) }
}
function Assert-Match($Actual, $Pattern, $Name) {
    if ("$Actual" -match $Pattern) { Pass $Name }
    else { Fail ("{0} - expected match '{1}', got '{2}'" -f $Name, $Pattern, $Actual) }
}

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

# ---------------------------------------------------------------------------------------
# 1. Format-WuuHorizontalBar Unit Tests
# ---------------------------------------------------------------------------------------
# Basic 50% fill (5 of 10 with BarWidth 10 -> 5 '=', 5 '-')
$bar50 = Format-WuuHorizontalBar -Label 'Testing' -Value 5 -Total 10 -BarWidth 10 -LabelWidth 10 -CountWidth 6
Assert-Match $bar50 'Testing\s+5/10\s+\[=====-----\]\s+50\.0%' 'Format-WuuHorizontalBar 50% fill renders exact count and half bar'

# Zero total edge case: must not divide by zero, renders N/A
$barZero = Format-WuuHorizontalBar -Label 'Empty' -Value 0 -Total 0 -BarWidth 10 -LabelWidth 8 -CountWidth 5
Assert-Match $barZero 'Empty\s+0/0\s+\[----------\]\s+N/A' 'Format-WuuHorizontalBar zero total renders 0/0 empty bar with N/A'

# Zero value with positive total: 0%
$barZeroVal = Format-WuuHorizontalBar -Label 'None' -Value 0 -Total 20 -BarWidth 10 -LabelWidth 8 -CountWidth 6
Assert-Match $barZeroVal 'None\s+0/20\s+\[----------\]\s+0\.0%' 'Format-WuuHorizontalBar zero value renders 0/20 and 0.0%'

# 100% full bar
$barFull = Format-WuuHorizontalBar -Label 'Complete' -Value 10 -Total 10 -BarWidth 10 -LabelWidth 10 -CountWidth 6
Assert-Match $barFull 'Complete\s+10/10\s+\[==========\]\s+100\.0%' 'Format-WuuHorizontalBar 100% renders full bar'

# Value > Total: clamps visual bar to full but preserves exact count
$barOverflow = Format-WuuHorizontalBar -Label 'Overflow' -Value 15 -Total 10 -BarWidth 10 -LabelWidth 10 -CountWidth 6
Assert-Match $barOverflow 'Overflow\s+15/10\s+\[==========\]\s+100\.0%' 'Format-WuuHorizontalBar clamps bar to 100% while preserving 15/10 count'

# Minimal non-zero fill: 1 of 100 with BarWidth 10 must show at least 1 fill character
$barMinFill = Format-WuuHorizontalBar -Label 'Low' -Value 1 -Total 100 -BarWidth 10 -LabelWidth 6 -CountWidth 6
Assert-Match $barMinFill 'Low\s+1/100\s+\[=---------\]\s+1\.0%' 'Format-WuuHorizontalBar forces at least 1 fill character for non-zero values'

# Custom characters: '#' fill and '.' empty
$barCustom = Format-WuuHorizontalBar -Label 'Custom' -Value 3 -Total 6 -BarWidth 6 -FillChar '#' -EmptyChar '.' -LabelWidth 8 -CountWidth 5
Assert-Match $barCustom 'Custom\s+3/6\s+\[###\.\.\.\]\s+50\.0%' 'Format-WuuHorizontalBar honors custom fill and empty characters'

# Negative value and total clamping
$barNeg = Format-WuuHorizontalBar -Label 'Neg' -Value -5 -Total -10 -BarWidth 6
Assert-Match $barNeg 'Neg\s+0/0\s+\[------\]\s+N/A' 'Format-WuuHorizontalBar clamps negative inputs to zero'

# ---------------------------------------------------------------------------------------
# 2. Format-WuuPhaseDistribution Category Independence
# ---------------------------------------------------------------------------------------
$phaseRows = Format-WuuPhaseDistribution -Succeeded 6 -Failed 2 -TimedOut 1 -Running 1 -Queued 2 -Unknown 0 -Total 12 -BarWidth 10
Assert-Equal $phaseRows.Count 6 'Format-WuuPhaseDistribution returns 6 distinct category rows'

$succRow = $phaseRows | Where-Object { $_.Label -eq 'Succeeded' }
Assert-Equal $succRow.Value 6 'Succeeded count is 6'
Assert-Equal $succRow.Role 'Success' 'Succeeded role is Success'
Assert-Match $succRow.Line 'Succeeded\s+6/12\s+\[=====-----\]\s+50\.0%' 'Succeeded line displays 6/12 and 50.0%'

$failRow = $phaseRows | Where-Object { $_.Label -eq 'Failed' }
Assert-Equal $failRow.Value 2 'Failed count is 2'
Assert-Equal $failRow.Role 'Failure' 'Failed role is Failure'

$toRow = $phaseRows | Where-Object { $_.Label -eq 'TimedOut' }
Assert-Equal $toRow.Value 1 'TimedOut count is 1'
Assert-Equal $toRow.Role 'Attention' 'TimedOut role is Attention'

$runRow = $phaseRows | Where-Object { $_.Label -eq 'Running' }
Assert-Equal $runRow.Value 1 'Running count is 1'
Assert-Equal $runRow.Role 'Progress' 'Running role is Progress'

$qRow = $phaseRows | Where-Object { $_.Label -eq 'Queued' }
Assert-Equal $qRow.Value 2 'Queued count is 2'
Assert-Equal $qRow.Role 'Muted' 'Queued role is Muted'

# Format as string
$phaseText = Format-WuuPhaseDistribution -Succeeded 5 -Failed 1 -TimedOut 0 -Running 2 -Queued 2 -Unknown 0 -Total 10 -BarWidth 10 -AsString
Assert-Match $phaseText 'Succeeded\s+5/10' 'Format-WuuPhaseDistribution -AsString contains Succeeded row'
Assert-Match $phaseText 'Failed\s+1/10' 'Format-WuuPhaseDistribution -AsString contains Failed row'
Assert-Match $phaseText 'Running\s+2/10' 'Format-WuuPhaseDistribution -AsString contains Running row'

# ---------------------------------------------------------------------------------------
# 3. Format-WuuFleetDistribution State Store Integration
# ---------------------------------------------------------------------------------------
$store = New-WuuStateStore

# Row 1: Succeeded (Complete)
$r1 = New-WuuComputerRow -Computer 'SRV-01'
$r1.State = 'Complete'
$r1.OpState = 'Idle'
Add-WuuComputerRow -Store $store -Row $r1 | Out-Null

# Row 2: Failed (Error)
$r2 = New-WuuComputerRow -Computer 'SRV-02'
$r2.State = 'Error'
$r2.OpState = 'Idle'
Add-WuuComputerRow -Store $store -Row $r2 | Out-Null

# Row 3: TimedOut (Timeout)
$r3 = New-WuuComputerRow -Computer 'SRV-03'
$r3.State = 'Timeout'
$r3.OpState = 'Idle'
Add-WuuComputerRow -Store $store -Row $r3 | Out-Null

# Row 4: Running (OpState = Running)
$r4 = New-WuuComputerRow -Computer 'SRV-04'
$r4.OpState = 'Running'
$r4.State = 'Downloading'
Add-WuuComputerRow -Store $store -Row $r4 | Out-Null

# Row 5: Queued (OpState = Queued)
$r5 = New-WuuComputerRow -Computer 'SRV-05'
$r5.OpState = 'Queued'
$r5.State = 'Queued'
Add-WuuComputerRow -Store $store -Row $r5 | Out-Null

# Row 6: InstallErrors (Counts as Failed)
$r6 = New-WuuComputerRow -Computer 'SRV-06'
$r6.State = 'Complete'
$r6.InstallErrors = 2
Add-WuuComputerRow -Store $store -Row $r6 | Out-Null

$fleetCounts = Get-WuuFleetDistributionCounts -Store $store
Assert-Equal $fleetCounts.Total 6 'Fleet total is 6'
Assert-Equal $fleetCounts.Succeeded 1 'Succeeded count is 1 (excluding InstallErrors)'
Assert-Equal $fleetCounts.Failed 2 'Failed count is 2 (Error + InstallErrors)'
Assert-Equal $fleetCounts.TimedOut 1 'TimedOut count is 1'
Assert-Equal $fleetCounts.Running 1 'Running count is 1'
Assert-Equal $fleetCounts.Queued 1 'Queued count is 1'

$fleetChart = Format-WuuFleetDistribution -Store $store -BarWidth 12
Assert-Equal $fleetChart.Count 6 'Fleet distribution chart produces 6 rows'

# ---------------------------------------------------------------------------------------
# 4. Host Rendering & Theme Safety (Write-WuuHorizontalChart, Write-WuuFleetDistributionChart)
# ---------------------------------------------------------------------------------------
foreach ($thm in @('Standard', 'Accessible', 'NoColor')) {
    Set-WuuTheme -Theme $thm | Out-Null

    $threwChart = $false
    try {
        Write-WuuHorizontalChart -ChartRows $fleetChart -Indent '  ' | Out-Null
        Write-WuuFleetDistributionChart -Store $store -BarWidth 12 | Out-Null
    } catch {
        $threwChart = $true
        Fail ("Chart host rendering threw under theme '$thm': $($_.Exception.Message)")
    }
    if (-not $threwChart) {
        Pass "Chart host rendering executed cleanly under theme '$thm'"
    }
}
Set-WuuTheme -Theme 'Standard' | Out-Null

# ---------------------------------------------------------------------------------------
# 5. Format-WuuReportTable Integration Verification
# ---------------------------------------------------------------------------------------
$dummyReport = [pscustomobject]@{
    Summary = [pscustomobject]@{
        TotalRuns          = 10
        SuccessfulRuns     = 7
        FailedRuns         = 2
        DeniedRuns         = 1
        StartedRuns        = 0
        UnknownRuns        = 0
        SettledRuns        = 9
        SuccessRatePercent = 77.8
        AvgDurationSeconds = 15.0
        DistinctTargets    = 5
        FailingTargets     = 2
    }
    Runs = @()
    TimeBuckets = @()
    ProblemTargets = @()
    ErrorBreakdown = @(
        [pscustomobject]@{ Count = 2; IsRefusal = $false; Error = '0x80240020 Failed download' }
        [pscustomobject]@{ Count = 1; IsRefusal = $true;  Error = 'Missing -Reason confirmation' }
    )
}

foreach ($thm in @('Standard', 'Accessible', 'NoColor')) {
    Set-WuuTheme -Theme $thm | Out-Null
    $repThrew = $false
    try {
        Format-WuuReportTable -Report $dummyReport -Window $null | Out-Null
    } catch {
        $repThrew = $true
        Fail ("Format-WuuReportTable with charts threw under theme '$thm': $($_.Exception.Message)")
    }
    if (-not $repThrew) {
        Pass "Format-WuuReportTable with charts rendered cleanly under theme '$thm'"
    }
}
Set-WuuTheme -Theme 'Standard' | Out-Null

# ---------------------------------------------------------------------------------------
# 6. AST & Line-Orientation Purity (No Cursor Control, No ANSI)
# ---------------------------------------------------------------------------------------
$presContent = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Presentation.psm1') -Raw
$forbiddenPatterns = @(
    'CursorPosition'
    'CursorLeft'
    'CursorTop'
    'Clear-Host'
    '`e\['
    '\x1b\['
    '\[Console\]::SetCursorPosition'
)
foreach ($p in $forbiddenPatterns) {
    if ($presContent -match $p) {
        Fail "Presentation module violates line-oriented purity: matches '$p'"
    } else {
        Pass "Presentation module free of forbidden pattern '$p'"
    }
}

# ---------------------------------------------------------------------------------------
if ($fail) {
    Write-Host "`nTest-ChartRendering: FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nTest-ChartRendering: ALL ASSERTIONS PASSED" -ForegroundColor Green
    exit 0
}
