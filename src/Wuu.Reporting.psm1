#Requires -Version 5.1
<#
.DESCRIPTION
Deployment and reliability reporting: reads the audit trail and answers operational questions
("did the roll-out work, and what keeps failing?").

READ-ONLY, AND PROVABLY SO. This module opens audit files for reading only and never writes one.
That is not a convenience - the audit trail's value is that it is append-only and hash-chained, so a
reporting tool that could rewrite it would undermine the control it reports on. Nothing here calls
Add-WuuAuditRecordLocked or Write-WuuAuditRecord; `wuu report` records itself through the ordinary
best-effort read path in Wuu.Command, like `show` and `export`.

WHAT THE DATA ACTUALLY SUPPORTS, WHICH IS NOT WHAT A REPORTING BRIEF USUALLY ASSUMES
-----------------------------------------------------------------------------------
The trail records operations at TWO levels, and they carry different information:

  * A BATCH record (category 'outcome', written by Invoke-WuuAuditedAction) carries the full `targets`
    array and the batch `result`, but NO per-target outcome - Invoke-WuuAuditedAction never passes
    -Counts. So "run #12 installed on 8 of 10 machines" is NOT reconstructable from the trail.
  * A COMMAND record (written by the command-mode path in Wuu.Core) carries `counts` and a
    per-computer `Computers` array, but that array is in the 'parameters' bag, NOT in `targets`, and
    the action name is the VERB ('install') rather than the handler it dispatches ('EventInstallUpdates').

Reporting therefore counts what each record can actually prove:
  * Batch-level: one count per distinct runId (with its target list).
  * Target-level: PER-TARGET FAILURE from records that name a target AND carry a failure. The
    brief asks for per-target success counts; those live in the state store the moment an operation
    runs and are gone from the audit trail after, so reporting a fabricateable zero would be worse
    than reporting nothing. Success is a BATCH fact; failure is a TARGET fact. The Summary says so.

RESULT VOCABULARY. The trail uses 'started', 'succeeded', 'failed', 'denied', 'declined', 'whatif',
'info', plus a handful of legacy 'Success' records from before the vocabulary settled. Only
'succeeded'/'failed' are deployment OUTCOMES; treating 'started' as one would count every intent
record as a successful deployment, and 'denied' (111 of them in the local store, all "missing
-Reason") is a PRE-FLIGHT refusal, not an install that ran and failed.

STREAMING. Files are read with [System.IO.File]::ReadLines, not Get-Content: a busy estate's daily
log is large, and materialising every line as a string array before filtering is the kind of thing
that works on a developer's five-day store and dies on a real one.
#>

#region Schema handling

# Field names are read through ONE accessor per record shape rather than dotted directly, because
# a property that is absent in an older log would otherwise surface as $null from a missing member
# on some objects and throw on others. A record written before a field existed must read as "no
# value", not crash the report.
function Get-WuuRecordField {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Record,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$Default = $null
    )
    if ($null -eq $Record) { return $Default }
    try {
        # PSObject.Properties is the correct existence test: a PSCustomObject built from JSON has no
        # such property on a missing key, whereas $Record.$Name on a hashtable silently yields $null
        # and on a strict object throws.
        $prop = $Record.PSObject.Properties[$Name]
        if ($null -eq $prop) { return $Default }
        $value = $prop.Value
        if ($null -eq $value) { return $Default }
        return $value
    } catch {
        return $Default
    }
}

#endregion Schema handling

#region Time window

