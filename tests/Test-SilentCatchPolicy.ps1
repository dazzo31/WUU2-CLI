# Test: the silent-catch policy (reviewer P2 - "a release gate could even reject empty catches outside
# a small allowlist").
#
# WHY THIS SUITE EXISTS
# ---------------------
# A catch whose body performs no statement turns a fault into apparent success: the caller cannot tell
# "nothing to do" from "the work failed". That is the shape that hides real failures. But some
# silences are CORRECT - a disposal failure must not mask the original error, and a logging failure
# cannot be logged - so the rule cannot be "no silent catches". It is "no UNJUSTIFIED silent catches".
#
# This suite asserts:
#   1. the detector FINDS silences at all (driven with synthetic input, so a passing result is
#      evidence rather than luck) - and specifically that it finds the MULTI-LINE form, which is the
#      form the real code uses and the form an earlier broken detector could not see
#   2. it does NOT flag a catch with a real body, nor a documented (comment-only) silence
#   3. every allowlist entry states WHY it is allowed (an entry without a justification is
#      indistinguishable from "we stopped looking")
#   4. the guard walk-back finds the guarded statement, and does not cross a function boundary
#   5. THE REAL TREE: every silent catch is either documented or allowlisted. This is the assertion
#      the release gate also makes - both call the same shared policy, so they cannot disagree.
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-SilentCatchPolicy.ps1
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

. (Join-Path $root 'Scripts\Wuu.CatchAudit.ps1')

'=== 1. the detector FINDS the multi-line silent form (synthetic, so this means something) ==='
# The multi-line form is what the real code uses, and it is the form an earlier detector could not see:
# `    } catch {` contains both a closing brace (ending the try) and an opening brace (starting the
# catch), so naive brace counting from the start of the line computed depth 0 and collected no body -
# reporting 194 "silent" catches that all had real bodies.
$multiLine = @'
function Something {
    try {
        Do-Work
    } catch {
    }
}
'@
$foundMulti = @(Get-WuuSilentCatch -Text $multiLine)
Assert-Equal $foundMulti.Count 1 'a multi-line empty catch is found'
Assert-Equal $foundMulti[0].Kind 'empty' 'and is classified as empty (no statement, no comment)'

$multiLineComment = @'
function Something {
    try {
        Do-Work
    } catch {
        # The work is best-effort; there is nothing to recover.
    }
}
'@
$foundDoc = @(Get-WuuSilentCatch -Text $multiLineComment)
Assert-Equal $foundDoc.Count 1 'a comment-only catch is still FOUND (it is a silence)'
Assert-Equal $foundDoc[0].Kind 'comment-only' 'but is classified as documented'

$inlineEmpty = @'
function Something {
    try { Do-Work } catch { }
}
'@
$foundInline = @(Get-WuuSilentCatch -Text $inlineEmpty)
Assert-Equal $foundInline.Count 1 'an inline `catch { }` is found'
Assert-Equal $foundInline[0].Kind 'inline-empty' 'and is classified as an inline empty'

'=== 2. a catch with a REAL body is NOT flagged ==='
$realBody = @'
function Something {
    try {
        Do-Work
    } catch {
        Write-WarningLog "failed: $($_.Exception.Message)"
    }
}
'@
Assert-Equal @(Get-WuuSilentCatch -Text $realBody).Count 0 'a catch that logs is not flagged'

$multiStatement = @'
function Something {
    try {
        Do-Work
    } catch {
        $failed = $true
        return $null
    }
}
'@
Assert-Equal @(Get-WuuSilentCatch -Text $multiStatement).Count 0 'a catch with several statements is not flagged'

$nestedBraces = @'
function Something {
    try {
        Do-Work
    } catch {
        $h = @{ a = 1 }
    }
}
'@
Assert-Equal @(Get-WuuSilentCatch -Text $nestedBraces).Count 0 'a catch whose body contains braces is not mistaken for empty'

'=== 3. the guard walk-back finds what is guarded, without crossing a function boundary ==='
$guarded = @(Get-WuuSilentCatch -Text $multiLine)
Assert-True ($guarded[0].Guarded -like '*Do-Work*') "the guarded statement is found ($($guarded[0].Guarded))"

