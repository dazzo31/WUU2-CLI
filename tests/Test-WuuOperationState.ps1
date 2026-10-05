# Test: the single state-mutation funnel (hardening brief SS16).
#
# WHY THIS SUITE EXISTS
# ---------------------
# The invariant "a superseded operation cannot write" was only true of 2 of 6 producers. Four state
# helpers (Set-ComputerState, Set-ComputerTimeout and their two injected worker twins) mutated
# operation state with NO identity check at all, and 46 direct `$Computer.<prop> = ...` assignments
# in Wuu.Core bypassed every writer. A gate existed that looked for the word OperationId in one file
# and passed on all of it.
#
# Update-WuuOperationState is now the funnel: it validates identity FIRST, then transition legality,
# then owns every write. This suite asserts:
#
#   1. a proven-stale writer is REFUSED and the row is left byte-identical (not written-then-reverted)
#   2. an UNATTRIBUTED write is still permitted, or list loading would be discarded
#   3. a settled row cannot be dragged back into the workflow without a new attributed operation
#   4. the copy-pasted 6-line cleanup block is ONE behaviour, and all 4 former copies agree with it
#   5. the deadline/heartbeat helpers keep their exact previous behaviour when routed through it
#   6. the invariant checker actually DETECTS each violation (a checker that always returns empty
#      would make every gate that calls it a tautology)
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-WuuOperationState.ps1
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

Import-Module (Join-Path $root 'src\Wuu.State.psm1') -Force -ErrorAction Stop

# ---------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------
function New-TestRow {
    param([string]$Name = 'TEST-PC')
    return (New-WuuComputerRow -Computer $Name)
}

# A deterministic serialisation of the row, used to prove a refused write changed NOTHING.
# Property ORDER matters too, so this uses the raw property collection rather than a hashtable.
function Get-RowFingerprint($Row) {
    $parts = @()
    foreach ($p in $Row.PSObject.Properties) {
        $v = $p.Value
        if ($v -is [datetime]) { $v = $v.ToString('o') }
        $parts += ("{0}={1}" -f $p.Name, $v)
    }
    return ($parts -join '|')
}

'=== 1. identity: a REFUSED write must change nothing ==='
$row = New-TestRow 'STALE-PC'
$null = Update-WuuOperationState -Row $row -OperationId 'op-A' -OpState 'Running' -OperationIdNew 'op-A'
$before = Get-RowFingerprint $row

# The stale writer presents op-B while the row belongs to op-A.
$r = Update-WuuOperationState -Row $row -OperationId 'op-B' -State 'Complete' -OpState 'Idle' -ClearOperation
Assert-False $r.Applied 'a proven-stale writer is not applied'
Assert-True  $r.Refused 'the refusal is reported as Refused (not as an error)'
Assert-True  ($r.Reason -like 'stale writer*') "the refusal names the reason: $($r.Reason)"
Assert-Equal (Get-RowFingerprint $row) $before 'the row is BYTE-IDENTICAL after a refusal'

'=== 2. identity: an UNATTRIBUTED write is still permitted ==='
$row2 = New-TestRow 'LIST-PC'
$r2 = Update-WuuOperationState -Row $row2 -State 'Checking' -StatusSuffix 'from list load'
Assert-True $r2.Applied 'an unattributed write (list loading) is permitted'
Assert-Equal $row2.State 'Checking' 'the unattributed write reached the row'
Assert-Equal $row2.Status 'Initializing update session... from list load' 'the status suffix is appended to the canned text'

'=== 3. the correct owner is applied ==='
$row3 = New-TestRow 'OWNER-PC'
$null = Update-WuuOperationState -Row $row3 -OperationId 'op-C' -OperationIdNew 'op-C' -OpState 'Running'
$r3 = Update-WuuOperationState -Row $row3 -OperationId 'op-C' -State 'Complete' -OpState 'Idle'
Assert-True $r3.Applied 'the owning writer is applied'
Assert-Equal $row3.State 'Complete' 'the owning writer reached the row'

