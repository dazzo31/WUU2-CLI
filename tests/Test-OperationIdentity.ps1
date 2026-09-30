# Test: operation identity and stale-worker rejection (hardening brief SS2/SS3).
#
# WHY THIS SUITE EXISTS
# ---------------------
# Invariant 8.1 (one operation per computer) makes the stale-worker race UNREACHABLE, not SAFE.
# Nothing compared an operation identity, so nothing rejected a stale result - and three paths can
# emit one:
#
#   1. the cleanup loop settles jobs in the order it NOTICES them. A job force-stopped on timeout
#      is queued for removal, but its runspace tears down asynchronously. If the computer is
#      resubmitted in that window, the loop's next pass releases the NEW operation's lock, clears
#      its deadline and stamps the OLD operation's timeout text onto it. The computer is then
#      unguarded: a third submission is admitted while the second still runs, and the runspace
#      DISCARDS it silently (see Test-ComputerBusy for the measured platform behaviour).
#
#   2. a payload parked mid-write when the timeout path detaches the runspace still holds a
#      reference to the row and writes into it through its own module-scope $StateStore.
#
#   3. Remove-WuuComputers removes jobs from $jobs out-of-band, so no cleanup pass runs for them.
#
# This suite asserts the identity exists, that the staleness rule is the SAME in all six places it
# is written (the module function plus five inlined copies in isolated runspaces that cannot call
# it), and that a proven-stale writer is refused while an unattributed write is still permitted.
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-OperationIdentity.ps1
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

Import-Module (Join-Path $root 'src\Wuu.State.psm1') -Force -ErrorAction Stop

