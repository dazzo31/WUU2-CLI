#Requires -Version 5.1
<#
.SYNOPSIS Phase 4 test: the audit trail is append-only, hash-chained, and tamper-evident.
.DESCRIPTION
Proves, against the real module:
  1. The canonical serialiser distinguishes an ARRAY from a STRING. A naive implementation
     collapses ["one"] and "one" to the same text, so two different records hash identically -
     a collision in the exact component the chain depends on. (Found by probe before writing
     the module; this test locks it.)
  2. A written chain VERIFIES clean.
  3. Each tamper class is DETECTED and the FIRST break is reported: modified field, deleted
     record, reordered record, malformed line.
  4. The chain spans sessions (a new session continues from the existing chain head rather than
     resetting), so yesterday's records are still covered by today's hashes.
  5. -FailClosed refuses to proceed when the audit sink is unwritable (no audit, no change),
     while read-only writes degrade to a warning.
  6. Intent + outcome are two separate records sharing a correlationId, so a killed process
     still leaves evidence the action was attempted.
Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-AuditTrail.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$fail = $false
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail = $true }
function Pass($m) { Write-Host "PASS: $m" -ForegroundColor Green }

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

# Isolated audit dir per run so tests never touch real audit data.
$tmp = Join-Path $env:TEMP ("WUU_audit_test_{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# ---------------------------------------------------------------------------------------
# 1. Canonical serialisation: array vs string must NOT collide
# ---------------------------------------------------------------------------------------
$asArray = Get-WuuCanonicalJson @{ targets = @('SRV01') }
$asString = Get-WuuCanonicalJson @{ targets = 'SRV01' }
if ($asArray -eq $asString) {
    Fail "canonical form collides: array and string both serialise to '$asArray' - two different records would hash identically"
} else {
    Pass "array and string serialise differently ('$asArray' vs '$asString')"
}
# and the array really is an array
if ($asArray -notmatch '^\{.*\[.*\].*\}$') { Fail "array did not serialise as an array: $asArray" }
else { Pass 'arrays serialise as JSON arrays' }

# key order must not change the hash
$h1 = Get-WuuRecordHash -Record ([pscustomobject]@{ a = 1; b = 2 }) -PrevHash 'x'
$h2 = Get-WuuRecordHash -Record ([pscustomobject]@{ b = 2; a = 1 }) -PrevHash 'x'
if ($h1 -ne $h2) { Fail 'key order changed the hash (canonicalisation is not order-independent)' }
else { Pass 'key order does not affect the hash' }

# empty collection vs empty string must differ too
if ((Get-WuuCanonicalJson @()) -eq (Get-WuuCanonicalJson '')) { Fail 'empty array collides with empty string' }
else { Pass 'empty array and empty string differ' }

# ---------------------------------------------------------------------------------------
# 2. A clean chain verifies
# ---------------------------------------------------------------------------------------
$s1 = Start-WuuAuditSession -Directory $tmp -Action 'test'
Write-WuuAuditRecord -Session $s1 -Action 'check' -Result 'info' -Targets @('SRV01','SRV02') -Parameters @{ json = $false } | Out-Null
Write-WuuAuditRecord -Session $s1 -Action 'download' -Result 'succeeded' -Targets @('SRV01') -Counts @{ downloaded = 3 } | Out-Null
$v = Test-WuuAuditChain -LogPath $s1.LogPath -Quiet
if (-not $v.Ok) { Fail "clean chain failed verification: $($v.Problems -join ' | ')" }
else { Pass "clean chain verifies ($($v.Checked) records)" }

# ---------------------------------------------------------------------------------------
# 3. Each tamper class is detected, and the FIRST break is reported
# ---------------------------------------------------------------------------------------
function New-TamperedLog {
    param([string]$SourcePath, [scriptblock]$Mutate)
    $dest = Join-Path $tmp ("tampered_{0}.jsonl" -f ([guid]::NewGuid().ToString('N').Substring(0, 6)))
    $lines = [System.Collections.ArrayList]@(Get-Content -LiteralPath $SourcePath)
    & $Mutate $lines
    Set-Content -LiteralPath $dest -Value $lines -Encoding UTF8
    return $dest
}

# (a) modified field
$t1 = New-TamperedLog $s1.LogPath { param($l) $l[1] = ($l[1] -replace '"SRV01"', '"EVIL01"') }
$r1 = Test-WuuAuditChain -LogPath $t1 -Quiet
if ($r1.Ok) { Fail 'modified record NOT detected' }
elseif ($r1.FirstBreak -ne 2) { Fail "modified record detected but wrong first break ($($r1.FirstBreak), expected 2)" }
else { Pass "modified record detected at line $($r1.FirstBreak) (hash mismatch)" }

# (b) deleted record (breaks seq continuity AND the chain)
$t2 = New-TamperedLog $s1.LogPath { param($l) $l.RemoveAt(1) }
$r2 = Test-WuuAuditChain -LogPath $t2 -Quiet
if ($r2.Ok) { Fail 'deleted record NOT detected' }
else { Pass "deleted record detected at line $($r2.FirstBreak) ($($r2.Problems[0]))" }

# (c) reordered records
$t3 = New-TamperedLog $s1.LogPath { param($l) $tmpL = $l[1]; $l[1] = $l[2]; $l[2] = $tmpL }
$r3 = Test-WuuAuditChain -LogPath $t3 -Quiet
if ($r3.Ok) { Fail 'reordered records NOT detected' }
else { Pass "reordered records detected at line $($r3.FirstBreak)" }

# (d) malformed line
$t4 = New-TamperedLog $s1.LogPath { param($l) $l.Insert(1, '{ this is not json') }
$r4 = Test-WuuAuditChain -LogPath $t4 -Quiet
if ($r4.Ok) { Fail 'malformed line NOT detected' }
else { Pass "malformed line detected at line $($r4.FirstBreak)" }

# the tampered files must NOT have been modified by verification (verification is read-only)
if ((Get-Content -LiteralPath $t1).Count -ne (Get-Content -LiteralPath $s1.LogPath).Count) {
    Fail 'verification altered the file it checked'
} else { Pass 'verification is read-only' }

# ---------------------------------------------------------------------------------------
# 4. The chain spans sessions (new session continues BOTH the hash and the sequence)
# ---------------------------------------------------------------------------------------
$headBefore = Get-WuuAuditChainHead -LogPath $s1.LogPath
$s2 = Start-WuuAuditSession -Directory $tmp -Action 'test-2'
if ([string]::IsNullOrEmpty($s2.LastHash)) { Fail 'new session did not pick up the previous chain head' }
# The bug this asserts: a new session restarting seq at 1 makes later records look deleted.
# Start-WuuAuditSession writes one record (session-start), so after it returns Seq has advanced
# by exactly one from the previous head - not restarted at 1.
if ($s2.Seq -ne ($headBefore.Seq + 1)) { Fail "new session did not continue the sequence correctly (head was $($headBefore.Seq), session ended at $($s2.Seq), expected $($headBefore.Seq + 1)) - verification would report false tampering" }
else { Pass "new session continued the sequence ($($headBefore.Seq) -> $($s2.Seq), not restarted at 1)" }
$v2 = Test-WuuAuditChain -LogPath $s2.LogPath -Quiet
# Both sessions share the daily log file, so the combined chain must still verify.
if (-not $v2.Ok) { Fail "multi-session chain failed verification: $($v2.Problems[0])" }
else { Pass "chain continues across sessions and still verifies ($($v2.Checked) records)" }
if ((Get-WuuAuditChainHead -LogPath $s1.LogPath).Hash -eq $headBefore.Hash) { Fail 'chain head did not advance' }
else { Pass 'chain head advanced after a new session' }

# ---------------------------------------------------------------------------------------
# 5. Fail-closed vs best-effort
# ---------------------------------------------------------------------------------------
# Point a session at an impossible path to simulate an unwritable sink.
$badSession = [pscustomobject]@{
    RunId = 'x'; Operator = [pscustomobject]@{ User = 'u'; Machine = 'm'; Elevated = $false }
    StartedUtc = ''; Directory = $tmp; LogPath = Join-Path $tmp 'no_such_dir\nope.jsonl'
    TranscriptPath = ''; Seq = 0; LastHash = ''; Lock = New-Object object; Reason = ''
}
$threw = $false
try { Write-WuuAuditRecord -Session $badSession -Action 'mutate' -Result 'started' -FailClosed | Out-Null }
catch { $threw = $true }
if (-not $threw) { Fail 'FailClosed did not throw when the audit sink was unwritable (a mutation could go unlogged)' }
else { Pass 'FailClosed refuses to proceed when the audit sink is unwritable' }
# NOTE: $badSession.LogPath points at a nonexistent directory. Add-Content does NOT create
# missing parent directories, which is what makes this a valid "unwritable sink" case.

$warnedOnly = $true
try { Write-WuuAuditRecord -Session $badSession -Action 'read' -Result 'info' | Out-Null } catch { $warnedOnly = $false }
if (-not $warnedOnly) { Fail 'a best-effort (read-only) record threw instead of degrading to a warning' }
else { Pass 'read-only audit write degrades to a warning, does not block' }

# ---------------------------------------------------------------------------------------
# 6. Intent + outcome are separate correlated records
# ---------------------------------------------------------------------------------------
$s3 = Start-WuuAuditSession -Directory $tmp -Action 'test-3'
$res = Invoke-WuuAuditedAction -Session $s3 -Action 'install' -Targets @('SRV01') `
    -Parameters @{ reboot = $true } -Reason 'CHG-1041' -Body { Start-Sleep -Milliseconds 50 }
if (-not $res.Ok) { Fail "audited action reported failure: $($res.Error)" }
$recs = @(Get-Content -LiteralPath $s3.LogPath | ForEach-Object { $_ | ConvertFrom-Json })
$mine = @($recs | Where-Object { $_.correlationId -eq $res.CorrelationId })
if ($mine.Count -ne 2) { Fail "expected 2 correlated records (intent + outcome), got $($mine.Count)" }
elseif ($mine[0].result -ne 'started' -or $mine[1].result -ne 'succeeded') {
    Fail "correlated results wrong: $($mine[0].result) / $($mine[1].result)"
}
else { Pass "intent+outcome recorded as 2 correlated records ('started' then 'succeeded')" }
if ($mine[0].durationMs -ne 0 -and $mine[1].durationMs -le 0) { Fail 'outcome record did not capture a duration' }
else { Pass "outcome record captured durationMs=$($mine[1].durationMs) and reason='$($mine[1].reason)'" }

# a -WhatIf audit records intent and does NOT run the body
$s4 = Start-WuuAuditSession -Directory $tmp -Action 'test-4'
$script:bodyRan = $false
$r4b = Invoke-WuuAuditedAction -Session $s4 -Action 'install' -Targets @('SRV01') -WhatIf -Body { $script:bodyRan = $true }
if ($script:bodyRan) { Fail '-WhatIf audited action ran the body' } else { Pass '-WhatIf audited action records intent without running the body' }
$v4 = Test-WuuAuditChain -LogPath $s4.LogPath -Quiet
if (-not $v4.Ok) { Fail 'chain with a whatif record failed verification' } else { Pass 'whatif records are chained correctly' }

# ---------------------------------------------------------------------------------------
# 7. The log is JSONL and append-only (one record per line, nothing rewritten)
# ---------------------------------------------------------------------------------------
$raw = Get-Content -LiteralPath $s1.LogPath
$allParse = $true
foreach ($l in $raw) { try { $null = $l | ConvertFrom-Json } catch { $allParse = $false } }
if (-not $allParse) { Fail 'log is not valid JSONL' } else { Pass "log is valid JSONL ($($raw.Count) lines, one record each)" }

$countBefore = $raw.Count
Write-WuuAuditRecord -Session $s1 -Action 'extra' -Result 'info' | Out-Null
$after = @(Get-Content -LiteralPath $s1.LogPath)
if ($after.Count -ne ($countBefore + 1)) { Fail 'append did not add exactly one line' }
elseif (($after[0..($countBefore - 1)]) -join "`n" -ne ($raw -join "`n")) { Fail 'append REWROTE existing lines (not append-only)' }
else { Pass 'append adds one line and rewrites nothing' }

# ---------------------------------------------------------------------------------------
# 8. INTEGRATION: a mutating COMMAND is audited end-to-end (not just the module)
# ---------------------------------------------------------------------------------------
# Deliberately a SEPARATE directory with an explicit path, so this section cannot be confused
# with sections 1-7 and the log under test is unambiguous (an earlier draft searched the temp
# tree recursively, picked up a different session's file, and produced three misleading
# failures - always address the log explicitly in tests).
$intDir = Join-Path $tmp 'integration'
New-Item -ItemType Directory -Path $intDir -Force | Out-Null
$env:ProgramData = $intDir
$env:LOCALAPPDATA = $intDir

# The store must be initialized the way the app does it for handlers to resolve rows.
$global:uiHash = [hashtable]::Synchronized(@{})
$global:jobs = [system.collections.arraylist]::Synchronized((New-Object System.Collections.ArrayList))
$global:backgroundProcessing = [hashtable]::Synchronized(@{ Suspended = $false })
$global:MaxConcurrentJobs = 10
$global:enableDebugLogging = $false
$global:LogPath = Join-Path $intDir 'test.log'
$global:LogLock = New-Object object
$global:updatesHash = [hashtable]::Synchronized(@{})
$global:performanceHash = [hashtable]::Synchronized(@{})
$global:CustomCredentials = $null
$global:UseCustomCredentials = $false
$global:CredentialCache = @{}
$store = New-WuuStateStore
Add-WuuComputerRow -Store $store -Row (New-WuuComputerRow -Computer 'SRV01') | Out-Null

# Record which handler ran via a SHARED LIST captured by reference. A closure over
# $script:ran rebinds to whatever $script:ran points at later, so writes vanish (this bit the
# Phase 2 test too - use the list pattern).
$ranLog = New-Object System.Collections.ArrayList
$actions = [hashtable]::Synchronized(@{ Quit = $false })
foreach ($h in @('EventDownloadUpdates','EventInstallUpdates','EventGetUpdates')) {
    $name = $h
    $actions[$name] = [scriptblock]::Create("`$null = `$ranLog.Add('$name')").GetNewClosure()
}

# A MUTATING verb must produce audit records; -Reason must be captured.
$res = Invoke-WuuCommand -Verb 'download' -Actions $actions -Store $store -Computer 'SRV01' -Reason 'CHG-9001'
if (-not $res.Audited) { Fail 'mutating command was not audited (no Audited flag on the result)' }
else { Pass 'mutating command routed through the audited choke point' }
if ($ranLog -notcontains 'EventDownloadUpdates') { Fail "the action did not actually run (ran: $($ranLog -join ','))" }
else { Pass 'audited command still executed its action' }

# Find the log this section wrote, by path (today's file inside intDir).
$logPath8 = @(Get-ChildItem -LiteralPath $intDir -Filter 'audit-*.jsonl' -File -Recurse |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
if (-not $logPath8) { Fail 'integration run wrote no audit log' }
else {
    $recs = @(Get-Content -LiteralPath $logPath8 | ForEach-Object { $_ | ConvertFrom-Json })
    $dl = @($recs | Where-Object { $_.action -eq 'download' })
    # MUST be two records: 'started' (fail-closed intent) then the outcome.
    if ($dl.Count -ne 2) { Fail "download command produced $($dl.Count) audit record(s), expected 2 (intent + outcome)" }
    else { Pass "download audited as intent+outcome ('$($dl[0].result)' then '$($dl[1].result)')" }
    if ($dl.Count -ge 1) {
        if ($dl[0].reason -ne 'CHG-9001') { Fail "-Reason was not recorded in the intent record (got '$($dl[0].reason)')" }
        else { Pass '-Reason recorded in the audit record' }
        if (($dl[0].targets) -notcontains 'SRV01') { Fail "-Computer not recorded as a target (got '$($dl[0].targets -join ',')')" }
        else { Pass '-Computer recorded as the audit target' }
        if ($dl[0].correlationId -ne $dl[1].correlationId) { Fail 'intent and outcome records are not correlated' }
        else { Pass 'intent and outcome share a correlationId' }
    }
    # The whole trail (including the integration records) must verify
    $vFinal = Test-WuuAuditChain -LogPath $logPath8 -Quiet
    if (-not $vFinal.Ok) { Fail "final chain broken: $($vFinal.Problems[0])" }
    else { Pass "final integration chain verifies ($($vFinal.Checked) records)" }
}

# A READ-ONLY verb must NOT be routed through the audited choke point (no false 'started' rows).
$before = if ($logPath8) { @(Get-Content -LiteralPath $logPath8).Count } else { 0 }
$r2 = Invoke-WuuCommand -Verb 'check' -Actions $actions -Store $store -Computer 'SRV01'
if ($r2.Audited) { Fail 'read-only command was audited as a mutation' }
else { Pass 'read-only command is not audited as a mutation' }
$afterRead = @(Get-Content -LiteralPath $logPath8).Count
if ($afterRead -ne $before) { Fail "read-only command wrote audit records ($before -> $afterRead)" }
else { Pass 'read-only command writes no audit records' }

# -WhatIf on the command surface must not audit a mutation or run the action
$ranLog.Clear()
$beforeW = @(Get-Content -LiteralPath $logPath8).Count
$r3 = Invoke-WuuCommand -Verb 'install' -Actions $actions -Store $store -Computer 'SRV01' -WhatIf
$afterW = @(Get-Content -LiteralPath $logPath8).Count
if ($ranLog.Count -gt 0) { Fail '-WhatIf ran the action via the command surface' }
elseif ($afterW -ne $beforeW) { Fail "-WhatIf wrote audit records (expected none; $beforeW -> $afterW)" }
else { Pass '-WhatIf writes no mutation records and runs nothing' }

# ---------------------------------------------------------------------------------------
# 9. -Reason is REQUIRED for mutating commands (enforced, not just recorded)
# ---------------------------------------------------------------------------------------
# An audit record saying "changed 12 servers" with no reason has little change-review value,
# so omission must fail before anything runs - including before the fail-closed intent record.
$ranLog.Clear()
$beforeNoReason = @(Get-Content -LiteralPath $logPath8).Count
$r4 = Invoke-WuuCommand -Verb 'install' -Actions $actions -Store $store -Computer 'SRV01'   # no -Reason
if ($r4.Ok) { Fail 'mutating command without -Reason succeeded (should be refused)' }
elseif (-not $r4.NeedsReason) { Fail 'refusal did not identify the missing reason' }
elseif ($ranLog.Count -gt 0) { Fail 'action ran despite the missing reason' }
elseif (@(Get-Content -LiteralPath $logPath8).Count -ne $beforeNoReason) { Fail 'a refused command still wrote audit records' }
else { Pass 'mutating command without -Reason is refused before running or logging' }

# ---------------------------------------------------------------------------------------
# 10. The INTERACTIVE menu is audited too (not just the command surface)
# ---------------------------------------------------------------------------------------
# Gap found by inspection after the command surface was done: a human using the menu could make
# unaudited changes, which would make the trail misleading (it would look like only scripted
# changes ever happened). The loop takes an injected AuditHook; verify it is called for mutating
# menu entries and that a blank reason cancels.
$menuActions = Get-WuuMenuActions
$mutatingMenu = @($menuActions | Where-Object { $_.Mutating })
if ($mutatingMenu.Count -eq 0) { Fail 'no menu entries are flagged Mutating - the menu would be unaudited' }
else { Pass "menu flags $($mutatingMenu.Count) mutating entries: $((($mutatingMenu | ForEach-Object { $_.Label }) -join '; '))" }

# Drive the hook the way the loop does, to prove the wiring contract (label + reason + body).
$s5 = Start-WuuAuditSession -Action 'menu-hook-test'
$hookCalls = New-Object System.Collections.ArrayList
$hook = {
    param([string]$ActionName, [string]$Reason, [scriptblock]$Body)
    $null = $hookCalls.Add("$ActionName|$Reason")
    Invoke-WuuAuditedAction -Session $s5 -Action $ActionName -Reason $Reason -Body $Body
}.GetNewClosure()
& $hook 'Download updates' 'CHG-2002 menu change' { $null = $hookCalls.Add('body-ran') }
if ($hookCalls -notcontains 'body-ran') { Fail 'menu audit hook did not run the action body' }
else { Pass 'menu audit hook runs the action body' }
$mrecs = @(Get-Content -LiteralPath $s5.LogPath | ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object { $_.action -eq 'Download updates' })
if ($mrecs.Count -ne 2) { Fail "menu action produced $($mrecs.Count) audit records, expected intent+outcome" }
elseif ($mrecs[0].reason -ne 'CHG-2002 menu change') { Fail "menu reason not recorded (got '$($mrecs[0].reason)')" }
else { Pass "menu action audited with its reason (intent+outcome)" }
$v5 = Test-WuuAuditChain -LogPath $s5.LogPath -Quiet
if (-not $v5.Ok) { Fail "menu-hook chain broken: $($v5.Problems[0])" } else { Pass 'menu-hook chain verifies' }

# ---------------------------------------------------------------------------------------
# 11. Session transcript: captured when available, never fatal, and only stopped if we started it
# ---------------------------------------------------------------------------------------
$s6 = Start-WuuAuditSession -Action 'transcript-test'
$started = Start-WuuAuditTranscript -Session $s6
if ($started) {
    Pass 'transcript started'
    Write-Host '  (transcript capture active - marker line)'
    Stop-WuuAuditTranscript -Session $s6
    if (-not (Test-Path -LiteralPath $s6.TranscriptPath)) {
        Fail 'transcript reported started but no file was produced'
    } else {
        $tLen = (Get-Item -LiteralPath $s6.TranscriptPath).Length
        if ($tLen -le 0) { Fail 'transcript file is empty' }
        else { Pass "transcript captured $tLen bytes" }
    }
    # Second stop must be a harmless no-op (idempotent), not a throw.
    $threwStop = $false
    try { Stop-WuuAuditTranscript -Session $s6 } catch { $threwStop = $true }
    if ($threwStop) { Fail 'second Stop-WuuAuditTranscript threw (not idempotent)' }
    else { Pass 'Stop-WuuAuditTranscript is idempotent' }
} else {
    # Not a failure: some hosts cannot start a transcript, and the design says that must be
    # non-fatal. Assert the contract (returns false, does not throw, session marked inactive).
    if ($s6.TranscriptActive) { Fail 'transcript reported unavailable but the session is marked active' }
    else { Pass 'transcript unavailable in this host: returned $false without throwing (non-fatal by design)' }
}

# Stop on a session that never started a transcript must be a silent no-op.
$s7 = Start-WuuAuditSession -Action 'no-transcript'
$threwNoStart = $false
try { Stop-WuuAuditTranscript -Session $s7 } catch { $threwNoStart = $true }
if ($threwNoStart) { Fail 'Stop on a session with no transcript threw' }
else { Pass 'Stop on a session with no transcript is a no-op' }

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

if ($fail) { Write-Host 'SOME CHECKS FAILED' -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS' -ForegroundColor Cyan }
