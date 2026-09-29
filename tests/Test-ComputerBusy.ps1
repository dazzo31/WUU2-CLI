# Test: the per-computer operation gate (hardening brief SS3).
#
# WHY THIS SUITE EXISTS
# ---------------------
# Submitting a second pipeline to a runspace that is already running one is SILENTLY DISCARDED.
# Measured on this platform:
#
#     $ComputerItem.Runspace is busy
#     $ps = [powershell]::Create(); $ps.Runspace = $rs
#     $h  = $ps.BeginInvoke()        # ACCEPTED - returns a handle
#     $h.AsyncWaitHandle.WaitOne()   # completes normally
#     $ps.EndInvoke($h)              # THROWS: "The pipeline was not run because a pipeline is
#                                    #          already running. Pipelines cannot be run concurrently."
#     $ps.InvocationStateInfo.State  # 'Failed'
#     $ps.Streams.Error              # EMPTY - no error until EndInvoke is called
#
# So a second operation on a busy computer is not merely delayed: the work never happens, the
# submission reports success, and the only trace is a log line from the job-cleanup loop - the row
# itself keeps saying whatever it said before. Test-WuuComputerBusy is the gate that prevents it.
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-ComputerBusy.ps1
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$failures = @()
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -eq "$Expected") { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host ("FAIL: {0} - expected '{1}', got '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red; $script:failures += $Name }
}

Import-Module (Join-Path $root 'src\Wuu.State.psm1') -Force -ErrorAction Stop

# --- 1. The row contract carries the operation state -----------------------------------------
$row = New-WuuComputerRow -Computer 'SRV01'
Assert-Equal ($null -ne $row.PSObject.Properties['OpState']) $true 'row contract has OpState'
Assert-Equal $row.OpState 'Idle' 'a new row is Idle'
Assert-Equal ($null -ne $row.PSObject.Properties['OpStartedAt']) $true 'row contract has OpStartedAt'

# --- 2. Gate truth table ----------------------------------------------------------------------
# Idle + nothing queued -> free.
$row.OpState = 'Idle'; $row.Pending = $false
Assert-Equal (Test-WuuComputerBusy -Row $row) $false 'Idle row (no queued follow-up) is free'

# Running -> busy. This is the case that was silently discarding work.
$row.OpState = 'Running'
Assert-Equal (Test-WuuComputerBusy -Row $row) $true 'Running row is busy'

# Queued -> busy (an operation is already committed to this runspace).
$row.OpState = 'Queued'
Assert-Equal (Test-WuuComputerBusy -Row $row) $true 'Queued row is busy'

# A queued FOLLOW-UP (the auto-download/auto-install chain) must also block a direct submission.
# Without this, a direct op wins the runspace and the queued chain is the one discarded.
$row.OpState = 'Idle'; $row.Pending = $true
Assert-Equal (Test-WuuComputerBusy -Row $row) $true 'row with a queued follow-up (Pending) is busy'
# ...but the SCHEDULER must not treat Pending as busy, because its input queue IS the Pending rows.
# Without -IgnorePending it would skip every row it was handed and nothing would ever run.
Assert-Equal (Test-WuuComputerBusy -Row $row -IgnorePending) $false 'scheduler view ignores Pending (else it skips everything)'
# The scheduler must still refuse a row that genuinely has an op in flight.
$row.OpState = 'Running'
Assert-Equal (Test-WuuComputerBusy -Row $row -IgnorePending) $true 'scheduler view still refuses a Running row'
$row.Pending = $false

# Unknown/absent state must not crash and must not read as busy (fail-open on the GATE, because the
# gate only prevents submission; refusing everything would wedge the tool if a field went missing).
$row.OpState = ''
Assert-Equal (Test-WuuComputerBusy -Row $row) $false 'empty OpState does not read as busy'
$row.OpState = 'Idle'

# A row object from an older contract (no OpState property at all) must not throw.
$legacy = [pscustomobject]@{ Computer = 'OLD01'; Pending = $false }
$legacyBusy = $null
try { $legacyBusy = Test-WuuComputerBusy -Row $legacy } catch { $legacyBusy = "threw: $($_.Exception.Message)" }
Assert-Equal $legacyBusy $false 'a row without OpState is handled (no throw, not busy)'

# $null row (a lookup miss) must not throw either - the gate is called from loops.
$nullBusy = $null
try { $nullBusy = Test-WuuComputerBusy -Row $null } catch { $nullBusy = "threw" }
Assert-Equal $nullBusy $false '$null row is handled (no throw, not busy)'

# --- 3. The gate must be READ-ONLY ------------------------------------------------------------
# It is called from the scheduler, every console handler and tests, so mutating would be a
# side effect in a predicate.
$row.OpState = 'Running'; $row.Pending = $false
$null = Test-WuuComputerBusy -Row $row
Assert-Equal $row.OpState 'Running' 'the gate does not mutate OpState'
Assert-Equal $row.Pending $false 'the gate does not mutate Pending'

# --- 4. The measured platform behaviour the gate exists to avoid ------------------------------
# Asserted here rather than only documented, because if this changed the gate's necessity (and its
# comment) would be wrong - and a future reader would rightly delete it.
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$rs = [runspacefactory]::CreateRunspace($iss)
$rs.Open()
try {
    $psA = [powershell]::Create(); $psA.Runspace = $rs
    [void]$psA.AddScript({ Start-Sleep -Seconds 2; 'A' })
    $hA = $psA.BeginInvoke()
    Start-Sleep -Milliseconds 300

    $psB = [powershell]::Create(); $psB.Runspace = $rs
    [void]$psB.AddScript({ 'B-RAN' })
    $hB = $psB.BeginInvoke()

    $hA.AsyncWaitHandle.WaitOne(15000) | Out-Null
    $hB.AsyncWaitHandle.WaitOne(15000) | Out-Null

    # The handle completing is NOT evidence the work ran - that is the whole point.
    Assert-Equal $hB.IsCompleted $true 'a discarded pipeline still reports its handle complete (this is why a gate is needed)'
    Assert-Equal $psB.InvocationStateInfo.State 'Failed' 'the discarded pipeline ends in InvocationState Failed'

    $threw = $false
    try { $null = $psB.EndInvoke($hB) } catch { $threw = $true }
    Assert-Equal $threw $true 'EndInvoke throws for the discarded pipeline (no error is visible before it)'
} finally {
    try { $psA.Dispose() } catch { }
    try { $psB.Dispose() } catch { }
    try { $rs.Close() } catch { }
    try { $rs.Dispose() } catch { }
}

Write-Host ''
if ($failures.Count) {
    Write-Host ("SOME CHECKS FAILED ({0}): {1}" -f $failures.Count, ($failures -join '; ')) -ForegroundColor Red
    exit 1
}
Write-Host 'ALL PASS' -ForegroundColor Cyan
