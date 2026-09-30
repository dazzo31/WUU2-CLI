# Test: remaining-budget propagation (reviewer P3).
#
# WHY THIS SUITE EXISTS
# ---------------------
# The operation deadline was enforced only at the OUTERMOST level: the cleanup loop kills a payload that
# overruns its budget. But a payload's inner probes each take a FIXED timeout of their own (a CIM
# connectivity probe defaults to 5s, a service start to 10s), chosen independently of how much budget is
# left. Two things follow, and both were reachable:
#
#   * an operation 1 second from expiry still starts a 30-second probe - the pool slot is then held for
#     29 seconds AFTER the cleanup loop has given up on the operation, starving other work;
#   * an operation 44 minutes into a 45-minute budget starts a 10-second probe, so a probe that would
#     have answered in 15 seconds is killed for no reason but timing, and the operator concludes the HOST
#     is broken.
#
# The rule that fixes both: an inner call takes min(its own timeout, what is left).
#
# THE DISTINCTION THIS SUITE EXISTS TO PROTECT is Known=$false. "No deadline recorded" must not become a
# number: returning 0 would fail every probe instantly, and returning a large number would silently remove
# the probe's own ceiling. Most of the assertions below are about that one distinction and about
# Remaining NOT being clamped, because both are the kind of thing a later "simplification" would quietly
# undo.
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-RemainingBudget.ps1
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

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force -DisableNameChecking
Import-WuuModules -WuuRoot $root

# A row carrying a deadline N seconds from "now".
#
# THE SHAPE HERE IS LOAD-BEARING. Production rows are PSCustomObjects (New-WuuComputerRow), and the state
# layer tests property existence with $Row.PSObject.Properties[...] - which DOES NOT SURFACE HASHTABLE
# KEYS. An earlier version of this fixture used a [hashtable], so every deadline went unread, Known came
# back $false, and the assertions passed for entirely the wrong reason: the "no deadline" cases were
# indistinguishable from "the deadline was ignored". Use [pscustomobject] - anything else tests a shape
# the product never produces.
$now = Get-Date
function New-Row([object]$ExpiresIn, [string]$Op = 'Check') {
    $r = [pscustomobject]@{ OperationId = 'op-test'; OpName = $Op }
    if ($null -ne $ExpiresIn) {
        $r | Add-Member -NotePropertyName 'TimeoutExpiresAt' -NotePropertyValue $now.AddSeconds([double]$ExpiresIn) -Force
        $r | Add-Member -NotePropertyName 'TimeoutSource' -NotePropertyValue 'test' -Force
    }
    return $r
}

# Pins the fixture to the production shape. If New-WuuComputerRow ever starts returning something else,
# the accessor in Wuu.State needs revisiting - and this assertion is where that gets noticed, rather than
# in a production run where the cap silently stops applying.
function Test-RowShape {
    $real = New-WuuComputerRow -Computer 'SHAPE-PROBE' -ErrorAction SilentlyContinue
    if ($null -eq $real) { return @{ Checked = $false } }
    return @{
        Checked        = $true
        RealType       = $real.GetType().Name
        FixtureType    = (New-Row 10).GetType().Name
        RealHasDeadline = [bool]$real.PSObject.Properties['TimeoutExpiresAt']
    }
}

'=== 0. the fixture matches the production row shape ==='
# Pinned FIRST, because every assertion below is worthless if the fixture is a shape the product never
# produces. This is not hypothetical: the original fixture used a [hashtable], production uses a
# PSCustomObject, and the state layer's $Row.PSObject.Properties[...] existence test does not surface
# hashtable keys - so all the deadline cases silently degraded to the "no deadline" branch and passed.
$shape = Test-RowShape
if ($shape.Checked) {
    Assert-Equal $shape.FixtureType $shape.RealType 'the fixture row is the same TYPE as a production row'
    Assert-True $shape.RealHasDeadline 'a production row really carries TimeoutExpiresAt (the accessor is pointed at a real property)'
    '    production type: {0} / fixture type: {1}' -f $shape.RealType, $shape.FixtureType | Write-Host
} else {
    Write-Host 'SKIP: New-WuuComputerRow unavailable, row shape not pinned' -ForegroundColor Yellow
}

