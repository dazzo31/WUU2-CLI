#Requires -Version 5.1
<#
.SYNOPSIS Observability, heartbeat staleness, status tokens, and phase dependency ticker tests (CLI-OBSERVE-01).
.DESCRIPTION
Validates:
  1. Get-WuuStatusToken returns exact fixed-width ASCII tokens:
     - [FAIL] for Error/Timeout/Offline/InstallErrors
     - [RUN] for Running/Checking/Downloading/Installing/Rebooting
     - [RBT] for RebootRequired when idle
     - [WAIT] for Queued/Pending/Waiting for phase
     - [OK] for Complete/Clean idle
  2. Format-WuuTable displays [STALE beat Xs ago] when a running worker has no heartbeat for > 45s.
  3. Format-WuuTable cleans verbose status strings and prefixes fixed-width status tokens.
  4. Write-WuuStatusTable renders without throwing on fleets with stale workers.
  5. Get-WuuOperationProgress and Format-WuuProgressTicker report "Waiting for Phase <N> (<count> active)"
     when higher phases have work waiting on lower phase active workers.
  6. Observational AST purity: formatting and token functions never invoke mutating commands.

Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-Observability.ps1
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

# Helper to construct rows with required properties
function New-ObservabilityRow {
    param(
        [string]$Computer,
        [string]$Phase = 'Phase 1',
        [string]$OpState = 'Idle',
        [string]$State = 'Complete',
        [bool]$Pending = $false,
        [datetime]$OpStartedAt = [datetime]::MinValue,
        [string]$Status = ''
    )
    $r = New-WuuComputerRow -Computer $Computer -Phase $Phase
    $r.OpState = $OpState
    $r.State = $State
    $r.Pending = $Pending
    if ($OpStartedAt -ne [datetime]::MinValue) {
        $r.OperationId = [guid]::NewGuid().ToString()
        $r.OpStartedAt = $OpStartedAt
    }
    if ($Status) { $r.Status = $Status }
    return $r
}

# ---------------------------------------------------------------------------------------
# 1. Get-WuuStatusToken Token Verification
# ---------------------------------------------------------------------------------------
# [FAIL] cases
$errRow = New-WuuComputerRow -Computer 'SRV-ERR'
$errRow.State = 'Error'
Assert-Equal (Get-WuuStatusToken -Row $errRow) '[FAIL]' 'Get-WuuStatusToken returns [FAIL] for State=Error'

$timeoutRow = New-WuuComputerRow -Computer 'SRV-TO'
$timeoutRow.State = 'Timeout'
Assert-Equal (Get-WuuStatusToken -Row $timeoutRow) '[FAIL]' 'Get-WuuStatusToken returns [FAIL] for State=Timeout'

$offlineRow = New-WuuComputerRow -Computer 'SRV-OFF'
$offlineRow.State = 'Offline'
Assert-Equal (Get-WuuStatusToken -Row $offlineRow) '[FAIL]' 'Get-WuuStatusToken returns [FAIL] for State=Offline'

$colorErrRow = New-WuuComputerRow -Computer 'SRV-CERR'
$colorErrRow.Color = 'Error'
Assert-Equal (Get-WuuStatusToken -Row $colorErrRow) '[FAIL]' 'Get-WuuStatusToken returns [FAIL] for Color=Error'

$instErrRow = New-WuuComputerRow -Computer 'SRV-IERR'
$instErrRow.InstallErrors = 2
Assert-Equal (Get-WuuStatusToken -Row $instErrRow) '[FAIL]' 'Get-WuuStatusToken returns [FAIL] for InstallErrors > 0'

# [RUN] cases
$runRow = New-WuuComputerRow -Computer 'SRV-RUN'
$runRow.OpState = 'Running'
Assert-Equal (Get-WuuStatusToken -Row $runRow) '[RUN]' 'Get-WuuStatusToken returns [RUN] for OpState=Running'

$dlRow = New-WuuComputerRow -Computer 'SRV-DL'
$dlRow.State = 'Downloading'
Assert-Equal (Get-WuuStatusToken -Row $dlRow) '[RUN]' 'Get-WuuStatusToken returns [RUN] for State=Downloading'

