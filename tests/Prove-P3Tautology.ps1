# Tautology proof for the P3 additions (remaining-budget propagation + external audit anchoring).
#
# WHY: a check that passes on a tree where the behaviour is REMOVED proves nothing. Each mutation below
# removes a real behaviour and must be caught by BOTH the release gate and the behavioural suite. Anything
# that survives a mutation is decoration and is reported as such.
#
# MECHANICS, each of which cost a cycle the last time this was done:
#   * runs DETACHED via Start-Process with output to a file - the agent terminal reuses a single session and
#     a killed harness can leave the SOURCE MUTATED
#   * a startup SELF-HEAL restores any file left mutated by an earlier killed run
#   * every mutation is a COUNT-CHECKED literal replace, so a pattern that silently matches nothing
#     (which would make both checks "pass" on an unbroken tree) is itself a FAILURE
#   * per-run TIMEOUT, treated as a failure rather than a hang
#   * pure .NET SHA256 (Get-FileHash did not resolve in a Start-Process-launched child)
#   * BOM-PRESERVING writes, because a BOM-less rewrite makes the gate fail for the WRONG reason and hides
#     the result of the mutation under test
#
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Prove-P3Tautology.ps1
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$statePath = Join-Path $root 'src\Wuu.State.psm1'
$corePath = Join-Path $root 'src\Wuu.Core.psm1'
$auditPath = Join-Path $root 'src\Wuu.Audit.psm1'
$gatePath = Join-Path $root 'Scripts\Validate-Release.ps1'
$budgetSuite = Join-Path $root 'tests\Test-RemainingBudget.ps1'
$anchorSuite = Join-Path $root 'tests\Test-AuditAnchoring.ps1'

function Invoke-Check([string]$Command, [string[]]$Arguments, [int]$TimeoutMs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Command
    # $psi.ArgumentList does NOT exist on .NET Framework 4.x, which is what Windows PowerShell 5.1 runs
    # on - using it throws "You cannot call a method on a null-valued expression" before anything runs.
    # The arguments are quoted individually into the single Arguments string instead, since the paths and
    # filenames here contain spaces.
    $quoted = @()
    foreach ($a in $Arguments) {
        if ($a -match '[\s"]') { $quoted += '"' + ($a -replace '"', '\"') + '"' } else { $quoted += $a }
    }
    $psi.Arguments = ($quoted -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutMs)) {
        # A HANG IS A FAILURE. Blocking synchronisation primitives are one of the mutations this kind of
        # harness has used before, and a hung child that is never killed reports nothing at all.
        try { $proc.Kill() } catch { }
        return @{ TimedOut = $true; ExitCode = -1; Output = '' }
    }
    # Bounded wait for the async reads so a killed child cannot hang the harness.
    $null = $outTask.Wait(5000)
    $null = $errTask.Wait(5000)
    $text = ($outTask.Result + "`n" + $errTask.Result)
    return @{ TimedOut = $false; ExitCode = $proc.ExitCode; Output = $text }
}