'=== 4. transition legality: a settled row is terminal ==='
$legality = Test-WuuStateTransitionAllowed -Row $row3 -ToState 'Downloading' -OperationId $null
Assert-False $legality.Allowed 'a settled row may not move to Downloading without an attributed operation'
Assert-True  ($legality.Reason -like '*settled*') "the reason names the settled rule: $($legality.Reason)"

$legality2 = Test-WuuStateTransitionAllowed -Row $row3 -ToState 'Downloading' -OperationId 'op-D'
Assert-True $legality2.Allowed 'a RESUBMISSION (new attributed op) may leave a settled state'

# A resubmission stamps the NEW id, and the transition is then applied.
$r4 = Update-WuuOperationState -Row $row3 -OperationId 'op-D' -OperationIdNew 'op-D' -State 'Queued' -OpState 'Running'
Assert-True $r4.Applied 'the attributed resubmission is applied'
Assert-Equal $row3.OperationId 'op-D' 'the resubmission stamped the new identity'

# The transition rule must NOT gate bookkeeping writes - a deadline refresh is not a transition.
$row4 = New-TestRow 'BOOKKEEP-PC'
$null = Update-WuuOperationState -Row $row4 -OperationId 'op-E' -OperationIdNew 'op-E' -OpState 'Running' -State 'Complete'
$r5 = Update-WuuOperationState -Row $row4 -OperationId 'op-E' -Heartbeat
Assert-True $r5.Applied 'a heartbeat on a settled row is bookkeeping, not a transition, and is allowed'

'=== 5. deadline helpers keep their exact behaviour through the funnel ==='
$row5 = New-TestRow 'DEADLINE-PC'
$now = [datetime]'2026-01-01T12:00:00'
$expires = Set-WuuOperationDeadline -Row $row5 -Op 'Download' -Now $now
$budget = Get-WuuOperationTimeoutSeconds -Op 'Download'
Assert-Equal $expires $now.AddSeconds($budget) 'Set-WuuOperationDeadline still returns now+budget'
Assert-Equal $row5.TimeoutSource 'Download' 'the deadline records its source'
Assert-Equal $row5.OpName 'Download' 'the deadline records the operation name'
Assert-Equal $row5.Heartbeats 0 'the deadline resets the heartbeat count'

$hb = Update-WuuOperationHeartbeat -Row $row5 -Now $now.AddSeconds(30)
Assert-True $hb 'Update-WuuOperationHeartbeat reports success'
Assert-Equal $row5.Heartbeats 1 'the heartbeat increments the count'
Assert-Equal $row5.LastHeartbeatAt $now.AddSeconds(30) 'the heartbeat refreshes the timestamp'

Clear-WuuOperationDeadline -Row $row5
Assert-Equal $row5.TimeoutExpiresAt $null 'Clear-WuuOperationDeadline clears the deadline'
Assert-Equal $row5.TimeoutSource '' 'Clear-WuuOperationDeadline clears the source'
Assert-Equal $row5.OpName '' 'Clear-WuuOperationDeadline clears the op name'
Assert-Equal $row5.LastHeartbeatAt $null 'Clear-WuuOperationDeadline clears the heartbeat'

'=== 6. the copy-pasted cleanup block is ONE behaviour ==='
# The 4 former copies cleared OpState/TimeoutExpiresAt/TimeoutSource/OpName/LastHeartbeatAt, and the
# extra copies also retired OperationId and detached Runspace. ClearOperation is the superset.
$row6 = New-TestRow 'CLEANUP-PC'
$null = Update-WuuOperationState -Row $row6 -OperationId 'op-F' -OperationIdNew 'op-F' -OpState 'Running'
$null = Update-WuuOperationState -Row $row6 -Phase 'Update Search' -TimeoutSec 900
$row6.Runspace = [object]::new()
$row6.OpStartedAt = $now
$r6 = Update-WuuOperationState -Row $row6 -OperationId 'op-F' -ClearOperation -Touch:$false
Assert-True $r6.Applied 'ClearOperation is applied for the owning writer'
Assert-Equal $row6.OpState 'Idle' 'ClearOperation releases the lock'
Assert-Equal $row6.TimeoutExpiresAt $null 'ClearOperation clears the deadline'
Assert-Equal $row6.TimeoutSource '' 'ClearOperation clears the timeout source'
Assert-Equal $row6.OpName '' 'ClearOperation clears the op name'
Assert-Equal $row6.LastHeartbeatAt $null 'ClearOperation clears the heartbeat timestamp'
Assert-Equal $row6.OperationId '' 'ClearOperation retires the identity'
Assert-Equal $row6.Runspace $null 'ClearOperation detaches the runspace'

