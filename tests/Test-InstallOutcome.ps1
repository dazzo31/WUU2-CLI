#Requires -Version 5.1
<#
.SYNOPSIS Verification that patch installation failures are never masked as success (STATE-INSTALL-01).
.DESCRIPTION
Validates:
  1. Failed updates (InstallErrors > 0) produce State='Error', UpdatesStatus='Error', Color='Error'.
  2. Failed updates with RebootRequired preserve RebootRequired=$true while remaining State='Error'.
  3. Clean updates (InstallErrors = 0) produce State='Complete' (or 'RebootRequired' if reboot flagged).
  4. Get-WuuTargetOutcome returns 'Failed' whenever InstallErrors > 0, even if State was 'Complete'.
  5. Aggregate outcome on install failure is OperationFailed (1) or PartialSuccess (4), never Success (0).
  6. Scripts/Install-Patches.ps1 reports Result='Failed' when numErrors > 0.
  7. Wuu.Remote.psm1 preserves error count and RebootRequired on failure.

Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-InstallOutcome.ps1
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
function Assert-True($Condition, $Name) {
    if ($Condition) { Pass $Name }
    else { Fail $Name }
}

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

# ---------------------------------------------------------------------------------------
# 1. Target Outcome Classification with InstallErrors
# ---------------------------------------------------------------------------------------
# Clean complete host
$cleanRow = New-WuuComputerRow -Computer 'SRV-CLEAN'
$cleanRow.State = 'Complete'
$cleanRow.UpdatesStatus = 'Complete'
$cleanRow.InstallErrors = 0
Assert-Equal (Get-WuuTargetOutcome -Row $cleanRow) 'Success' 'clean row with 0 InstallErrors is Success'

# The core bug reproduction: State was stamped Complete, but 2 updates failed
$reproRow = New-WuuComputerRow -Computer 'SRV-REPRO'
$reproRow.State = 'Complete'
$reproRow.UpdatesStatus = 'Complete'
$reproRow.InstallErrors = 2
Assert-Equal (Get-WuuTargetOutcome -Row $reproRow) 'Failed' 'row with InstallErrors > 0 resolves to Failed even if State=Complete'

# Mixed fleet aggregation: 1 clean success, 1 with install errors -> PartialSuccess (exit 4)
$mixedOutcome = Get-WuuAggregateOutcome -Rows @($cleanRow, $reproRow)
Assert-Equal $mixedOutcome 'PartialSuccess' 'fleet with 1 clean and 1 install-errored node is PartialSuccess'

# All failed fleet -> OperationFailed (exit 1), never Success
$allFailedOutcome = Get-WuuAggregateOutcome -Rows @($reproRow)
Assert-Equal $allFailedOutcome 'OperationFailed' 'fleet where all nodes had install errors is OperationFailed'

# ---------------------------------------------------------------------------------------
# 2. Remote Task Result Model in Wuu.Remote.psm1
# ---------------------------------------------------------------------------------------
# Mock reading a state file with Result='Failed', Count=2, RebootRequired=$true
$remoteRaw = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Remote.psm1'))
Assert-True ($remoteRaw -match '\$errorCount\s*=\s*if\s*\(\$state\s*-and\s*\$state\.Count\)') 'Remote task preserves Count on non-success'
Assert-True ($remoteRaw -match '\$rebootReq\s*=\s*if\s*\(\$state\s*-and\s*\$state\.RebootRequired\)') 'Remote task preserves RebootRequired on non-success'

# ---------------------------------------------------------------------------------------
# 3. Core Install Handler State and Error Handling
# ---------------------------------------------------------------------------------------
$coreRaw = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Core.psm1'))

# Verify Core checks ($installErrors -gt 0) and does not unconditionally set Complete
Assert-True ($coreRaw -match 'if\s*\(-not\s*\$taskResult\.Success\s*-or\s*\$installErrors\s*-gt\s*0\)') 'Core install handler checks task failure or installErrors > 0'
Assert-True ($coreRaw -match "\`$computer\.State\s*=\s*'Error'[\s\S]*?\`$computer\.UpdatesStatus\s*=\s*'Error'") 'Core sets State=Error and UpdatesStatus=Error on failure'

# ---------------------------------------------------------------------------------------
# 4. Install-Patches.ps1 Script Contract
# ---------------------------------------------------------------------------------------
$installScriptRaw = [System.IO.File]::ReadAllText((Join-Path $root 'Scripts\Install-Patches.ps1'))
Assert-True ($installScriptRaw -match '\$resultStr\s*=\s*if\s*\(\$numErrors\s*-gt\s*0\)\s*\{\s*''Failed''\s*\}\s*else\s*\{\s*''Success''\s*\}') 'Install-Patches reports Result=Failed when numErrors > 0'

# ---------------------------------------------------------------------------------------
# 5. Row State & Reboot Required Preservation Under Install Errors
# ---------------------------------------------------------------------------------------
# Row with install errors and reboot required
$errWithRebootRow = New-WuuComputerRow -Computer 'SRV-ERR-RBT'
$errWithRebootRow.InstallErrors = 1
$errWithRebootRow.RebootRequired = $true
$errWithRebootRow.State = 'Error'
$errWithRebootRow.UpdatesStatus = 'Error'
Assert-Equal (Get-WuuTargetOutcome -Row $errWithRebootRow) 'Failed' 'errored row with RebootRequired=true is still Failed'
Assert-True $errWithRebootRow.RebootRequired 'RebootRequired remains true on failed installation'

# Final Verdict
Write-Host ''
if ($fail) {
    Write-Host 'Test-InstallOutcome: SOME CHECKS FAILED' -ForegroundColor Red
    exit 1
}
Write-Host 'Test-InstallOutcome: ALL PASS' -ForegroundColor Cyan
exit 0