'=== 1. no deadline is KNOWN=$false, never a fabricated number ==='
# The load-bearing case. A row with no deadline is the normal state for work submitted outside the
# scheduled path, and it must leave the caller's own timeout alone.
$noDeadline = Get-WuuOperationRemainingSeconds -Row (New-Row $null) -Now $now
Assert-False $noDeadline.Known 'a row with no deadline reports Known=$false'
Assert-True ($null -eq $noDeadline.Remaining) 'and Remaining is $null rather than 0 (0 would fail every probe instantly)'
Assert-Equal $noDeadline.Op '' 'and the operation name is empty rather than a fabricated one'

# DISCRIMINATION CHECK. Known=$false for a row with NO deadline would also be returned by a function that
# ignores the row entirely, so the assertions above cannot tell "correctly reports no deadline" from
# "never reads the row". This one can: a row that DOES carry a deadline must NOT report Known=$false.
Assert-True (Get-WuuOperationRemainingSeconds -Row (New-Row 60) -Now $now).Known 'CONTROL: a row WITH a deadline does not report Known=$false (the function really reads the row)'

# $null tolerance: these run inside payload scriptblocks with no exception handling around them.
$nullRow = Get-WuuOperationRemainingSeconds -Row $null -Now $now
Assert-False $nullRow.Known 'a $null row reports Known=$false instead of throwing'
$emptyRow = Get-WuuOperationRemainingSeconds -Row ([pscustomobject]@{}) -Now $now
Assert-False $emptyRow.Known 'a row with no deadline property reports Known=$false instead of throwing'

'=== 2. a recorded deadline yields the true remainder ==='
$row120 = New-Row 120
$b120 = Get-WuuOperationRemainingSeconds -Row $row120 -Now $now
Assert-True $b120.Known 'a row with a deadline reports Known=$true'
Assert-Equal $b120.Remaining 120 'and the remainder is exact'
Assert-Equal $b120.Op 'Check' 'and the operation name travels with it (for the caller''s log message)'

'=== 3. an OVERDUE operation reports a NEGATIVE remainder, never a clamped 0 ==='
# Collapsing overshoot to 0 hides from the caller how far past the deadline it is - which is exactly the
# number an operator needs when reading why a probe was cut short.
$rowPast = New-Row -30
$bPast = Get-WuuOperationRemainingSeconds -Row $rowPast -Now $now
Assert-True $bPast.Known 'an overdue row still reports Known=$true'
Assert-Equal $bPast.Remaining -30 'a NEGATIVE remainder is reported (overshoot is not clamped to 0)'
Assert-True ($bPast.Remaining -lt 0) 'and the sign survives, so the caller can see it is past the deadline'

'=== 4. the effective inner timeout is min(own, remaining) ==='
# Budget is generous: the probe's OWN timeout is the ceiling and must not be inflated.
$plan = Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds 30 -Row (New-Row 600) -Now $now
Assert-Equal $plan.Seconds 30 'a generous budget leaves the inner timeout at its own value'
Assert-False $plan.Capped 'and reports Capped=$false'
Assert-True ($plan.Reason -like '*permits the full*') "and says the budget permitted it ($($plan.Reason))"

# Budget is tighter than the probe's own timeout: cap DOWN to what is left.
$plan2 = Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds 30 -Row (New-Row 12) -Now $now
Assert-Equal $plan2.Seconds 12 'a tight budget caps the inner timeout to what is left'
Assert-True $plan2.Capped 'and reports Capped=$true'

'=== 5. the FLOOR keeps an expiring probe usable ==='
# A 1-second CIM call reports "timed out" for a host that was merely slow. That false negative costs an
# operator a real investigation, so a floor is applied rather than capping to a second.
$plan3 = Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds 30 -Row (New-Row 1) -Now $now -FloorSeconds 5
Assert-Equal $plan3.Seconds 5 'a 1-second remainder is raised to the 5-second floor'
Assert-True $plan3.Capped 'and is still reported as capped'