$rebootingRow = New-WuuComputerRow -Computer 'SRV-RBTG'
$rebootingRow.OpState = 'Running'
$rebootingRow.State = 'Rebooting'
$rebootingRow.RebootRequired = $true
Assert-Equal (Get-WuuStatusToken -Row $rebootingRow) '[RUN]' 'Get-WuuStatusToken returns [RUN] for active Rebooting even if RebootRequired is set'

# [RBT] cases
$rebootRow = New-WuuComputerRow -Computer 'SRV-RBT'
$rebootRow.OpState = 'Idle'
$rebootRow.RebootRequired = $true
Assert-Equal (Get-WuuStatusToken -Row $rebootRow) '[RBT]' 'Get-WuuStatusToken returns [RBT] for RebootRequired when idle'

$rebootStateRow = New-WuuComputerRow -Computer 'SRV-RBTS'
$rebootStateRow.OpState = 'Idle'
$rebootStateRow.State = 'RebootRequired'
Assert-Equal (Get-WuuStatusToken -Row $rebootStateRow) '[RBT]' 'Get-WuuStatusToken returns [RBT] for State=RebootRequired'

# [WAIT] cases
$queuedRow = New-WuuComputerRow -Computer 'SRV-QUE'
$queuedRow.OpState = 'Queued'
Assert-Equal (Get-WuuStatusToken -Row $queuedRow) '[WAIT]' 'Get-WuuStatusToken returns [WAIT] for OpState=Queued'

$pendingRow = New-WuuComputerRow -Computer 'SRV-PEN'
$pendingRow.State = 'Queued'
$pendingRow.Pending = $true
Assert-Equal (Get-WuuStatusToken -Row $pendingRow) '[WAIT]' 'Get-WuuStatusToken returns [WAIT] for Pending=true'

$waitingRow = New-WuuComputerRow -Computer 'SRV-WPH'
$waitingRow.Status = 'Waiting for previous phase to complete'
Assert-Equal (Get-WuuStatusToken -Row $waitingRow) '[WAIT]' 'Get-WuuStatusToken returns [WAIT] for Waiting for previous phase status'

# [OK] cases
$completeRow = New-WuuComputerRow -Computer 'SRV-OK'
$completeRow.State = 'Complete'
$completeRow.Pending = $false
$completeRow.OpState = 'Idle'
Assert-Equal (Get-WuuStatusToken -Row $completeRow) '[OK]' 'Get-WuuStatusToken returns [OK] for State=Complete'

$defaultRow = New-WuuComputerRow -Computer 'SRV-DEF'
Assert-Equal (Get-WuuStatusToken -Row $defaultRow) '[WAIT]' 'Get-WuuStatusToken returns [WAIT] for newly initialized default row'

# ---------------------------------------------------------------------------------------
# 2. Format-WuuTable Heartbeat Staleness & Status Token Rendering
# ---------------------------------------------------------------------------------------
$now = Get-Date

# Fresh heartbeat (< 45s)
$activeRow = New-WuuComputerRow -Computer 'SRV-ACT' -Phase 'Phase 1'
$activeRow.OpState = 'Running'
$activeRow.OpName = 'Download'
$activeRow.LastHeartbeatAt = $now.AddSeconds(-10)
$activeRow.TimeoutExpiresAt = $now.AddMinutes(15)
$activeRow.Status = 'Downloading updates'

$tableText = Format-WuuTable -Rows @($activeRow)
if ($tableText -match '\[RUN\]') {
    Pass 'Format-WuuTable prefixes active row with [RUN]'
} else {
    Fail 'Format-WuuTable did not prefix active row with [RUN]'
}

if ($tableText -match '\[Download \d+m left beat \d+s ago\]') {
    Pass 'Format-WuuTable formats fresh running operation with deadline and heartbeat'
} else {
    Fail "Format-WuuTable missing active deadline/heartbeat tag: $tableText"
}

if ($tableText -match '\[STALE') {
    Fail "Format-WuuTable falsely flagged fresh row as STALE: $tableText"
} else {
    Pass 'Format-WuuTable does not flag fresh row as STALE'
}

# Stale heartbeat (> 45s)
$staleRow = New-WuuComputerRow -Computer 'SRV-STL' -Phase 'Phase 1'
$staleRow.OpState = 'Running'
$staleRow.OpName = 'Download'
$staleRow.LastHeartbeatAt = $now.AddSeconds(-75)
$staleRow.TimeoutExpiresAt = $now.AddMinutes(15)
$staleRow.Status = 'Downloading updates'

