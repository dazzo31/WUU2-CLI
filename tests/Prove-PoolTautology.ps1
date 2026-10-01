# Tautology proof for the pool-versus-cap invariant (P3 close-out).
#
# WHY: this invariant was a REAL DEFECT that had shipped - cap 10, pool 8, so two admitted operations had
# probes that could never start. A check that passes on a tree where the defect is restored proves
# nothing, so each mutation below puts the defect back (or disables the check) and must be caught by BOTH
# the release gate and the behavioural suite. Anything that survives a mutation is decoration.
#
# MECHANICS, each of which cost a cycle on the previous harness:
#   * runs DETACHED-friendly with output to a file - the agent terminal reuses one session and a killed
#     harness can leave the SOURCE MUTATED
#   * backup by BYTE COPY (never `git checkout --`: this runs against work that may be uncommitted)
#   * a PRE-FLIGHT that refuses to run unless the tree is already green, because a mutation on a broken
#     tree produces failures that cannot be attributed to the mutation
#   * every mutation is a COUNT-CHECKED literal replace, so a pattern that matches nothing (which would
#     make both checks "pass" on an unbroken tree) is itself a FAILURE
#   * per-run TIMEOUT, treated as a failure rather than a hang
#   * pure .NET SHA256 (Get-FileHash does not resolve in a Start-Process child on this host)
#   * restore from the ORIGINAL BYTES after every mutation, hash-verified
#
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Prove-PoolTautology.ps1
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$workersPath = Join-Path $root 'src\Wuu.Workers.psm1'
$corePath = Join-Path $root 'src\Wuu.Core.psm1'
$gatePath = Join-Path $root 'Scripts\Validate-Release.ps1'
$poolSuite = Join-Path $root 'tests\Test-PoolCompatibility.ps1'

function Invoke-Check([string]$Command, [string[]]$Arguments, [int]$TimeoutMs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Command
    # $psi.ArgumentList does NOT exist on .NET Framework 4.x (.NET Framework, which Windows PowerShell
    # 5.1 runs on) - using it throws "You cannot call a method on a null-valued expression".
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
        # A HANG IS A FAILURE, not a wait.
        try { $proc.Kill() } catch { }
        return @{ TimedOut = $true; ExitCode = -1; Output = '' }
    }
    $null = $outTask.Wait(5000)
    $null = $errTask.Wait(5000)
    return @{ TimedOut = $false; ExitCode = $proc.ExitCode; Output = ($outTask.Result + "`n" + $errTask.Result) }
}

