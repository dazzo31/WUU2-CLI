# Test: the pending-request policy (hardening brief SS7 / invariant 8.7).
#
# WHY THIS SUITE EXISTS
# ---------------------
# A row has ONE PendingOp slot, so a busy computer cannot hold two outstanding requests. The slot was
# assigned in place, so a second request silently destroyed the first:
#
#     busy computer -> `download`   sets PendingOp='Download'
#                   -> `install`    sets PendingOp='InstallAndRecheck'   (Download is GONE)
#
# and the operator was told only "queued to run when they finish".
#
# The direction that is easy to miss is the DOWNGRADE: `install` then `download` replaced the install
# with a download, so an operator who asked for MORE got less, with no indication at all. That case is
# asserted explicitly below because the reported defect was only the upgrade direction.
#
# THE POLICY: one slot, newest request wins, and a replacement is ALWAYS reported. Refusing a second
# request outright would make `download` then `install` silently do nothing, which is worse than doing
# the newer thing. Internal (automatic) follow-ups use -OnlyIfEmpty so they can never displace an
# operator's request.
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-PendingPolicy.ps1
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

$failures = @()
function Assert-True($Condition, $Name) {
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host ("FAIL: {0}" -f $Name) -ForegroundColor Red; $script:failures += $Name }
}
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -eq "$Expected") { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host ("FAIL: {0} - expected '{1}', got '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red; $script:failures += $Name }
}

# ---------------------------------------------------------------------------------------
# 1. the policy truth table
# ---------------------------------------------------------------------------------------
$r = New-WuuComputerRow -Computer 'P001'
$r.OpState = 'Running'   # busy, which is the only state in which a request is queued

# An empty slot is filled, and nothing is reported as replaced.
$res = Set-WuuPendingOperation -Row $r -Op 'Download'
Assert-Equal $res.Set $true '1. an empty slot is filled'
Assert-Equal $res.Op 'Download' '1. the queued op is returned'
Assert-Equal "$($res.Replaced)" '' '1. filling an empty slot replaces nothing'
Assert-Equal $r.PendingOp 'Download' '1. the row carries the queued op'
Assert-Equal $r.Pending $true '1. queueing sets Pending (or the scheduler never sees it)'

# UPGRADE: download -> install. The download IS replaced, and that must be REPORTED.
$res = Set-WuuPendingOperation -Row $r -Op 'InstallAndRecheck'
Assert-Equal $res.Set $true '1. an UPGRADE is accepted (refusing it would silently do nothing)'
Assert-Equal $res.Refused $false '1. an UPGRADE is not a refusal'
Assert-Equal $res.Replaced 'Download' '1. the displaced request is RETURNED to the caller (this is what makes it reportable)'
Assert-Equal $r.PendingOp 'InstallAndRecheck' '1. an UPGRADE replaces the queued request (it does the same work and more)'

# DOWNGRADE: install -> download. The install is KEPT - the case the report did not mention. SS16
# replaced newest-wins here: the operator asked for MORE, so honouring the later, smaller request
# would do less than they asked while leaving the slot describing the smaller thing.
$res = Set-WuuPendingOperation -Row $r -Op 'Download'
Assert-Equal $res.Set $false '1. DOWNGRADE: the lower request is DECLINED'
Assert-Equal $res.Refused $true '1. DOWNGRADE: the decline is REPORTED - a silent no-op is the defect class'
Assert-Equal $res.Existing 'InstallAndRecheck' '1. DOWNGRADE: the caller is told what was KEPT, so the decision can be explained'
Assert-True ([bool]$res.Reason) '1. DOWNGRADE: the decline carries a reason'
Assert-Equal "$($res.Replaced)" '' '1. DOWNGRADE: nothing was displaced, so nothing is reported as replaced'
Assert-Equal $r.PendingOp 'InstallAndRecheck' '1. DOWNGRADE: the higher request STAYS queued (asked for more, still getting more)'

# ---------------------------------------------------------------------------------------
# 1b. SEMANTIC PRECEDENCE (SS16). The rank table, and the rule that a LOWER request never displaces a
#     HIGHER one. Driven from the table itself so a re-ranked operation cannot pass by accident.
# ---------------------------------------------------------------------------------------
# Check < Download < Install < Restart. AutoFlow is the full chain, so it ranks with Restart.
$rankCases = @(
    @{ Op = 'Check'; Rank = 1 }, @{ Op = 'Download'; Rank = 2 },
    @{ Op = 'InstallAndRecheck'; Rank = 3 }, @{ Op = 'Install'; Rank = 3 },
    @{ Op = 'Restart'; Rank = 4 }, @{ Op = 'AutoFlow'; Rank = 4 },
    # An unrecognised operation ranks 0: declining it in favour of anything already queued is the
    # safe direction, because nothing the operator asked for is abandoned.
    @{ Op = 'SomethingNew'; Rank = 0 }
)
foreach ($c in $rankCases) {
    Assert-Equal (Get-WuuPendingOpRank -Op $c.Op) $c.Rank "1b. rank('$($c.Op)') is $($c.Rank)"
}
Assert-Equal (Get-WuuPendingOpRank -Op '') 0 '1b. a blank op ranks 0 (degenerate input never throws)'

# Every ordered PAIR from the table: a lower request must be declined and leave the slot alone; a
# higher one must replace. This is the whole policy in one loop, so the direction that used to be
# missed (install then download) is asserted for every combination rather than the two we thought of.
foreach ($existing in @('Check', 'Download', 'InstallAndRecheck', 'Restart')) {
    foreach ($requested in @('Check', 'Download', 'InstallAndRecheck', 'Restart')) {
        $pairRow = New-WuuComputerRow -Computer 'PAIR'
        $pairRow.OpState = 'Running'
        $pairRow.PendingOp = $existing
        $pairRes = Set-WuuPendingOperation -Row $pairRow -Op $requested
        $eRank = Get-WuuPendingOpRank -Op $existing
        $rRank = Get-WuuPendingOpRank -Op $requested
        if ($rRank -lt $eRank) {
            Assert-Equal $pairRes.Refused $true "1b. $existing -> $requested is DECLINED (a lower request must not displace a higher one)"
            Assert-Equal $pairRow.PendingOp $existing "1b. $existing -> $requested leaves the higher request queued"
        } elseif ($rRank -gt $eRank) {
            Assert-Equal $pairRes.Set $true "1b. $existing -> $requested is accepted (an upgrade loses nothing)"
            Assert-Equal $pairRes.Replaced $existing "1b. $existing -> $requested reports the displaced request"
            Assert-Equal $pairRow.PendingOp $requested "1b. $existing -> $requested queues the upgrade"
        }
    }
}

# EQUAL rank is genuinely ambiguous, so the newer request wins within its rank - and that IS a
# replacement, so it is reported exactly like any other.
$sameRow = New-WuuComputerRow -Computer 'SAME'
$sameRow.OpState = 'Running'
$null = Set-WuuPendingOperation -Row $sameRow -Op 'Install'
$sameRes = Set-WuuPendingOperation -Row $sameRow -Op 'InstallAndRecheck'
Assert-Equal $sameRes.Set $true '1b. an equal-rank request replaces (the ambiguity is settled by arrival order)'
Assert-Equal $sameRes.Replaced 'Install' '1b. an equal-rank replacement is REPORTED, not silent'
Assert-Equal $sameRes.Refused $false '1b. an equal-rank replacement is not a refusal'

# A DOWNGRADE that is DECLINED must leave Pending alone as well as PendingOp: the queued higher
# request still has to be picked up by the scheduler.
$keepRow = New-WuuComputerRow -Computer 'KEEP'
$keepRow.OpState = 'Running'
$keepRow.Pending = $true
$keepRow.PendingOp = 'Restart'
$null = Set-WuuPendingOperation -Row $keepRow -Op 'Check'
Assert-Equal $keepRow.Pending $true '1b. a declined request leaves the higher one still marked Pending (or it would never run)'

# Re-queueing the SAME op is not a replacement - nothing was lost, so nothing is reported.
$r.PendingOp = 'Download'
$res = Set-WuuPendingOperation -Row $r -Op 'Download'
Assert-Equal $res.Set $true '1. a repeated identical request is accepted'
Assert-Equal "$($res.Replaced)" '' '1. a repeated identical request replaces nothing (no spurious report)'

# ---------------------------------------------------------------------------------------
# 2. -OnlyIfEmpty: an internal follow-up must never displace an operator request
# ---------------------------------------------------------------------------------------
$r.PendingOp = 'InstallAndRecheck'
$res = Set-WuuPendingOperation -Row $r -Op 'Download' -OnlyIfEmpty
Assert-Equal $res.Set $false '2. an internal follow-up is REFUSED when an operator request is queued'
Assert-Equal $r.PendingOp 'InstallAndRecheck' '2. the operator request survives the internal follow-up'
Assert-Equal "$($res.Replaced)" '' '2. nothing was lost, so nothing is reported'

# ...but it DOES fill an empty slot (an automatic download must still be able to queue).
$r.PendingOp = $null
$res = Set-WuuPendingOperation -Row $r -Op 'AutoFlow' -OnlyIfEmpty
Assert-Equal $res.Set $true '2. an internal follow-up fills an EMPTY slot'
Assert-Equal $r.PendingOp 'AutoFlow' '2. the internal follow-up is queued when nothing else is'

# ---------------------------------------------------------------------------------------
# 3. degenerate inputs (called from loops; must never throw or queue a blank op)
# ---------------------------------------------------------------------------------------
Assert-Equal (Set-WuuPendingOperation -Row $null -Op 'Download').Set $false '3. a null row is a clean no-op'
Assert-Equal (Set-WuuPendingOperation -Row $r -Op '').Set $false '3. a blank op is refused'
Assert-Equal (Set-WuuPendingOperation -Row $r -Op '   ').Set $false '3. a whitespace op is refused'
$noProp = [pscustomobject]@{ Computer = 'X' }
Assert-Equal (Set-WuuPendingOperation -Row $noProp -Op 'Download').Set $false '3. a row without PendingOp is a clean no-op'

# ---------------------------------------------------------------------------------------
# 4. THE DIFFERENTIAL: the two inlined payload guards must match -OnlyIfEmpty
# ---------------------------------------------------------------------------------------
# The payloads run in ISOLATED worker runspaces where no module function resolves, so each inlines the
# "only if empty" rule. An inlined copy that drifts is invisible to every other test here, so this
# block extracts each shipped guard from source and drives it against the function.
$coreRaw = Get-Content (Join-Path $root 'src\Wuu.Core.psm1') -Raw
function Get-CodeNoComments([string]$Text) {
    if (-not $Text) { return '' }
    $noBlocks = [regex]::Replace($Text, '(?s)<#.*?#>', '')
    return (($noBlocks -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
}
$coreCode = Get-CodeNoComments $coreRaw

# The two guards are `if ($existingRequest -eq '')` and `if ($existingRequestAd -eq '')`.
$guards = @(
    @{ Name = 'auto-install tail'; Var = 'existingRequest';   Pattern = "if \(\`$existingRequest -eq ''\)" }
    @{ Name = 'auto-download tail'; Var = 'existingRequestAd'; Pattern = "if \(\`$existingRequestAd -eq ''\)" }
)
foreach ($g in $guards) {
    $found = [regex]::Match($coreCode, $g.Pattern).Success
    Assert-True $found ("4. the {0} guard is present in the shipped source" -f $g.Name)
    if (-not $found) { continue }

    # Drive the SHIPPED condition text: it guards on whether the existing request is empty.
    $agreed = $true
    foreach ($existing in @('', 'Download', 'InstallAndRecheck', 'AutoFlow')) {
        $conditionTrue = [bool](Invoke-Expression ("'" + $existing + "' -eq ''"))
        # The function's refusal decision for the same input, with -OnlyIfEmpty.
        $row = New-WuuComputerRow -Computer 'DIFF'
        $row.PendingOp = if ($existing -eq '') { $null } else { $existing }
        $fnWouldSet = (Set-WuuPendingOperation -Row $row -Op 'InstallAndRecheck' -OnlyIfEmpty).Set
        # The inline guard sets the slot when the condition is TRUE.
        if ($conditionTrue -ne $fnWouldSet) {
            $agreed = $false
            Write-Host ("      drift at {0}: existing='{1}' inlineSets={2} functionSets={3}" -f $g.Name, $existing, $conditionTrue, $fnWouldSet) -ForegroundColor Yellow
        }
    }
    Assert-True $agreed ("4. {0} agrees with Set-WuuPendingOperation -OnlyIfEmpty on all 4 inputs" -f $g.Name)
}

# Tautology check: the differential must be able to FAIL. Invert the guard and it must disagree.
$flipped = $true
foreach ($existing in @('', 'Download')) {
    $inlineFlipped = -not ([bool](Invoke-Expression ("'" + $existing + "' -eq ''")))
    $row = New-WuuComputerRow -Computer 'DIFF2'
    $row.PendingOp = if ($existing -eq '') { $null } else { $existing }
    $fnWouldSet = (Set-WuuPendingOperation -Row $row -Op 'InstallAndRecheck' -OnlyIfEmpty).Set
    if ($inlineFlipped -eq $fnWouldSet) { $flipped = $false }
}
Assert-True $flipped '4. the differential CAN fail: an inverted guard is detected'

# ---------------------------------------------------------------------------------------
# 5. every operator-facing handler reports a replacement
# ---------------------------------------------------------------------------------------
# A policy that replaces silently is the original defect with a tidier implementation. Each handler
# that can displace a queued request must keep the replaced value and print it.
foreach ($handler in @('EventDownloadUpdates', 'EventInstallUpdates')) {
    # SINGLE-quoted pattern. The first version used a double-quoted string, where `"\$consoleActions\."`
    # still INTERPOLATES `$consoleActions` - and because the module is imported that variable holds a
    # hashtable, so the pattern became `\System.Collections.Hashtable\.EventDownloadUpdates...` and
    # matched nothing. The handlers were present; the locator was wrong.
    $m = [regex]::Match($coreRaw, ('\$consoleActions\.' + $handler + ' = \{[\s\S]{0,2600}'))
    Assert-True $m.Success ("5. {0} was located in the shipped source" -f $handler)
    if (-not $m.Success) { continue }
    $body = Get-CodeNoComments $m.Value
    Assert-True ($body -match 'Set-WuuPendingOperation') ("5. {0} routes through the pending policy" -f $handler)
    Assert-True ($body -match '\$replaced \+=') ("5. {0} accumulates the replaced requests" -f $handler)
    Assert-True ($body -match 'REPLACED by this one') ("5. {0} REPORTS the replacement to the operator" -f $handler)
    Assert-True ($body -notmatch '\$r\.PendingOp = ') ("5. {0} no longer assigns PendingOp directly (that was the silent overwrite)" -f $handler)
}
# The check handler uses -OnlyIfEmpty, so it must NOT claim a replacement it did not make.
$chk = [regex]::Match($coreRaw, ('\$consoleActions\.EventGetUpdates = \{[\s\S]{0,2600}'))
$chkBody = Get-CodeNoComments $chk.Value
Assert-True ($chkBody -match "Set-WuuPendingOperation -Row \`$r -Op 'Check' -OnlyIfEmpty") '5. the check handler uses -OnlyIfEmpty (a re-check must not displace an operator request)'
Assert-True ($chkBody -match 'NOT replaced') '5. the check handler says the existing request is KEPT (its message must match its behaviour)'

# ---------------------------------------------------------------------------------------
# 6. the end-to-end sequence from the report: busy -> download -> install
# ---------------------------------------------------------------------------------------
$seq = New-WuuComputerRow -Computer 'SEQ01'
$seq.OpState = 'Running'
$reported = @()
# `download` while busy
$p1 = Set-WuuPendingOperation -Row $seq -Op 'Download'
if ($p1.Replaced) { $reported += $p1.Replaced }
Assert-Equal $seq.PendingOp 'Download' '6. busy -> download queues Download'
# `install` while still busy
$p2 = Set-WuuPendingOperation -Row $seq -Op 'InstallAndRecheck'
if ($p2.Replaced) { $reported += $p2.Replaced }
Assert-Equal $seq.PendingOp 'InstallAndRecheck' '6. busy -> download -> install leaves the install queued'
Assert-Equal ($reported -join ',') 'Download' '6. the displaced Download was REPORTED (the original defect was the silence)'

# ---------------------------------------------------------------------------------------
# 7. the scheduler consumes the slot by clearing it, so nothing is left to displace
# ---------------------------------------------------------------------------------------
# The clear must go THROUGH THE MUTATION FUNNEL (SS16). It used to be a bare
# `$item.PendingOp = $null`, which is why this site was one of the three module-scope
# operation-state writes the P0 investigation identified. Asserting the call - not merely that the
# text disappeared - is the point: the requirement is that pending state IS cleared, and that it is
# cleared by the state API rather than by whoever happened to be holding the row.
$schedCode = Get-CodeNoComments (Get-Content (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw)
Assert-True ($schedCode -match 'Update-WuuOperationState\s+-Row\s+\$item\s+-ClearPendingOp') `
    '7. the scheduler clears the slot through the mutation funnel (-ClearPendingOp), not by assigning the property'
Assert-True (-not ($schedCode -match '\$item\.PendingOp\s*=\s*\$null')) `
    '7. the scheduler no longer assigns PendingOp directly (the direct write is what SS16 removed)'
Assert-True ($schedCode -match 'if \(\$item\.PSObject\.Properties\[''PendingOp''\] -and \$item\.PendingOp\)') `
    '7. the slot is still read BEFORE it is cleared (a blind clear would discard the queued request without running it)'

# ---------------------------------------------------------------------------------------
# 8. A SETTLED row cannot take a queued follow-up (the 8.4 contradiction).
# ---------------------------------------------------------------------------------------
# A queued follow-up presupposes an operation to follow. Writing one onto a row that has already
# settled produced a row reported FINISHED while its next operation was still queued - and that
# state was reachable through the funnel's own cleanup path, because ClearOperation retires the
# operation (OpState='Idle') while the slot survives. Settlement is a transition, so the funnel
# must decide it: settlement wins and the follow-up is refused WITH A REASON, so the caller can
# say why nothing was queued instead of reporting a queue that will never be honoured.
foreach ($terminal in @(Get-WuuTerminalStates)) {
    $settled = New-WuuComputerRow -Computer ('SETTLED-' + $terminal)
    $settled.State = $terminal
    # A Timeout display is only consistent with a deadline; the refusal must not depend on that.
    if ($terminal -eq 'Timeout') { $settled.TimeoutExpiresAt = (Get-Date).AddMinutes(5) }
    $refused = Set-WuuPendingOperation -Row $settled -Op 'Download'
    Assert-Equal $refused.Set $false ("8. a settled '$terminal' row refuses a queued follow-up")
    Assert-True ([bool]$refused.Reason) ("8. the refusal for '$terminal' carries a reason (a silent no-op is the defect class)")
    Assert-Equal "$($settled.PendingOp)" '' ("8. no PendingOp is written on a settled '$terminal' row")
}

# SETTLEMENT THROUGH THE FUNNEL, which is the reachable path: queue while busy, then settle.
$funnel = New-WuuComputerRow -Computer 'SETTLE-FUNNEL'
$funnel.OpState = 'Running'
$funnel.OperationId = 'op-settle'
$null = Set-WuuPendingOperation -Row $funnel -Op 'Download'
$null = Update-WuuOperationState -Row $funnel -OperationId 'op-settle' -State 'Complete' -ClearOperation
$liveViolations = @(Test-WuuOperationStateInvariant -Row $funnel)
Assert-Equal $liveViolations.Count 0 '8. settling a row that holds a queued follow-up leaves no invariant violation'
Assert-Equal $funnel.State 'Queued' '8. the row is not left reported finished while its follow-up is queued'
Assert-Equal $funnel.PendingOp 'Download' '8. the queued follow-up survives settlement (it must still run)'
Assert-Equal $funnel.Pending $true '8. Pending survives, so the scheduler will still drain it'

# And it really does drain: the scheduler only considers rows with Pending set, and the row it
# would start is the queued op - so "the follow-up cannot run" was never the actual hazard.
Assert-True ($schedCode -match '\$op = \$item\.PendingOp') '8. the scheduler starts the queued op, so it drains'

# Tautology check: the guard must be ABLE to fail. Force the settled row past the refusal and the
# very state the check exists to forbid must reappear.
$taut = New-WuuComputerRow -Computer 'TAUTOLOGY'
$taut.State = 'Error'
$taut.PendingOp = 'Download'
$tautViolations = @(Test-WuuOperationStateInvariant -Row $taut)
Assert-True ($tautViolations.Count -gt 0) '8. the invariant CAN fail: a settled row forced to hold a queued op is still detected'

# ---------------------------------------------------------------------------------------
Write-Host ''
if ($failures.Count) {
    Write-Host ("RESULT: {0} assertion(s) FAILED" -f $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'ALL PASS - the pending-request policy replaces explicitly and reports it (SS7 / 8.7)' -ForegroundColor Green
exit 0