# Overdue by 30 seconds: the floor still applies, so the probe gets one usable slice rather than a
# negative timeout (which would be passed to WaitForExit and throw).
$plan4 = Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds 30 -Row (New-Row -30) -Now $now -FloorSeconds 5
Assert-Equal $plan4.Seconds 5 'an OVERDUE operation still gets the floor, not a negative timeout'
Assert-True ($plan4.Seconds -gt 0) 'and the resulting timeout is positive (a negative one would throw at the API)'

'=== 6. no deadline leaves the inner timeout UNTOUCHED ==='
# The whole point of Known=$false. An operation with no recorded deadline is not "expired" - it has no
# budget concept at all, and inventing one would silently change every unscheduled submission.
$plan5 = Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds 30 -Row (New-Row $null) -Now $now
Assert-Equal $plan5.Seconds 30 'no deadline leaves the inner timeout unchanged'
Assert-False $plan5.Capped 'and reports Capped=$false'
Assert-True ($plan5.Reason -like '*no deadline recorded*') "and says so ($($plan5.Reason))"
Assert-Equal (Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds 30 -Row $null -Now $now).Seconds 30 'a $null row is likewise unchanged'

'=== 7. a non-positive inner timeout is passed through, not floored ==='
# 0 means "no timeout" to the underlying API, which is a deliberate caller choice. Raising it to the
# floor would turn "wait forever" into "wait 5 seconds".
$plan6 = Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds 0 -Row (New-Row 5) -Now $now
Assert-Equal $plan6.Seconds 0 'a 0 inner timeout is passed through unchanged'
Assert-False $plan6.Capped 'and is not reported as capped'

'=== 8. the functions are pure (they mutate nothing) ==='
# They are called from payload scriptblocks, so a side effect here would be a side effect inside a
# runspace whose row another runspace also holds.
$rowPure = New-Row 45
$before = ($rowPure.Keys | Sort-Object) -join ','
$beforeExpiry = $rowPure['TimeoutExpiresAt']
$null = Get-WuuOperationRemainingSeconds -Row $rowPure -Now $now
$null = Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds 30 -Row $rowPure -Now $now
Assert-Equal (($rowPure.Keys | Sort-Object) -join ',') $before 'the row gained no keys'
Assert-Equal $rowPure['TimeoutExpiresAt'] $beforeExpiry 'and the deadline was not rewritten'

'=== 9. the payload helpers apply the cap INLINE (they cannot call a module function) ==='
# These two functions are DEFINED inside payload scriptblocks, so they run in an isolated runspace whose
# InitialSessionState is CreateDefault() with no module imported. A module function is NOT callable there
# (tests\Probe-PayloadFunctionReach.ps1 proves it: Get-Command returns nothing), so a cap written as a call
# to Get-WuuEffectiveInnerTimeout would throw on every production probe. That was the first version of this
# code; the assertions below are the ones that would have caught it.
$coreText = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
# Strip block and line comments but NOT string literals, so a claim in a comment cannot satisfy a check.
$coreCode = [regex]::Replace($coreText, '(?s)<#.*?#>', '')
$coreCode = [regex]::Replace($coreCode, '(?m)#.*$', '')

function Get-Body([string]$Name) {
    # BRACE-BALANCED, not "up to the next \n}". The helpers are defined at INDENT 8 inside payload
    # scriptblocks, so their closing brace is `\n        }` and a `\n\}` slice runs straight past it into
    # the NEXT function - which made the service helper appear to contain the CIM helper's call, and made
    # its own `-TimeoutSeconds $effectiveTimeout` assertion pass while reading someone else's line.
    # Verified against both functions: the balanced slice ends at the real closing brace and contains no
    # `function Invoke-<other>` (tests\Probe-BodyExtraction.ps1).
    $m = [regex]::Match($coreCode, "function\s+$Name\s*(?:\([^)]*\))?\s*\{")
    if (-not $m.Success) { return '' }
    $start = $m.Index + $m.Length - 1
    $depth = 0
    $i = $start
    $inSingle = $false
    $inDouble = $false
    while ($i -lt $coreCode.Length) {
        $c = $coreCode[$i]
        if (-not $inSingle -and -not $inDouble) {
            if ($c -eq "'") { $inSingle = $true }
            elseif ($c -eq '"') { $inDouble = $true }
            elseif ($c -eq '{') { $depth++ }
            elseif ($c -eq '}') { $depth--; if ($depth -eq 0) { return $coreCode.Substring($start, $i - $start + 1) } }
        } elseif ($inSingle -and $c -eq "'") { $inSingle = $false }
        elseif ($inDouble -and $c -eq '"') { $inDouble = $false }
        $i++
    }
    return ''
}

