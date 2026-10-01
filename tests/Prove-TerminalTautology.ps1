# Tautology proof for the invariant-8.4 block (beta.5).
#
# WHY: the 8.4 defect was that two functions each defined "terminal" independently and disagreed, so a
# timed-out row was a COUNTED FAILURE to the exit-code classifier and a freely-rewritable row to the
# transition guard - an unattributed writer could convert a counted failure into a counted success. A
# check that passes on a tree where that is restored proves nothing. Each mutation below puts part of the
# defect back (or disables a check) and must be caught by BOTH the release gate and the suite.
#
# MECHANICS, each of which cost a cycle on the earlier harnesses:
#   * backup by BYTE COPY, never `git checkout --` (this runs against work that may be uncommitted)
#   * a PRE-FLIGHT that refuses to run unless the tree is already green - a mutation on a broken tree
#     produces failures that cannot be attributed to the mutation
#   * every mutation is a COUNT-CHECKED literal replace, so a pattern matching nothing (which would make
#     both checks "pass" on an unbroken tree) is itself a FAILURE
#   * per-run TIMEOUT treated as a failure, never as a wait
#   * pure .NET SHA256, and restore from the ORIGINAL BYTES with the hash verified
#
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Prove-TerminalTautology.ps1
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$statePath = Join-Path $root 'src\Wuu.State.psm1'
$gatePath = Join-Path $root 'Scripts\Validate-Release.ps1'
$terminalSuite = Join-Path $root 'tests\Test-TerminalStates.ps1'

function Invoke-Check([string]$Command, [string[]]$Arguments, [int]$TimeoutMs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Command
    # $psi.ArgumentList does NOT exist on .NET Framework, which is what Windows PowerShell 5.1 runs on.
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
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($HadBom)))
}

