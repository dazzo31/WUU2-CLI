#Requires -Version 5.1
<#
.SYNOPSIS Deployment reporting over the audit trail: window parsing, aggregation, classification.
.DESCRIPTION
Proves, on SYNTHETIC records written to a throwaway log (never the real audit store):

  1. The time window parses correctly and REJECTS nonsense rather than silently widening to everything.
  2. Only deployment actions count. A read ('check', 'show') and a session start must not be reported
     as a deployment, or a report says the fleet is fine whenever nobody tried anything.
  3. Classification: succeeded / failed / refused are distinguished, and a record with only a 'started'
     intent is NOT counted as a success.
  4. A REFUSAL is not a machine failure. This is the defect the first implementation had: it counted
     112 refusals ("missing -Reason") as a host failing 112 deployments at a 100% failure rate.
  5. Double-counting: many records share one runId (session, intent, outcome) and must yield ONE run.
  6. Per-machine failure counts, error breakdown, time buckets and the console renderer.
  7. The CLI: options parse and are consumed, an invalid argument is a UsageError, and the report
     never writes to the audit store.

Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-Reporting.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$fail = 0
function Ok($m)  { Write-Host "PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail++ }

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force -DisableNameChecking
Import-WuuModules -WuuRoot $root
$global:EnableDebugLogging = $false

# A synthetic log in a throwaway directory. The suite must never read, let alone disturb, the real
# %PROGRAMDATA% store - and a test that depends on whatever happens to be in the local audit trail
# would pass for the wrong reason on one machine and fail on another.
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("wuu-report-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
$log = Join-Path $sandbox 'audit-20261002.jsonl'

function New-Record {
    param(
        [string]$Action, [string]$Result, [string]$RunId, [string]$Computer = '',
        [string]$Error = '', [string]$Timestamp = '2026-10-02T10:00:00.0000000Z',
        [string]$Category = 'outcome', [int]$DurationMs = 0
    )
    $targets = if ($Computer) { @($Computer) } else { @() }
    return ([pscustomobject][ordered]@{
            seq          = 0
            timestampUtc = $Timestamp
            runId        = $RunId
            category     = $Category
            action       = $Action
            targets      = $targets
            result       = $Result
            error        = $Error
            durationMs   = $DurationMs
        } | ConvertTo-Json -Compress -Depth 6)
}

try {
    $null = New-Item -ItemType Directory -Path $sandbox -Force

    # --- 1. window parsing ------------------------------------------------------------
    $w = ConvertTo-WuuReportWindow -Period '24h'
    $hours24 = ($w.To - $w.From).TotalHours
    if (-not $w.Ok -or [math]::Round($hours24) -ne 24) { Bad "24h window is $hours24 hours, not 24" }
    else { Ok '24h resolves to a 24-hour window' }

    $wd = ConvertTo-WuuReportWindow -Period '7d'
    if ([math]::Round(($wd.To - $wd.From).TotalHours) -ne 168) { Bad '7d did not resolve to 168 hours' }
    else { Ok '7d resolves to 168 hours' }

    # A bad period must FAIL. Silently falling back to the default would report on a window nobody
    # asked for while looking like it worked.
    $bad = @()
    foreach ($p in @('7', 'x', '0d', '-3d', 'seven days', '')) {
        $r = ConvertTo-WuuReportWindow -Period $p
        if ($p -eq '') { continue }   # empty is documented as "use the default"
        if ($r.Ok) { $bad += $p }
    }
    if ($bad.Count -gt 0) { Bad "invalid period(s) accepted: $($bad -join ', ')" }
    else { Ok 'invalid periods are rejected, not silently widened' }

    if ((ConvertTo-WuuReportWindow -Period '').Period -ne '7d') { Bad "an empty period did not fall back to the documented default 7d" }
    else { Ok 'an empty period falls back to the documented default (7d)' }

    $all = ConvertTo-WuuReportWindow -Period 'all'
    if ($all.From -ne [datetime]::MinValue) { Bad "'all' does not start at the beginning of time" }
    else { Ok "'all' covers all history" }

    # Explicit dates must WIN over -Period: an operator who gives both means the dates.
    $both = ConvertTo-WuuReportWindow -Period 90d -FromUtc '2026-10-01' -ToUtc '2026-10-02'
    if ($both.Period -ne 'custom' -or $both.From.Date -eq (Get-Date).AddDays(-90).Date) {
        Bad 'explicit -From/-To did not override -Period'
    } else { Ok 'explicit -From/-To overrides -Period' }

    $inverted = ConvertTo-WuuReportWindow -FromUtc '2026-10-02' -ToUtc '2026-10-01'
    if ($inverted.Ok) { Bad 'an inverted range (from > to) was accepted' }
    else { Ok 'an inverted range is refused' }

    # --- 2. only deployment actions count ---------------------------------------------
    if (Test-WuuDeploymentAction 'install' -and (Test-WuuDeploymentAction 'EventInstallUpdates') -and (Test-WuuDeploymentAction 'reboot')) {
        Ok 'deployment actions are recognised (verb and handler names)'
    } else { Bad 'a deployment action was not recognised' }

    $nonDeploy = @('session-start', 'check', 'show', 'audit', 'export', 'report', '')
    $wrong = @($nonDeploy | Where-Object { Test-WuuDeploymentAction $_ })
    if ($wrong.Count -gt 0) { Bad "non-deployment action(s) treated as deployments: $($wrong -join ', ')" }
    else { Ok "no read/session action is counted as a deployment ($($nonDeploy.Count) checked)" }

    # --- build a synthetic log --------------------------------------------------------
    $lines = New-Object System.Collections.ArrayList
    # One SUCCESSFUL multi-target install batch: 4 records, one runId (session-less here).
    [void]$lines.Add((New-Record -Action 'install' -Result 'started'   -RunId 'run-ok'  -Computer 'SRV01' -Timestamp '2026-10-01T08:00:00Z'))
    [void]$lines.Add((New-Record -Action 'install' -Result 'succeeded' -RunId 'run-ok'  -Computer 'SRV01' -Timestamp '2026-10-01T08:05:00Z' -DurationMs 300000))
    # One FAILED install on a different host.
    [void]$lines.Add((New-Record -Action 'install' -Result 'started' -RunId 'run-bad' -Computer 'SRV02' -Timestamp '2026-10-01T09:00:00Z'))
    [void]$lines.Add((New-Record -Action 'install' -Result 'failed'  -RunId 'run-bad' -Computer 'SRV02' -Timestamp '2026-10-01T09:10:00Z' -Error '0x80240020' -DurationMs 600000))
    # TWENTY refusals of the SAME host - the case that made "failing targets" lie.
    for ($n = 1; $n -le 20; $n++) {
        [void]$lines.Add((New-Record -Action 'install' -Result 'denied' -RunId "run-denied-$n" -Computer 'SRV09' -Timestamp '2026-10-02T07:00:00Z' -Error 'missing -Reason'))
    }
    # A 'declined' refusal with no error text.
    [void]$lines.Add((New-Record -Action 'install' -Result 'declined' -RunId 'run-declined' -Computer 'SRV10' -Timestamp '2026-10-02T07:30:00Z'))
    # An intent record with NO outcome at all - interrupted. Must not read as success or failure.
    [void]$lines.Add((New-Record -Action 'install' -Result 'started' -RunId 'run-cut' -Computer 'SRV11' -Timestamp '2026-10-02T08:00:00Z'))
    # Non-deployment noise that must be ignored.
    [void]$lines.Add((New-Record -Action 'session-start' -Result 'started' -RunId 'sess-1' -Category 'session' -Timestamp '2026-10-02T08:00:00Z'))
    [void]$lines.Add((New-Record -Action 'check'        -Result 'info'    -RunId 'sess-1' -Computer 'SRV01' -Category 'operational' -Timestamp '2026-10-02T08:01:00Z'))
    [void]$lines.Add((New-Record -Action 'report'       -Result 'info'    -RunId 'sess-1' -Category 'operational' -Timestamp '2026-10-02T08:02:00Z'))
    # A malformed line must be counted and skipped, not thrown on.
    [void]$lines.Add('{"action": "install", broken json')
    # A record OUTSIDE the window (used for the window test below).
    [void]$lines.Add((New-Record -Action 'install' -Result 'succeeded' -RunId 'run-old' -Computer 'SRV77' -Timestamp '2026-08-01T00:00:00Z'))

    [System.IO.File]::WriteAllText($log, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

    # --- 3. history reads the file and reports the malformed line ---------------------
    $h = Get-WuuAuditHistory -LogPath $log -Period 'all'
    if (-not $h.Ok) { Bad "history read failed: $($h.Error)" }
    elseif ($h.MalformedLines -ne 1) { Bad "expected 1 malformed line reported, got $($h.MalformedLines)" }
    else { Ok 'a malformed line is counted and skipped, not thrown on' }

    # --- 4. aggregation: 6 runs, not one per record -----------------------------------
    $r = Get-WuuDeploymentReport -Records $h.Records -GroupBy Day
    $s = $r.Summary
    # runs: run-ok, run-bad, run-denied x20, run-declined, run-cut, run-old = 25
    if ($s.TotalRuns -ne 25) { Bad "expected 25 deployment runs, got $($s.TotalRuns) (records were double-counted or ignored)" }
    else { Ok 'records sharing a runId collapse into ONE run (25 runs from 32 records)' }
    if ($s.SuccessfulRuns -ne 2 -or $s.FailedRuns -ne 1 -or $s.DeniedRuns -ne 21 -or $s.StartedRuns -ne 1) {
        Bad "classification wrong: ok=$($s.SuccessfulRuns) failed=$($s.FailedRuns) denied=$($s.DeniedRuns) started=$($s.StartedRuns) (want 2/1/21/1)"
    } else { Ok 'runs classify as 2 succeeded / 1 failed / 21 refused / 1 started-with-no-outcome' }

    if ($s.SuccessRatePercent -ne 66.7) { Bad "success rate is $($s.SuccessRatePercent)%, expected 66.7% of the 3 settled runs" }
    else { Ok 'success rate is over SETTLED runs only (66.7% = 2 of 3)' }

    # --- 5. a refusal is NOT a machine failure ----------------------------------------
    $names = @($r.ProblemTargets | ForEach-Object { $_.Computer })
    if ($names -contains 'SRV09' -or $names -contains 'SRV10') {
        Bad "a refused host is listed as a failing machine: $($names -join ', ') - refusals never reached the machine"
    } elseif ($names -notcontains 'SRV02') {
        Bad "the genuinely failed host SRV02 is missing from the failing-targets table (got: $($names -join ', '))"
    } else { Ok 'only hosts that actually failed appear as failing targets (20 refusals are not 20 failures)' }

    $srv02 = @($r.ProblemTargets | Where-Object { $_.Computer -eq 'SRV02' })[0]
    if ($srv02.Failures -ne 1 -or $srv02.Attempts -ne 1) { Bad "SRV02 shows $($srv02.Failures) failures / $($srv02.Attempts) attempts, expected 1/1" }
    else { Ok 'a failed host reports its real failure count (1/1), not an inflated one' }

    # --- 6. causes distinguish refusal from failure, and keep declined != denied -------
    $refusals = @($r.ErrorBreakdown | Where-Object { $_.IsRefusal })
    $failures = @($r.ErrorBreakdown | Where-Object { -not $_.IsRefusal })
    if ($failures.Count -lt 1) { Bad 'the WUA error code from the failed run is not in the cause table' }
    elseif ($refusals.Count -lt 2) { Bad "expected both refusal causes (missing -Reason, declined), got $($refusals.Count)" }
    else { Ok 'causes separate refusals from failures, and distinguish denied from declined' }

    $declined = @($r.ErrorBreakdown | Where-Object { $_.Error -match 'declined' })
    if ($declined.Count -ne 1) { Bad "'declined' is not reported under its own name (collapsed into 'denied'?)" }
    else { Ok "'declined' is reported as declined, not folded into 'denied'" }

    # --- 7. buckets and the window ---------------------------------------------------
    $oct1 = @($r.TimeBuckets | Where-Object { $_.PeriodLabel -eq '2026-10-01' })[0]
    if (-not $oct1 -or $oct1.Total -ne 2) { Bad "the 2026-10-01 bucket should hold 2 runs, got $($oct1.Total)" }
    else { Ok 'runs land in the correct day bucket' }

    $weekBucket = Get-WuuDeploymentReport -Records $h.Records -GroupBy Week
    if (@($weekBucket.TimeBuckets).Count -ge 2) { Ok 'Week grouping produces week buckets' }
    else { Bad 'Week grouping did not produce separate weekly buckets' }

    $hw = Get-WuuAuditHistory -LogPath $log -Period '48h'
    $oldRows = @([datetime]::Parse('2026-08-01T00:00:00Z') | Where-Object { $_ -ge $hw.From -and $_ -le $hw.To })
    if ($oldRows.Count -eq 0 -and @($hw.Records | Where-Object { $_.runId -eq 'run-old' }).Count -eq 0) {
        Ok 'a record outside the window is excluded'
    } else { Bad 'a record from outside the window was included' }

    # --- 8. per-computer filter ------------------------------------------------------
    $h1 = Get-WuuAuditHistory -LogPath $log -Period 'all' -Computer @('SRV02')
    $onlySrv02 = @($h1.Records | Where-Object { $_.runId -ne 'run-bad' })
    if ($onlySrv02.Count -ne 0) { Bad "the -Computer filter returned $($onlySrv02.Count) unrelated record(s)" }
    else { Ok 'the -Computer filter returns only the named target''s records' }

    # --- 9. the console renderer must not throw -------------------------------------
    $rendered = ''
    try {
        $rendered = (& { Format-WuuReportTable -Report $r -Window $h -Top 3 } 6>&1 | Out-String)
        Ok 'the console renderer completes without throwing'
    } catch {
        Bad "the console renderer threw: $($_.Exception.Message)"
    }
    if ($rendered -match 'DEPLOYMENT REPORT') { Ok 'the renderer prints the report header' }
    else { Bad 'the renderer did not print the report header' }

    # --- 10. CSV export ---------------------------------------------------------------
    $csv = Join-Path $sandbox 'runs.csv'
    $ex = Export-WuuDeploymentReport -Report $r -Path $csv -Dataset Runs
    if (-not $ex.Success) { Bad "CSV export failed: $($ex.Error)" }
    elseif (-not (Test-Path $csv)) { Bad 'CSV export reported success but wrote no file' }
    elseif ((Get-Content $csv).Count -lt 2) { Bad 'CSV export wrote no data rows' }
    else { Ok "CSV export wrote $($ex.Rows) run row(s)" }

    $csvT = Join-Path $sandbox 'targets-empty.csv'
    $exT = Export-WuuDeploymentReport -Report (Get-WuuDeploymentReport -Records @()) -Path $csvT -Dataset Targets
    if (-not (Test-Path $csvT) -or (Get-Content $csvT -TotalCount 1) -notmatch 'Computer') {
        Bad 'an empty dataset produced no header, so an empty export looks like a failed one'
    } else { Ok 'an empty dataset still writes a header row' }

    # --- 11. the CLI surface ----------------------------------------------------------
    $p = ConvertTo-WuuCommandLine -Arguments @('report', '-Period', '30d', '-GroupBy', 'Week', '-FailedOnly')
    if ($p.Unknown.Count -gt 0) { Bad "report options not recognised: $($p.Unknown -join ', ')" }
    elseif ($p.Options['Period'] -ne '30d' -or $p.Options['GroupBy'] -ne 'Week' -or -not $p.Options['FailedOnly']) {
        Bad "report options parsed wrong: Period='$($p.Options['Period'])' GroupBy='$($p.Options['GroupBy'])' FailedOnly='$($p.Options['FailedOnly'])'"
    } else { Ok 'the CLI parses -Period/-GroupBy/-FailedOnly and consumes their values' }

    $p2 = ConvertTo-WuuCommandLine -Arguments @('report', '-From', '2026-10-01', '-To', '2026-10-02')
    if ($p2.Options['From'] -ne '2026-10-01' -or $p2.Options['To'] -ne '2026-10-02') { Bad 'from/to did not parse' }
    else { Ok 'the CLI parses -From/-To' }

    $p3 = ConvertTo-WuuCommandLine -Arguments @('report', '-Period')
    if ($p3.Unknown -notcontains '-Period (missing value)') { Bad 'a value-taking option with no value was not reported' }
    else { Ok 'an option missing its value is reported rather than silently dropped' }

    $entry = (Get-WuuCommandTable)['report']
    if (-not $entry) { Bad 'the report verb is not registered' }
    elseif ($entry.Mutating) { Bad 'the report verb is registered as MUTATING - it only reads the audit trail' }
    else { Ok 'the report verb is registered, and as read-only' }

    # --- 12. exit codes ---------------------------------------------------------------
    if ((Get-WuuExitCode -Result 'Success') -ne 0) { Bad 'Success does not map to exit 0' }
    if ((Get-WuuExitCode -Result 'OperationFailed') -ne 1) { Bad 'OperationFailed does not map to exit 1' }
    if ((Get-WuuExitCode -Result 'UsageError') -ne 2) { Bad 'UsageError does not map to exit 2' }
    Ok 'report outcomes map to the documented exit codes (0/1/2)'

    # A report that FINDS failures still exits 0: reporting a failure is a successful report.
    $badPeriod = Invoke-WuuReportCommand -Period 'bogus'
    if ($badPeriod.Ok -or $badPeriod.Result -ne 'UsageError') { Bad 'an invalid period did not produce a UsageError' }
    else { Ok 'an invalid period is a UsageError (exit 2)' }

    $missingLog = Invoke-WuuReportCommand -Period 'all' -LogPath (Join-Path $sandbox 'no-such-file.jsonl')
    if ($missingLog.Ok -or $missingLog.Result -ne 'OperationFailed') { Bad "a named log that does not exist did not fail (Ok=$($missingLog.Ok) Result=$($missingLog.Result))" }
    else { Ok 'a named -LogPath that does not exist is an OperationFailed (exit 1), not a silent empty report' }

    # -LogPath must actually BE CONSUMED. It is registered as a known option, but a name missing from
    # the value-taking list sets the option to $true and leaves the path as a stray positional, so the
    # command silently reads the newest log instead of the one named.
    $lp = ConvertTo-WuuCommandLine -Arguments @('report', '-LogPath', 'C:\some\audit.jsonl')
    if ($lp.Options['LogPath'] -ne 'C:\some\audit.jsonl') {
        Bad "-LogPath did not consume its value (got '$($lp.Options['LogPath'])')"
    } else { Ok '-LogPath consumes its value rather than being set to true' }

    # The CLI drives the reporting engine against the named log, end to end.
    $cliFixture = Join-Path $sandbox 'fixture.jsonl'
    [System.IO.File]::WriteAllText($cliFixture, ((New-Record -Action 'install' -Result 'succeeded' -RunId 'cli-1' -Computer 'SRV50' -Timestamp '2026-10-02T10:00:00Z') + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $cliRes = Invoke-WuuReportCommand -Period 'all' -LogPath $cliFixture
    if (-not $cliRes.Ok -or $cliRes.Runs -ne 1) { Bad "the CLI path did not report the fixture log (Ok=$($cliRes.Ok) Runs=$($cliRes.Runs))" }
    else { Ok 'the CLI reports only the named -LogPath file (1 run, not the host''s own history)' }

    # --- 14. GUIDED UI (phase 2) ------------------------------------------------------
    # A stub action map: the guided screens resolve handlers by NAME out of this object, so the
    # reporting screen must work with the same shape the real one has. Only the audit subverb path
    # is exercised here, and that is a command-layer call, not an action.
    $script:uiActions = [hashtable]::Synchronized(@{})
    foreach ($h in @('EventDeploymentReport', 'EventSaveComputerList')) {
        $script:uiActions[$h] = { param() }
    }

    # The menu must OFFER the report, and choosing it must hand off to a state the workflow
    # loop actually dispatches. An entry that returns a state nobody handles is the "dead menu
    # entry" defect this codebase has hit before (the AD-import handler existed for months,
    # reachable from no menu).
    $reportItems = @(Get-WuuReportsMenu)
    $reportEntry = @($reportItems | Where-Object { $_.ContainsKey('Report') })
    if ($reportEntry.Count -ne 1) { Bad "the Reports menu does not offer exactly one report entry (found $($reportEntry.Count))" }
    else { Ok 'the Reports menu offers the deployment report' }

    # Every entry needs ONE dispatch key: Handler, AuditSubVerb, Preflight, Starts or Report.
    $undispatched = @($reportItems | Where-Object {
            -not $_.ContainsKey('Handler') -and -not $_.ContainsKey('AuditSubVerb') -and
            -not $_.ContainsKey('Preflight') -and -not $_.ContainsKey('Starts') -and
            -not $_.ContainsKey('Report') -and $_.Key -ne 'b'
        })
    if ($undispatched.Count -gt 0) { Bad "$($undispatched.Count) Reports entry(ies) dispatch to nothing" }
    else { Ok 'every Reports menu entry dispatches to something' }

    $uiCtx = [pscustomobject]@{ Set = $null; Store = (New-WuuStateStore); Actions = $script:uiActions; AuditHook = $null; DenialHook = $null }

    Initialize-WuuInputMode -NonInteractive -Answers @('1')
    try { $nextState = Show-WuuCategoryScreen -Ctx $uiCtx -Title 'REPORTS / AUDIT' -Items $reportItems -State 'REPORTS' }
    finally { Initialize-WuuInputMode -NonInteractive:$false }
    if ($nextState -ne 'REPORT') { Bad "choosing the report entry returned '$nextState', not the REPORT state" }
    else { Ok 'choosing the report entry hands off to the REPORT state' }

    # The state must be one the workflow loop dispatches, or the hand-off dead-ends.
    $navRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Navigate.psm1') -Raw
    if ($navRaw -notmatch "'REPORT'\s*\{\s*\`$state = Show-WuuReportScreen") {
        Bad "the workflow loop has no dispatch for the 'REPORT' state - the hand-off dead-ends"
    } else { Ok "the workflow loop dispatches the 'REPORT' state" }

    # Back must still work from the category screen after the new entry was inserted.
    Initialize-WuuInputMode -NonInteractive -Answers @('b')
    try { $backState = Show-WuuCategoryScreen -Ctx $uiCtx -Title 'REPORTS / AUDIT' -Items $reportItems -State 'REPORTS' }
    finally { Initialize-WuuInputMode -NonInteractive:$false }
    if ($backState -ne 'DASHBOARD') { Bad "Back returned '$backState' instead of DASHBOARD" }
    else { Ok 'Back still leaves the Reports menu for the dashboard' }

    # The screen drives the same engine, so the menu and the CLI cannot disagree.
    $screenOut = ''
    try {
        Initialize-WuuInputMode -NonInteractive -Answers @('4', '5')
        try { $screenOut = (& { Show-WuuReportScreen -Ctx $uiCtx } 6>&1 | Out-String) }
        finally { Initialize-WuuInputMode -NonInteractive:$false }
        Ok 'the guided report screen runs and returns'
    } catch {
        Bad "the guided report screen threw: $($_.Exception.Message)"
    }
    if ($screenOut -match 'WUU2 DEPLOYMENT REPORT') { Ok 'the guided screen renders the same report the CLI produces' }
    else { Bad 'the guided screen did not render the report' }

    # Every period preset must resolve - a preset that silently became 'BACK' would look like a
    # dead menu entry to the operator.
    $presetsOk = $true
    foreach ($preset in @('1', '2', '3', '4')) {
        Initialize-WuuInputMode -NonInteractive -Answers @($preset, '5')
        try { $st = Show-WuuReportScreen -Ctx $uiCtx } finally { Initialize-WuuInputMode -NonInteractive:$false }
        if ($st -ne 'REPORTS') { $presetsOk = $false }
    }
    if (-not $presetsOk) { Bad 'a period preset did not complete and return to REPORTS' }
    else { Ok 'all four period presets (24h/7d/30d/all) run and return to the menu' }

    # Export from the menu writes a file...
    $guidedCsv = Join-Path $sandbox 'guided.csv'
    Initialize-WuuInputMode -NonInteractive -Answers @($guidedCsv)
    try { $gRes = Invoke-WuuReportExportScreen -Report $r -Dataset Runs } finally { Initialize-WuuInputMode -NonInteractive:$false }
    if (-not (Test-Path $guidedCsv)) { Bad 'exporting from the menu wrote no file' }
    elseif ($gRes -ne 'REPORTS') { Bad "the export screen returned '$gRes' instead of REPORTS" }
    else { Ok 'the guided export writes the CSV and returns to the menu' }

    # ...and a cancelled export writes NOTHING (a header-only file would look like a successful
    # export of an empty dataset, which is a different thing).
    $cancelCsv = Join-Path $sandbox 'guided-cancelled.csv'
    Initialize-WuuInputMode -NonInteractive -Answers @('')
    try { $cRes = Invoke-WuuReportExportScreen -Report $r -Dataset Runs } finally { Initialize-WuuInputMode -NonInteractive:$false }
    if (Test-Path $cancelCsv) { Bad 'a cancelled export still wrote a file' }
    elseif ($cRes -ne 'REPORTS') { Bad "a cancelled export returned '$cRes'" }
    else { Ok 'a cancelled export writes nothing and returns quietly' }

    # The flat menu entry must point at a handler that EXISTS. Its dispatcher calls $a.Run and
    # discards the return value, so an entry returning a workflow state would go nowhere - which
    # is why it delegates to the screen through an action-layer wrapper.
    $flat = @(Get-WuuMenuActions)
    $flatReport = @($flat | Where-Object { $_.Handler -eq 'EventDeploymentReport' })
    if ($flatReport.Count -ne 1) { Bad 'the flat menu does not offer the deployment report' }
    elseif ($flatReport[0].Mutating) { Bad 'the flat-menu report entry is flagged as mutating' }
    else { Ok 'the flat menu offers the deployment report as a read-only action' }

    $coreRaw2 = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
    if ($coreRaw2 -notmatch '\$consoleActions\.EventDeploymentReport\s*=') {
        Bad 'the flat menu references EventDeploymentReport but no such console action is registered (dead menu entry)'
    } else { Ok 'EventDeploymentReport is registered in $consoleActions (the flat entry is reachable)' }

    # Spec 15: the report is reachable after an operation, not only from the Reports menu.
    # The option MOVED as the results screen grew, so the assertion is on the LABEL rather than on
    # a number: pinning the digit here would make an unrelated menu edit fail this suite.
    if ($navRaw -notmatch 'Deployment report \(fleet history\)' -or $navRaw -notmatch "return 'REPORT'") {
        Bad 'the results screen does not offer the deployment report (spec 15)'
    } else { Ok 'the results screen offers the report and maps it to the REPORT state (spec 15)' }

    # --- 15. read-only over the synthetic log ----------------------------------------
    $before = (Get-FileHash -LiteralPath $log -Algorithm SHA256).Hash
    $null = Invoke-WuuReportCommand -Period 'all' -LogPath $log
    $null = Get-WuuDeploymentReport -Records (Get-WuuAuditHistory -LogPath $log -Period 'all').Records
    $after = (Get-FileHash -LiteralPath $log -Algorithm SHA256).Hash
    if ($before -ne $after) { Bad 'reporting MODIFIED the audit log - the trail must be read-only to reporting' }
    else { Ok 'reporting does not modify the audit log (hash unchanged)' }

    # The module must not contain a CALL that could write a record. Checked over the AST's command
    # nodes rather than over the text: the module's header explains this rule in prose, and a text
    # match reported the explanation itself as the defect (the same trap this project has hit before -
    # "a check that matches its own comment"). The AST sees commands, so comments cannot match.
    $repPath = Join-Path $root 'src\Wuu.Reporting.psm1'
    $repErrors = $null
    $repAst = [System.Management.Automation.Language.Parser]::ParseFile($repPath, [ref]$null, [ref]$repErrors)
    $forbidden = @('Write-WuuAuditRecord', 'Add-WuuAuditRecordLocked', 'Invoke-WuuAuditedAction',
        'Set-Content', 'Add-Content', 'Out-File', 'Remove-Item', 'Clear-Content')
    $called = @()
    if ($repAst) {
        foreach ($c in $repAst.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $c.GetCommandName()
            if ($name -and ($forbidden -contains $name)) { $called += "$name (line $($c.Extent.StartLineNumber))" }
        }
    }
    if ($called.Count -gt 0) {
        Bad "Wuu.Reporting CALLS something that could write to the audit trail: $($called -join '; ')"
    } else {
        Ok 'Wuu.Reporting calls nothing that could write to the audit trail (verified on the AST, so comments cannot mask it)'
    }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'Test-Reporting.ps1: ALL PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host "Test-Reporting.ps1: $fail FAILURE(S)" -ForegroundColor Red
    exit 1
}