function Get-Sha([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path))) -replace '-', '') }
    finally { $sha.Dispose() }
}
function Read-Text([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    # Read with the BOM stripped from the STRING so the text can be compared/replaced consistently; the
    # BOM is re-added on write based on what was there originally.
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($hadBom) { $text = $text.Substring(1) }
    return @{ Text = $text; HadBom = $hadBom }
}
function Write-Text([string]$Path, [string]$Text, [bool]$HadBom) {
    $enc = New-Object System.Text.UTF8Encoding($HadBom)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# ---- BACKUP, NOT git checkout -----------------------------------------------------------------
# An interrupted run can leave a source file MUTATED, and the next run's baseline would then be captured
# from the broken state. The fix is NOT `git checkout --`: this harness runs against work that may not be
# committed yet, and discarding uncommitted work is forbidden here (it has destroyed a working tree
# before). Instead:
#   1. byte-copy every file it will touch into a UNIQUE per-run directory, with SHA-256 recorded
#   2. VERIFY the tree is healthy BEFORE mutating anything - if it is not, stop and say so rather than
#      "healing" from a state that may already be broken
#   3. restore from that copy after every mutation, and verify the hash came back
$backupDir = Join-Path ([System.IO.Path]::GetTempPath()) ('wuu-tautology-backup-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $backupDir -Force
$backup = @{}
foreach ($p in @($statePath, $corePath, $auditPath, $gatePath)) {
    $copy = Join-Path $backupDir (Split-Path $p -Leaf)
    Copy-Item -LiteralPath $p -Destination $copy -Force
    $backup[$p] = @{ Copy = $copy; Sha = (Get-Sha $p); ShaCopy = (Get-Sha $copy) }
    if ($backup[$p].Sha -ne $backup[$p].ShaCopy) {
        Write-Host "BACKUP FAILED: the copy of $(Split-Path $p -Leaf) does not match the original - refusing to run" -ForegroundColor Red
        exit 1
    }
}
Write-Host "backed up $($backup.Count) files to $backupDir (all copies hash-verified)" -ForegroundColor DarkGray

function Restore-FromBackup([string]$Path) {
    Copy-Item -LiteralPath $backup[$Path].Copy -Destination $Path -Force
    return ((Get-Sha $Path) -eq $backup[$Path].Sha)
}

# ---- PRE-FLIGHT: the tree must be HEALTHY before it is mutated ---------------------------------
# Mutating a broken tree produces failures that have nothing to do with the mutation, so every "CAUGHT"
# below would be meaningless. This also catches a previous run that died mid-mutation.
Write-Host ''
Write-Host '=== PRE-FLIGHT: the tree must already be green ===' -ForegroundColor Cyan
$preGate = Invoke-Check 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $gatePath) 900000
$preBud = Invoke-Check 'powershell.exe' @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $budgetSuite) 300000
$preAnc = Invoke-Check 'powershell.exe' @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $anchorSuite) 300000
$preOk = ($preGate.ExitCode -eq 0) -and ($preBud.ExitCode -eq 0) -and ($preAnc.ExitCode -eq 0) -and -not $preGate.TimedOut
if (-not $preOk) {
    Write-Host "  gate=$($preGate.ExitCode) budget=$($preBud.ExitCode) anchor=$($preAnc.ExitCode) - the tree is NOT green, so mutations cannot be attributed" -ForegroundColor Red
    Write-Host "  restore the real source from your own backup before running this harness. Refusing to mutate." -ForegroundColor Red
    exit 1
}
Write-Host '  gate, budget suite and anchor suite are all green - mutations will be attributable' -ForegroundColor Green

$baseline = @{}
foreach ($p in @($statePath, $corePath, $auditPath)) { $baseline[$p] = Get-Sha $p }
foreach ($p in @($statePath, $corePath, $auditPath)) { Write-Host ("  baseline {0} {1}" -f (Split-Path $p -Leaf), $baseline[$p].Substring(0, 16)) }

