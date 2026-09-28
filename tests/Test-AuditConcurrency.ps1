#Requires -Version 5.1
<#
.SYNOPSIS Phase 4 concurrency test: multiple PROCESSES appending to one audit log stay verifiable.
.DESCRIPTION
The per-session Monitor lock is in-process only, so before this test the chain relied on
Add-Content append behaviour plus a read-head/append sequence that two processes could interleave.
A probe (Scripts/_probe-concurrency.ps1) showed that path LOSING 86 of 100 records AND allowing
two writers to chain from the same prevHash - which verification reports as tampering on an intact
trail. That is the worst failure mode for an audit tool, so it is now proven, not assumed.

This test spawns real child processes (Start-Job = separate processes) that all append to ONE log
through the real Write-WuuAuditRecord and then asserts:
  1. EVERY record survives (nothing lost to a lock conflict);
  2. the combined chain VERIFIES - no forked chain, no sequence gaps;
  3. each child's records are all present (no child silently starved);
  4. verification still detects tampering in the concurrently-written file.
Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-AuditConcurrency.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$fail = $false
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail = $true }
function Pass($m) { Write-Host "PASS: $m" -ForegroundColor Green }

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

$dir = Join-Path $env:TEMP ("WUU_audit_conc_{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
New-Item -ItemType Directory -Path $dir -Force | Out-Null

$writerCount = 4
$recordsEach = 20
$expected = $writerCount * $recordsEach

# Each child writes through the REAL writer against the SAME log path. Deliberately a separate
# PROCESS (Start-Job), because an in-process test would only exercise the Monitor lock and would
# completely miss the cross-process file-lock path this test exists to prove.
$childScript = {
    param($Root, $Dir, $WriterId, $Count)
    Set-Location $Root
    Import-Module (Join-Path $Root 'src\Wuu.Core.psm1') -Force
    Import-WuuModules -WuuRoot $Root
    $session = Start-WuuAuditSession -Directory $Dir -Action "writer-$WriterId"
    for ($i = 1; $i -le $Count; $i++) {
        Write-WuuAuditRecord -Session $session -Action 'concurrent-write' -Result 'info' `
            -Targets @("W$WriterId") -Parameters @{ writer = $WriterId; index = $i } -FailClosed | Out-Null
    }
    return "writer $WriterId done"
}

$jobs = @()
for ($w = 1; $w -le $writerCount; $w++) {
    $jobs += Start-Job -ScriptBlock $childScript -ArgumentList $root, $dir, $w, $recordsEach
}
$null = $jobs | Wait-Job -Timeout 180
$childOutput = $jobs | Receive-Job
$jobState = @($jobs | ForEach-Object { $_.State })
$jobs | Remove-Job -Force

$failedJobs = @($jobState | Where-Object { $_ -ne 'Completed' })
if ($failedJobs.Count) { Fail "$($failedJobs.Count) writer(s) did not complete (states: $($jobState -join ','))" }
else { Pass "all $writerCount writer processes completed" }

$logPath = @(Get-ChildItem -LiteralPath $dir -Filter 'audit-*.jsonl' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
if (-not $logPath) { Fail 'no audit log was produced'; }
else {
    $records = @(Get-Content -LiteralPath $logPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })

    # 1. Nothing lost. session-start adds one record per writer, so allow exactly that much extra.
    $minExpected = $expected
    if ($records.Count -lt $minExpected) {
        Fail "LOST RECORDS: $($records.Count) present, expected at least $minExpected (concurrent writes dropped)"
    } else {
        Pass "no records lost: $($records.Count) present (>= $minExpected expected data records)"
    }

    # 2. The combined chain must verify. This is the assertion that matters: it proves no two
    #    writers forked the chain from the same prevHash.
    $v = Test-WuuAuditChain -LogPath $logPath -Quiet
    if (-not $v.Ok) {
        Fail "concurrently-written chain does NOT verify: $($v.Problems[0])"
        $v.Problems | Select-Object -First 3 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkRed }
    } else {
        Pass "concurrently-written chain VERIFIES ($($v.Checked) records, no forked chain)"
    }

    # 3. Every writer's records are present (no starved process).
    $missingWriters = @()
    for ($w = 1; $w -le $writerCount; $w++) {
        $n = @($records | Where-Object { $_.action -eq 'concurrent-write' -and ($_.targets) -contains "W$w" }).Count
        if ($n -ne $recordsEach) { $missingWriters += "W${w}=$n/$recordsEach" }
    }
    if ($missingWriters.Count) { Fail "writer record counts wrong: $($missingWriters -join ', ')" }
    else { Pass "each writer's $recordsEach records are present" }

    # 4. Sequence numbers must be contiguous 1..N with no duplicates (a duplicate seq would mean
    #    two writers read the same head).
    $seqs = @($records | ForEach-Object { [int]$_.seq } | Sort-Object)
    $dupes = @($seqs | Group-Object | Where-Object { $_.Count -gt 1 })
    if ($dupes.Count) { Fail "duplicate seq number(s): $(($dupes | ForEach-Object { $_.Name }) -join ',') - two writers shared a chain head" }
    elseif ($seqs[0] -ne 1 -or $seqs[$seqs.Count - 1] -ne $seqs.Count) { Fail "sequence is not contiguous 1..$($seqs.Count) (first=$($seqs[0]), last=$($seqs[$seqs.Count - 1]))" }
    else { Pass "sequence is contiguous 1..$($seqs.Count) with no duplicates" }

    # 5. Tampering is still detected in a concurrently-written file.
    $tampered = Join-Path $dir 'tampered.jsonl'
    $lines = [System.Collections.ArrayList]@(Get-Content -LiteralPath $logPath)
    $lines[2] = ($lines[2] -replace '"concurrent-write"', '"INJECTED"')
    Set-Content -LiteralPath $tampered -Value $lines -Encoding UTF8
    $tv = Test-WuuAuditChain -LogPath $tampered -Quiet
    if ($tv.Ok) { Fail 'tampering NOT detected in a concurrently-written log' }
    else { Pass "tampering still detected at line $($tv.FirstBreak) in the concurrent log" }
}

Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "  Child process output:" -ForegroundColor DarkGray
$childOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

if ($fail) { Write-Host 'SOME CHECKS FAILED' -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS' -ForegroundColor Cyan }