function ConvertTo-WuuReportWindow {
    <#
    .SYNOPSIS Turns a period token ('24h', '7d', 'all') or explicit dates into a [From, To] window.
    .DESCRIPTION
    Returns a UTC window. Explicit -From/-To win over -Period, because an operator who names both a
    period and a range has told us exactly what they mean and resolving the period first would throw
    their dates away.
    #>
    param(
        [string]$Period = '7d',
        [AllowNull()][object]$FromUtc,
        [AllowNull()][object]$ToUtc
    )

    $to = if ($ToUtc) { [datetime]$ToUtc } else { (Get-Date).ToUniversalTime() }
    $to = $to.ToUniversalTime()

    if ($FromUtc) {
        $from = ([datetime]$FromUtc).ToUniversalTime()
        if ($from -gt $to) {
            return @{ Ok = $false; Error = "-From ($($from.ToString('u'))) is after -To ($($to.ToString('u'))) - the window is empty by construction" }
        }
        return @{ Ok = $true; From = $from; To = $to; Label = "custom range"; Period = 'custom' }
    }

    # LOCAL VARIABLE, not an assignment to $Period. PowerShell parameter names are case-insensitive,
    # so `$Period = ...` mutates the [string]$Period parameter - and the declared type is enforced on
    # every assignment, so a later non-string would throw from the parameter rather than here. The
    # release gate refuses this pattern for exactly that reason.
    $periodToken = if ([string]::IsNullOrWhiteSpace($Period)) { '7d' } else { $Period.Trim().ToLowerInvariant() }

    if ($periodToken -eq 'all') {
        return @{ Ok = $true; From = [datetime]::MinValue; To = $to; Label = 'all time'; Period = 'all' }
    }

    # <n><unit>: h = hours, d = days, w = weeks, m = months (30-day months, documented because an
    # operator comparing a monthly report to a calendar will otherwise ask why the numbers differ).
    $m = [regex]::Match($periodToken, '^(\d+)\s*(h|d|w|m)$')
    if (-not $m.Success) {
        return @{ Ok = $false; Error = "invalid -Period '$Period' - use <n>h, <n>d, <n>w, <n>m, or 'all' (for example 24h, 7d, 30d)" }
    }
    $n = [int]$m.Groups[1].Value
    if ($n -le 0) { return @{ Ok = $false; Error = "-Period '$Period' is not a positive length" } }

    $seconds = switch ($m.Groups[2].Value) {
        'h' { $n * 3600 }
        'd' { $n * 86400 }
        'w' { $n * 604800 }
        'm' { $n * 2592000 }
    }
    $from = $to.AddSeconds(-$seconds)
    $totalHours = [math]::Round(($to - $from).TotalHours, 1)
    return @{ Ok = $true; From = $from; To = $to; Label = "last $periodToken"; Period = $periodToken; TotalHours = $totalHours }
}

#endregion Time window

#region History

function Get-WuuAuditHistory {
    <#
    .SYNOPSIS Reads audit records inside a time window, newest-last, without materialising the logs.
    .DESCRIPTION
    Streams every matching audit-*.jsonl line with [System.IO.File]::ReadLines and keeps the records
    that fall in the window and match the optional target filter.

    A malformed line is COUNTED AND SKIPPED, not thrown on. One bad line in a 300 KB log must not
    make a month of history unreadable - and the trail already has a dedicated tool (wuu audit
    verify) for deciding whether a break is tampering, which is not this tool's job. The count is
    returned so the report can say the figures are based on the lines it could read.
    #>
    param(
        [string]$Period = '7d',
        [AllowNull()][object]$FromUtc,
        [AllowNull()][object]$ToUtc,
        [string[]]$Computer = @(),
        [string]$LogPath
    )

    $window = ConvertTo-WuuReportWindow -Period $Period -FromUtc $FromUtc -ToUtc $ToUtc
    if (-not $window.Ok) {
        return @{ Ok = $false; Error = $window.Error; Records = @(); MalformedLines = 0; Files = @() }
    }

    # Which files to open. A named -LogPath is authoritative (used by tests and for an air-gapped
    # copy); otherwise every daily log is considered, and its FILENAME date is used to skip whole
    # files cheaply - an audit-YYYYMMDD.jsonl holds that UTC day, so a file outside the window
    # cannot contribute and does not need to be opened.
    $files = @()
    if ($LogPath) {
        if (-not (Test-Path -LiteralPath $LogPath)) {
            return @{ Ok = $false; Error = "audit log not found: $LogPath"; Records = @(); MalformedLines = 0; Files = @() }
        }
        $files = @(Get-Item -LiteralPath $LogPath)
    } else {
        $dir = Get-WuuAuditDirectory
        $files = @(Get-ChildItem -LiteralPath $dir -Filter 'audit-*.jsonl' -File -ErrorAction SilentlyContinue |
            Sort-Object Name)
        if ($files.Count -eq 0) {
            return @{ Ok = $true; Records = @(); MalformedLines = 0; Files = @(); From = $window.From; To = $window.To
                Label = $window.Label; Period = $window.Period; TotalHours = $window.TotalHours; Empty = $true }
        }
    }

    $filter = @($Computer | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    $records = New-Object System.Collections.ArrayList
    $malformed = 0
    $read = New-Object System.Collections.ArrayList
    $skippedFiles = 0

    foreach ($f in $files) {
        # Filename-date skip: audit-YYYYMMDD.jsonl. Only applied when the name matches the pattern,
        # so an oddly named file is read rather than silently ignored.
        $dm = [regex]::Match($f.Name, '^audit-(\d{4})(\d{2})(\d{2})\.jsonl$')
        if ($dm.Success -and $window.Period -ne 'all') {
            try {
                $fileDay = (New-Object datetime([int]$dm.Groups[1].Value, [int]$dm.Groups[2].Value, [int]$dm.Groups[3].Value)).ToUniversalTime()
                # A day file covers [fileDay, fileDay + 1 day). Skip it only when that whole span sits
                # outside the window - an overlap of even one hour means it must be read.
                if ($fileDay.AddDays(1) -le $window.From -or $fileDay -gt $window.To) { $skippedFiles++; continue }
            } catch { }
        }

        [void]$read.Add($f.Name)
        try {
            foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $rec = $null
                try { $rec = $line | ConvertFrom-Json } catch { $malformed++; continue }
                if ($null -eq $rec) { $malformed++; continue }

                $ts = Get-WuuRecordField -Record $rec -Name 'timestampUtc'
                if ($ts) {
                    $when = [datetime]::MinValue
                    if (-not [datetime]::TryParse([string]$ts, [ref]$when)) { $malformed++; continue }
                    $when = $when.ToUniversalTime()
                    if ($when -lt $window.From -or $when -gt $window.To) { continue }
                }

                if ($filter.Count -gt 0) {
                    $targets = @(Get-WuuRecordField -Record $rec -Name 'targets' -Default @())
                    $hit = $false
                    foreach ($t in $targets) { if ($filter -contains [string]$t) { $hit = $true; break } }
                    if (-not $hit) { continue }
                }
                [void]$records.Add($rec)
            }
        } catch {
            Write-WarningLog "Report: could not read $($f.FullName): $($_.Exception.Message)"
            $malformed++
        }
    }

    return @{
        Ok             = $true
        Records        = @($records.ToArray())
        MalformedLines = $malformed
        Files          = @($read.ToArray())
        FilesSkipped   = $skippedFiles
        From           = $window.From
        To             = $window.To
        Label          = $window.Label
        Period         = $window.Period
        TotalHours     = $window.TotalHours
        Empty          = ($records.Count -eq 0)
    }
}