$acrossBoundary = @'
function A {
    try { Do-Work } catch { }
}
function B {
    try { Other-Work } catch { }
}
'@
$both = @(Get-WuuSilentCatch -Text $acrossBoundary)
Assert-Equal $both.Count 2 'two functions each contribute their own silence'

'=== 4. the policy ACCEPTS the correct silences and REFUSES an unjustified one ==='
$ok = Test-WuuSilentCatchAllowed -Guarded 'try { Write-WarningLog "x" }' -Body ''
Assert-True $ok.Allowed "best-effort logging is allowed ($($ok.Reason))"

$okRelease = Test-WuuSilentCatchAllowed -Guarded 'try { $ps.Dispose() }' -Body ''
Assert-True $okRelease.Allowed "resource release is allowed ($($okRelease.Reason))"

$okMon = Test-WuuSilentCatchAllowed -Guarded 'try { [System.Threading.Monitor]::Exit($gate) }' -Body ''
Assert-True $okMon.Allowed "lock release is allowed ($($okMon.Reason))"

$okDoc = Test-WuuSilentCatchAllowed -Guarded 'try { Do-Something }' -Body '# best effort by design'
Assert-True $okDoc.Allowed "a documented silence is allowed ($($okDoc.Reason))"

# THE FALSE-NEGATIVE CONTROL. Without this, a policy that allowed everything would pass every check
# above and the real-tree assertion below would be meaningless.
$bad = Test-WuuSilentCatchAllowed -Guarded 'try { Invoke-CriticalWork }' -Body ''
Assert-False $bad.Allowed 'an UNJUSTIFIED silence is refused'
Assert-True ($bad.Reason -like '*no allowlist entry*') "the refusal says why ($($bad.Reason))"

'=== 5. every allowlist entry states WHY it is allowed ==='
$allow = @(Get-WuuSilentCatchAllowlist)
Assert-True ($allow.Count -ge 4) "the allowlist is non-trivial ($($allow.Count) entries)"
Assert-True ($allow.Count -le 12) "the allowlist is SMALL ($($allow.Count) entries) - a large one would mean the policy stopped looking"
foreach ($e in $allow) {
    Assert-True (($null -ne $e.Name) -and $e.Name -ne '') 'each entry has a Name'
    Assert-True (($null -ne $e.Pattern) -and $e.Pattern -ne '') "each entry has a Pattern ($($e.Name))"
    Assert-True (($null -ne $e.Why) -and $e.Why.Length -gt 20) "each entry states WHY ($($e.Name) : $($e.Why.Length) chars)"
}

'=== 6. THE REAL TREE: no unjustified silence ==='
$treeFindings = @()
$treeTotal = 0
$treeAllowed = 0
$byReason = @{}
foreach ($file in Get-ChildItem (Join-Path $root 'src\*.psm1') | Sort-Object Name) {
    $text = [System.IO.File]::ReadAllText($file.FullName)
    foreach ($c in (Get-WuuSilentCatch -Text $text)) {
        $treeTotal++
        $verdict = Test-WuuSilentCatchAllowed -Guarded $c.Guarded -Body $c.Body
        if ($verdict.Allowed) {
            $treeAllowed++
            $key = $verdict.Reason
            if (-not $byReason.ContainsKey($key)) { $byReason[$key] = 0 }
            $byReason[$key]++
        } else {
            $treeFindings += "  $($file.Name) L$($c.Line) [$($c.Kind)] : $($verdict.Reason)"
        }
    }
}

Write-Host ("  scanned: $treeTotal silent catch(es), $treeAllowed justified") -ForegroundColor Gray
$byReason.Keys | Sort-Object | ForEach-Object { Write-Host ("    {0,-62} {1}" -f $_, $byReason[$_]) -ForegroundColor Gray }

Assert-True ($treeTotal -gt 0) "the scan actually found silences to judge ($treeTotal)"
if ($treeFindings.Count -gt 0) {
    Write-Host ("FAIL: {0} unjustified silent catch(es) in src/" -f $treeFindings.Count) -ForegroundColor Red
    $treeFindings | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    $script:failures += "unjustified silent catches: $($treeFindings.Count)"
} else {
    Write-Host 'PASS: every silent catch in src/ is documented or allowlisted' -ForegroundColor Green
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