# ---- THE MUTATIONS -----------------------------------------------------------------------------
# Detection needles are EXACT phrases from the messages the gate and suite emit, never the mutation token
# itself: the mutation token is also present in the source, so searching for it would report a detection
# that did not happen.
$mutations = @(
    @{
        Name = 'M1: drop -Row from an inner-timeout call site'
        File = $corePath
        From = "Invoke-CimWithTimeout -ComputerName `$Computer.computer -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 5 -Operation 'WMI connectivity test' -Row `$Computer"
        To   = "Invoke-CimWithTimeout -ComputerName `$Computer.computer -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 5 -Operation 'WMI connectivity test'"
        Needle = 'omit -Row'
        Suites = @($budgetSuite)
    },
    @{
        Name = 'M2: fabricate a zero budget when no deadline is recorded'
        File = $statePath
        From = "`$result = @{ Known = `$false; Remaining = `$null; Op = ''; ExpiresAt = `$null }"
        To   = "`$result = @{ Known = `$true; Remaining = 0; Op = ''; ExpiresAt = `$null }"
        Needle = 'no recorded deadline had its inner timeout changed'
        Suites = @($budgetSuite)
    },
    @{
        Name = 'M3: pass the UNCAPPED timeout to the pool'
        File = $corePath
        From = "-ArgumentList @(`$ComputerName, `$ClassName, `$Credential) -TimeoutSeconds `$effectiveTimeout -OperationName `$Operation"
        To   = "-ArgumentList @(`$ComputerName, `$ClassName, `$Credential) -TimeoutSeconds `$TimeoutSeconds -OperationName `$Operation"
        Needle = 'does not PASS it to the pool'
        Suites = @($budgetSuite)
    },
    @{
        Name = 'M4: remove the same-directory anchor refusal'
        File = $auditPath
        # SINGLE-quoted: the source line contains both " and ', and single quotes need only doubling.
        # Writing this in a double-quoted string put `" and `' next to each other and broke the parse.
        From = '$result.Reason = "anchor refused: the anchor directory is the log''s own directory (''$logDir''), so it offers no separation from the log it anchors"'
        To   = '$result.Reason = "anchor written anywhere the caller asks"'
        Needle = 'offers no separation'
        Suites = @($anchorSuite)
    },
    @{
        Name = 'M5: call a module function from the payload helper (throws in production)'
        File = $corePath
        From = "`$effectiveTimeout = `$TimeoutSeconds`r`n            if (`$TimeoutSeconds -gt 0 -and `$null -ne `$Row) {"
        To   = "`$effectiveTimeout = (Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds `$TimeoutSeconds -Row `$Row).Seconds`r`n            if (`$false) {"
        Needle = 'CALLS a module function'
        Suites = @($budgetSuite)
    }
)