#endregion History

#region Classification

# The actions that represent a DEPLOYMENT. A session start is not a deployment, and neither is a
# read ('show', 'check', 'audit verify'): counting those would make a report that says the fleet
# is fine whenever nobody tried anything.
$script:WuuDeploymentActions = @(
    'install', 'EventInstallUpdates'
    'download', 'EventDownloadUpdates'
    'reboot', 'EventRestartComputer'
    'service', 'EventServiceAction'
    'autofill', 'EventAutoFlow'
)

function Test-WuuDeploymentAction {
    <#
    .SYNOPSIS Whether an action name represents a deployment (as opposed to a read or a session).
    #>
    param([AllowNull()][string]$Action)
    if ([string]::IsNullOrWhiteSpace($Action)) { return $false }
    return ($script:WuuDeploymentActions -contains $Action.Trim())
}

function Resolve-WuuRunOutcome {
    <#
    .SYNOPSIS Classifies a run's records into exactly one outcome.
    .DESCRIPTION
    Order is deliberate and each step is a rule with a reason:

      1. DENIED / DECLINED WINS. A run refused before it started never touched a machine. If any
         of its records was refused, the run is a refusal even if some other record succeeded
         (which would mean the refusal happened on a later attempt under the same run).
      2. SUCCEEDED requires a 'succeeded' record. Anything else - only 'started', or only 'info' -
         has no recorded outcome, which is a THIRD state, not a success. Recording it as success
         is how a report claims a roll-out worked when the machine may never have been contacted.
      3. FAILED if a 'failed' record or a non-empty error exists.
      4. Otherwise UNKNOWN.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records)

    $denied = $false; $succeeded = $false; $failed = $false; $started = $false
    $lastError = ''
    # The RAW result that decided the verdict, kept so a caller can phrase the cause precisely.
    # 'denied' (blocked - e.g. no -Reason) and 'declined' (the operator or a busy machine chose not to
    # proceed) are both refusals but they are not the same finding, and collapsing them into one word
    # loses the difference between a process defect and a machine that was reachable but occupied.
    $refusalResult = ''
    foreach ($r in @($Records)) {
        $result = [string](Get-WuuRecordField -Record $r -Name 'result' -Default '')
        $err = [string](Get-WuuRecordField -Record $r -Name 'error' -Default '')
        if ($err) { $lastError = $err }
        switch ($result.ToLowerInvariant()) {
            'denied' { $denied = $true; if (-not $refusalResult) { $refusalResult = 'denied' } }
            'declined' { $denied = $true; if (-not $refusalResult) { $refusalResult = 'declined' } }
            'succeeded' { $succeeded = $true }
            'success' { $succeeded = $true }
            'failed' { $failed = $true }
            'started' { $started = $true }
        }
        if ($err -and $result -notin @('denied', 'declined')) { $failed = $true }
    }

    if ($denied) { return [pscustomobject]@{ Outcome = 'Denied'; Error = $lastError; RefusalResult = $refusalResult } }
    if ($failed) { return [pscustomobject]@{ Outcome = 'Failed'; Error = $lastError; RefusalResult = '' } }
    if ($succeeded) { return [pscustomobject]@{ Outcome = 'Succeeded'; Error = $lastError; RefusalResult = '' } }
    if ($started) { return [pscustomobject]@{ Outcome = 'Started'; Error = $lastError; RefusalResult = '' } }
    return [pscustomobject]@{ Outcome = 'Unknown'; Error = $lastError; RefusalResult = '' }
}