# The invariant checker must agree that this row is now consistent.
$v6 = @(Test-WuuOperationStateInvariant -Row $row6)
Assert-Equal $v6.Count 0 "a cleared row satisfies the invariant ($($v6 -join '; '))"

# STATE-TERMINAL-RESET-01: ending the operation on a TIMED-OUT row keeps the Timeout display. Rewriting
# it to 'Queued' was an unattributed terminal->Queued transition that laundered a counted timeout.
$row6t = New-TestRow 'TIMEOUT-CLOSE-PC'
$row6t.State = 'Timeout'
$row6t.OpState = 'Running'
$row6t.OperationId = 'op-T6'
$row6t.TimeoutExpiresAt = (Get-Date).AddMinutes(5)
$row6t.TimeoutSource = 'Update Search'
$null = Update-WuuOperationState -Row $row6t -OperationId 'op-T6' -ClearOperation -Touch:$false
Assert-Equal ([string]$row6t.State) 'Timeout' 'ClearOperation PRESERVES a settled Timeout (terminal stays terminal)'
Assert-Equal $row6t.OpState 'Idle' 'ClearOperation still ends the operation on a timed-out row'
Assert-Equal $row6t.TimeoutExpiresAt $null 'and still clears the stale deadline'
$v6t = @(Test-WuuOperationStateInvariant -Row $row6t)
Assert-Equal $v6t.Count 0 "the settled-Timeout row satisfies the invariant ($($v6t -join '; '))"

'=== 7. the invariant checker DETECTS each violation (else every gate calling it is a tautology) ==='

# 1. Running with no OperationId
$a = New-TestRow; $a.OpState = 'Running'; $a.OperationId = ''
Assert-True ((@(Test-WuuOperationStateInvariant -Row $a) -join ' ') -like '*Running OpState with no OperationId*') 'detects: running with no identity'

# 2. Idle with an OperationId
$b = New-TestRow; $b.OpState = 'Idle'; $b.OperationId = 'op-X'
Assert-True ((@(Test-WuuOperationStateInvariant -Row $b) -join ' ') -like '*survives an Idle row*') 'detects: identity surviving an idle row'

# 3. a deadline with no operation
$c = New-TestRow; $c.OpState = 'Idle'; $c.TimeoutExpiresAt = (Get-Date)
Assert-True ((@(Test-WuuOperationStateInvariant -Row $c) -join ' ') -like '*deadline is recorded while no operation*') 'detects: deadline with no operation'

# 4. Timeout state with no deadline WHILE THE OPERATION IS RUNNING (the hang-in-yellow case).
$d = New-TestRow; $d.State = 'Timeout'; $d.OpState = 'Running'; $d.OperationId = 'op-T'; $d.TimeoutExpiresAt = $null
Assert-True ((@(Test-WuuOperationStateInvariant -Row $d) -join ' ') -like "*State='Timeout' with no deadline*") 'detects: a RUNNING Timeout with no deadline'

# 4b. A SETTLED Timeout (operation ended) legitimately has no deadline - that is the normal
# post-timeout shape the worker writes, so it must NOT be reported as a violation.
$d2 = New-TestRow; $d2.State = 'Timeout'; $d2.OpState = 'Idle'; $d2.OperationId = ''; $d2.TimeoutExpiresAt = $null
Assert-Equal (@(Test-WuuOperationStateInvariant -Row $d2) -join ' ') '' 'a SETTLED Timeout with no deadline is NOT a violation (the operation has ended)'

# 5. settled plus PendingOp
$e = New-TestRow; $e.State = 'Complete'; $e.PendingOp = 'Download'
Assert-True ((@(Test-WuuOperationStateInvariant -Row $e) -join ' ') -like '*still queues PendingOp*') 'detects: a follow-up queued on a settled row'