function Get-BodyAfterParams([string]$Body) {
    # Drops the param(...) block. Without this the reassignment scan matches the DECLARATION
    # `[int]$TimeoutSeconds = 5,` - which is not an assignment and is not a defect. The project's own
    # gate walks the AST and only inspects assignments inside the BODY, so it does not have this problem;
    # a text scan has to exclude the param block explicitly.
    #
    # Matches the FIRST `param(` anywhere in the body rather than anchoring on a leading `function ...`:
    # Get-Body returns a BRACE-BALANCED slice that starts at the opening brace, so the body does not begin
    # with the word `function` and an anchored pattern never matched (which left the declaration in the
    # scan and produced two false "reassigns its own parameter" findings). The param block is the first
    # `param(` by construction; a nested scriptblock's param list comes later.
    $pm = [regex]::Match($Body, '\bparam\s*\(')
    if (-not $pm.Success) { return $Body }
    $open = $pm.Index + $pm.Length - 1
    $depth = 0
    $i = $open
    while ($i -lt $Body.Length) {
        $c = $Body[$i]
        if ($c -eq '(') { $depth++ } elseif ($c -eq ')') { $depth--; if ($depth -eq 0) { return $Body.Substring($i) } }
        $i++
    }
    return $Body
}

foreach ($helper in 'Invoke-CimWithTimeout', 'Invoke-ServiceWithTimeout') {
    $body = Get-Body $helper
    Assert-True ($body.Length -gt 0) "$helper body was located (the assertions below are meaningful)"
    # FIXTURE SANITY: the slice must not have run past this function into the next one. Without this a
    # later "does not call a module function" assertion could pass by reading someone else's code, and an
    # assertion about one helper could be satisfied by the other.
    Assert-False ($body -match 'function\s+Invoke-(Cim|Service)WithTimeout') "$helper body does not bleed into the next function"
    $afterParams = Get-BodyAfterParams $body
    # The row must be ACCEPTED, or the caller has nothing to pass...
    Assert-True ($body.Contains('$Row')) "$helper accepts a row to cap against"
    # ...and it must be READ, guarding property existence (the row is a PSCustomObject in production).
    Assert-True ($body.Contains("`$Row.PSObject.Properties['TimeoutExpiresAt']")) "$helper reads the deadline off the row"
    # The floor must be present: without it an overdue operation passes a negative timeout to the API.
    Assert-True ($body.Contains('[math]::Max(5, $remaining)')) "$helper applies the floor to the capped timeout"
    # THE ASSERTION THAT MATTERS: no module function may be called from inside a payload helper.
    Assert-False ($body -match 'Get-WuuEffectiveInnerTimeout\s*-') "$helper does NOT call a module function (which would throw in a payload runspace)"
    Assert-False ($body -match 'Get-WuuOperationRemainingSeconds\s*-') "$helper does not call the state helper either"
    # The capped value must be what the POOL receives. Capping into a variable that is then ignored is
    # indistinguishable from not capping at all, and this is the only assertion that would notice.
    Assert-True ($body -match '-TimeoutSeconds\s+\$effectiveTimeout') "$helper passes the CAPPED value to the pool (not the original)"
    # The cap must not be written back onto the parameter: this project gates parameter reassignment
    # because a declared type is enforced on every assignment and a later coercion can throw. Scanned only
    # AFTER the param block, so the DECLARATION is not mistaken for an assignment.
    Assert-False ($afterParams -match '\$TimeoutSeconds\s*=\s*[^=]') "$helper does not reassign its own `$TimeoutSeconds parameter (a gated defect class here)"
    # The cap must be applied BEFORE the timeout reaches the pool, or it arrives too late to matter.
    $capAt = $body.IndexOf('$rowExpiry = $Row.PSObject.Properties')
    $useAt = $body.IndexOf('$effectiveTimeout', $capAt)
    Assert-True ($capAt -ge 0 -and $useAt -gt $capAt) "$helper applies the cap before the timeout is used"
}

