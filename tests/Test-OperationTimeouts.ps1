#Requires -Version 5.1
<#
.SYNOPSIS
    SS5: operation-specific timeouts.

.DESCRIPTION
    The defect was a flat 10-minute stop for every operation. Four things are asserted:

      1. The budget table is per-op, complete, and every op Start-UpdateCheckJob can be given has an
         entry (an op with no entry silently inherits 'default', which is a real budget but not the
         intended one).
      2. The row contract carries the fields the decision needs (OpName, deadline, heartbeat). Adding
         OpName to the row is what makes a per-op budget possible at all: the cleanup loop holds only
         (Computer, Runspace, StartTime) and cannot otherwise know WHICH budget applies - which is
         exactly why the old code needed one number for everything.
      3. The decision function behaves correctly on: no row, no deadline (fallback), a deadline in the
         future, a deadline in the past, and a cleared deadline (which must NOT be treated as expired).
      4. THE RUNSPACE BLOCK AGREES WITH THE FUNCTION. The cleanup loop cannot call module functions, so
         the deadline logic exists twice. This test runs the block's own decision snippet, injected
         into a real runspace the way Wuu.Core injects it, against the same inputs as the function and
         compares the verdicts. Without this the two copies drift and the enforced budget silently
         stops matching the documented one.

    (4) is the point of the suite. A duplicate that is only checked by eye is not a duplicate that stays
    correct.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail++ }

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force -DisableNameChecking
Import-WuuModules -WuuRoot $root

$wupdRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw
$coreRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$stateRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw

# The budget table lives in Start-WuuApplication's config region (it is set when the application
# starts, not at import). Load the SHIPPED LITERAL out of the source so this suite tests the real
# table rather than a copy - and so the table's existence is asserted rather than assumed.
$coreAst = [System.Management.Automation.Language.Parser]::ParseInput($coreRaw, [ref]$null, [ref]$null)
$tableAssign = $coreAst.FindAll({
    param($n)
    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left.Extent.Text -eq '$global:OperationTimeoutSeconds'
}, $true)
$table = $null
if ($tableAssign.Count -gt 0) {
    try {
        $table = & ([scriptblock]::Create($tableAssign[0].Right.Extent.Text))
        $global:OperationTimeoutSeconds = $table
    } catch {
        Write-Host "  (could not evaluate the shipped table literal: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}
# The heartbeat interval is a plain number in the same region.
$hbMatch = [regex]::Match($coreRaw, '\$global:OperationHeartbeatSeconds\s*=\s*(\d+)')
if ($hbMatch.Success) { $global:OperationHeartbeatSeconds = [int]$hbMatch.Groups[1].Value }

# --- 1. the budget table -------------------------------------------------------------
$table = $global:OperationTimeoutSeconds
if ($table -and $table.Count -gt 0) {
    Ok "the per-op budget table exists ($($table.Count) entries)"
} else {
    Bad 'the per-op budget table is missing'
}
if ($table -and $table.ContainsKey('default')) {
    Ok 'the table has a default entry (an unknown op is bounded, not unlimited)'
} else {
    Bad 'the table has no default entry - an unrecognised op would be unbounded'
}

# Every op Start-UpdateCheckJob accepts must have its own budget, or it silently inherits the default.
$validate = [regex]::Match($wupdRaw, "ValidateSet\(([^)]*)\)\]\s*\r?\n\s*\[string\]\`$Op")
if ($validate.Success) {
    $ops = @($validate.Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim("'").Trim('"') })
    $missing = @($ops | Where-Object { $_ -and -not $table.ContainsKey($_) })
    if ($missing.Count -eq 0) {
        Ok "every op Start-UpdateCheckJob accepts has its own budget ($($ops -join ', '))"
    } else {
        Bad "ops with no budget entry (they silently inherit default): $($missing -join ', ')"
    }
} else {
    Bad 'could not read the op ValidateSet from Start-UpdateCheckJob'
}

# The whole point: reboot/install budgets must EXCEED the flat 10 minutes they replace, or the
# change is cosmetic. AutoFlow must also exceed its own reboot waits (600s offline + 1800s online).
foreach ($op in @('InstallAndRecheck', 'AutoFlow', 'Restart', 'Check')) {
    if ($table[$op] -gt 600) {
        Ok "$op budget ($($table[$op])s) exceeds the flat 10-minute stop it replaces"
    } else {
        Bad "$op budget ($($table[$op])s) is no better than the flat 10-minute stop"
    }
}
if ($table['AutoFlow'] -gt (600 + 1800)) {
    Ok "AutoFlow budget ($($table['AutoFlow'])s) exceeds its own reboot waits (600s + 1800s)"
} else {
    Bad "AutoFlow budget ($($table['AutoFlow'])s) is shorter than its own reboot waits"
}
if ($table['ServiceAction'] -lt 600) {
    Ok "ServiceAction budget ($($table['ServiceAction'])s) is short - a hung service control is stuck, not slow"
} else {
    Bad "ServiceAction budget ($($table['ServiceAction'])s) is too long to catch a hung service control"
}

# Get-WuuOperationTimeoutSeconds must never return 0 (every job would expire instantly).
$zeroBudget = $false
foreach ($k in $table.Keys) {
    if ((Get-WuuOperationTimeoutSeconds -Op $k) -le 0) { $zeroBudget = $true }
}
if (-not $zeroBudget) { Ok 'no budget resolves to <= 0 (a zero budget would expire every job instantly)' }
else { Bad 'some budget resolves to <= 0' }
if ((Get-WuuOperationTimeoutSeconds -Op 'no-such-op') -eq $table['default']) {
    Ok 'an unknown op falls back to the default budget, not to a literal'
} else {
    Bad 'an unknown op does not fall back to the default budget'
}

# --- 2. the row contract -------------------------------------------------------------
$row = New-WuuComputerRow -Computer 'SRV01'
foreach ($f in @('OpName', 'TimeoutExpiresAt', 'TimeoutSource', 'LastHeartbeatAt', 'Heartbeats')) {
    if ($row.PSObject.Properties[$f]) {
        Ok "the row contract carries $f"
    } else {
        Bad "the row contract is missing $f - the per-op decision could not work"
    }
}

# --- 3. the decision function --------------------------------------------------------
$now = Get-Date '2026-01-01T12:00:00'

# no row -> not expired, basis none
$v = Test-WuuOperationExpired -Row $null -Now $now
if (-not $v.Expired -and $v.Basis -eq 'none') { Ok 'a null row is never expired' } else { Bad "null row returned Expired=$($v.Expired) Basis=$($v.Basis)" }

# a deadline in the future -> not expired
$row = New-WuuComputerRow -Computer 'SRV01'
$null = Set-WuuOperationDeadline -Row $row -Op 'InstallAndRecheck' -Now $now
$v = Test-WuuOperationExpired -Row $row -Now $now.AddMinutes(5)
if (-not $v.Expired -and $v.Basis -eq 'row-deadline') { Ok 'a deadline in the future is not expired (basis=row-deadline)' }
else { Bad "future deadline reported Expired=$($v.Expired) Basis=$($v.Basis)" }
if ($v.Op -eq 'InstallAndRecheck') { Ok 'the verdict reports which op the deadline belongs to' } else { Bad "verdict Op='$($v.Op)'" }

# just past the deadline -> expired, with the overshoot reported
$v = Test-WuuOperationExpired -Row $row -Now $now.AddSeconds($table['InstallAndRecheck'] + 90)
if ($v.Expired -and $v.OvershootSeconds -ge 60) { Ok "a passed deadline is expired and reports the overshoot ($($v.OvershootSeconds)s)" }
else { Bad "passed deadline reported Expired=$($v.Expired) Overshoot=$($v.OvershootSeconds)" }

# cleared deadline -> NOT expired (this is the trap: a stale deadline would kill the next operation)
$null = Clear-WuuOperationDeadline -Row $row
$v = Test-WuuOperationExpired -Row $row -Now $now.AddHours(9)
if (-not $v.Expired -and $v.Basis -eq 'none') {
    Ok 'a cleared deadline is not expired (a finished row cannot kill the next operation)'
} else {
    Bad "a cleared deadline reported Expired=$($v.Expired) Basis=$($v.Basis)"
}
if (-not $row.TimeoutExpiresAt -and -not $row.OpName) { Ok 'Clear-WuuOperationDeadline blanks the deadline and op name' }
else { Bad "clear left TimeoutExpiresAt=$($row.TimeoutExpiresAt) OpName='$($row.OpName)'" }

# no deadline but a start time -> fallback basis, using the default budget
$row2 = New-WuuComputerRow -Computer 'SRV02'
$v = Test-WuuOperationExpired -Row $row2 -Now $now.AddMinutes(5) -StartedAt $now
if (-not $v.Expired -and $v.Basis -eq 'start-time-fallback') { Ok 'a row with no deadline falls back to start time (basis=start-time-fallback)' }
else { Bad "fallback returned Expired=$($v.Expired) Basis=$($v.Basis)" }
$v = Test-WuuOperationExpired -Row $row2 -Now $now.AddSeconds($table['default'] + 30) -StartedAt $now
if ($v.Expired) { Ok 'the start-time fallback still expires (it is bounded, unlike the old flat 10 min)' }
else { Bad 'the start-time fallback never expires' }
# ...and with neither basis there is nothing to enforce, so it must not be treated as expired.
$v = Test-WuuOperationExpired -Row $row2 -Now $now.AddHours(9)
if (-not $v.Expired -and $v.Basis -eq 'none') { Ok 'with neither deadline nor start time the verdict is Expired=$false Basis=none' }
else { Bad "no-basis row returned Expired=$($v.Expired) Basis=$($v.Basis)" }

# --- 4. the runspace block agrees with the function ----------------------------------
# Extract the decision snippet the cleanup loop uses, so BOTH copies can be driven on identical
# inputs. If this extraction stops matching, the test fails loudly rather than silently testing
# nothing - which is how a "differential" test becomes a tautology.
$startMarker = 'ElseIf ($runspace.StartTime) {'
$logMarker = 'Job timeout detected for'
$si = $coreRaw.IndexOf($startMarker)
$li = if ($si -ge 0) { $coreRaw.IndexOf($logMarker, $si) } else { -1 }
# The snippet must run to the point where the TIMEOUT ACTION begins, i.e. up to and including the
# '}' that closes the heartbeat 'if'. Cutting mid-statement produces an UNBALANCED snippet, and an
# unbalanced snippet throws before producing a verdict - which reported "block produced no verdict"
# rather than a clean extraction failure while this was being written.
$ei = if ($li -gt 0) { $coreRaw.LastIndexOf('} else {', $li) } else { -1 }
if ($si -lt 0 -or $ei -le $si) {
    Bad 'could not extract the cleanup loop decision snippet (the differential check would be a no-op)'
} else {
    # From just after 'ElseIf (...) {' through the '}' closing the heartbeat if. That is a complete
    # `if` statement on its own, so it evaluates without the else branch.
    $snippet = $coreRaw.Substring($si + $startMarker.Length, $ei - ($si + $startMarker.Length) + 1)
    if ($snippet -notmatch '\$elapsedMin') {
        Bad 'the extracted snippet does not contain the deadline computation (extraction drifted)'
    }
    # NOTE ON THE CLOCK: the snippet sets `$nowTs = Get-Date` itself, so a fake clock CANNOT be
    # injected - an earlier version of this test tried and produced a false failure. The harness
    # therefore uses real time and keeps every case at least 5 minutes from its boundary, so the
    # sub-second gap between the block's Get-Date and the function's -Now cannot flip a verdict.
    $verdict = @'
                    [pscustomobject]@{
                        Expired = [bool]($expires -and $nowTs -gt $expires)
                        Basis = $basis
                        Op = $opName
                        Budget = $budget
                    }
'@
    $blockSource = @"
param([bool]`$RowPresent, `$RowObj, [string]`$RowComputer, [string]`$StartText)
`$runspace = [pscustomobject]@{ Computer = `$RowComputer; StartTime = [datetime]::ParseExact(`$StartText, 'o', [cultureinfo]::InvariantCulture) }
`$stateStore = @{ ByName = @{} }
if (`$RowPresent) { `$stateStore.ByName[`$RowComputer.ToLowerInvariant()] = `$RowObj }
$snippet
$verdict
"@

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    # Injected the same way Wuu.Core injects it: a plain SetVariable'd OBJECT, which the runspace
    # BODY can read (only nested literal scriptblocks fail to bind, and there are none here).
    $rs.SessionStateProxy.SetVariable('OperationTimeoutSeconds', $global:OperationTimeoutSeconds)
    $rs.SessionStateProxy.SetVariable('OperationHeartbeatSeconds', $global:OperationHeartbeatSeconds)
    # The timeout path calls the log block; a no-op stand-in with the same call shape keeps this test
    # from needing a log file.
    $rs.SessionStateProxy.SetVariable('WriteLogFileScript', [scriptblock]::Create('param([string]$LogEntry)'))

    function Invoke-BlockDecision {
        param($Ps, $Source, $RowObj, [bool]$RowPresent, [datetime]$Start)
        $Ps.Commands.Clear()
        $Ps.AddScript($Source) | Out-Null
        $Ps.AddArgument($RowPresent).AddArgument($RowObj).AddArgument('SRV01').AddArgument($Start.ToString('o')) | Out-Null
        $h = $Ps.BeginInvoke()
        if (-not $h.AsyncWaitHandle.WaitOne(15000)) { return $null }
        $out = @($Ps.EndInvoke($h) | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Expired'] })
        if ($out.Count -gt 0) { return $out[-1] }
        return $null
    }

    $ps = [powershell]::Create()
    $ps.Runspace = $rs

    # Rows built against REAL time, because the snippet reads the clock itself.
    $rt = Get-Date
    $futureRow = New-WuuComputerRow -Computer 'SRV01'
    $null = Set-WuuOperationDeadline -Row $futureRow -Op 'AutoFlow' -Now $rt          # 4h away
    $pastRow = New-WuuComputerRow -Computer 'SRV01'
    $pastRow.TimeoutExpiresAt = $rt.AddMinutes(-30)                                    # deliberately past
    $pastRow.TimeoutSource = 'ServiceAction'
    $pastRow.OpName = 'ServiceAction'
    $clearedRow = New-WuuComputerRow -Computer 'SRV01'                                 # no deadline

    $cases = @(
        @{ Name = 'deadline 4h in the future';     Row = $futureRow;  Present = $true;  Start = $rt;             Expect = $false }
        @{ Name = 'deadline 30m in the past';      Row = $pastRow;    Present = $true;  Start = $rt.AddHours(-1); Expect = $true }
        @{ Name = 'no deadline, just started';     Row = $clearedRow; Present = $true;  Start = $rt;             Expect = $false }
        @{ Name = 'no deadline, ran 2h';           Row = $clearedRow; Present = $true;  Start = $rt.AddHours(-2); Expect = $true }
        @{ Name = 'no row at all';                 Row = $null;       Present = $false; Start = $rt;             Expect = $false }
    )
    $mismatches = @()
    foreach ($c in $cases) {
        $blockVerdict = Invoke-BlockDecision -Ps $ps -Source $blockSource -RowObj $c.Row -RowPresent $c.Present -Start $c.Start
        $fnVerdict = Test-WuuOperationExpired -Row $c.Row -Now (Get-Date) -StartedAt $c.Start
        if (-not $blockVerdict) {
            $mismatches += "$($c.Name): the block produced no verdict"
            continue
        }
        if ($blockVerdict.Expired -ne $fnVerdict.Expired) {
            $mismatches += "$($c.Name): block=$($blockVerdict.Expired) function=$($fnVerdict.Expired)"
        } elseif ($blockVerdict.Expired -ne $c.Expect) {
            $mismatches += "$($c.Name): expected $($c.Expect) but got $($blockVerdict.Expired)"
        }
    }
    if ($mismatches.Count -eq 0) {
        Ok "the runspace block and Test-WuuOperationExpired agree on all $($cases.Count) cases"
    } else {
        Bad "block/function disagreement: $($mismatches -join ' | ')"
    }
    $ps.Dispose(); $rs.Close(); $rs.Dispose()

    # The snippet must actually CONSULT the table and the recorded deadline - a differential test on a
    # snippet that ignored both would still pass on a future deadline.
    if ($snippet -match 'OperationTimeoutSeconds' -and $snippet -match 'TimeoutExpiresAt') {
        Ok 'the cleanup snippet consults the per-op table AND the recorded deadline'
    } else {
        Bad 'the cleanup snippet does not consult the table and/or the recorded deadline'
    }
    if ($snippet -match 'StartTime.AddSeconds\(\$budget\)') {
        Ok 'the cleanup snippet retains a start-time fallback for rows with no deadline'
    } else {
        Bad 'the cleanup snippet has no start-time fallback (work not submitted through Start-UpdateCheckJob would be unbounded)'
    }
    if ($snippet -match 'Heartbeat') {
        Ok 'the cleanup snippet records a liveness heartbeat while the job is within its deadline'
    } else {
        Bad 'the cleanup snippet records no heartbeat (slow and stuck would be indistinguishable)'
    }
    if ($snippet -notmatch 'TotalMinutes -gt 10') {
        Ok 'the flat 10-minute stop is gone'
    } else {
        Bad 'the flat 10-minute stop is still present'
    }
}

# --- 5. the deadline is recorded at submission, and cleared on every exit path --------
$sup = [regex]::Match($wupdRaw, 'function Start-UpdateCheckJob[\s\S]*?\nfunction ')
$supText = if ($sup.Success) { $sup.Value } else { '' }
if ($supText -match 'Set-WuuOperationDeadline') {
    Ok 'the submission point records the deadline (one source of truth for the budget)'
} else {
    Bad 'the submission point does not record the deadline - the loop would guess the budget'
}
# Every place OpState returns to Idle must clear the deadline, or the next op is killed instantly.
$idleSites = ([regex]::Matches($coreRaw, "OpState = 'Idle'")).Count
$clearSites = ([regex]::Matches($coreRaw, "TimeoutExpiresAt'\]\) \{ \`$?\w+\.TimeoutExpiresAt = \`$null")).Count
if ($idleSites -gt 0 -and $clearSites -ge $idleSites) {
    Ok "every OpState release also clears the deadline ($clearSites clear site(s) for $idleSites release site(s))"
} else {
    Bad "only $clearSites deadline clear site(s) for $idleSites OpState release site(s) - a stale deadline would kill the next operation"
}

# The table must be injected into the cleanup runspace, or the loop cannot resolve any budget.
if ($coreRaw -match "SetVariable\('OperationTimeoutSeconds'") {
    Ok 'the per-op table is injected into the cleanup runspace'
} else {
    Bad 'the per-op table is not injected - the loop would fall back to a literal for every op'
}
# ...and it must be a hashtable, not a scriptblock: a SetVariable'd OBJECT is visible to the loop
# body, while a nested literal scriptblock binds nothing. Verified on this host.
if ($stateRaw -match 'function Test-WuuOperationExpired') {
    Ok 'the decision function exists for tests and for non-runspace callers'
} else {
    Bad 'Test-WuuOperationExpired is missing'
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'Test-OperationTimeouts.ps1: ALL PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host "Test-OperationTimeouts.ps1: $fail FAILURE(S)" -ForegroundColor Red
    exit 1
}
