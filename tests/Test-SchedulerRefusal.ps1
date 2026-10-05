#Requires -Version 5.1
<#
.SYNOPSIS Regression test: scheduler refusal does not lose queued work (SCHED-REFUSAL-01).
.DESCRIPTION
Validates:
  1. When Start-UpdateCheckJob refuses (returns $false), Pending remains $true.
  2. When Start-UpdateCheckJob refuses, PendingOp is preserved and not cleared.
  3. When Start-UpdateCheckJob accepts (returns $true), Pending is cleared to $false and PendingOp is cleared.
  4. On subsequent retry after refusal, the preserved PendingOp is submitted to Start-UpdateCheckJob.
  5. Multi-item queue: accepted item is consumed, refused item stays pending with its operation intact.

Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-SchedulerRefusal.ps1
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
# Setup Scheduler Context & State Store
# ---------------------------------------------------------------------------------------
$stateStore = New-WuuStateStore
$jobs = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$bgProcessing = [hashtable]::Synchronized(@{ Suspended = $false })

$ctx = @{
    StateStore           = $stateStore
    Jobs                 = $jobs
    MaxConcurrentJobs    = 10
    BackgroundProcessing = $bgProcessing
}
Initialize-WuuSchedulerContext -Context $ctx

# Track submissions received by Start-UpdateCheckJob
$script:Submissions = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$script:ShouldAcceptSubmission = $false

# Mock Start-UpdateCheckJob in module/global scope
function global:Start-UpdateCheckJob {
    param($ComputerItem, [string]$Op = 'Check', [string]$ServiceAction = '', [switch]$IgnorePending)
    [void]$script:Submissions.Add(@{
        Computer      = $ComputerItem.Computer
        Op            = $Op
        IgnorePending = [bool]$IgnorePending
    })
    return $script:ShouldAcceptSubmission
}

# ---------------------------------------------------------------------------------------
# 1. Refusal Case: Submission returns $false (concurrency cap / reservation race)
# ---------------------------------------------------------------------------------------
$rowRefused = New-WuuComputerRow -Computer 'SRV-REFUSED-01' -Phase 'Phase 1'
$rowRefused.Pending = $true
$rowRefused.PendingOp = 'InstallAndRecheck'
$rowRefused.OpState = 'Idle'
Add-WuuComputerRow -Store $stateStore -Row $rowRefused | Out-Null

$script:Submissions.Clear()
$script:ShouldAcceptSubmission = $false

Start-PendingUpdateCheck -Context $ctx

Assert-Equal $script:Submissions.Count 1 'Start-UpdateCheckJob was called once for pending item'
Assert-Equal $script:Submissions[0].Op 'InstallAndRecheck' 'Start-UpdateCheckJob was called with requested PendingOp'
Assert-True $script:Submissions[0].IgnorePending 'Start-UpdateCheckJob was called with IgnorePending'
Assert-True $rowRefused.Pending 'row remains Pending=$true when submission is refused'
Assert-Equal $rowRefused.PendingOp 'InstallAndRecheck' 'PendingOp is preserved when submission is refused'

# ---------------------------------------------------------------------------------------
# 2. Subsequent Tick: Concurrency frees up, submission accepted ($true)
# ---------------------------------------------------------------------------------------
$script:Submissions.Clear()
$script:ShouldAcceptSubmission = $true

Start-PendingUpdateCheck -Context $ctx

Assert-Equal $script:Submissions.Count 1 'Start-UpdateCheckJob was called on retry'
Assert-Equal $script:Submissions[0].Op 'InstallAndRecheck' 'Retry submitted the preserved PendingOp'
Assert-True (-not $rowRefused.Pending) 'Pending is cleared ($false) after submission is accepted'
Assert-True ($null -eq $rowRefused.PendingOp) 'PendingOp is cleared ($null) after submission is accepted'

# ---------------------------------------------------------------------------------------
# 3. Default 'Check' Op Refusal and Acceptance
# ---------------------------------------------------------------------------------------
$rowCheck = New-WuuComputerRow -Computer 'SRV-CHECK-01' -Phase 'Phase 1'
$rowCheck.Pending = $true
$rowCheck.OpState = 'Idle'
Add-WuuComputerRow -Store $stateStore -Row $rowCheck | Out-Null

$script:Submissions.Clear()
$script:ShouldAcceptSubmission = $false

Start-PendingUpdateCheck -Context $ctx

Assert-Equal $script:Submissions.Count 1 'Start-UpdateCheckJob called for default check item'
Assert-Equal $script:Submissions[0].Op 'Check' 'default op is Check'
Assert-True $rowCheck.Pending 'default check item remains Pending=$true when refused'

$script:Submissions.Clear()
$script:ShouldAcceptSubmission = $true

Start-PendingUpdateCheck -Context $ctx

Assert-Equal $script:Submissions.Count 1 'Start-UpdateCheckJob called on retry for default check item'
Assert-True (-not $rowCheck.Pending) 'default check item Pending is cleared ($false) when accepted'

# ---------------------------------------------------------------------------------------
# 4. Multi-Item Queue: One Accepted, One Refused
# ---------------------------------------------------------------------------------------
$rowA = New-WuuComputerRow -Computer 'SRV-MULTI-A' -Phase 'Phase 1'
$rowA.Pending = $true
$rowA.PendingOp = 'Download'
$rowA.OpState = 'Idle'
Add-WuuComputerRow -Store $stateStore -Row $rowA | Out-Null

$rowB = New-WuuComputerRow -Computer 'SRV-MULTI-B' -Phase 'Phase 1'
$rowB.Pending = $true
$rowB.PendingOp = 'InstallAndRecheck'
$rowB.OpState = 'Idle'
Add-WuuComputerRow -Store $stateStore -Row $rowB | Out-Null

$script:Submissions.Clear()
# Mock selective admission: Accept rowA, refuse rowB
function global:Start-UpdateCheckJob {
    param($ComputerItem, [string]$Op = 'Check', [string]$ServiceAction = '', [switch]$IgnorePending)
    [void]$script:Submissions.Add(@{
        Computer      = $ComputerItem.Computer
        Op            = $Op
        IgnorePending = [bool]$IgnorePending
    })
    if ($ComputerItem.Computer -eq 'SRV-MULTI-A') { return $true }
    return $false
}

Start-PendingUpdateCheck -Context $ctx

Assert-True (-not $rowA.Pending) 'accepted item SRV-MULTI-A has Pending cleared ($false)'
Assert-True ($null -eq $rowA.PendingOp) 'accepted item SRV-MULTI-A has PendingOp cleared'
Assert-True $rowB.Pending 'refused item SRV-MULTI-B retains Pending ($true)'
Assert-Equal $rowB.PendingOp 'InstallAndRecheck' 'refused item SRV-MULTI-B retains PendingOp'

# ---------------------------------------------------------------------------------------
# Final Verdict
# ---------------------------------------------------------------------------------------
Write-Host ''
if ($fail) {
    Write-Host 'Test-SchedulerRefusal: SOME CHECKS FAILED' -ForegroundColor Red
    exit 1
}
Write-Host 'Test-SchedulerRefusal: ALL PASS' -ForegroundColor Cyan
exit 0