function Get-Sha([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path))) -replace '-', '') }
    finally { $sha.Dispose() }
}
function Read-Text([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($hadBom) { $text = $text.Substring(1) }
    return @{ Text = $text; HadBom = $hadBom }
}
function Write-Text([string]$Path, [string]$Text, [bool]$HadBom) {
    $enc = New-Object System.Text.UTF8Encoding($HadBom)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# ---- BACKUP (byte copy, never git checkout) -----------------------------------------------------
$backupDir = Join-Path ([System.IO.Path]::GetTempPath()) ('wuu-pool-tautology-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $backupDir -Force
$backup = @{}
foreach ($p in @($workersPath, $corePath, $gatePath)) {
    $copy = Join-Path $backupDir (Split-Path $p -Leaf)
    Copy-Item -LiteralPath $p -Destination $copy -Force
    $backup[$p] = @{ Copy = $copy; Sha = (Get-Sha $p) }
    if ((Get-Sha $copy) -ne $backup[$p].Sha) {
        Write-Host "BACKUP FAILED for $(Split-Path $p -Leaf) - refusing to run" -ForegroundColor Red
        exit 1
    }
}
Write-Host "backed up $($backup.Count) files to $backupDir (byte-verified)" -ForegroundColor DarkGray

function Restore-FromBackup([string]$Path) {
    Copy-Item -LiteralPath $backup[$Path].Copy -Destination $Path -Force
    return ((Get-Sha $Path) -eq $backup[$Path].Sha)
}

# ---- PRE-FLIGHT ---------------------------------------------------------------------------------
Write-Host ''
Write-Host '=== PRE-FLIGHT: the tree must already be green ===' -ForegroundColor Cyan
$preGate = Invoke-Check 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $gatePath) 900000
$preSuite = Invoke-Check 'powershell.exe' @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $poolSuite) 300000
if ($preGate.ExitCode -ne 0 -or $preSuite.ExitCode -ne 0 -or $preGate.TimedOut) {
    Write-Host "  gate=$($preGate.ExitCode) suite=$($preSuite.ExitCode) - the tree is NOT green, so a mutation's effect cannot be attributed" -ForegroundColor Red
    Write-Host '  restore the real source from your own backup first. Refusing to mutate.' -ForegroundColor Red
    exit 1
}
Write-Host '  gate and suite are both green - mutations will be attributable' -ForegroundColor Green

$baseline = @{}
foreach ($p in @($workersPath, $corePath)) { $baseline[$p] = Get-Sha $p }
foreach ($p in @($workersPath, $corePath)) { Write-Host ("  baseline {0,-20} {1}" -f (Split-Path $p -Leaf), $baseline[$p].Substring(0, 16)) }

# ---- THE MUTATIONS ------------------------------------------------------------------------------
# Detection needles are EXACT phrases from the messages the gate and suite emit, never the mutation
# token - the token is also present in the source, so searching for it would report a detection that
# did not happen.
$mutations = @(
    @{
        Name = 'M1: shrink the pool back below the cap (the shipped defect)'
        File = $workersPath
        From = '[int]$script:MaxPoolSize = 10'
        To   = '[int]$script:MaxPoolSize = 8'
        Needle = 'SMALLER than the concurrency cap'
        Suites = @($poolSuite)
    },
    @{
        Name = 'M2: raise the cap above the pool'
        File = $corePath
        From = '$global:MaxConcurrentJobs = 10'
        To   = '$global:MaxConcurrentJobs = 12'
        Needle = 'SMALLER than the concurrency cap'
        Suites = @($poolSuite)
    },
    @{
        Name = 'M3: drop the export, so the invariant has no verifier'
        File = $workersPath
        # REMOVES the entry. An earlier draft ADDED a placeholder name instead, which left the real export
        # in place - a mutation that changes nothing, and the harness would have reported CAUGHT against
        # an unbroken tree if the added name had happened to appear in an unrelated message.
        From = "`r`n    'Test-PoolCompatibility'`r`n)"
        To   = "`r`n)"
        Needle = 'not exported from Wuu.Workers'
        Suites = @($poolSuite)
    },
    @{
        Name = 'M4: invert the comparison, so a smaller pool reads as compatible'
        File = $workersPath
        From = '$compatible = ($MaxConcurrentJobs -gt 0) -and ($capacity -ge $MaxConcurrentJobs)'
        To   = '$compatible = ($MaxConcurrentJobs -gt 0) -and ($capacity -le $MaxConcurrentJobs)'
        # NO NEEDLE, deliberately. Inverting the comparison does not necessarily change any MESSAGE, so
        # requiring a phrase would report a miss for a check that noticed through DRIVING it. The gate
        # drives Test-PoolCompatibility against the live values, so an inversion must make it fail.
        Needle = ''
        Suites = @($poolSuite)
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
        # A mutation that matches nothing would edit nothing, and the check would then "pass" against a
        # HEALTHY tree - reporting success for a proof that never ran.
        Write-Host "  HARNESS FAIL: the pattern matched $occurrences times (exactly 1 required) - nothing was mutated" -ForegroundColor Red
        $null = $results.Add(@{ Name = $m.Name; Verdict = 'HARNESS-FAIL'; Detail = "matched $occurrences" })
        continue
    }
    $gateCaught = $false
    $suiteCaught = $false
    $detail = ''
    try {
        Write-Text $m.File $read.Text.Replace($m.From, $m.To) $read.HadBom
        if ((Get-Sha $m.File) -eq $baseline[$m.File]) {
            Write-Host '  HARNESS FAIL: the file hash did not change - the mutation was a no-op' -ForegroundColor Red
            $null = $results.Add(@{ Name = $m.Name; Verdict = 'HARNESS-FAIL'; Detail = 'no hash change' })
            continue
        }

        $gateRes = Invoke-Check 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $gatePath) 900000
        # With a needle, require the gate to have FAILED for the RIGHT REASON - a failure for an
        # unrelated cause would otherwise count as a detection. Without a needle (a check that must notice
        # through DRIVING rather than through a message), require only a failure.
        if ($gateRes.TimedOut) {
            Write-Host '  gate TIMED OUT (treated as not-caught)' -ForegroundColor Yellow
        } elseif ($m.Needle) {
            $gateCaught = ($gateRes.ExitCode -ne 0) -and ($gateRes.Output -like "*$($m.Needle)*")
        } else {
            $gateCaught = ($gateRes.ExitCode -ne 0)
        }

        # The suite must fail too. It reads the VALUES from source, so it catches M1/M2 independently of
        # the gate - which is what makes the two checks separate evidence rather than one check twice.
        foreach ($s in $m.Suites) {
            $sRes = Invoke-Check 'powershell.exe' @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $s) 300000
            if ((-not $sRes.TimedOut) -and $sRes.ExitCode -ne 0) { $suiteCaught = $true }
            $detail = "{0}={1}" -f (Split-Path $s -Leaf), $(if ($sRes.TimedOut) { 'TIMEOUT' } elseif ($sRes.ExitCode -ne 0) { 'CAUGHT' } else { 'MISSED' })
        }

        $verdict = if ($gateCaught -and $suiteCaught) { 'CAUGHT' } elseif ($gateCaught -or $suiteCaught) { 'PARTIAL' } else { 'MISSED' }
        Write-Host ("  gate={0}  {1}  => {2}" -f $(if ($gateCaught) { 'CAUGHT' } else { 'MISSED' }), $detail, $verdict) -ForegroundColor $(switch ($verdict) { 'CAUGHT' { 'Green' } 'PARTIAL' { 'Yellow' } default { 'Red' } })
        if ($verdict -ne 'CAUGHT') {
            $tail = (($gateRes.Output.Trim() -split "`n") | Select-Object -Last 4) -join ' / '
            Write-Host "  gate tail: $tail" -ForegroundColor DarkGray
        }
        $null = $results.Add(@{ Name = $m.Name; Verdict = $verdict; Detail = $detail })
    } finally {
        # ALWAYS restore from the ORIGINAL BYTES. `break` is illegal inside a finally block, so the
        # failure is recorded in a flag and acted on after the try/finally.
        if (-not (Restore-FromBackup $m.File)) {
            Write-Host '  RESTORE FAILED - stopping' -ForegroundColor Red
            $restoreBroke = $true
        } else {
            Write-Host '  restored (byte hash verified)' -ForegroundColor DarkGray
        }
    }
    if ($restoreBroke) { break }
}