# ---- BACKUP (byte copy) -------------------------------------------------------------------------
$backupDir = Join-Path ([System.IO.Path]::GetTempPath()) ('wuu-84-tautology-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $backupDir -Force
$backup = @{}
foreach ($p in @($statePath, $gatePath)) {
    $copy = Join-Path $backupDir (Split-Path $p -Leaf)
    Copy-Item -LiteralPath $p -Destination $copy -Force
    $backup[$p] = @{ Copy = $copy; Sha = (Get-Sha $p) }
    if ((Get-Sha $copy) -ne $backup[$p].Sha) { Write-Host "BACKUP FAILED for $(Split-Path $p -Leaf) - refusing to run" -ForegroundColor Red; exit 1 }
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
$preSuite = Invoke-Check 'powershell.exe' @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $terminalSuite) 300000
if ($preGate.ExitCode -ne 0 -or $preSuite.ExitCode -ne 0 -or $preGate.TimedOut) {
    Write-Host "  gate=$($preGate.ExitCode) suite=$($preSuite.ExitCode) - the tree is NOT green, so a mutation's effect cannot be attributed" -ForegroundColor Red
    Write-Host '  restore the real source from your own backup first. Refusing to mutate.' -ForegroundColor Red
    exit 1
}
Write-Host '  gate and suite are both green - mutations will be attributable' -ForegroundColor Green

$baseline = Get-Sha $statePath
Write-Host ("  baseline Wuu.State.psm1    {0}" -f $baseline.Substring(0, 16))

# ---- THE MUTATIONS ------------------------------------------------------------------------------
$mutations = @(
    @{
        Name = 'M1: revert the guard to the LOOSE rule (terminal -> non-terminal only)'
        From = "if (`$fromTerminal.Terminal -and (`$fromState -ne [string]`$ToState)) {"
        To   = "if (`$fromTerminal.Terminal -and -not (Test-WuuTerminalState -State `$ToState).Terminal) {"
        Needle = 'laundered into a counted success'
        Suites = @($terminalSuite)
    },
    @{
        Name = 'M2: drop Timeout from the terminal declaration'
        From = "State = 'Timeout';  Outcome = 'TimedOut'"
        To   = "State = 'TimedOut'; Outcome = 'TimedOut'"
        # The OFF-VOCABULARY needle, which is the check that actually fires and the message verified by
        # applying this mutation by hand. Two wrong needles preceded it, and both were guesses about which
        # check would fire: first 'OPEN to the transition guard' (the forward check cannot see this - the
        # row stops classifying as settled and is skipped), then the reverse-settle message (the
        # off-vocabulary check sits earlier in the else-if chain and wins). A needle that has not been
        # OBSERVED is a guess, and a guessed needle reports MISSED for a gate that caught the mutation.
        Needle = 'not in the canonical vocabulary'
        Suites = @($terminalSuite)
    },
    @{
        Name = 'M3: reintroduce a second copy of the terminal set in the guard'
        From = "    `$fromTerminal = Test-WuuTerminalState -State `$fromState"
        To   = "    `$settledCopy = @('Complete', 'Error')`r`n    `$fromTerminal = @{ Terminal = (`$settledCopy -contains `$fromState) }"
        Needle = 'still keep their own'
        Suites = @($terminalSuite)
    },
    @{
        Name = 'M4: reorder the declaration so Complete precedes Error'
        From = "    @{ State = 'Error';    Outcome = 'Failed' }`r`n    @{ State = 'Timeout';  Outcome = 'TimedOut' }`r`n    @{ State = 'Complete'; Outcome = 'Success' }"
        To   = "    @{ State = 'Complete'; Outcome = 'Success' }`r`n    @{ State = 'Error';    Outcome = 'Failed' }`r`n    @{ State = 'Timeout';  Outcome = 'TimedOut' }"
        Needle = 'internally inconsistent'
        Suites = @($terminalSuite)
    }
)

$results = New-Object System.Collections.ArrayList
$restoreBroke = $false
foreach ($m in $mutations) {
    Write-Host ''
    Write-Host "=== $($m.Name) ===" -ForegroundColor Cyan
    $read = Read-Text $statePath
    $occurrences = ([regex]::Matches($read.Text, [regex]::Escape($m.From))).Count
    if ($occurrences -ne 1) {
        Write-Host "  HARNESS FAIL: the pattern matched $occurrences times (exactly 1 required) - nothing was mutated" -ForegroundColor Red
        $null = $results.Add(@{ Name = $m.Name; Verdict = 'HARNESS-FAIL'; Detail = "matched $occurrences" })
        continue
    }
    $gateCaught = $false
    $suiteCaught = $false
    $detail = ''
    try {
        Write-Text $statePath $read.Text.Replace($m.From, $m.To) $read.HadBom
        if ((Get-Sha $statePath) -eq $baseline) {
            Write-Host '  HARNESS FAIL: the file hash did not change - the mutation was a no-op' -ForegroundColor Red
            $null = $results.Add(@{ Name = $m.Name; Verdict = 'HARNESS-FAIL'; Detail = 'no hash change' })
            continue
        }

        $gateRes = Invoke-Check 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $gatePath) 900000
        if ($gateRes.TimedOut) {
            Write-Host '  gate TIMED OUT (treated as not-caught)' -ForegroundColor Yellow
        } else {
            # Require the gate to have failed for the RIGHT REASON - an unrelated failure would otherwise
            # count as a detection.
            $gateCaught = ($gateRes.ExitCode -ne 0) -and ($gateRes.Output -like "*$($m.Needle)*")
        }

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
        if (-not (Restore-FromBackup $statePath)) {
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
$clean = ((Get-Sha $statePath) -eq $baseline)
Write-Host ("  Wuu.State.psm1    {0}" -f $(if ($clean) { 'unchanged' } else { 'CHANGED - restore from your backup' })) -ForegroundColor $(if ($clean) { 'Green' } else { 'Red' })

Write-Host ''
Write-Host '=== SUMMARY ===' -ForegroundColor Cyan
$results | ForEach-Object { Write-Host ("  {0,-66} {1}" -f $_.Name, $_.Verdict) -ForegroundColor $(switch ($_.Verdict) { 'CAUGHT' { 'Green' } 'PARTIAL' { 'Yellow' } default { 'Red' } }) }
$caught = @($results | Where-Object { $_.Verdict -eq 'CAUGHT' }).Count
$harnessFail = @($results | Where-Object { $_.Verdict -eq 'HARNESS-FAIL' }).Count
Write-Host ''
Write-Host ("  {0}/{1} mutations caught by BOTH gate and suite; {2} harness failures; source state: {3}" -f $caught, $mutations.Count, $harnessFail, $(if ($clean) { 'clean' } else { 'NOT CLEAN' })) -ForegroundColor $(if ($caught -eq $mutations.Count -and $clean -and $harnessFail -eq 0) { 'Green' } else { 'Red' })

if ($caught -eq $mutations.Count -and $clean -and $harnessFail -eq 0) { exit 0 } else { exit 1 }