#endregion Classification

#region Report

function Get-WuuDeploymentReport {
    <#
    .SYNOPSIS Builds the deployment report from history records.
    .DESCRIPTION
    Aggregates at BATCH level (one entry per distinct runId) and derives per-TARGET FAILURES from the
    records that name a target. See the module header for why per-target success is not reported.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [ValidateSet('Day', 'Week', 'Month', 'None')][string]$GroupBy = 'Day',
        [switch]$FailedOnly
    )

    $deployment = @($Records | Where-Object { Test-WuuDeploymentAction ([string](Get-WuuRecordField -Record $_ -Name 'action' -Default '')) })
    if ($FailedOnly) {
        $deployment = @($deployment | Where-Object {
                [string](Get-WuuRecordField -Record $_ -Name 'result' -Default '') -in @('failed', 'denied', 'declined')
            })
    }

    # Group into runs. runId is the batch key; a record without one cannot be attributed to a batch,
    # so it is grouped alone rather than merged into another run's verdict.
    $byRun = @{}
    $order = New-Object System.Collections.ArrayList
    foreach ($r in $deployment) {
        $runId = [string](Get-WuuRecordField -Record $r -Name 'runId' -Default '')
        if (-not $runId) { $runId = "unattributed:$([guid]::NewGuid().ToString('N'))" }
        if (-not $byRun.ContainsKey($runId)) {
            $byRun[$runId] = New-Object System.Collections.ArrayList
            [void]$order.Add($runId)
        }
        [void]$byRun[$runId].Add($r)
    }

    $runs = New-Object System.Collections.ArrayList
    foreach ($runId in $order) {
        $recs = @($byRun[$runId].ToArray())
        $verdict = Resolve-WuuRunOutcome -Records $recs

        # The batch's targets: the union across its records, because the intent record and the outcome
        # record can name the same list and a target appearing in either is a target of this run.
        $targets = New-Object System.Collections.ArrayList
        $action = ''
        $when = $null
        $duration = 0
        foreach ($r in $recs) {
            if (-not $action) { $action = [string](Get-WuuRecordField -Record $r -Name 'action' -Default '') }
            foreach ($t in @(Get-WuuRecordField -Record $r -Name 'targets' -Default @())) {
                if ($t -and -not $targets.Contains([string]$t)) { [void]$targets.Add([string]$t) }
            }
            $ts = [string](Get-WuuRecordField -Record $r -Name 'timestampUtc' -Default '')
            if ($ts) {
                $parsed = [datetime]::MinValue
                if ([datetime]::TryParse($ts, [ref]$parsed)) {
                    # The EARLIEST record is the run's start: the intent line precedes the outcome.
                    if ($null -eq $when -or $parsed.ToUniversalTime() -lt $when) { $when = $parsed.ToUniversalTime() }
                }
            }
            $duration = [Math]::Max($duration, [int](Get-WuuRecordField -Record $r -Name 'durationMs' -Default 0))
        }

        [void]$runs.Add([pscustomobject]@{
                RunId     = $runId
                Action    = $action
                Outcome   = $verdict.Outcome
                RefusalResult = $verdict.RefusalResult
                Targets   = @($targets.ToArray())
                Started   = $when
                DurationMs = $duration
                Error     = $verdict.Error
            })
    }

    $runsArr = @($runs.ToArray())
    $succeededRuns = @($runsArr | Where-Object { $_.Outcome -eq 'Succeeded' }).Count
    $failedRuns = @($runsArr | Where-Object { $_.Outcome -eq 'Failed' }).Count
    $deniedRuns = @($runsArr | Where-Object { $_.Outcome -eq 'Denied' }).Count
    $startedRuns = @($runsArr | Where-Object { $_.Outcome -eq 'Started' }).Count
    $unknownRuns = @($runsArr | Where-Object { $_.Outcome -eq 'Unknown' }).Count

    # Per-target FAILURES. A target is counted once per run it FAILED in.
    #
    # REFUSED RUNS ARE EXCLUDED, and that exclusion is the difference between a useful report and a
    # misleading one. A refusal never reached the machine: the local store holds 112 runs against one
    # host refused for "missing -Reason", which is an OPERATOR error. Counting those as failures would
    # put that host top of a "failing machines" table at a 100% failure rate, telling a reader the host
    # is broken when in fact nobody ever tried to patch it. Refusals are reported - in the summary and
    # in the cause table - but they are not machine failures, and the two must not share a column.
    $targetStats = @{}
    foreach ($run in $runsArr) {
        if ($run.Outcome -ne 'Failed') { continue }
        foreach ($t in $run.Targets) {
            if (-not $targetStats.ContainsKey($t)) {
                $targetStats[$t] = [pscustomobject]@{ Computer = $t; Attempts = 0; Failures = 0; LastError = ''; LastSeen = $null }
            }
            $targetStats[$t].Failures++
            if ($run.Error) { $targetStats[$t].LastError = $run.Error }
            if ($null -eq $targetStats[$t].LastSeen -or $run.Started -gt $targetStats[$t].LastSeen) { $targetStats[$t].LastSeen = $run.Started }
        }
    }
    # Attempts: every FAILED run that named the target. Counting attempts across refusals too would
    # dilute the failure rate with runs that never executed.
    foreach ($run in $runsArr) {
        if ($run.Outcome -ne 'Failed') { continue }
        foreach ($t in $run.Targets) {
            if ($targetStats.ContainsKey($t)) { $targetStats[$t].Attempts++ }
        }
    }

    $problemTargets = @($targetStats.Values |
        Where-Object { $_.Failures -gt 0 } |
        Sort-Object -Property @{ Expression = 'Failures'; Descending = $true }, @{ Expression = 'Computer'; Descending = $false })

    # Error breakdown: WHY RUNS DID NOT SUCCEED - failed and refused alike.
    #
    # This one DOES include refusals, and that is not inconsistent with the target table above: a
    # refusal cause is a real operational finding ("111 runs were blocked because -Reason was missing"
    # is exactly the process defect a report should surface). It is a frequency table of error strings
    # across runs that did not succeed, so it answers "what is stopping the roll-out?" rather than
    # "which machine is broken?" - two different questions that a shared column would conflate.
    $errors = @{}
    $refusalCauses = @{}
    foreach ($run in $runsArr) {
        if ($run.Outcome -notin @('Failed', 'Denied')) { continue }
        # Prefer the recorded error; otherwise name WHAT HAPPENED using the raw result rather than the
        # collapsed verdict word, so "declined" is not reported as "denied".
        $key = if ($run.Error) { $run.Error }
        elseif ($run.Outcome -eq 'Denied') { "$($run.RefusalResult) - no error text recorded" }
        else { 'failed - no error text recorded' }
        if (-not $errors.ContainsKey($key)) { $errors[$key] = 0 }
        $errors[$key]++
        if ($run.Outcome -eq 'Denied') { $refusalCauses[$key] = $true }
    }
    $errorBreakdown = @($errors.GetEnumerator() |
        Sort-Object -Property @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Key'; Descending = $false } |
        ForEach-Object {
            [pscustomobject]@{
                Error = $_.Key
                Count = $_.Value
                # Lets a reader (and the console) tell an operator-process refusal apart from a machine
                # fault without parsing the message text.
                IsRefusal = [bool]$refusalCauses[$_.Key]
            }
        })

    # Time buckets.
    $buckets = @()
    if ($GroupBy -ne 'None') {
        $bucketMap = @{}
        $bucketOrder = New-Object System.Collections.ArrayList
        foreach ($run in $runsArr) {
            if ($null -eq $run.Started -or $run.Started -eq [datetime]::MinValue) { continue }
            $d = $run.Started.Date
            $label = switch ($GroupBy) {
                'Day' { $d.ToString('yyyy-MM-dd') }
                'Week' { $start = $d.AddDays(-[int]$d.DayOfWeek); "week of {0}" -f $start.ToString('yyyy-MM-dd') }
                'Month' { $d.ToString('yyyy-MM') }
            }
            if (-not $bucketMap.ContainsKey($label)) {
                $bucketMap[$label] = [pscustomobject]@{ PeriodLabel = $label; Total = 0; Succeeded = 0; Failed = 0; Denied = 0; Started = 0; Unknown = 0 }
                [void]$bucketOrder.Add($label)
            }
            $b = $bucketMap[$label]
            $b.Total++
            switch ($run.Outcome) {
                'Succeeded' { $b.Succeeded++ }
                'Failed' { $b.Failed++ }
                'Denied' { $b.Denied++ }
                'Started' { $b.Started++ }
                default { $b.Unknown++ }
            }
        }
        $buckets = @($bucketOrder | ForEach-Object {
                $b = $bucketMap[$_]
                $settled = $b.Succeeded + $b.Failed
                $rate = if ($settled -gt 0) { [math]::Round(($b.Succeeded / $settled) * 100, 1) } else { $null }
                [pscustomobject]@{
                    PeriodLabel = $b.PeriodLabel; Total = $b.Total; Succeeded = $b.Succeeded; Failed = $b.Failed
                    Denied = $b.Denied; Started = $b.Started; Unknown = $b.Unknown; SuccessRate = $rate
                }
            })
    }

    # Average duration over runs that COMPLETED (succeeded/failed). Averaging in 'started' records
    # would drag the mean toward zero, because an intent record has no duration.
    $completed = @($runsArr | Where-Object { $_.Outcome -in @('Succeeded', 'Failed') -and $_.DurationMs -gt 0 })
    $avg = if ($completed.Count -gt 0) { [math]::Round((($completed | Measure-Object -Property DurationMs -Average).Average) / 1000, 1) } else { $null }

    $settledTotal = $succeededRuns + $failedRuns
    $successRate = if ($settledTotal -gt 0) { [math]::Round(($succeededRuns / $settledTotal) * 100, 1) } else { $null }

    return [pscustomobject]@{
        Summary = [pscustomobject]@{
            TotalRuns          = $runsArr.Count
            SuccessfulRuns     = $succeededRuns
            FailedRuns         = $failedRuns
            DeniedRuns         = $deniedRuns
            StartedRuns        = $startedRuns
            UnknownRuns        = $unknownRuns
            SettledRuns        = $settledTotal
            SuccessRatePercent = $successRate
            AvgDurationSeconds = $avg
            DistinctTargets    = @($targetStats.Keys).Count
            FailingTargets     = @($problemTargets).Count
        }
        Runs          = $runsArr
        TimeBuckets   = $buckets
        ProblemTargets = @($problemTargets | ForEach-Object {
                [pscustomobject]@{
                    Computer    = $_.Computer
                    Attempts    = $_.Attempts
                    Failures    = $_.Failures
                    FailureRate = if ($_.Attempts -gt 0) { [math]::Round(($_.Failures / $_.Attempts) * 100, 1) } else { $null }
                    LastError   = $_.LastError
                }
            })
        ErrorBreakdown = $errorBreakdown
    }
}

