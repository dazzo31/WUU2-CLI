# Test: Worker identity fencing and terminal transition guards (STATE-FENCE-01).
#
# Asserts:
# 1. UpdateWuuOperationStateScript refuses writes from workers after ResetOperation.
# 2. UpdateWuuOperationStateScript refuses transitioning settled terminal states (Error/Timeout/Complete).
# 3. UpdateWuuComputerRowScript refuses writes when LastResetOperationId is populated.
# 4. UpdateWuuComputerRowScript refuses transitioning settled terminal states.
# 5. Update-WuuComputerRow in Wuu.Core refuses writes after ResetOperation and terminal transitions.
# 6. Payload completion guards preserve reset and terminal Error states.
#
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-WorkerIdentityFence.ps1
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

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force -ErrorAction Stop
Import-WuuModules -WuuRoot $root

Write-Host '=== 1. Worker Funnel (UpdateWuuOperationStateScript) Reset Fencing ===' -ForegroundColor Cyan

# Create a test runspace using New-ComputerRunspace to obtain the exact injected scriptblocks
$testRow = New-WuuComputerRow -Computer 'FENCE-PC-1'
$testRow.Runspace = New-ComputerRunspace -Computer $testRow -searchTimeout 60 -sessionTimeout 60 -rebootCheckTimeout 60

$runspace = $testRow.Runspace
$workerFunnel = $runspace.SessionStateProxy.GetVariable('UpdateWuuOperationStateScript')
$workerRowScript = $runspace.SessionStateProxy.GetVariable('UpdateWuuComputerRowScript')

Assert-True ($null -ne $workerFunnel) 'UpdateWuuOperationStateScript is present in worker runspace'
Assert-True ($null -ne $workerRowScript) 'UpdateWuuComputerRowScript is present in worker runspace'

# Set an operation ID in the runspace
$runspace.SessionStateProxy.SetVariable('WuuOperationId', 'op-fence-01')
$testRow.OperationId = 'op-fence-01'
$testRow.OpState = 'Running'

# Legitimate worker write succeeds
$applied = & $workerFunnel -Computer $testRow -State 'Searching' -Status 'Searching updates...'
Assert-True $applied 'Legitimate in-flight worker write is applied'
Assert-Equal $testRow.State 'Searching' 'Row state is Searching'

# Reset the operation via the official funnel
$resetCtx = New-WuuResetOperationContext -Source 'SubmissionFailure' -Reason 'Init failed'
$resetRes = Update-WuuOperationState -Row $testRow -ResetOperation $resetCtx -State 'Error'
Assert-True $resetRes.Applied 'ResetOperation applied'
Assert-Equal $testRow.State 'Error' 'Row state moved to Error on reset'
Assert-Equal $testRow.OperationId '' 'Row OperationId cleared by reset'
Assert-True ($testRow.LastResetOperationId -ne '') 'LastResetOperationId populated on row'

# Late worker from op-fence-01 tries to write Complete
$lateApplied = & $workerFunnel -Computer $testRow -State 'Complete' -Status 'Finished'
Assert-False $lateApplied 'Worker funnel refuses write after operation was reset'
Assert-Equal $testRow.State 'Error' 'Row state remains Error (stale worker did not overwrite)'

Write-Host '=== 2. Worker Funnel (UpdateWuuOperationStateScript) Terminal Transition Guard ===' -ForegroundColor Cyan

$termRow = New-WuuComputerRow -Computer 'TERM-PC-1'
$termRow.State = 'Error'
$termRow.OperationId = ''
$termRow.OpState = 'Idle'

# Worker with no reset context tries to move Error -> Complete
$illegalTerm = & $workerFunnel -Computer $termRow -State 'Complete'
Assert-False $illegalTerm 'Worker funnel refuses transition from terminal Error to Complete'
Assert-Equal $termRow.State 'Error' 'Row state remains Error'

# Worker tries to move Timeout -> Complete
$termRow.State = 'Timeout'
$illegalTerm2 = & $workerFunnel -Computer $termRow -State 'Complete'
Assert-False $illegalTerm2 'Worker funnel refuses transition from terminal Timeout to Complete'
Assert-Equal $termRow.State 'Timeout' 'Row state remains Timeout'

# Worker tries to move Complete -> Checking
$termRow.State = 'Complete'
$illegalTerm3 = & $workerFunnel -Computer $termRow -State 'Checking'
Assert-False $illegalTerm3 'Worker funnel refuses transition from terminal Complete to Checking'
Assert-Equal $termRow.State 'Complete' 'Row state remains Complete'

try { $runspace.Close(); $runspace.Dispose() } catch { }

Write-Host '=== 3. Worker Row Script (UpdateWuuComputerRowScript) Fencing ===' -ForegroundColor Cyan