$staleTableText = Format-WuuTable -Rows @($staleRow)
if ($staleTableText -match '\[RUN\] \[STALE beat \d+s ago\]') {
    Pass 'Format-WuuTable formats stale running row as [RUN] [STALE beat Xs ago]'
} else {
    Fail "Format-WuuTable did not format stale heartbeat correctly: $staleTableText"
}

# Settled status cleaning
$settledRow = New-WuuComputerRow -Computer 'SRV-CLN' -Phase 'Phase 1'
$settledRow.State = 'Complete'
$settledRow.Pending = $false
$settledRow.Status = 'All updates installed successfully.'
$settledTableText = Format-WuuTable -Rows @($settledRow)
if ($settledTableText -match '\[OK\] Up-to-date') {
    Pass 'Format-WuuTable simplifies boilerplate status to [OK] Up-to-date'
} else {
    Fail "Format-WuuTable did not simplify status to [OK] Up-to-date: $settledTableText"
}

# ---------------------------------------------------------------------------------------
# 3. Write-WuuStatusTable Execution on Mixed Fleet
# ---------------------------------------------------------------------------------------
$store = New-WuuStateStore
Add-WuuComputerRow -Store $store -Row $activeRow | Out-Null
Add-WuuComputerRow -Store $store -Row $staleRow | Out-Null
Add-WuuComputerRow -Store $store -Row $errRow | Out-Null
Add-WuuComputerRow -Store $store -Row $completeRow | Out-Null