#endregion Report

#region Output

function Format-WuuReportTable {
    <#
    .SYNOPSIS Renders a report to the console: summary card, buckets, failing targets, causes.
    .DESCRIPTION
    Prose goes to stdout via Write-Host; the machine-readable form is built by the caller. A report
    whose only output is a table cannot be diffed between runs, and one whose only output is JSON is
    unusable at a console - so both exist and the caller chooses.
    #>
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][AllowNull()]$Window,
        [int]$Top = 5
    )

    $writeReportLine = {
        param([string]$Text, [string]$Role = '')
        if ($Role) {
            $col = Get-WuuThemeColor -Role $Role
            if ($col) { Write-Host $Text -ForegroundColor $col } else { Write-Host $Text }
        } else {
            Write-Host $Text
        }
    }

    $s = $Report.Summary
    Write-Host ''
    &$writeReportLine '  ============================================================' 'Muted'
    &$writeReportLine '   WUU2 DEPLOYMENT REPORT' 'Info'
    &$writeReportLine '  ============================================================' 'Muted'
    if ($Window) {
        &$writeReportLine ("   Period   : {0}" -f $Window.Label)
        &$writeReportLine ("   From (UTC): {0}" -f ([datetime]$Window.From).ToString('yyyy-MM-dd HH:mm:ss'))
        &$writeReportLine ("   To   (UTC): {0}" -f ([datetime]$Window.To).ToString('yyyy-MM-dd HH:mm:ss'))
        if ($Window.Files) { &$writeReportLine ("   Logs     : {0} file(s)" -f @($Window.Files).Count) 'Muted' }
        if ($Window.FilesSkipped) { &$writeReportLine ("              ({0} file(s) outside the window skipped by name)" -f $Window.FilesSkipped) 'Muted' }
    }
    Write-Host ''

    &$writeReportLine '   DEPLOYMENT RUNS' 'Header'
    &$writeReportLine ("     Runs recorded      : {0}" -f $s.TotalRuns)
    $succRole = if ($s.SuccessfulRuns -gt 0) { 'Success' } else { 'Muted' }
    &$writeReportLine ("     Succeeded          : {0}" -f $s.SuccessfulRuns) $succRole
    $failRole = if ($s.FailedRuns -gt 0) { 'Failure' } else { 'Muted' }
    &$writeReportLine ("     Failed             : {0}" -f $s.FailedRuns) $failRole
    $denRole = if ($s.DeniedRuns -gt 0) { 'Attention' } else { 'Muted' }
    &$writeReportLine ("     Refused (pre-flight): {0}" -f $s.DeniedRuns) $denRole
    if ($s.StartedRuns -gt 0) {
        &$writeReportLine ("     Started, no outcome: {0}" -f $s.StartedRuns) 'Attention'
        &$writeReportLine '       (intent recorded with no outcome record - typically interrupted)' 'Muted'
    }
    if ($s.UnknownRuns -gt 0) { &$writeReportLine ("     Unclassified       : {0}" -f $s.UnknownRuns) 'Muted' }

    if ($null -ne $s.SuccessRatePercent) {
        $rateRole = if ($s.SuccessRatePercent -ge 95) { 'Success' } elseif ($s.SuccessRatePercent -ge 80) { 'Attention' } else { 'Failure' }
        &$writeReportLine ("     Success rate       : {0}% of settled runs" -f $s.SuccessRatePercent) $rateRole
    } else {
        &$writeReportLine '     Success rate       : n/a (no run reached a settled outcome)' 'Muted'
    }
    if ($null -ne $s.AvgDurationSeconds) { &$writeReportLine ("     Avg duration       : {0}s" -f $s.AvgDurationSeconds) 'Muted' }

    Write-Host ''
    &$writeReportLine '   NOTE: rates above are per RUN. The audit trail records a batch outcome and its target' 'Muted'
    &$writeReportLine '         list, not a per-machine result, so per-machine success cannot be derived from it.' 'Muted'
    &$writeReportLine ("         Per-machine detail below shows FAILURES only ({0} target(s) affected)." -f $s.FailingTargets) 'Muted'

    if ($Report.TimeBuckets.Count -gt 0) {
        Write-Host ''
        &$writeReportLine '   BY PERIOD' 'Header'
        &$writeReportLine ("     {0,-16} {1,6} {2,7} {3,6} {4,7} {5,8}" -f 'Period', 'Total', 'OK', 'Failed', 'Refused', 'Rate')
        foreach ($b in $Report.TimeBuckets) {
            $rate = if ($null -ne $b.SuccessRate) { "$($b.SuccessRate)%" } else { '-' }
            &$writeReportLine ("     {0,-16} {1,6} {2,7} {3,6} {4,7} {5,8}" -f $b.PeriodLabel, $b.Total, $b.Succeeded, $b.Failed, $b.Denied, $rate)
        }
    }

    if ($Report.ProblemTargets.Count -gt 0) {
        Write-Host ''
        &$writeReportLine ("   TOP FAILING TARGETS (machines that failed a deployment, top {0})" -f $Top) 'Failure'
        &$writeReportLine ("     {0,-22} {1,9} {2,9} {3,8}  {4}" -f 'Computer', 'Attempts', 'Failures', 'Rate', 'Last error')
        foreach ($t in @($Report.ProblemTargets | Select-Object -First $Top)) {
            $rate = if ($null -ne $t.FailureRate) { "$($t.FailureRate)%" } else { '-' }
            $err = if ($t.LastError) { $t.LastError } else { '-' }
            if ($err.Length -gt 34) { $err = $err.Substring(0, 31) + '...' }
            &$writeReportLine ("     {0,-22} {1,9} {2,9} {3,8}  {4}" -f $t.Computer, $t.Attempts, $t.Failures, $rate, $err)
        }
    } else {
        Write-Host ''
        &$writeReportLine '   No target failures recorded in this window.' 'Success'
        if ($s.DeniedRuns -gt 0) {
            &$writeReportLine '     (Deployment runs were refused before reaching a machine - see causes below.)' 'Muted'
        }
    }

    if ($Report.ErrorBreakdown.Count -gt 0) {
        Write-Host ''
        &$writeReportLine ("   TOP CAUSES OF UNSETTLED RUNS (top {0})" -f $Top) 'Attention'
        foreach ($e in @($Report.ErrorBreakdown | Select-Object -First $Top)) {
            $tag = if ($e.IsRefusal) { ' [refused]' } else { ' [failed] ' }
            $causeRole = if ($e.IsRefusal) { 'Muted' } else { 'Attention' }
            &$writeReportLine ("     {0,5}x{1} {2}" -f $e.Count, $tag, $e.Error) $causeRole
        }
    }

    if ($Window -and $Window.MalformedLines -gt 0) {
        Write-Host ''
        &$writeReportLine ("   WARNING: {0} unreadable line(s) were skipped; figures cover the lines that parsed." -f $Window.MalformedLines) 'Attention'
        &$writeReportLine '            Run "wuu audit verify" to decide whether that is tampering.' 'Muted'
    }
    Write-Host ''
}