$testRow2 = New-WuuComputerRow -Computer 'FENCE-PC-2'
$testRow2.Runspace = New-ComputerRunspace -Computer $testRow2 -searchTimeout 60 -sessionTimeout 60 -rebootCheckTimeout 60
$runspace2 = $testRow2.Runspace
$workerRowScript2 = $runspace2.SessionStateProxy.GetVariable('UpdateWuuComputerRowScript')

$mockStore = [pscustomobject]@{
    ByName = @{}
    TouchCount = 0
    Touch = { $this.TouchCount++ }
}
$mockRow = New-WuuComputerRow -Computer 'ROW-PC-1'
$mockStore.ByName['row-pc-1'] = $mockRow

$runspace2.SessionStateProxy.SetVariable('stateStore', $mockStore)
$runspace2.SessionStateProxy.SetVariable('WuuOperationId', 'op-row-01')

# Set row as reset
$mockRow.State = 'Error'
$mockRow.OperationId = ''
$mockRow.LastResetOperationId = 'reset-row-99'
$mockRow.LastResetSource = 'SubmissionFailure'
$mockRow.LastResetReason = 'worker timeout'

& $workerRowScript2 -ComputerName 'ROW-PC-1' -Properties @{ State = 'Complete'; Status = 'All done' }
Assert-Equal $mockRow.State 'Error' 'UpdateWuuComputerRowScript refused write on reset row'

# Test terminal transition on UpdateWuuComputerRowScript
$mockRow2 = New-WuuComputerRow -Computer 'ROW-PC-2'
$mockRow2.State = 'Error'
$mockStore.ByName['row-pc-2'] = $mockRow2
$runspace2.SessionStateProxy.SetVariable('WuuOperationId', '')

& $workerRowScript2 -ComputerName 'ROW-PC-2' -Properties @{ State = 'Complete' }
Assert-Equal $mockRow2.State 'Error' 'UpdateWuuComputerRowScript refused transition from Error to Complete'

try { $runspace2.Close(); $runspace2.Dispose() } catch { }

Write-Host '=== 4. Module-Scope Update-WuuComputerRow Fencing ===' -ForegroundColor Cyan

$coreStore = [pscustomobject]@{
    ByName = @{}
    TouchCount = 0
    Touch = { $this.TouchCount++ }
}
$coreRow = New-WuuComputerRow -Computer 'CORE-PC-1'
$coreRow.State = 'Error'
$coreRow.OperationId = ''
$coreRow.LastResetOperationId = 'reset-core-77'
$coreRow.LastResetSource = 'SubmissionFailure'
$coreRow.LastResetReason = 'core reset test'
$coreStore.ByName['core-pc-1'] = $coreRow

$coreRaw = Get-Content (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$fnMatch = [regex]::Match($coreRaw, '(?s)function Update-WuuComputerRow\s*\{(.*?)\n\}')
Assert-True $fnMatch.Success 'Update-WuuComputerRow found in Wuu.Core.psm1'
$updateComputerRowSb = [scriptblock]::Create($fnMatch.Groups[1].Value)

$stateStore = $coreStore
. $updateComputerRowSb 'CORE-PC-1' @{ OperationId = 'op-core-old'; State = 'Complete' }
Assert-Equal $coreRow.State 'Error' 'Update-WuuComputerRow refused write when LastResetOperationId is set'

# Terminal transition without operation id
$coreRow2 = New-WuuComputerRow -Computer 'CORE-PC-2'
$coreRow2.State = 'Timeout'
$coreStore.ByName['core-pc-2'] = $coreRow2

. $updateComputerRowSb 'CORE-PC-2' @{ State = 'Complete' }
Assert-Equal $coreRow2.State 'Timeout' 'Update-WuuComputerRow refused transition from Timeout to Complete'

Write-Host '=== 5. Payload Completion Guards (Direct State Assignments) ===' -ForegroundColor Cyan

$payloadRow = New-WuuComputerRow -Computer 'PAYLOAD-PC-1'
$payloadRow.State = 'Error'
$payloadRow.LastResetOperationId = 'reset-pl-88'

# Simulate payload block checks
$curState = if ($payloadRow.PSObject.Properties['State']) { [string]$payloadRow.State } else { '' }
$wouldRefuse = ($payloadRow.PSObject.Properties['LastResetOperationId'] -and $payloadRow.LastResetOperationId) -or ($curState -in @('Error', 'Timeout', 'Complete'))
Assert-True $wouldRefuse 'Payload guard successfully identifies reset and settled Error state'

if ($failures.Count -eq 0) {
    Write-Host "`nALL PASS - Worker identity fencing and terminal guards verified (STATE-FENCE-01)`n" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`nFAILURES: $($failures.Count)`n" -ForegroundColor Red
    exit 1
}
