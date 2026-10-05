#Requires -Version 5.1
<#
.SYNOPSIS Unified theming, truthful status tokens, and accessibility test suite (CLI-ACCORD-01).
.DESCRIPTION
Validates:
  1. Get-WuuTheme and Set-WuuTheme lifecycle, environment overrides ($env:NO_COLOR, $env:WUU_THEME).
  2. Get-WuuThemeColor palette correctness across Standard, Accessible (Okabe-Ito), and NoColor themes.
  3. Get-WuuRowColor delegation to presentation theme resolver.
  4. Get-WuuStatusToken truthfulness: unmatched/uninspected rows return [---] instead of false [OK].
  5. Get-WuuRowOperationState (guided navigation) theme responsiveness and name invariance.
  6. Table rendering, status line, progress ticker, and report rendering execute without error under NoColor.
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

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

# Ensure environment is clean before testing
$origNoColor = $env:NO_COLOR
$origWuuTheme = $env:WUU_THEME
Remove-Item env:NO_COLOR -ErrorAction SilentlyContinue
Remove-Item env:WUU_THEME -ErrorAction SilentlyContinue

try {
    # -----------------------------------------------------------------------------------
    # 1. Theme Configuration & Environment Overrides
    # -----------------------------------------------------------------------------------
    Set-WuuTheme -Theme 'Standard' | Out-Null
    Assert-Equal (Get-WuuTheme) 'Standard' 'Default theme is Standard'

    Set-WuuTheme -Theme 'Accessible' | Out-Null
    Assert-Equal (Get-WuuTheme) 'Accessible' 'Set-WuuTheme switches to Accessible'

    Set-WuuTheme -Theme 'NoColor' | Out-Null
    Assert-Equal (Get-WuuTheme) 'NoColor' 'Set-WuuTheme switches to NoColor'

    Set-WuuTheme -Theme 'Standard' | Out-Null
    Assert-Equal (Get-WuuTheme) 'Standard' 'Set-WuuTheme switches back to Standard'

    # ValidateSet guard on Set-WuuTheme
    $threwInvalid = $false
    try {
        Set-WuuTheme -Theme 'NeonGlow' -ErrorAction Stop
    } catch {
        $threwInvalid = $true
    }
    Assert-Equal $threwInvalid $true 'Set-WuuTheme throws on invalid theme name'

    # Environment override: WUU_THEME
    $env:WUU_THEME = 'Accessible'
    Assert-Equal (Get-WuuTheme) 'Accessible' '$env:WUU_THEME overrides script theme to Accessible'

    $env:WUU_THEME = 'InvalidTheme'
    Assert-Equal (Get-WuuTheme) 'Standard' 'Invalid $env:WUU_THEME falls back to script theme'
    Remove-Item env:WUU_THEME -ErrorAction SilentlyContinue

    # Environment override: NO_COLOR (takes top precedence)
    $env:WUU_THEME = 'Accessible'
    $env:NO_COLOR = '1'
    Assert-Equal (Get-WuuTheme) 'NoColor' '$env:NO_COLOR takes top precedence over $env:WUU_THEME'

    Remove-Item env:NO_COLOR -ErrorAction SilentlyContinue
    Remove-Item env:WUU_THEME -ErrorAction SilentlyContinue
    Set-WuuTheme -Theme 'Standard' | Out-Null

    # -----------------------------------------------------------------------------------
    # 2. Get-WuuThemeColor Palette Correctness
    # -----------------------------------------------------------------------------------
    # Standard theme
    Assert-Equal (Get-WuuThemeColor -Role 'Success' -Theme 'Standard') 'Green' 'Standard Success is Green'
    Assert-Equal (Get-WuuThemeColor -Role 'Failure' -Theme 'Standard') 'Red' 'Standard Failure is Red'
    Assert-Equal (Get-WuuThemeColor -Role 'RowError' -Theme 'Standard') 'DarkGray' 'Standard RowError is DarkGray'
    Assert-Equal (Get-WuuThemeColor -Role 'Attention' -Theme 'Standard') 'Yellow' 'Standard Attention is Yellow'
    Assert-Equal (Get-WuuThemeColor -Role 'Timeout' -Theme 'Standard') 'Yellow' 'Standard Timeout is Yellow'
    Assert-Equal (Get-WuuThemeColor -Role 'Stale' -Theme 'Standard') 'DarkYellow' 'Standard Stale is DarkYellow'
    Assert-Equal (Get-WuuThemeColor -Role 'Progress' -Theme 'Standard') 'Cyan' 'Standard Progress is Cyan'
    Assert-Equal (Get-WuuThemeColor -Role 'Header' -Theme 'Standard') 'DarkCyan' 'Standard Header is DarkCyan'
    Assert-Equal (Get-WuuThemeColor -Role 'Muted' -Theme 'Standard') 'DarkGray' 'Standard Muted is DarkGray'
    Assert-Equal (Get-WuuThemeColor -Role 'Info' -Theme 'Standard') 'White' 'Standard Info is White'
    Assert-Equal (Get-WuuThemeColor -Role 'Default' -Theme 'Standard') 'Gray' 'Standard Default is Gray'

    # Accessible theme (Okabe-Ito inspired)
    Assert-Equal (Get-WuuThemeColor -Role 'Success' -Theme 'Accessible') 'Cyan' 'Accessible Success is Cyan'
    Assert-Equal (Get-WuuThemeColor -Role 'Failure' -Theme 'Accessible') 'Magenta' 'Accessible Failure is Magenta'
    Assert-Equal (Get-WuuThemeColor -Role 'RowError' -Theme 'Accessible') 'DarkMagenta' 'Accessible RowError is DarkMagenta'
    Assert-Equal (Get-WuuThemeColor -Role 'Attention' -Theme 'Accessible') 'Yellow' 'Accessible Attention is Yellow'
    Assert-Equal (Get-WuuThemeColor -Role 'Timeout' -Theme 'Accessible') 'Yellow' 'Accessible Timeout is Yellow'
    Assert-Equal (Get-WuuThemeColor -Role 'Stale' -Theme 'Accessible') 'Yellow' 'Accessible Stale is Yellow'
    Assert-Equal (Get-WuuThemeColor -Role 'Progress' -Theme 'Accessible') 'White' 'Accessible Progress is White'
    Assert-Equal (Get-WuuThemeColor -Role 'Header' -Theme 'Accessible') 'DarkCyan' 'Accessible Header is DarkCyan'
    Assert-Equal (Get-WuuThemeColor -Role 'Muted' -Theme 'Accessible') 'DarkGray' 'Accessible Muted is DarkGray'
    Assert-Equal (Get-WuuThemeColor -Role 'Info' -Theme 'Accessible') 'White' 'Accessible Info is White'
    Assert-Equal (Get-WuuThemeColor -Role 'Default' -Theme 'Accessible') 'Gray' 'Accessible Default is Gray'

    # NoColor theme
    Assert-Equal (Get-WuuThemeColor -Role 'Success' -Theme 'NoColor') '' 'NoColor Success is empty string'
    Assert-Equal (Get-WuuThemeColor -Role 'Failure' -Theme 'NoColor') '' 'NoColor Failure is empty string'
    Assert-Equal (Get-WuuThemeColor -Role 'Progress' -Theme 'NoColor') '' 'NoColor Progress is empty string'
    Assert-Equal (Get-WuuThemeColor -Role 'Header' -Theme 'NoColor') '' 'NoColor Header is empty string'

    # -----------------------------------------------------------------------------------
    # 3. Get-WuuRowColor Delegation
    # -----------------------------------------------------------------------------------
    Set-WuuTheme -Theme 'Standard' | Out-Null
    Assert-Equal (Get-WuuRowColor -Color 'Success') 'Green' 'Get-WuuRowColor Success in Standard is Green'
    Assert-Equal (Get-WuuRowColor -Color 'Error') 'DarkGray' 'Get-WuuRowColor Error in Standard is DarkGray'
    Assert-Equal (Get-WuuRowColor -Color 'Timeout') 'Yellow' 'Get-WuuRowColor Timeout in Standard is Yellow'
    Assert-Equal (Get-WuuRowColor -Color 'Default') 'Gray' 'Get-WuuRowColor Default in Standard is Gray'

    Set-WuuTheme -Theme 'Accessible' | Out-Null
    Assert-Equal (Get-WuuRowColor -Color 'Success') 'Cyan' 'Get-WuuRowColor Success in Accessible is Cyan'
    Assert-Equal (Get-WuuRowColor -Color 'Error') 'DarkMagenta' 'Get-WuuRowColor Error in Accessible is DarkMagenta'
    Assert-Equal (Get-WuuRowColor -Color 'Timeout') 'Yellow' 'Get-WuuRowColor Timeout in Accessible is Yellow'

    Set-WuuTheme -Theme 'NoColor' | Out-Null
    Assert-Equal (Get-WuuRowColor -Color 'Success') '' 'Get-WuuRowColor Success in NoColor is empty string'
    Assert-Equal (Get-WuuRowColor -Color 'Error') '' 'Get-WuuRowColor Error in NoColor is empty string'

    Set-WuuTheme -Theme 'Standard' | Out-Null

    # -----------------------------------------------------------------------------------
    # 4. Truthful Status Tokens (Get-WuuStatusToken)
    # -----------------------------------------------------------------------------------
    # Unmatched / unknown rows must return [---], NEVER false [OK]
    $unknownRow = [pscustomobject]@{
        Computer = 'SRV-UNK'
        State    = 'Unknown'
        OpState  = 'Idle'
        Status   = 'Uninspected machine'
    }
    Assert-Equal (Get-WuuStatusToken -Row $unknownRow) '[---]' 'Unmatched row with State=Unknown returns [---]'

    $emptyRow = [pscustomobject]@{
        Computer = 'SRV-EMPTY'
    }
    Assert-Equal (Get-WuuStatusToken -Row $emptyRow) '[---]' 'Empty row without state properties returns [---]'

    # Verified states must continue to return their truthful tokens
    $okRow = [pscustomobject]@{ Computer = 'SRV-1'; State = 'Complete'; OpState = 'Idle' }
    Assert-Equal (Get-WuuStatusToken -Row $okRow) '[OK]' 'Concluded successful row returns [OK]'

    $runRow = [pscustomobject]@{ Computer = 'SRV-2'; OpState = 'Running'; State = 'Checking' }
    Assert-Equal (Get-WuuStatusToken -Row $runRow) '[RUN]' 'Running row returns [RUN]'

    $waitRow = [pscustomobject]@{ Computer = 'SRV-3'; OpState = 'Queued'; State = 'Queued' }
    Assert-Equal (Get-WuuStatusToken -Row $waitRow) '[WAIT]' 'Queued row returns [WAIT]'

    $rbtRow = [pscustomobject]@{ Computer = 'SRV-4'; RebootRequired = $true; OpState = 'Idle' }
    Assert-Equal (Get-WuuStatusToken -Row $rbtRow) '[RBT]' 'Reboot required row returns [RBT]'

    $failRow = [pscustomobject]@{ Computer = 'SRV-5'; State = 'Error'; OpState = 'Idle' }
    Assert-Equal (Get-WuuStatusToken -Row $failRow) '[FAIL]' 'Error row returns [FAIL]'

    $instErrRow = [pscustomobject]@{ Computer = 'SRV-6'; State = 'Complete'; InstallErrors = 1 }
    Assert-Equal (Get-WuuStatusToken -Row $instErrRow) '[FAIL]' 'Row with InstallErrors > 0 returns [FAIL]'

    # -----------------------------------------------------------------------------------
    # 5. Guided Navigation Lifecycle Translation (Get-WuuRowOperationState)
    # -----------------------------------------------------------------------------------
    Set-WuuTheme -Theme 'Standard' | Out-Null
    $navRowSuccess = [pscustomobject]@{ State = 'Complete' }
    $s1 = Get-WuuRowOperationState -Row $navRowSuccess
    Assert-Equal $s1.Name 'Complete' 'Nav state name for Complete is Complete'
    Assert-Equal $s1.Color 'Green' 'Nav state color for Complete in Standard is Green'

    $navRowError = [pscustomobject]@{ State = 'Error' }
    $s2 = Get-WuuRowOperationState -Row $navRowError
    Assert-Equal $s2.Name 'Failed' 'Nav state name for Error is Failed'
    Assert-Equal $s2.Color 'Red' 'Nav state color for Error in Standard is Red'

    Set-WuuTheme -Theme 'Accessible' | Out-Null
    $s3 = Get-WuuRowOperationState -Row $navRowSuccess
    Assert-Equal $s3.Color 'Cyan' 'Nav state color for Complete in Accessible is Cyan'
    $s4 = Get-WuuRowOperationState -Row $navRowError
    Assert-Equal $s4.Color 'Magenta' 'Nav state color for Error in Accessible is Magenta'

    Set-WuuTheme -Theme 'NoColor' | Out-Null
    $s5 = Get-WuuRowOperationState -Row $navRowSuccess
    Assert-Equal $s5.Color '' 'Nav state color for Complete in NoColor is empty string'
    $s6 = Get-WuuRowOperationState -Row $navRowError
    Assert-Equal $s6.Color '' 'Nav state color for Error in NoColor is empty string'

    Set-WuuTheme -Theme 'Standard' | Out-Null

    # -----------------------------------------------------------------------------------
    # 6. Renderers Do Not Throw Under Any Theme (Especially NoColor)
    # -----------------------------------------------------------------------------------
    $store = New-WuuStateStore
    Add-WuuComputerRow -Store $store -Row (New-WuuComputerRow -Computer 'SRV-TST1') | Out-Null
    Add-WuuComputerRow -Store $store -Row (New-WuuComputerRow -Computer 'SRV-TST2') | Out-Null
    $store.SetStatus('Live fleet test')

    foreach ($themeToTest in @('Standard', 'Accessible', 'NoColor')) {
        Set-WuuTheme -Theme $themeToTest | Out-Null

        $renderThrew = $false
        try {
            Write-WuuStatusTable -Store $store | Out-Null
            Write-WuuStatusLine -Store $store | Out-Null
        } catch {
            $renderThrew = $true
            Fail ("Write-WuuStatusTable threw under theme '$themeToTest': $($_.Exception.Message)")
        }
        if (-not $renderThrew) {
            Pass "Console table and status line rendered cleanly under '$themeToTest'"
        }
    }

    # Format-WuuReportTable under all themes
    $dummyReport = [pscustomobject]@{
        Summary = [pscustomobject]@{
            TotalRuns          = 10
            SuccessfulRuns     = 8
            FailedRuns         = 2
            DeniedRuns         = 0
            StartedRuns        = 0
            UnknownRuns        = 0
            SettledRuns        = 10
            SuccessRatePercent = 80.0
            AvgDurationSeconds = 12.5
            DistinctTargets    = 2
            FailingTargets     = 1
        }
        Runs = @()
        TimeBuckets = @(
            [pscustomobject]@{
                PeriodLabel = 'Today'
                Total       = 10
                Succeeded   = 8
                Failed      = 2
                Denied      = 0
                SuccessRate = 80.0
            }
        )
        ProblemTargets = @(
            [pscustomobject]@{
                Computer    = 'SRV-TST2'
                Attempts    = 2
                Failures    = 2
                FailureRate = 100.0
                LastError   = '0x80240020'
            }
        )
        ErrorBreakdown = @(
            [pscustomobject]@{
                Count     = 2
                IsRefusal = $false
                Error     = '0x80240020 Failed download'
            }
        )
    }

    foreach ($themeToTest in @('Standard', 'Accessible', 'NoColor')) {
        Set-WuuTheme -Theme $themeToTest | Out-Null
        $reportThrew = $false
        try {
            Format-WuuReportTable -Report $dummyReport -Window $null | Out-Null
        } catch {
            $reportThrew = $true
            Fail ("Format-WuuReportTable threw under theme '$themeToTest': $($_.Exception.Message)")
        }
        if (-not $reportThrew) {
            Pass "Format-WuuReportTable rendered cleanly under '$themeToTest'"
        }
    }

} finally {
    # Restore original environment
    if ($origNoColor) { $env:NO_COLOR = $origNoColor } else { Remove-Item env:NO_COLOR -ErrorAction SilentlyContinue }
    if ($origWuuTheme) { $env:WUU_THEME = $origWuuTheme } else { Remove-Item env:WUU_THEME -ErrorAction SilentlyContinue }
    Set-WuuTheme -Theme 'Standard' | Out-Null
}

if ($fail) {
    Write-Host "`nTest suite FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nAll tests PASSED" -ForegroundColor Green
    exit 0
}