function Export-WuuDeploymentReport {
    <#
    .SYNOPSIS Writes a report to CSV (runs, targets or causes), or returns it for -Json.
    .DESCRIPTION
    Three datasets because they are three different tables; flattening them into one CSV would
    produce a file whose rows mean different things, which is not a dataset.
    #>
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Runs', 'Targets', 'Causes')][string]$Dataset = 'Runs'
    )

    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop }

        $rows = switch ($Dataset) {
            'Runs' {
                @($Report.Runs | ForEach-Object {
                        [pscustomobject][ordered]@{
                            RunId      = $_.RunId
                            Action     = $_.Action
                            Outcome    = $_.Outcome
                            Started    = $(if ($_.Started) { ([datetime]$_.Started).ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
                            DurationMs = $_.DurationMs
                            Targets    = ($_.Targets -join ';')
                            Error      = $_.Error
                        }
                    })
            }
            'Targets' {
                @($Report.ProblemTargets | ForEach-Object {
                        [pscustomobject][ordered]@{
                            Computer = $_.Computer; Attempts = $_.Attempts; Failures = $_.Failures
                            FailureRate = $_.FailureRate; LastError = $_.LastError
                        }
                    })
            }
            'Causes' {
                @($Report.ErrorBreakdown | ForEach-Object {
                        [pscustomobject][ordered]@{ Error = $_.Error; Count = $_.Count }
                    })
            }
        }

        # -NoTypeInformation keeps the first line as the header rather than a #TYPE comment, so the
        # file opens as a table in Excel rather than as a comment followed by data.
        if (@($rows).Count -eq 0) {
            # An empty dataset still writes a HEADER: a zero-byte file is indistinguishable from a
            # failed export, and a consumer parsing it would fail rather than find no rows.
            $headers = switch ($Dataset) {
                'Runs' { 'RunId,Action,Outcome,Started,DurationMs,Targets,Error' }
                'Targets' { 'Computer,Attempts,Failures,FailureRate,LastError' }
                'Causes' { 'Error,Count' }
            }
            [System.IO.File]::WriteAllText($Path, $headers + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        } else {
            $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
        }
        return @{ Success = $true; Path = $Path; Rows = @($rows).Count; Dataset = $Dataset; Error = $null }
    } catch {
        return @{ Success = $false; Path = $Path; Rows = 0; Dataset = $Dataset; Error = $_.Exception.Message }
    }
}

#endregion Output

Export-ModuleMember -Function @(
    'Get-WuuAuditHistory'
    'Get-WuuDeploymentReport'
    'Format-WuuReportTable'
    'Export-WuuDeploymentReport'
    'ConvertTo-WuuReportWindow'
    'Test-WuuDeploymentAction'
    'Resolve-WuuRunOutcome'
)
