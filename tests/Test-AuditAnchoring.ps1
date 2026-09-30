# Test: external audit anchoring (reviewer P3).
#
# WHY THIS SUITE EXISTS
# ---------------------
# A hash-chained log is tamper-EVIDENT only to someone who already knows what the head was. Anyone with
# write access to the log AND the code can recompute a complete, internally consistent chain over their
# own edits - every hash matches, and Test-WuuAuditChain reports a clean log. That is a property of every
# hash chain, not a defect in this one, and no amount of additional hashing fixes it. The fix is putting
# the head SOMEWHERE THE LOG'S EDITOR DOES NOT CONTROL, and then comparing.
#
# THE ASSERTION THAT MATTERS is the forged-chain one below: a rebuilt chain - produced by the REAL audit
# writer, so it is arithmetically perfect - verifies clean on its own terms, and only the anchor catches
# it. Without that, the anchoring code would be decoration.
#
# THE FIXTURES USE THE REAL WRITER (Start-WuuAuditSession + Write-WuuAuditRecord). An earlier version
# hand-built records and computed the hash before adding PrevHash, so the "clean" fixture did not verify
# at all and the forged-chain assertion could not be demonstrated. A fixture that reimplements the format
# tests the reimplementation, not the product.
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-AuditAnchoring.ps1
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
# The REAL topology: Core pulls in the whole set via Import-WuuModules (-Global). A bare
# Import-Module of Wuu.Audit alone leaves the audit module unable to reach New-WuuOperatorContext in
# Wuu.State, so the fixture writer fails before a single assertion runs. Same bootstrap as Test-AuditTrail.
Import-WuuModules -WuuRoot $root

# A dedicated temp tree. The anchor MUST live in a DIFFERENT directory from the log - the whole control is
# the separation - so the fixture creates the log and anchor trees side by side.
$base = Join-Path ([System.IO.Path]::GetTempPath()) ('wuu-anchor-' + [guid]::NewGuid().ToString('N'))
$realDir = Join-Path $base 'real'
$forgedDir = Join-Path $base 'forged'
$anchorDir = Join-Path $base 'anchors'
$null = New-Item -ItemType Directory -Path $realDir, $forgedDir, $anchorDir -Force