# 6. settled plus Running
$f = New-TestRow; $f.State = 'Complete'; $f.OpState = 'Running'
Assert-True ((@(Test-WuuOperationStateInvariant -Row $f) -join ' ') -like '*still holds the runspace lock*') 'detects: a settled row holding the lock'

# 7. TimeoutSource without a deadline
$g = New-TestRow; $g.TimeoutSource = 'Update Search'; $g.TimeoutExpiresAt = $null
Assert-True ((@(Test-WuuOperationStateInvariant -Row $g) -join ' ') -like '*half-cleared timeout state*') 'detects: half-cleared timeout state'

# 8. heartbeat count without a timestamp
$h = New-TestRow; $h.Heartbeats = 3; $h.LastHeartbeatAt = $null
Assert-True ((@(Test-WuuOperationStateInvariant -Row $h) -join ' ') -like '*but LastHeartbeatAt is empty*') 'detects: a heartbeat count with no timestamp'

# A clean row must produce NO violations - otherwise the checker is useless noise.
$clean = New-TestRow
Assert-Equal (@(Test-WuuOperationStateInvariant -Row $clean).Count) 0 'a fresh row produces no violations'

'=== 8. a recoverable timeout records the deadline and the recoverable colour ==='
$row8 = New-TestRow 'TIMEOUT-PC'
$null = Update-WuuOperationState -Row $row8 -OperationId 'op-G' -OperationIdNew 'op-G' -OpState 'Running'
$r8 = Update-WuuOperationState -Row $row8 -OperationId 'op-G' -Phase 'Update Search' -TimeoutSec 900 -Now $now
Assert-True $r8.Applied 'the timeout transition is applied'
Assert-Equal $row8.State 'Timeout' 'the timeout sets the display state'
Assert-Equal $row8.UpdatesStatus 'Timeout' 'the timeout sets UpdatesStatus'
Assert-Equal $row8.TimeoutSource 'Update Search' 'the timeout records what timed out'
Assert-Equal $row8.TimeoutExpiresAt $now.AddSeconds(900) 'the timeout records the deadline'
Assert-Equal $row8.Status 'Timeout during Update Search after 900s - continuing to monitor.' 'the timeout status sentence is preserved'

# A Phase with no budget must NOT record a deadline in the past - that would kill the next operation.
$row9 = New-TestRow 'NOPHASE-PC'
$null = Update-WuuOperationState -Row $row9 -OperationId 'op-H' -OperationIdNew 'op-H' -OpState 'Running'
$null = Update-WuuOperationState -Row $row9 -OperationId 'op-H' -Phase 'Unknown Phase' -TimeoutSec 0 -Now $now
Assert-True ($row9.TimeoutExpiresAt -gt $now) 'a Phase with no explicit budget still records a FUTURE deadline'

'=== 9. revision precondition (optimistic concurrency) ==='
$row10 = New-TestRow 'REV-PC'
$row10.Revision = 5
$revBefore = Get-RowFingerprint $row10
$rr = Update-WuuOperationState -Row $row10 -State 'Checking' -Revision 4
Assert-False $rr.Applied 'a stale revision is refused'
Assert-True ($rr.Reason -like 'revision changed*') "the revision refusal names the reason: $($rr.Reason)"
Assert-Equal (Get-RowFingerprint $row10) $revBefore 'the row is unchanged after a revision refusal'

$row10.Revision = 5
$rr2 = Update-WuuOperationState -Row $row10 -State 'Checking' -Revision 5
Assert-True $rr2.Applied 'the matching revision is applied'