$results = New-Object System.Collections.ArrayList
$restoreBroke = $false
foreach ($m in $mutations) {
    Write-Host ''
    Write-Host "=== $($m.Name) ===" -ForegroundColor Cyan
    $read = Read-Text $m.File
    $occurrences = ([regex]::Matches($read.Text, [regex]::Escape($m.From))).Count
    if ($occurrences -ne 1) {
        # A mutation that matches nothing (or everything) would edit nothing, and the check would then
        # "pass" against a HEALTHY tree - reporting success for a proof that never ran.
        Write-Host "  HARNESS FAIL: the mutation pattern matched $occurrences times (exactly 1 required) - nothing was mutated" -ForegroundColor Red
        $null = $results.Add(@{ Name = $m.Name; Verdict = 'HARNESS-FAIL'; Gate = '-'; Suite = '-' })
        continue
    }
    try {
        Write-Text $m.File $read.Text.Replace($m.From, $m.To) $read.HadBom
        if ((Get-Sha $m.File) -eq $baseline[$m.File]) {
            Write-Host '  HARNESS FAIL: the file hash did not change - the mutation was a no-op' -ForegroundColor Red
            $null = $results.Add(@{ Name = $m.Name; Verdict = 'HARNESS-FAIL'; Gate = '-'; Suite = '-' })
            continue
        }

        $gateRes = Invoke-Check 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $gatePath) 900000
        $gateCaught = (-not $gateRes.TimedOut) -and $gateRes.ExitCode -ne 0 -and ($gateRes.Output -like "*$($m.Needle)*")
        if ($gateRes.TimedOut) { Write-Host '  gate TIMED OUT (treated as not-caught)' -ForegroundColor Yellow }

        $suiteCaughtAll = $true
        $suiteNames = @()
        foreach ($s in $m.Suites) {
            $sRes = Invoke-Check 'powershell.exe' @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $s) 300000
            $sCaught = (-not $sRes.TimedOut) -and $sRes.ExitCode -ne 0
            $suiteNames += ("{0}={1}" -f (Split-Path $s -Leaf), $(if ($sRes.TimedOut) { 'TIMEOUT' } elseif ($sCaught) { 'CAUGHT' } else { 'MISSED' }))
            if (-not $sCaught) { $suiteCaughtAll = $false }
        }

        $verdict = if ($gateCaught -and $suiteCaughtAll) { 'CAUGHT' } elseif ($gateCaught -or $suiteCaughtAll) { 'PARTIAL' } else { 'MISSED' }
        $colour = switch ($verdict) { 'CAUGHT' { 'Green' } 'PARTIAL' { 'Yellow' } default { 'Red' } }
        Write-Host ("  gate={0}  suites={1}  => {2}" -f $(if ($gateCaught) { 'CAUGHT' } else { 'MISSED' }), ($suiteNames -join ', '), $verdict) -ForegroundColor $colour
        if ($verdict -ne 'CAUGHT') {
            # The needle tells us WHY the gate missed: it may have failed for an unrelated reason, which
            # would make a green "it failed" reading meaningless.
            Write-Host "  gate output (last 400 chars): $(($gateRes.Output.Trim() -split "`n" | Select-Object -Last 4) -join ' / ')" -ForegroundColor DarkGray
        }
        $null = $results.Add(@{ Name = $m.Name; Verdict = $verdict; Gate = $(if ($gateCaught) { 'CAUGHT' } else { 'MISSED' }); Suite = ($suiteNames -join ', ') })
    } finally {
        # ALWAYS restore, byte-for-byte, and verify the hash came back. It restores the ORIGINAL BYTES
        # rather than re-writing the text captured before the mutation: that text was read with the BOM
        # stripped and re-added on write, so a text round-trip is only BOM-equivalent, not byte-equivalent,
        # and a byte comparison after it could fail for a reason that has nothing to do with the mutation.
        # A harness that leaves the tree mutated is worse than no harness at all.
        #
        # NOTE: `break` is ILLEGAL inside a finally block ("Flow of control cannot leave a Finally
        # block"), so the failure is recorded in a flag and acted on after the try/finally - otherwise the
        # harness does not even parse, which it did when this was first written.
        $restored = Restore-FromBackup $m.File
        if (-not $restored -or (Get-Sha $m.File) -ne $baseline[$m.File]) {
            Write-Host '  RESTORE FAILED - source hash does not match baseline' -ForegroundColor Red
            $restoreBroke = $true
        } else {
            Write-Host '  restored (byte hash verified)' -ForegroundColor DarkGray
        }
    }
    if ($restoreBroke) {
        Write-Host '  stopping immediately - the tree is no longer trustworthy for further mutations' -ForegroundColor Red
        break
    }
}

Write-Host ''
Write-Host '=== FINAL HASH CHECK ===' -ForegroundColor Cyan
$allClean = $true
foreach ($p in @($statePath, $corePath, $auditPath)) {
    $now = Get-Sha $p
    $ok = ($now -eq $baseline[$p])
    if (-not $ok) { $allClean = $false }
    Write-Host ("  {0,-18} {1}" -f (Split-Path $p -Leaf), $(if ($ok) { 'unchanged' } else { 'CHANGED - restore from git' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}

Write-Host ''
Write-Host '=== SUMMARY ===' -ForegroundColor Cyan
$results | ForEach-Object { Write-Host ("  {0,-62} {1}" -f $_.Name, $_.Verdict) -ForegroundColor $(switch ($_.Verdict) { 'CAUGHT' { 'Green' } 'PARTIAL' { 'Yellow' } default { 'Red' } }) }
$caught = @($results | Where-Object { $_.Verdict -eq 'CAUGHT' }).Count
$harnessFail = @($results | Where-Object { $_.Verdict -eq 'HARNESS-FAIL' }).Count
Write-Host ''
Write-Host ("  {0}/{1} mutations caught by BOTH gate and suite; {2} harness failures; source state: {3}" -f $caught, $mutations.Count, $harnessFail, $(if ($allClean) { 'clean' } else { 'NOT CLEAN' })) -ForegroundColor $(if ($caught -eq $mutations.Count -and $allClean -and $harnessFail -eq 0) { 'Green' } else { 'Red' })

if ($caught -eq $mutations.Count -and $allClean -and $harnessFail -eq 0) { exit 0 } else { exit 1 }