function New-RealLog([string]$Directory, [string[]]$Messages) {
    # Uses the REAL writer, so the chain is valid by construction.
    $session = Start-WuuAuditSession -Directory $Directory -Action 'test-session'
    foreach ($m in $Messages) {
        $null = Write-WuuAuditRecord -Session $session -Action 'test-event' -Category 'operational' -Result 'info' -Parameters @{ message = $m }
    }
    return (Join-Path $Directory ("audit-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd')))
}

'=== 1. the real writer produces a clean chain, and the anchor records its head ==='
$logPath = New-RealLog -Directory $realDir -Messages @('one', 'two', 'three')
Assert-True (Test-Path -LiteralPath $logPath) "the fixture log exists ($logPath)"
$chainOk = Test-WuuAuditChain -LogPath $logPath -Quiet
Assert-True $chainOk.Ok 'the fixture chain verifies clean (built by the real writer, so the fixture is real)'

$anchorPath = Join-Path $anchorDir 'audit-anchor.json'
$anchor = New-WuuAuditAnchor -LogPath $logPath -AnchorPath $anchorPath -Operator 'TEST'
Assert-True $anchor.Written "the anchor was written ($($anchor.Reason))"
Assert-True ($anchor.Seq -gt 0) "the anchor recorded a head sequence number ($($anchor.Seq))"
Assert-True ($anchor.Hash.Length -ge 32) 'the anchor recorded a head hash'

$verdict = Test-WuuAuditAnchor -LogPath $logPath -AnchorPath $anchorPath
Assert-True $verdict.Available 'the anchor is available for comparison'
Assert-True $verdict.Consistent 'an unchanged log compares as consistent'
Assert-False $verdict.Rewritten 'and is not reported as rewritten'

'=== 2. an APPENDED log still compares as consistent (growth is not tampering) ==='
$appendSession = Start-WuuAuditSession -Directory $realDir -Action 'test-session-2'
$null = Write-WuuAuditRecord -Session $appendSession -Action 'test-event' -Category 'operational' -Result 'info' -Parameters @{ message = 'four' }
$null = Write-WuuAuditRecord -Session $appendSession -Action 'test-event' -Category 'operational' -Result 'info' -Parameters @{ message = 'five' }

$grown = Test-WuuAuditAnchor -LogPath $logPath -AnchorPath $anchorPath
Assert-True $grown.Consistent 'a log that GREW still compares as consistent (appending is not tampering)'
Assert-True ($grown.CurrentSeq -gt $grown.AnchoredSeq) "the current head advanced past the anchor ($($grown.CurrentSeq) > $($grown.AnchoredSeq))"

'=== 3. A FORGED CHAIN VERIFIES CLEAN AND IS CAUGHT ONLY BY THE ANCHOR ==='
# The assertion the feature exists for. The forged log is written by the SAME real writer, so it is
# arithmetically perfect: every hash correct, every link intact.
$forgedLog = New-RealLog -Directory $forgedDir -Messages @('FORGED-1', 'FORGED-2', 'FORGED-3', 'FORGED-4')
$forgedChain = Test-WuuAuditChain -LogPath $forgedLog -Quiet
Assert-True $forgedChain.Ok 'the FORGED chain verifies CLEAN - which is why hash verification alone cannot detect a rebuild'

$forgedVerdict = Test-WuuAuditAnchor -LogPath $forgedLog -AnchorPath $anchorPath
Assert-True $forgedVerdict.Rewritten 'the ANCHOR catches a chain that hash verification passed'
Assert-False $forgedVerdict.Consistent 'and does not call it consistent'
Assert-True ($forgedVerdict.Reason -like '*rewritten*' -or $forgedVerdict.Reason -like '*replaced*' -or $forgedVerdict.Reason -like '*different*') "the anchor names the finding ($($forgedVerdict.Reason))"

'=== 4. truncation and same-length replacement are both rewrites ==='
# Truncation: a log with FEWER records than the anchor recorded.
$truncDir = Join-Path $base 'trunc'
$null = New-Item -ItemType Directory -Path $truncDir -Force
$truncLog = New-RealLog -Directory $truncDir -Messages @('only-one')
$truncVerdict = Test-WuuAuditAnchor -LogPath $truncLog -AnchorPath $anchorPath
Assert-True $truncVerdict.Rewritten 'a TRUNCATED log is reported as rewritten'
Assert-True ($truncVerdict.Reason -like '*SHORTER*') "the truncation is named ($($truncVerdict.Reason))"

# Same LENGTH, different content: the case a length check alone misses entirely.
$swapDir = Join-Path $base 'swap'
$null = New-Item -ItemType Directory -Path $swapDir -Force
$swapLog = New-RealLog -Directory $swapDir -Messages @('a', 'b', 'c', 'd')
$swapVerdict = Test-WuuAuditAnchor -LogPath $swapLog -AnchorPath $anchorPath
Assert-True $swapVerdict.Rewritten 'a SAME-LENGTH replacement is reported as rewritten (not missed by a length check)'

'=== 5. an anchor in the log''s own directory is REFUSED ==='
# Separation IS the control: an anchor beside the log is written by the same access path as the log, so it
# proves nothing and would create a false sense of external anchoring.
$sillyAnchor = Join-Path $realDir 'anchor-beside-the-log.json'
$refused = New-WuuAuditAnchor -LogPath $logPath -AnchorPath $sillyAnchor -Operator 'TEST'
Assert-False $refused.Written 'an anchor in the log''s own directory is refused'
Assert-True ($refused.Reason -like '*no separation*') "the refusal explains why ($($refused.Reason))"
Assert-False (Test-Path -LiteralPath $sillyAnchor) 'and nothing was written'

'=== 6. the anchor records its own limits, so nobody has to infer them ==='
$anchorJson = Get-Content -LiteralPath $anchorPath -Raw | ConvertFrom-Json
Assert-Equal $anchorJson.Schema 'wuu.audit.anchor.v1' 'the anchor declares its schema'
Assert-True ($anchorJson.Claim -like '*NOT non-repudiation*') "the anchor states what it is NOT ($($anchorJson.Claim))"
Assert-True ($anchorJson.Note -like '*writable by the same account*') 'the anchor tells the holder what makes it useless'

# A missing anchor must be reported as UNAVAILABLE, not as consistent - absence of evidence is not
# evidence of integrity.
$missingVerdict = Test-WuuAuditAnchor -LogPath $logPath -AnchorPath (Join-Path $anchorDir 'nope.json')
Assert-False $missingVerdict.Available 'a missing anchor is unavailable'
Assert-False $missingVerdict.Consistent 'and is NOT reported as consistent'
Assert-True ($missingVerdict.Reason -like '*undetectable*') "and says what that means ($($missingVerdict.Reason))"

try { Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue } catch { }

''
if ($failures.Count -eq 0) {
    Write-Host "ALL PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FAILURES: {0}" -f $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