Write-Host ''
Write-Host '=== FINAL HASH CHECK ===' -ForegroundColor Cyan
$allClean = $true
foreach ($p in @($workersPath, $corePath)) {
    $ok = ((Get-Sha $p) -eq $baseline[$p])
    if (-not $ok) { $allClean = $false }
    Write-Host ("  {0,-20} {1}" -f (Split-Path $p -Leaf), $(if ($ok) { 'unchanged' } else { 'CHANGED - restore from your backup' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}

Write-Host ''
Write-Host '=== SUMMARY ===' -ForegroundColor Cyan
$results | ForEach-Object { Write-Host ("  {0,-62} {1}" -f $_.Name, $_.Verdict) -ForegroundColor $(switch ($_.Verdict) { 'CAUGHT' { 'Green' } 'PARTIAL' { 'Yellow' } default { 'Red' } }) }
$caught = @($results | Where-Object { $_.Verdict -eq 'CAUGHT' }).Count
$harnessFail = @($results | Where-Object { $_.Verdict -eq 'HARNESS-FAIL' }).Count
Write-Host ''
Write-Host ("  {0}/{1} mutations caught by BOTH gate and suite; {2} harness failures; source state: {3}" -f $caught, $mutations.Count, $harnessFail, $(if ($allClean) { 'clean' } else { 'NOT CLEAN' })) -ForegroundColor $(if ($caught -eq $mutations.Count -and $allClean -and $harnessFail -eq 0) { 'Green' } else { 'Red' })

if ($caught -eq $mutations.Count -and $allClean -and $harnessFail -eq 0) { exit 0 } else { exit 1 }