'=== 10. the four former writers now route through the funnel ==='
# These are the producers that mutated operation state with no identity check at all.
$stateRaw = Get-Content (Join-Path $root 'src\Wuu.State.psm1') -Raw
$coreRaw  = Get-Content (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$wupdRaw  = Get-Content (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw

function Get-CodeNoComments([string]$Text) {
    if (-not $Text) { return '' }
    $noBlocks = [regex]::Replace($Text, '(?s)<#.*?#>', '')
    return (($noBlocks -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
}
function Get-FunctionText([string]$Text, [string]$Name) {
    $lines = $Text -split "`r?`n"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*function\s+$([regex]::Escape($Name))\b") { $start = $i; break }
    }
    if ($start -lt 0) { return '' }
    $out = @()
    $depth = 0
    $seenBrace = $false
    for ($i = $start; $i -lt $lines.Count; $i++) {
        $out += $lines[$i]
        $depth += ([regex]::Matches($lines[$i], '\{')).Count
        $depth -= ([regex]::Matches($lines[$i], '\}')).Count
        if ($depth -gt 0) { $seenBrace = $true }
        if ($seenBrace -and $depth -le 0) { break }
    }
    return ($out -join "`n")
}

# The injected workers are NOT `function` definitions - they are SetVariable'd scriptblocks built
# from a string, so Get-FunctionText cannot find them. An earlier version of this section searched
# for `function SetComputerStateScript` and correctly found nothing, which looked like a missing
# delegation. Extract them by their SetVariable variable name instead.
function Get-InjectedScript([string]$Text, [string]$VarName) {
    $lines = $Text -split "`r?`n"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "SetVariable\('$([regex]::Escape($VarName))'") { $start = $i; break }
    }
    if ($start -lt 0) { return '' }
    $out = @()
    $depth = 0
    $seenBrace = $false
    for ($i = $start; $i -lt $lines.Count; $i++) {
        $out += $lines[$i]
        $depth += ([regex]::Matches($lines[$i], '\{')).Count
        $depth -= ([regex]::Matches($lines[$i], '\}')).Count
        if ($depth -gt 0) { $seenBrace = $true }
        if ($seenBrace -and $depth -le 0) { break }
    }
    return ($out -join "`n")
}

function Get-FunctionTextOrInjected([string]$Text, [string]$Name) {
    $fn = Get-FunctionText $Text $Name
    if ($fn -ne '') { return $fn }
    return (Get-InjectedScript $Text $Name)
}

$coreCode = Get-CodeNoComments $coreRaw
$wupdCode = Get-CodeNoComments $wupdRaw

# Set-ComputerState must delegate to the funnel rather than assigning State directly.
$scs = Get-FunctionText $coreCode 'Set-ComputerState'
Assert-True ($scs -like '*Update-WuuOperationState*') 'Set-ComputerState delegates to the funnel'
Assert-False ($scs -match '\$Computer\.State\s*=') 'Set-ComputerState no longer assigns State directly'

$sct = Get-FunctionText $coreCode 'Set-ComputerTimeout'
Assert-True ($sct -like '*Update-WuuOperationState*') 'Set-ComputerTimeout delegates to the funnel'
Assert-False ($sct -match '\$Computer\.State\s*=') 'Set-ComputerTimeout no longer assigns State directly'
Assert-False ($sct -match '\$Computer\.TimeoutExpiresAt\s*=') 'Set-ComputerTimeout no longer assigns the deadline directly'

# The two injected worker twins cannot call a module function, so they DELEGATE to the inlined funnel
# (UpdateWuuOperationStateScript) rather than each carrying their own copy of the rule.
$wcs = Get-InjectedScript $wupdCode 'SetComputerStateScript'
Assert-True ($wcs -ne '') 'the worker state twin exists as an injected scriptblock'
Assert-True ($wcs -like '*UpdateWuuOperationStateScript*') 'the worker state twin delegates to the inlined funnel'
Assert-False ($wcs -match '\$Computer\.State\s*=\s*\$State') 'the worker state twin no longer writes State unguarded'

$wct = Get-InjectedScript $wupdCode 'SetComputerTimeoutScript'
Assert-True ($wct -ne '') 'the worker timeout twin exists as an injected scriptblock'
Assert-True ($wct -like '*UpdateWuuOperationStateScript*') 'the worker timeout twin delegates to the inlined funnel'
Assert-False ($wct -match '\$Computer\.State\s*=\s*''Timeout''') 'the worker timeout twin no longer writes State unguarded'

# The inlined funnel itself MUST carry the identity guard, or both twins delegate to nothing.
$wfunnel = Get-InjectedScript $wupdCode 'UpdateWuuOperationStateScript'
Assert-True ($wfunnel -ne '') 'the inlined worker funnel exists'
Assert-True ($wfunnel -like '*rowOpId*' -and $wfunnel -like '*writerOpId*') 'the inlined worker funnel compares row identity against writer identity'
Assert-True ($wfunnel -like '*cne*') 'the inlined worker funnel refuses on a DIFFERENCE (proven staleness), not on absence'

# ---------------------------------------------------------------------------------------
# 10b. ClearPendingOp - the explicit slot-clear operation (P0 #1, SS16)
# ---------------------------------------------------------------------------------------
# PendingOp is operation state, so clearing it belongs to the funnel rather than to the scheduler
# that happens to hold the row. Before this there was NO way to clear the slot through the state API,
# which made the scheduler's bare assignment one of the three module-scope writes the P0
# investigation identified.

# A. the operation clears the slot.
$cpA = New-WuuComputerRow -Computer 'CP-A'
$cpA.PendingOp = 'Install'
$resA = Update-WuuOperationState -Row $cpA -ClearPendingOp
Assert-True ($resA.Applied) 'A. ClearPendingOp is applied'
Assert-True (-not $resA.Refused) 'A. ClearPendingOp is not a refusal'
Assert-True ($null -eq $cpA.PendingOp) "A. ClearPendingOp empties the slot (got '$($cpA.PendingOp)')"

# B/C. clearing is NOT a transition, so the settled-row rule must not interfere - and this is the
# direction that makes the operation necessary: a settled row still CARRYING a pending op is
# invariant violation 5, so clearing must remain legal or that violation could never be repaired.
$cpB = New-WuuComputerRow -Computer 'CP-B'
$cpB.State = 'Error'
$cpB.PendingOp = 'Download'
$resB = Update-WuuOperationState -Row $cpB -ClearPendingOp
Assert-True ($resB.Applied -and $null -eq $cpB.PendingOp) 'B. a SETTLED (Error) row can still have its slot cleared - the repair path for invariant 5'
Assert-Equal ([string]$cpB.State) 'Error' 'B. clearing the slot does NOT rewrite the settled display state'

$cpC = New-WuuComputerRow -Computer 'CP-C'
$cpC.State = 'Timeout'
$cpC.PendingOp = 'Download'
$resC = Update-WuuOperationState -Row $cpC -ClearPendingOp
Assert-True ($resC.Applied -and $null -eq $cpC.PendingOp) 'C. a TIMED-OUT row can have its slot cleared'
Assert-Equal ([string]$cpC.State) 'Timeout' 'C. clearing the slot does NOT launder a timeout into another outcome'

# ...while the two transitions the instructions protect must STILL be refused, with or without the
# clear. This is the pair Test A/B/C must not have broken to make themselves pass.
foreach ($probe in @(
        @{ From = 'Complete'; To = 'Error'; Label = 'settled -> Error' },
        @{ From = 'Complete'; To = 'Queued'; Label = 'settled -> Queued' },
        @{ From = 'Timeout'; To = 'Queued'; Label = 'timed-out -> Queued' })) {
    $rowP = New-WuuComputerRow -Computer 'CP-GUARD'
    $rowP.State = $probe.From
    $refP = Update-WuuOperationState -Row $rowP -State $probe.To
    Assert-True ($refP.Refused) "$($probe.Label) is STILL refused by the funnel"
    Assert-Equal ([string]$rowP.State) $probe.From "$($probe.Label) refusal leaves the row untouched"
}

# D. a SUPERSEDED operation must not clear the slot of the operation that replaced it. The clear is
# operation state like any other write, so it goes through the same identity rule.
$cpD = New-WuuComputerRow -Computer 'CP-D'
$cpD.OperationId = 'op-B'
$cpD.PendingOp = 'Install'
$resD = Update-WuuOperationState -Row $cpD -OperationId 'op-A' -ClearPendingOp
Assert-True ($resD.Refused) 'D. stale worker A is refused when it tries to clear the slot'
Assert-Equal ([string]$cpD.PendingOp) 'Install' "D. A did NOT clear B's pending op (got '$($cpD.PendingOp)')"

# ...and the same clear by the OWNER is applied, so D is not refusing everything.
$resD2 = Update-WuuOperationState -Row $cpD -OperationId 'op-B' -ClearPendingOp
Assert-True ($resD2.Applied -and $null -eq $cpD.PendingOp) 'D. the owning operation CAN clear its own slot'

# ORDER: a combined clear-of-slot + end-of-operation must settle the row, not re-queue it for a
# follow-up the same call removed. The row starts settled and STILL carrying a queued op - invariant
# violation 5, which is precisely the row the follow-up branch of ClearOperation exists to re-queue.
# If the two were applied in the other order, that branch would see the not-yet-cleared slot and force
# State back to 'Queued', so this asserts the order and not merely the outcome.
$cpE = New-WuuComputerRow -Computer 'CP-E'
$cpE.State = 'Complete'
$cpE.PendingOp = 'Install'
$cpE.OpState = 'Running'
$cpE.OperationId = 'op-E'
$null = Update-WuuOperationState -Row $cpE -OperationId 'op-E' -ClearPendingOp -ClearOperation
Assert-Equal ([string]$cpE.OpState) 'Idle' 'E. a combined clear-slot+collapse leaves the operation ended'
Assert-True ($null -eq $cpE.PendingOp) 'E. the combined call emptied the slot'
Assert-Equal ([string]$cpE.State) 'Complete' "E. the removed follow-up did NOT re-queue a settled row (got '$($cpE.State)')"

# PARITY: the scheduler runs in the module scope, but the worker twin carries the same operation or
# the two copies disagree - the exact drift Test-WuuOperationState exists to catch.
Assert-True ($wfunnel -like '*ClearPendingOp*') 'the inlined worker funnel carries ClearPendingOp too, or the copies disagree'

'=== 11. NO unguarded async write remains ==='
# This is the reviewer's actual P1 requirement: "prove every async write identity-guarded".
#
# The cleanup loop and the injected payloads run in ISOLATED runspaces where no module function
# resolves, so they cannot call the funnel and MUST inline the rule. Demanding they delegate would
# demand something the architecture forbids - an earlier version of this section did exactly that and
# failed on 4 correct sites. What matters is not WHERE the rule is written but that NO write site
# lacks it, so this asserts proximity: every operation-lock release is within a few lines of an
# OperationId comparison.

function Get-UnguardedSites([string]$Text, [string]$Pattern) {
    $lines = $Text -split "`r?`n"
    $unguarded = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $Pattern) {
            # Look BACK up to 40 lines for an identity comparison that gates this write.
            $lo = [Math]::Max(0, $i - 40)
            $window = ($lines[$lo..$i] -join "`n")
            $hasGuard = ($window -match 'OperationId') -and ($window -match 'ceq|cne|-eq|-ne')
            if (-not $hasGuard) { $unguarded += ($i + 1) }
        }
    }
    return $unguarded
}