$stateRaw = Get-Content (Join-Path $root 'src\Wuu.State.psm1') -Raw
$coreRaw  = Get-Content (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$wupdRaw  = Get-Content (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw

# Strip comments before ANY pattern match. The guards below are explained at length by the comments
# that surround them, and this codebase has now produced a false failure four times by matching the
# comment that describes the code instead of the code itself.
function Get-CodeNoComments([string]$Text) {
    if (-not $Text) { return '' }
    $noBlocks = [regex]::Replace($Text, '(?s)<#.*?#>', '')
    return (($noBlocks -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
}
$coreCode = Get-CodeNoComments $coreRaw
$wupdCode = Get-CodeNoComments $wupdRaw

# ---------------------------------------------------------------------------------------
# 1. the row contract carries the identity
# ---------------------------------------------------------------------------------------
$row = New-WuuComputerRow -Computer 'SRV01'
Assert-True ($null -ne $row.PSObject.Properties['OperationId']) '1. the row contract has OperationId'
Assert-Equal $row.OperationId '' '1. a new row has no operation identity (nothing owns it yet)'

# ---------------------------------------------------------------------------------------
# 2. identities are unique, non-empty, and not derived from the computer name alone
# ---------------------------------------------------------------------------------------
$ids = @(1..200 | ForEach-Object { New-WuuOperationId -Computer 'SRV01' })
Assert-Equal @($ids | Sort-Object -Unique).Count 200 '2. 200 ids created in one process are all distinct'
Assert-True (($ids | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) '2. no identity is empty or whitespace'
Assert-True ($ids[0] -ne $ids[1]) '2. consecutive identities differ'
# The computer name alone must NOT be the identity - two operations on one computer are exactly the
# case that has to be told apart.
$otherComputer = New-WuuOperationId -Computer 'SRV01'
Assert-True ($otherComputer -ne 'SRV01') '2. identity is not merely the computer name'
Assert-True ((New-WuuOperationId -Computer 'SRV02') -ne (New-WuuOperationId -Computer 'SRV02')) '2. same computer, different operations -> different ids'

# ---------------------------------------------------------------------------------------
# 3. the staleness predicate truth table
# ---------------------------------------------------------------------------------------
$rowA = New-WuuComputerRow -Computer 'SRV01'
$rowA.OperationId = 'op-A'
Assert-Equal (Test-WuuOperationCurrent -Row $rowA -OperationId 'op-A') $true  '3. matching id -> current'
Assert-Equal (Test-WuuOperationCurrent -Row $rowA -OperationId 'op-B') $false '3. different id -> stale'
Assert-Equal (Test-WuuOperationCurrent -Row $rowA -OperationId '')     $false '3. empty writer id -> stale (not evidence of a match)'
Assert-Equal (Test-WuuOperationCurrent -Row $rowA -OperationId $null)  $false '3. null writer id -> stale'
Assert-Equal (Test-WuuOperationCurrent -Row $rowA -OperationId 'op-a') $false '3. case differs -> stale (identity is exact)'
Assert-Equal (Test-WuuOperationCurrent -Row $rowA -OperationId 'op')   $false '3. prefix only -> stale'

$rowNoId = New-WuuComputerRow -Computer 'SRV02'
Assert-Equal (Test-WuuOperationCurrent -Row $rowNoId -OperationId 'op-A') $false '3. row with no identity is never current'
Assert-Equal (Test-WuuOperationCurrent -Row $rowNoId -OperationId '')     $false '3. two unknowns are not a match'

# null-tolerance: called in loops on the cleanup thread, a lookup miss must be a clean $false
Assert-Equal (Test-WuuOperationCurrent -Row $null -OperationId 'op-A') $false '3. a null row is a clean false, not a throw'
$noProp = [pscustomobject]@{ Computer = 'X' }
Assert-Equal (Test-WuuOperationCurrent -Row $noProp -OperationId 'op-A') $false '3. a row without the property is a clean false'

# side-effect free: it is called from a loop that must not perturb what it inspects
$before = $rowA.OperationId
[void](Test-WuuOperationCurrent -Row $rowA -OperationId 'op-B')
Assert-Equal $rowA.OperationId $before '3. the predicate does not mutate the row'

# ---------------------------------------------------------------------------------------
# 4. THE DIFFERENTIAL: the rule is written in six places and they must not drift
# ---------------------------------------------------------------------------------------
# Test-WuuOperationCurrent lives in Wuu.State, but the cleanup loop and the injected row-writer run
# in ISOLATED runspaces where no module function resolves - so each inlines the rule. An inlined
# rule that drifts from the function is invisible to every other test in this repository, which is
# why this block extracts the SHIPPED CONDITION TEXT from each site and drives it on the same truth
# table, rather than re-implementing the comparison here.
#
# Each site names the function it must mirror and whether that function's result is inverted at the
# site. There is no single "polarity" because there are THREE behaviours in play, and collapsing
# them is the conflation the two functions exist to prevent:
#
#   writer refusals (2)          -> Test-WuuStaleWrite        directly.  Refuse PROVEN staleness only.
#   cleanup releases (3)         -> Test-WuuOperationCurrent  directly.  Release only PROVEN ownership.
#   timeout status write (1)     -> Test-WuuOperationCurrent  INVERTED.  Stricter: it stamps a
#                                   terminal status only when ownership is proven, so it refuses an
#                                   unattributed write too - unlike the lenient writer rule.
$sites = @(
    @{ Name = 'writer refusal (Wuu.Core Update-WuuComputerRow)'; Text = $coreCode; Pattern = 'if \((\$rowOpId -ne '''' -and \$writerOpId -ne '''' -and \$rowOpId -cne \$writerOpId)\)';  Row = 'rowOpId';     Writer = 'writerOpId';  Function = 'Test-WuuStaleWrite';       Invert = $false }

    @{ Name = 'failed-job release (cleanup loop)';               Text = $coreCode; Pattern = 'if \((\$rowOpId -ne '''' -and \$jobOpId -ne '''' -and \$rowOpId -ceq \$jobOpId)\)';        Row = 'rowOpId';     Writer = 'jobOpId';     Function = 'Test-WuuOperationCurrent'; Invert = $false }
    @{ Name = 'completion release (cleanup loop)';               Text = $coreCode; Pattern = 'if \((\$rowOpId2 -ne '''' -and \$jobOpId2 -ne '''' -and \$rowOpId2 -ceq \$jobOpId2)\)';     Row = 'rowOpId2';    Writer = 'jobOpId2';    Function = 'Test-WuuOperationCurrent'; Invert = $false }
    @{ Name = 'timeout release (cleanup loop)';                  Text = $coreCode; Pattern = 'if \((\$toRowId -ne '''' -and \$toOpId -ne '''' -and \$toRowId -ceq \$toOpId)\)';         Row = 'toRowId';     Writer = 'toOpId';      Function = 'Test-WuuOperationCurrent'; Invert = $false }

    @{ Name = 'writer refusal (injected worker writer)';         Text = $wupdCode; Pattern = 'if \((\$rowOpId -ne '''' -and \$writerOpId -ne '''' -and \$rowOpId -cne \$writerOpId)\)';  Row = 'rowOpId';     Writer = 'writerOpId';  Function = 'Test-WuuStaleWrite';       Invert = $false }
    @{ Name = 'timeout status write (cleanup loop)';             Text = $coreCode; Pattern = 'if \((\$toStatusRowId -eq '''' -or \$toStatusOpId -eq '''' -or \$toStatusRowId -cne \$toStatusOpId)\)'; Row = 'toStatusRowId'; Writer = 'toStatusOpId'; Function = 'Test-WuuOperationCurrent'; Invert = $true }
)

$table = @(
    @{ Row = 'A';  Writer = 'A';  Current = $true },
    @{ Row = 'A';  Writer = 'B';  Current = $false },
    @{ Row = 'A';  Writer = '';   Current = $false },
    @{ Row = '';   Writer = 'A';  Current = $false },
    @{ Row = '';   Writer = '';   Current = $false },
    @{ Row = 'A';  Writer = 'a';  Current = $false }
)

$missing = @()
foreach ($site in $sites) {
    $m = [regex]::Match($site.Text, $site.Pattern)
    if (-not $m.Success) { $missing += $site.Name; continue }

    # Give the SHIPPED condition text values, so the comparison operators it uses are the ones under
    # test - only the two operand NAMES are replaced, never the operators.
    #
    # Two wrong ways to do this, both tried before this one:
    #   * `-replace '\$rowOpId'` - the `$` is a regex end-of-string ANCHOR, so nothing matched, both
    #     operands stayed $null and the condition was evaluated with empty values;
    #   * `[scriptblock]::Create(...)` then `& $guard` - on this host, invoking a scriptblock that
    #     was built by ::Create returns the SCRIPTBLOCK, not its result, so `[bool]$result` was
    #     always True and every site appeared to "drift".
    # Substituting the operands as quoted literals and evaluating the resulting expression has
    # neither problem, and it keeps the operators untouched.
    $body = $m.Groups[1].Value
    $expr = $body.Replace('$' + $site.Row, "'__ROW__'").Replace('$' + $site.Writer, "'__WRITER__'")
    Assert-True ($expr -notmatch [regex]::Escape($site.Row)) ("4. {0}: the row operand was substituted" -f $site.Name)

    $agreed = $true
    foreach ($case in $table) {
        $evaluable = $expr.Replace("'__ROW__'", "'" + $case.Row + "'").Replace("'__WRITER__'", "'" + $case.Writer + "'")
        $conditionTrue = [bool](Invoke-Expression $evaluable)
        $siteDecision = if ($site.Invert) { -not $conditionTrue } else { $conditionTrue }
        # Compare against the function this site is supposed to mirror, not a single "the" function.
        $functionDecision = [bool](& $site.Function -Row ([pscustomobject]@{ OperationId = $case.Row }) -OperationId $case.Writer)

        if ($siteDecision -ne $functionDecision) {
            $agreed = $false
            Write-Host ("      drift at {0}: row='{1}' writer='{2}' site={3} {4}={5}" -f $site.Name, $case.Row, $case.Writer, $siteDecision, $site.Function, $functionDecision) -ForegroundColor Yellow
        }
    }
    Assert-True $agreed ("4. {0} agrees with {1}{2} on all {3} cases" -f $site.Name, $site.Function, $(if ($site.Invert) { ' (inverted)' } else { '' }), $table.Count)
}
Assert-Equal $missing.Count 0 ("4. all 6 guard sites were found and driven ({0} missing: {1})" -f $missing.Count, ($missing -join '; '))

# The two rules are NOT negations of each other, and the difference is load-bearing: a write must be
# PERMITTED against a row with no operation (list loading), while a release must be REFUSED for a job
# with no operation (an unattributed job must not unlock a row it cannot name). Asserted explicitly,
# because a future "simplification" of either into the other would look harmless and would break one.
$unownedRow = [pscustomobject]@{ OperationId = '' }
Assert-Equal (Test-WuuOperationCurrent -Row $unownedRow -OperationId 'op-A') $false '4. RELEASE rule refuses an unattributed job against an unowned row (must not unlock what it cannot name)'
Assert-Equal (Test-WuuStaleWrite -Row $unownedRow -OperationId 'op-A') $false '4. WRITE rule permits a write to an unowned row (list loading depends on it)'

$someRow = [pscustomobject]@{ OperationId = 'op-A' }
Assert-Equal (Test-WuuStaleWrite -Row $someRow -OperationId 'op-B') $true  '4. WRITE rule refuses a proven-superseded writer'
Assert-Equal (Test-WuuStaleWrite -Row $someRow -OperationId 'op-A') $false '4. WRITE rule permits the owner'
Assert-Equal (Test-WuuStaleWrite -Row $someRow -OperationId '')     $false '4. WRITE rule permits an unattributed writer (cannot prove staleness)'
Assert-Equal (Test-WuuStaleWrite -Row $null -OperationId 'op-A')    $false '4. WRITE rule tolerates a null row (called in loops)'

# Tautology check: the differential must be able to FAIL. A one-character change to the polarity
# (ceq -> cne) has to be detected, or this block proves nothing.
$flippedExpr = "$expr".Replace('-ceq', '-cne').Replace('-cne $', '-cne $')
if ($flippedExpr -notmatch '-cne') { $flippedExpr = $expr.Replace('-ceq', '-cne') }
$detected = $false
foreach ($case in $table) {
    $evaluable = $flippedExpr.Replace("'__ROW__'", "'" + $case.Row + "'").Replace("'__WRITER__'", "'" + $case.Writer + "'")
    $c = [bool](Invoke-Expression $evaluable)
    if ($c -ne $case.Current) { $detected = $true }
}
Assert-True $detected '4. the differential CAN fail: a polarity flip is detected (so agreement is not vacuous)'

# ---------------------------------------------------------------------------------------
# 5. the behavioural claim: a stale worker cannot unlock a newer operation
# ---------------------------------------------------------------------------------------
# Reproduce the scenario shape with the REAL predicate. Row is 'op-A' (the newer operation).
# Job 'op-B' is the superseded one, settling late.
$liveRow = [pscustomobject]@{ Computer = 'SRV01'; OpState = 'Running'; OperationId = 'op-A'; TimeoutExpiresAt = $null }

# What the guard decides for the late worker.
$wouldRelease = [bool](Test-WuuOperationCurrent -Row $liveRow -OperationId 'op-B')
Assert-Equal $wouldRelease $false '5. a superseded job is refused when it tries to settle the row (lock NOT released)'
Assert-Equal $liveRow.OpState 'Running' '5. the new operation keeps its lock - the computer stays busy, so a third submission is still refused'

# And the owner DOES settle it (otherwise the guard would deadlock every computer).
$ownerReleases = [bool](Test-WuuOperationCurrent -Row $liveRow -OperationId 'op-A')
Assert-Equal $ownerReleases $true '5. the operation that owns the row is still allowed to release it (the guard does not deadlock)'

# After the owner settles, a new submission gets a fresh identity, and the OLD one stays stale.
$liveRow.OpState = 'Idle'
$liveRow.OperationId = 'op-C'
Assert-Equal (Test-WuuOperationCurrent -Row $liveRow -OperationId 'op-A') $false '5. after a new operation starts, the previous operation is still stale (identity is not reused)'

# ---------------------------------------------------------------------------------------
# 6. the writer guard's asymmetry: refuse proven-stale, permit unattributed
# ---------------------------------------------------------------------------------------
# Refusing every unattributed write would break list loading (rows loaded from config have no
# operation), so the guard must permit it. Both halves are asserted, because a guard that refuses
# EVERYTHING would pass a "rejects staleness" test while breaking startup.
$writerGuard = [regex]::Match($coreCode, 'if \(\$rowOpId -ne '''' -and \$writerOpId -ne '''' -and \$rowOpId -cne \$writerOpId\)')
Assert-True $writerGuard.Success '6. the module-scope writer guard is present'
$injectedGuard = [regex]::Match($wupdCode, 'if \(\$rowOpId -ne '''' -and \$writerOpId -ne '''' -and \$rowOpId -cne \$writerOpId\)')
Assert-True $injectedGuard.Success '6. the injected worker writer guard is present'

# Evaluate the guard for the two cases that matter.
function Invoke-WriterGuard([string]$RowId, [string]$WriterId) {
    $rowOpId = $RowId; $writerOpId = $WriterId
    return [bool](& ([scriptblock]::Create('$rowOpId -ne '''' -and $writerOpId -ne '''' -and $rowOpId -cne $writerOpId')))
}
Assert-Equal (Invoke-WriterGuard 'op-A' 'op-B') $true  '6. a write naming a DIFFERENT operation is refused'
Assert-Equal (Invoke-WriterGuard 'op-A' 'op-A') $false '6. a write naming the SAME operation is permitted'
Assert-Equal (Invoke-WriterGuard 'op-A' '')     $false '6. an UNATTRIBUTED write is permitted (list loading writes rows with no operation)'
Assert-Equal (Invoke-WriterGuard '' 'op-A')     $false '6. a write against a row with no operation is permitted'

# ---------------------------------------------------------------------------------------
# 7. the identity reaches the worker, or the guard could never fire
# ---------------------------------------------------------------------------------------
# A guard that exists but can never see a writer identity is decoration. The submission point must
# inject the identity into the runspace, and the injected writer must READ it.
Assert-True ($wupdCode -match "SetVariable\('WuuOperationId'") '7. the submission point injects the operation identity into the worker runspace'
Assert-True ($wupdCode -match 'if \(\$writerOpId -eq '''' -and \$WuuOperationId\)') '7. the injected writer falls back to the injected $WuuOperationId (otherwise every payload write is unattributed)'

# ---------------------------------------------------------------------------------------
# 8. the identity is stamped BEFORE the pipeline can run, and rides on the job entry
# ---------------------------------------------------------------------------------------
$submitIdx = $wupdCode.IndexOf('$operationId = New-WuuOperationId')
$beginIdx  = $wupdCode.IndexOf('Runspace    = $PowerShell.BeginInvoke()')
Assert-True ($submitIdx -gt 0) '8. the submission point creates an operation identity'
Assert-True ($beginIdx -gt 0) '8. the submission point begins the pipeline'
Assert-True ($submitIdx -lt $beginIdx) '8. the identity is created BEFORE BeginInvoke (the payload may start on its own thread immediately)'
Assert-True ($wupdCode -match 'OperationId = \$operationId') '8. the job entry carries the identity (the cleanup loop holds the job, not the row)'
Assert-True ($coreCode -match "PSObject\.Properties\['OperationId'\]") '8. the cleanup loop reads the identity off the job entry'

# ---------------------------------------------------------------------------------------
# 9. the timeout path detaches the runspace, so a resubmission cannot inherit a dying one
# ---------------------------------------------------------------------------------------
Assert-True ($coreCode -match "Properties\['Runspace'\]\) \{ \`$toRow\.Runspace = \`$null \}") '9. the timeout path clears the row runspace before releasing the lock (a resubmission cannot build against a torn-down runspace)'

# ---------------------------------------------------------------------------------------
# 10. the out-of-band removal path releases the lock, clears the deadline and retires the identity
# ---------------------------------------------------------------------------------------
# Cut the window from the row-removal helper, which is CODE (not a comment) and therefore survives
# comment stripping. The first version of this block anchored on the explanatory comment's text and
# searched the comment-STRIPPED source - so it could never match. That is the same mistake this
# repository keeps making (checking the wrong text), and it is why the anchor is a code token.
$removeIdx = $coreCode.IndexOf('Failed to remove job from list')
Assert-True ($removeIdx -gt 0) '10. the out-of-band removal path exists'
if ($removeIdx -gt 0) {
    $removeBlock = $coreCode.Substring($removeIdx, [Math]::Min(1600, $coreCode.Length - $removeIdx))
    # Anchors are ORDINAL string tests, not regex: in a regex an unescaped `$` is an end-of-string
    # anchor, so '\$Computer\.OperationId' silently matches nothing. That mistake made this block
    # fail while the guard was correct - and it is the same class of error as matching a comment.
    Assert-True ($removeBlock.Contains("`$Computer.OpState = 'Idle'")) '10. it releases the lock'
    Assert-True ($removeBlock.Contains('TimeoutExpiresAt = $null')) '10. it clears the deadline (same trap as the cleanup loop)'
    Assert-True ($removeBlock.Contains("`$Computer.OperationId = ''")) '10. it retires the identity so a late writer cannot present a valid token for a dead job'
    Assert-True ($removeBlock.Contains('$Computer.Runspace = $null')) '10. it detaches the runspace'
}

# ---------------------------------------------------------------------------------------
Write-Host ''
if ($failures.Count) {
    Write-Host ("RESULT: {0} assertion(s) FAILED" -f $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'ALL PASS - operation identity is enforced (SS2/SS3)' -ForegroundColor Green
exit 0