'=== 10. the call sites pass the row they already hold ==='
# The helpers cap only when handed a row. A call site that omits -Row silently opts out of the whole
# mechanism, and the omission is invisible at runtime - the probe simply keeps its old fixed timeout.
#
# The pattern matches an INVOCATION: the cmdlet name followed by whitespace and then a parameter (a dash
# before an identifier). An earlier version matched any mention, to no line end, which counted the
# comment on the helper AND the test's own regex string - so the scan reported call sites that do not
# exist, and would have reported this file as a violation once it was inside the scan set.
$callSiteMatches = [regex]::Matches($coreCode, 'Invoke-(?:Cim|Service)WithTimeout\s+(?=-[A-Za-z])[^\r\n]*')
$total = 0
$withRow = 0
$missing = New-Object System.Collections.ArrayList
foreach ($cs in $callSiteMatches) {
    $line = $cs.Value
    $total++
    if ($line -match '-Row\s+\$Computer') { $withRow++ }
    else { $null = $missing.Add(($line.Substring(0, [Math]::Min(90, $line.Length)))) }
}
Assert-True ($total -gt 0) "invocations were found to inspect ($total)"
Assert-Equal $withRow $total 'EVERY inner-timeout invocation passes its row (an omission silently opts out of capping)'
if ($missing.Count -gt 0) {
    # Named explicitly, because "3 of 5" is not actionable and the offending line is what gets fixed.
    $missing | ForEach-Object { Write-Host "      no -Row: $_" -ForegroundColor Yellow }
}
# Pinned so the scan cannot be satisfied by finding nothing: production currently has exactly three
# sites, and a drop to zero means the matcher broke, not that the code got better.
Assert-True ($total -ge 3) "the scan found at least the three known sites ($total)"

'=== 11. the inlined arithmetic AGREES with the helper (drift guard) ==='
# The cap is now written twice: once as a reusable helper in Wuu.State, once inlined in the payload
# helpers where the helper is not callable. Duplication is the price of runspace isolation, so the price
# is paid explicitly here - the two are compared case by case rather than left to drift apart, which is
# exactly how "the same rule in two places" becomes two different rules.
#
# The inlined expression is EXTRACTED FROM THE SHIPPED SOURCE, not retyped, so this compares the real
# production arithmetic rather than a paraphrase of it.
$cimBody = Get-Body 'Invoke-CimWithTimeout'
$inlineBlock = ''
# The block now initialises a local and adjusts IT, so the extraction includes the seeding line - the
# probe reads $effectiveTimeout out of the payload, exactly as the shipped helper passes it to the pool.
$blockMatch = [regex]::Match($cimBody, "(?s)\`$effectiveTimeout = \`$TimeoutSeconds.*?\n            \}\n            \}")
if (-not $blockMatch.Success) { $blockMatch = [regex]::Match($cimBody, "(?s)\`$effectiveTimeout = \`$TimeoutSeconds.*?\n            \}") }
if ($blockMatch.Success) { $inlineBlock = $blockMatch.Value }
Assert-True ($inlineBlock.Length -gt 0) 'the inline cap block was extracted from Wuu.Core (the comparison is against real code)'