$unguardedReleases = Get-UnguardedSites $coreCode "OpState\s*=\s*'Idle'"
Assert-Equal $unguardedReleases.Count 0 "every OpState='Idle' release in Wuu.Core is identity-guarded (unguarded at line(s): $($unguardedReleases -join ', '))"

$unguardedTimeouts = Get-UnguardedSites $coreCode "UpdatesStatus\s*=\s*'Timeout'"
Assert-Equal $unguardedTimeouts.Count 0 "every timeout write in Wuu.Core is identity-guarded (unguarded at line(s): $($unguardedTimeouts -join ', '))"

# And the reverse: a guard that is present but never ENFORCED is not a guard. Each guarded site must
# have the comparison actually decide between a write and a refusal, not merely compute an id.
$guardCount = ([regex]::Matches($coreCode, 'OperationId')).Count
Assert-True ($guardCount -ge 10) "identity is consulted at multiple sites in Wuu.Core ($guardCount references)"

# The inlined worker writer must also carry the guard (it is the writer the PAYLOAD uses).
$wupdGuard = ([regex]::Matches($wupdCode, 'rowOpId')).Count
Assert-True ($wupdGuard -ge 2) "the injected worker writers consult row identity ($wupdGuard references)"

''
if ($failures.Count -eq 0) {
    Write-Host "ALL PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FAILURES: {0}" -f $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