try {
    Write-WuuStatusTable -Store $store
    Pass 'Write-WuuStatusTable renders mixed fleet (including stale worker) without throwing'
} catch {
    Fail "Write-WuuStatusTable threw: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------------------
# 4. Phase Dependency Tracking in Progress Ticker
# ---------------------------------------------------------------------------------------
# Scenario A: Single Phase - Phase 1 only (no phase dependency)
$singleStore = New-WuuStateStore
Add-WuuComputerRow -Store $singleStore -Row (New-ObservabilityRow -Computer 'P1-01' -Phase 'Phase 1' -OpState 'Running' -State 'Downloading' -OpStartedAt $now.AddMinutes(-2)) | Out-Null
Add-WuuComputerRow -Store $singleStore -Row (New-ObservabilityRow -Computer 'P1-02' -Phase 'Phase 1' -OpState 'Queued' -State 'Queued' -Pending $true) | Out-Null

$singleProg = Get-WuuOperationProgress -Store $singleStore -Now $now
Assert-Equal $singleProg.Active 1 'Single Phase: Active is 1'
Assert-Equal $singleProg.Queued 1 'Single Phase: Queued is 1'
if ($singleProg.WaitingPhase) {
    Fail "Single Phase: WaitingPhase should be null, got $($singleProg.WaitingPhase)"
} else {
    Pass 'Single Phase: WaitingPhase is null'
}
$singleLine = Format-WuuProgressTicker -Progress $singleProg
if ($singleLine -match 'Waiting for Phase') {
    Fail "Single Phase ticker should not mention Waiting for Phase: $singleLine"
} else {
    Pass 'Single Phase ticker does not mention Waiting for Phase'
}

# Scenario B: Multi-Phase - Phase 1 running (2 active), Phase 2 waiting (2 queued)
$multiStore = New-WuuStateStore
Add-WuuComputerRow -Store $multiStore -Row (New-ObservabilityRow -Computer 'P1-01' -Phase 'Phase 1' -OpState 'Running' -State 'Downloading' -OpStartedAt $now.AddMinutes(-3)) | Out-Null
Add-WuuComputerRow -Store $multiStore -Row (New-ObservabilityRow -Computer 'P1-02' -Phase 'Phase 1' -OpState 'Running' -State 'Downloading' -OpStartedAt $now.AddMinutes(-3)) | Out-Null
Add-WuuComputerRow -Store $multiStore -Row (New-ObservabilityRow -Computer 'P2-01' -Phase 'Phase 2' -OpState 'Queued' -State 'Queued' -Pending $true -Status 'Waiting for previous phase to complete') | Out-Null
Add-WuuComputerRow -Store $multiStore -Row (New-ObservabilityRow -Computer 'P2-02' -Phase 'Phase 2' -OpState 'Queued' -State 'Queued' -Pending $true -Status 'Waiting for previous phase to complete') | Out-Null

$multiProg = Get-WuuOperationProgress -Store $multiStore -Now $now
Assert-Equal $multiProg.Active 2 'Multi-Phase: Active is 2'
Assert-Equal $multiProg.Queued 2 'Multi-Phase: Queued is 2'
Assert-Equal $multiProg.WaitingPhase 1 'Multi-Phase: WaitingPhase identifies Phase 1'
Assert-Equal $multiProg.WaitingActiveCount 2 'Multi-Phase: WaitingActiveCount is 2'

$multiLine = Format-WuuProgressTicker -Progress $multiProg
if ($multiLine -match 'Waiting for Phase 1 \(2 active\)') {
    Pass 'Multi-Phase ticker displays "Waiting for Phase 1 (2 active)"'
} else {
    Fail "Multi-Phase ticker missing phase waiting notice: $multiLine"
}

# Scenario C: Phase 1 has completed; Phase 2 is now running
$p2Store = New-WuuStateStore
Add-WuuComputerRow -Store $p2Store -Row (New-ObservabilityRow -Computer 'P1-01' -Phase 'Phase 1' -OpState 'Idle' -State 'Complete') | Out-Null
Add-WuuComputerRow -Store $p2Store -Row (New-ObservabilityRow -Computer 'P1-02' -Phase 'Phase 1' -OpState 'Idle' -State 'Complete') | Out-Null
Add-WuuComputerRow -Store $p2Store -Row (New-ObservabilityRow -Computer 'P2-01' -Phase 'Phase 2' -OpState 'Running' -State 'Downloading' -OpStartedAt $now.AddMinutes(-1)) | Out-Null
Add-WuuComputerRow -Store $p2Store -Row (New-ObservabilityRow -Computer 'P2-02' -Phase 'Phase 2' -OpState 'Queued' -State 'Queued' -Pending $true) | Out-Null

$p2Prog = Get-WuuOperationProgress -Store $p2Store -Now $now
Assert-Equal $p2Prog.Active 1 'Phase 2 Active: Active is 1'
Assert-Equal $p2Prog.Queued 1 'Phase 2 Active: Queued is 1'
if ($p2Prog.WaitingPhase) {
    Fail "Phase 2 Active: WaitingPhase should be null, got $($p2Prog.WaitingPhase)"
} else {
    Pass 'Phase 2 Active: WaitingPhase is null since no lower phase is active'
}
$p2Line = Format-WuuProgressTicker -Progress $p2Prog
if ($p2Line -match 'Waiting for Phase') {
    Fail "Phase 2 Active ticker should not mention Waiting for Phase: $p2Line"
} else {
    Pass 'Phase 2 Active ticker does not mention Waiting for Phase'
}

# ---------------------------------------------------------------------------------------
# 5. Observational AST Purity Verification
# ---------------------------------------------------------------------------------------
$forbidden = @(
    'Update-WuuOperationState', 'Set-WuuSetting', 'Start-Job', 'Start-RSJob',
    'Invoke-Command', 'Enter-PSSession', 'Stop-Process', 'Restart-Computer'
)
$consoleAst = [System.Management.Automation.Language.Parser]::ParseInput(
    (Get-Content (Join-Path $root 'src\Wuu.Console.psm1') -Raw), [ref]$null, [ref]$null
)

foreach ($fnName in @('Get-WuuStatusToken', 'Format-WuuTable', 'Write-WuuStatusTable')) {
    $fnAst = @($consoleAst.FindAll({
        param($x) ($x -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($x.Name -ceq $fnName)
    }, $true))
    if (-not $fnAst.Count) {
        Fail "could not find AST for function $fnName"
        continue
    }
    $called = @($fnAst[0].FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
    $present = @($forbidden | Where-Object { $called -contains $_ })
    if ($present.Count) {
        Fail "$fnName invokes forbidden command: $($present -join ', ')"
    } else {
        Pass "$fnName invokes no forbidden mutating commands (checked on AST)"
    }
}

# ---------------------------------------------------------------------------------------
# Final Verdict
# ---------------------------------------------------------------------------------------
if ($script:fail) {
    Write-Host "`nTest-Observability: FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nTest-Observability: ALL ASSERTIONS PASSED" -ForegroundColor Green
    exit 0
}