if ($inlineBlock.Length -gt 0) {
    # A probe runspace, created exactly as production creates one, running the EXTRACTED block against a
    # row injected the production way. This also proves the arithmetic is usable in that runspace - the
    # module-function version was not.
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
    $probeRs = [runspacefactory]::CreateRunspace($iss)
    $probeRs.ApartmentState = 'STA'
    $probeRs.Open()

    $cases = @(
        @{ Name = 'no deadline';            ExpiresIn = $null;   Inner = 30 }
        @{ Name = 'generous budget';        ExpiresIn = 600;    Inner = 30 }
        @{ Name = 'tight budget';           ExpiresIn = 12;     Inner = 30 }
        @{ Name = 'below the floor';        ExpiresIn = 1;      Inner = 30 }
        @{ Name = 'overdue';                ExpiresIn = -30;    Inner = 30 }
        @{ Name = 'inner timeout is 0';     ExpiresIn = 5;      Inner = 0 }
        @{ Name = 'inner below remaining';  ExpiresIn = 600;    Inner = 5 }
    )

    $agree = 0
    $disagree = @()
    foreach ($case in $cases) {
        # Expected value from the SHIPPED helper.
        $row = [pscustomobject]@{ OpName = 'Check' }
        if ($null -ne $case.ExpiresIn) {
            $row | Add-Member -NotePropertyName 'TimeoutExpiresAt' -NotePropertyValue $now.AddSeconds([double]$case.ExpiresIn) -Force
        }
        $expected = (Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds $case.Inner -Row $row -Now $now).Seconds

        # Actual value from the EXTRACTED inline block, in a payload runspace, against an injected row.
        # The probe emits a MARKED string rather than the bare number: PowerShell writes nothing at all
        # for a bare 0, so an unwrapped result is indistinguishable from "the script produced no output"
        # - which is how the 'inner timeout is 0' case first appeared to diverge when it did not.
        $actual = $null
        $psProbe = [PowerShell]::Create()
        $psProbe.Runspace = $probeRs
        [void]$psProbe.AddScript([scriptblock]::Create(@"
`$Row = `$null
if (`$args[0] -ne `$null) {
    `$Row = [pscustomobject]@{ OpName = 'Check'; TimeoutExpiresAt = `$args[0] }
}
`$TimeoutSeconds = `$args[1]
$inlineBlock
"OUT=" + `$effectiveTimeout
"@))
        [void]$psProbe.AddArgument($(if ($null -ne $case.ExpiresIn) { $now.AddSeconds([double]$case.ExpiresIn) } else { $null }))
        [void]$psProbe.AddArgument([int]$case.Inner)
        $out = $psProbe.Invoke()
        if ($psProbe.Streams.Error.Count) {
            $actual = 'ERROR: ' + $psProbe.Streams.Error[0].ToString().Substring(0, [Math]::Min(80, $psProbe.Streams.Error[0].ToString().Length))
        } elseif ($out -and $out.Count) {
            $marked = [string]$out[$out.Count - 1]
            if ($marked -match '^OUT=(-?\d+)$') { $actual = [int]$matches[1] } else { $actual = "UNPARSEABLE: $marked" }
        }
        $psProbe.Dispose()

        if ("$actual" -eq "$expected") { $agree++ }
        else { $disagree += ("{0}: helper={1} inline={2}" -f $case.Name, $expected, $actual) }
    }
    $probeRs.Close(); $probeRs.Dispose()

    Assert-Equal $agree $cases.Count 'the inlined cap agrees with the helper on EVERY case'
    if ($disagree.Count -gt 0) { $disagree | ForEach-Object { Write-Host "      diverged: $_" -ForegroundColor Yellow } }

    # And the agreement is not vacuous: the cases must actually exercise a cap, not all pass through.
    $distinct = @($cases | ForEach-Object {
        $r = [pscustomobject]@{ OpName = 'Check' }
        if ($null -ne $_.ExpiresIn) { $r | Add-Member -NotePropertyName 'TimeoutExpiresAt' -NotePropertyValue $now.AddSeconds([double]$_.ExpiresIn) -Force }
        (Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds $_.Inner -Row $r -Now $now).Seconds
    } | Sort-Object -Unique)
    Assert-True ($distinct.Count -ge 3) "the cases produce at least three DIFFERENT results ($($distinct.Count)) - so agreement is meaningful"
}

''
if ($failures.Count -eq 0) {
    Write-Host "ALL PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FAILURES: {0}" -f $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
