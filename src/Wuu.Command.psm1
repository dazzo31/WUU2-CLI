#Requires -Version 5.1
<#
.DESCRIPTION
Command-line surface for WUU2-CLI (Phase 2 of docs/CLI_AUDIT_PLAN.md).

Turns the interactive operations into scriptable verbs so WUU can run unattended:

    wuu check    -Computer SRV01,SRV02
    wuu download -All
    wuu install  -Computer SRV01 -Reboot
    wuu show available -All
    wuu service restart -Computer SRV01
    wuu add -Computer A,B      wuu export -Path out.csv
    wuu audit wsus -All -Json

DESIGN: DISPATCH, NOT DUPLICATE
--------------------------------
This module does NOT reimplement any operation. Each verb resolves its arguments into
(a) an action name and (b) the ordered answers the interactive helper would have prompted for,
then calls the SAME handler the menu calls after switching input to non-interactive mode via
Initialize-WuuInputMode. So there is exactly one implementation of every operation, and the
`-WhatIf` flag is honoured the same way in both surfaces.

Consequences that fall out of that design (all intentional):
  * `-Computer` is simply the first answer to the handler's selection prompt. Because the
    selection helper already accepts names, comma lists, prefixes and "all", no per-verb
    selection logic is needed here.
  * A verb that needs an input the caller did not supply FAILS with a clear message rather
    than prompting (Read-WuuAnswer throws in non-interactive mode). That is what makes CI safe.
  * `-Json` is only meaningful for read verbs; mutating verbs return a status string.

VERB MAP (mirrors the menu in Wuu.Console.psm1 Get-WuuMenuActions 1:1)
----------------------------------------------------------------------
  check / download / install / restart          -> EventGetUpdates etc.
  add -Computer | -FromFile | -FromOU           -> EventAddComputer / EventAddFile
  remove / clear / prune                        -> EventRemoveSelected / ClearComputerList
  phase -Set N                                  -> EventAssignPhaseInteractive
  show available|installed|history|errors|phases-> EventShow* / GetErrors
  audit wsus                                    -> EventAuditWSUSUpdates
  logs                                          -> EventViewUpdateLog
  service start|stop|restart                    -> EventWUServiceActionInteractive
  export / config save|load / credentials set    -> EventSave* / EventLoadConfig / …
#>

function Invoke-WuuAuditCommand {
    <#
    .SYNOPSIS The local audit-trail verbs: verify / show / export.
    .DESCRIPTION
    These inspect the audit log itself (Phase 4), not a target's WSUS state (that is
    `audit wsus`). verify exits non-zero on a broken chain so CI can gate on it.

    -Path means different things per subverb and that is deliberate, but it used to be
    accidental: verify/show read it as the log to INSPECT, export writes it as the
    DESTINATION. Because -Path was blindly assigned to $logPath first, `audit export -Path D:\out`
    tried to copy a log from D:\out and threw ItemNotFoundException, surfacing as a
    "CRITICAL ERROR - console shell failed" for what is just an output path. Use -LogPath to
    name the log explicitly for any subverb.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('verify', 'show', 'export')][string]$SubVerb,
        # For verify/show: the log file to inspect. For export: the output destination.
        [string]$Path,
        # Explicit log to inspect/export. Overrides the default "newest daily log" resolution
        # and is unambiguous regardless of subverb.
        [string]$LogPath,
        [switch]$Json
    )

    # Resolve the log to READ. Never derived from -Path on export (that is the destination).
    $resolvedLog = $LogPath
    if (-not $resolvedLog -and $SubVerb -ne 'export' -and $Path) { $resolvedLog = $Path }
    if (-not $resolvedLog) {
        $dir = Get-WuuAuditDirectory
        # Newest daily log, if any.
        $candidates = @(Get-ChildItem -LiteralPath $dir -Filter 'audit-*.jsonl' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
        if ($candidates.Count -eq 0) {
            Write-Host ("  No audit log found in {0}." -f $dir) -ForegroundColor Yellow
            return [pscustomobject]@{ Ok = $false; Verb = 'audit'; SubVerb = $SubVerb; Error = 'no audit log'; Result = 'AuditFailure' }
        }
        $resolvedLog = $candidates[0].FullName
    }
    if (-not (Test-Path -LiteralPath $resolvedLog)) {
        Write-Host ("  Audit log not found: {0}" -f $resolvedLog) -ForegroundColor Red
        return [pscustomobject]@{ Ok = $false; Verb = 'audit'; SubVerb = $SubVerb; Error = "audit log not found: $resolvedLog"; Result = 'AuditFailure' }
    }

    switch ($SubVerb) {
        'verify' {
            Write-Host ("  Verifying {0}" -f $resolvedLog) -ForegroundColor Gray
            $v = Test-WuuAuditChain -LogPath $resolvedLog -Quiet
            if ($Json) {
                [pscustomobject]@{ Command = 'audit verify'; LogPath = $resolvedLog; Ok = $v.Ok; Checked = $v.Checked; FirstBreak = $v.FirstBreak; Problems = $v.Problems } | ConvertTo-Json -Depth 5
            } elseif ($v.Ok) {
                Write-Host ("  Chain intact: {0} record(s) verified." -f $v.Checked) -ForegroundColor Green
            } else {
                Write-Host ("  CHAIN BROKEN at line {0} of {1}:" -f $v.FirstBreak, $v.Checked) -ForegroundColor Red
                foreach ($p in $v.Problems) { Write-Host "    $p" -ForegroundColor Red }
            }
            # A broken chain is an audit-integrity failure, not an operation failure (SS10): it has
            # its own exit code so CI can tell "the trail is tampered with" from "the work failed".
            # The old code set $script:CommandExitCode here, which is THIS module's script scope -
            # not the caller's - so the value never reached the exit path. Classification travels on
            # the result object instead, which crosses the scope boundary correctly.
            return [pscustomobject]@{ Ok = $v.Ok; Verb = 'audit'; SubVerb = $SubVerb; Checked = $v.Checked; FirstBreak = $v.FirstBreak; Result = $(if ($v.Ok) { 'Success' } else { 'AuditFailure' }) }
        }
        'show' {
            $recs = @(Get-Content -LiteralPath $resolvedLog | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_ | ConvertFrom-Json })
            if ($Json) {
                [pscustomobject]@{ Command = 'audit show'; LogPath = $resolvedLog; Count = $recs.Count; Records = $recs } | ConvertTo-Json -Depth 8
            } else {
                Write-Host ("  {0}  ({1} record(s))" -f $resolvedLog, $recs.Count) -ForegroundColor White
                $fmt = "  {0,5} {1,-21} {2,-13} {3,-10} {4,-18} {5}"
                Write-Host ($fmt -f 'seq', 'timestampUtc', 'action', 'result', 'targets', 'reason') -ForegroundColor DarkCyan
                foreach ($r in $recs) {
                    Write-Host ($fmt -f $r.seq, $r.timestampUtc, $r.action, $r.result, (($r.targets) -join ','), $r.reason)
                }
            }
            return [pscustomobject]@{ Ok = $true; Verb = 'audit'; SubVerb = $SubVerb; Count = $recs.Count; Result = 'Success' }
        }
        'export' {
            # Bundle the log (and the matching transcript, if present) into one file for a
            # compliance handoff. Deliberately a copy, never a re-encode: the exported file must
            # be byte-identical to the log or `audit verify` on the copy would be meaningless.
            $outPath = if ($Path) { "$Path.export.zip" } else { Join-Path (Split-Path $resolvedLog -Parent) ("audit-export-{0}.zip" -f (Get-Date -Format 'yyyyMMdd_HHmmss')) }
            # Create the destination directory when -Path names one that does not exist yet.
            # Otherwise ZipFile::CreateFromDirectory throws ItemNotFoundException, which escaped
            # as a "CRITICAL ERROR - console shell failed" for what is really just a mistyped path.
            $outDir = Split-Path $outPath -Parent
            if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
                New-Item -ItemType Directory -Path $outDir -Force | Out-Null
            }
            $staging = Join-Path $env:TEMP ("wuu_audit_export_{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
            New-Item -ItemType Directory -Path $staging -Force | Out-Null
            Copy-Item -LiteralPath $resolvedLog -Destination $staging -Force
            $dirOfLog = Split-Path $resolvedLog -Parent
            foreach ($t in @(Get-ChildItem -LiteralPath $dirOfLog -Filter 'transcript-*.log' -File -ErrorAction SilentlyContinue)) {
                Copy-Item -LiteralPath $t.FullName -Destination $staging -Force
            }
            # Copy the compliance documentation alongside the evidence. An auditor receiving a
            # bundle needs the control mapping and the retention policy: without them the zip is
            # just JSONL, and "what am I looking at and how long is it kept?" is unanswerable.
            $docsDir = Join-Path $PSScriptRoot '..\docs'
            foreach ($docName in @('ISO_27001_A815_MAPPING.md', 'AUDIT_RETENTION.md', 'CLI_AUDIT_PLAN.md')) {
                $docPath = Join-Path $docsDir $docName
                if (Test-Path -LiteralPath $docPath) {
                    Copy-Item -LiteralPath $docPath -Destination $staging -Force
                }
            }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Force }
            [IO.Compression.ZipFile]::CreateFromDirectory($staging, $outPath)
            # Verify the bundle before claiming success: a silently-empty or unreadable zip handed
            # to an auditor is worse than a loud failure here.
            $entryCount = 0
            try {
                $zr = [IO.Compression.ZipFile]::OpenRead($outPath)
                $entryCount = $zr.Entries.Count
                $zr.Dispose()
            } catch {
                Write-Host ("  Export verification FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
                Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
                return [pscustomobject]@{ Ok = $false; Verb = 'audit'; SubVerb = $SubVerb; Error = "export bundle unreadable: $($_.Exception.Message)"; Result = 'AuditFailure' }
            }
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host ("  Exported audit bundle: {0} ({1} entries)" -f $outPath, $entryCount) -ForegroundColor Green
            Write-Host '  NOTE: the bundle carries the hash chain but NO external anchor, so it is' -ForegroundColor DarkGray
            Write-Host '        tamper-EVIDENT, not non-repudiable. See docs/ISO_27001_A815_MAPPING.md 8.' -ForegroundColor DarkGray
            return [pscustomobject]@{ Ok = $true; Verb = 'audit'; SubVerb = $SubVerb; Path = $outPath; Entries = $entryCount; Result = 'Success' }
        }
    }
}

function Get-WuuCommandPlan {
    <#
    .SYNOPSIS What a command WOULD do, per computer, without doing any of it (hardening brief SS11).
    .DESCRIPTION
    `-WhatIf` reported "would run 'install' against all computers" - a single sentence. For a change
    being reviewed before it touches production that is not enough: the reviewer needs to know WHICH
    computers, what each one will actually do, and which requests would NOT take effect. The brief asks
    for exactly that breakdown.

    Three facts per computer, because each changes what a reviewer should conclude:

      * ACTION  - run now, or something else. A `download` against a computer that already has every
                  available update downloaded does NOTHING (the handler answers 'Up-to-Date' and moves
                  on), so "would download to 40 servers" is misleading if 12 of them have nothing to do.
      * BUSY    - whether an operation is already in flight. This matters because the two policies
                  differ per verb, and the difference is not cosmetic:
                    DEFER  (check/download/install) - the row is marked Pending and runs when the
                           current operation finishes. The request is honoured, later.
                    REFUSE (restart/service)        - the request is dropped. A restart is never
                           silently deferred (the operator explicitly confirmed it), and a service
                           action is skipped and reported.
                  A dry run that said "would restart 10 servers" when 3 are busy would be wrong in the
                  most expensive possible direction for a reboot.
      * UNRESOLVED - names that match nothing (or are ambiguous). These are reported, never silently
                  dropped: a typo in a change ticket should be caught by the dry run, not by the change.

    Resolution mirrors Read-WuuSelection exactly (exact name case-insensitively, then a UNIQUE prefix
    match) so the plan lists what would really run rather than a second, divergent interpretation.

    Reads the store's own collections rather than the Wuu.State helpers, so it stays callable wherever
    the store object exists (including from a test that loads only this module).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Verb,
        [AllowNull()][hashtable]$Store,
        [string]$Computer,
        [switch]$All,
        [string]$ServiceAction,
        [int]$Set = 0
    )

    # Which policy applies when a computer is already busy. Stated as data so the dry run and the
    # handlers cannot disagree about it in a way nobody notices.
    $policy = if ($Verb -in @('restart', 'service')) { 'refuse' } else { 'defer' }

    # NOTE: this is $allRows, NOT $all. PowerShell variable names are case-insensitive, so $all IS
    # the [switch]$All parameter - and `$all = @()` therefore assigns an array to a SwitchParameter,
    # which fails at the first `+=` with "Cannot convert the System.Object[] to
    # System.Management.Automation.SwitchParameter". The stack pointed at the assignment, which looks
    # innocuous. Same family as the $Host / $PID collisions; the parameter name is the trap here.
    $allRows = @()
    if ($Store -and $Store.ContainsKey('Rows') -and $Store.Rows) {
        foreach ($r in $Store.Rows) { $allRows += $r }
    }

    $wanted = @()
    $allSelected = $false
    if ($All) { $allSelected = $true }
    elseif ($Computer) {
        foreach ($piece in ($Computer -split '[,;]')) {
            $n = $piece.Trim()
            if (-not $n) { continue }
            if ($n -match '^(all|\*)$') { $allSelected = $true; continue }
            $wanted += $n
        }
    }

    $unresolved = New-Object System.Collections.ArrayList
    $targets = New-Object System.Collections.ArrayList

    $resolve = {
        param([string]$Name)
        foreach ($r in $allRows) { if ([string]$r.Computer -eq $Name) { return $r } }
        $hits = @()
        foreach ($r in $allRows) { if ([string]$r.Computer -like "$Name*") { $hits += $r } }
        if ($hits.Count -eq 1) { return $hits[0] }
        return $null
    }

    $chosen = New-Object System.Collections.ArrayList
    if ($allSelected) {
        foreach ($r in $allRows) { [void]$chosen.Add($r) }
    } else {
        foreach ($n in $wanted) {
            $row = & $resolve $n
            if ($row) { [void]$chosen.Add($row) } else { [void]$unresolved.Add($n) }
        }
    }

    foreach ($r in $chosen) {
        $busy = $false
        $opState = ''
        if ($r.PSObject.Properties['OpState']) { $opState = [string]$r.OpState }
        if ($r.PSObject.Properties['Pending']) { $busy = [bool]$r.Pending }
        if ($opState -eq 'Running') { $busy = $true }

        $action = 'run'
        $reason = ''
        if ($busy) {
            if ($policy -eq 'refuse') {
                $action = 'skip'
                $reason = if ($Verb -eq 'restart') { "busy ($opState) - a confirmed restart is never silently deferred" } else { "busy ($opState) - service action is skipped" }
            } else {
                $action = 'queue'
                $reason = "busy ($opState) - queued to run when the current operation finishes"
            }
        } elseif ($Verb -eq 'download' -and $r.PSObject.Properties['Available']) {
            # The handler's own no-op test: `$r.Available -eq $r.Downloaded` answers 'Up-to-Date'.
            $avail = [int]$r.Available
            $dl = if ($r.PSObject.Properties['Downloaded']) { [int]$r.Downloaded } else { 0 }
            if ($avail -eq $dl) {
                $action = 'noop'
                $reason = if ($avail -eq 0) { 'no updates available for download' } else { 'all available updates are already downloaded' }
            }
        } elseif ($Verb -eq 'install' -and $r.PSObject.Properties['Downloaded']) {
            $dl = [int]$r.Downloaded
            if ($dl -eq 0) {
                $action = 'noop'
                $reason = 'nothing downloaded to install'
            }
        }

        [void]$targets.Add([pscustomobject]@{
            Computer = [string]$r.Computer
            Phase    = [string]$r.Phase
            Action   = $action
            Reason   = $reason
            Busy     = $busy
            OpState  = $opState
        })
    }

    $detail = if ($allSelected) { 'all computers' } elseif ($Computer) { $Computer } else { '(unspecified)' }
    if ($Verb -eq 'service' -and $ServiceAction) { $detail += " (service $ServiceAction)" }

    return [pscustomobject]@{
        Verb       = $Verb
        Detail     = "would run '$Verb' against $detail"
        Policy     = $policy
        Selected   = $chosen.Count
        WouldRun   = @($targets | Where-Object { $_.Action -eq 'run' }).Count
        WouldQueue = @($targets | Where-Object { $_.Action -eq 'queue' }).Count
        WouldSkip  = @($targets | Where-Object { $_.Action -eq 'skip' }).Count
        WouldNoOp  = @($targets | Where-Object { $_.Action -eq 'noop' }).Count
        Unresolved = @($unresolved)
        Targets    = @($targets)
    }
}

function Write-WuuCommandPlan {
    <#
    .SYNOPSIS Renders a command plan for a human reviewing a change (SS11).
    .DESCRIPTION
    Line-oriented, no cursor movement, so the output survives being pasted into a change record or a
    ticket - which is where a dry run's value actually lands.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)
    Write-Host ("  {0} - no changes made." -f $Plan.Detail) -ForegroundColor Yellow

    if ($Plan.Unresolved.Count -gt 0) {
        Write-Host ("  NOT RESOLVED ({0}) - these would be skipped by a real run:" -f $Plan.Unresolved.Count) -ForegroundColor Red
        foreach ($n in $Plan.Unresolved) { Write-Host ("    {0}" -f $n) -ForegroundColor Red }
    }

    if ($Plan.Targets.Count -eq 0) {
        Write-Host '  (no computers selected)' -ForegroundColor DarkGray
        return
    }

    $fmt = "    {0,-22} {1,-10} {2,-9} {3}"
    Write-Host ($fmt -f 'COMPUTER', 'PHASE', 'ACTION', 'NOTE') -ForegroundColor DarkCyan
    foreach ($t in $Plan.Targets) {
        $colour = switch ($t.Action) {
            'run'   { 'Green' }
            'queue' { 'Yellow' }
            'skip'  { 'Red' }
            'noop'  { 'DarkGray' }
            default { 'Gray' }
        }
        Write-Host ($fmt -f $t.Computer, $t.Phase, $t.Action, $t.Reason) -ForegroundColor $colour
    }

    # The totals are what a change reviewer signs off on, so they are stated in the same words the
    # real run uses.
    $bits = @("$($Plan.WouldRun) would run now")
    if ($Plan.WouldQueue -gt 0) { $bits += "$($Plan.WouldQueue) queued until idle" }
    if ($Plan.WouldSkip -gt 0) { $bits += "$($Plan.WouldSkip) would be SKIPPED (busy)" }
    if ($Plan.WouldNoOp -gt 0) { $bits += "$($Plan.WouldNoOp) have nothing to do" }
    Write-Host ("  Total: {0}." -f ($bits -join ', ')) -ForegroundColor White
    if ($Plan.WouldSkip -gt 0 -and $Plan.Policy -eq 'refuse') {
        Write-Host '  The skipped computers will NOT be changed by a real run either - re-run when idle.' -ForegroundColor Yellow
    }
}

function Get-WuuExitCode {
    <#
    .SYNOPSIS The exit-code contract for the command surface (hardening brief SS10).
    .DESCRIPTION
    One vocabulary, in one place, so a script can gate on a documented number rather than on the
    folklore that "non-zero means something went wrong". Before this, only 0 and 1 existed and 1
    conflated five different situations.

        0  Success         the requested operation actually completed successfully
        1  OperationFailed one or more targets failed, or every settled target failed
        2  UsageError      unknown verb, missing argument, invalid input
        3  Timeout         the wait elapsed with work still outstanding
        4  PartialSuccess  SOME settled targets succeeded and some did not
        5  AuditFailure    the audit chain failed to verify, or a fail-closed audit write failed
        6  Queued          -Async was requested and the work was ACCEPTED, not completed
        7  Refused         refused before running: missing -Reason, or a pre-flight/confirmation refusal

    WHY 6 EXISTS. `wuu install` used to return as soon as the work had been QUEUED (it waits a bounded
    period and then reports), so a script saw "success" for an install that had not happened. Returning
    a distinct code keeps the async behaviour useful without letting it masquerade as completion.

    WHY 4 IS PRODUCED (it used to be reserved). A mixed result was unobservable: `-Computer A,B` was
    resolved by one shared answer, so "A worked and B failed" could not be seen from here. The code was
    reserved so the number would not later mean something else, and the honest answer was 1. It now has
    a real source - Get-WuuAggregateOutcome over the per-target verdicts in Wuu.State - so a mixed fleet
    reports 4 rather than a flat failure. Targets that have NOT settled are ignored, not counted as
    failures: a still-running estate op is not a partial failure, and the caller has a separate
    measured signal for outstanding work (the bounded wait -> 3, or 6 with -Async).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Success', 'OperationFailed', 'UsageError', 'Timeout', 'PartialSuccess', 'AuditFailure', 'Queued', 'Refused')]
        [string]$Result = 'Success'
    )
    switch ($Result) {
        'Success' { 0 }
        'OperationFailed' { 1 }
        'UsageError' { 2 }
        'Timeout' { 3 }
        'PartialSuccess' { 4 }
        'AuditFailure' { 5 }
        'Queued' { 6 }
        'Refused' { 7 }
        default { 1 }
    }
}

function Get-WuuExitCodeMeaning {
    <#
    .SYNOPSIS Human-readable meaning of an exit code and the action it suggests.
    .DESCRIPTION
    Kept next to the numbers so the two cannot drift, and so a failure can print WHY it exited
    non-zero rather than leaving the operator to look it up.
    #>
    param([Parameter(Mandatory)][int]$Code)
    switch ($Code) {
        0 { 'success - the operation completed' }
        1 { 'operation failed - one or more targets did not succeed' }
        2 { 'usage error - check the verb and its arguments (wuu -Help)' }
        3 { 'timeout - the wait elapsed with work still outstanding' }
        4 { 'partial success - some targets succeeded and some did not' }
        5 { 'audit failure - the audit trail could not be trusted or written' }
        6 { 'queued - the work was accepted, not completed (-Async)' }
        7 { 'refused - the operation was declined before it ran (often a missing -Reason)' }
        default { "unknown exit code $Code" }
    }
}

function Get-WuuCommandTable {
    <#
    .SYNOPSIS The verb table: name -> action handler, mutating flag, and answer-builder.
    .DESCRIPTION Each entry's Answers scriptblock receives the parsed parameters and returns the
    ordered answers the handler's prompts expect. Keeping that mapping here (not inside the
    handlers) is what lets the handlers stay presentation-agnostic.
    #>
    @{
        'check' = @{
            Action = 'EventGetUpdates'; Mutating = $false
            Answers = { param($p) , $p.Computer }
            Help = 'Check for available updates:  wuu check -Computer SRV01[,SRV02] | -All'
        }
        'download' = @{
            Action = 'EventDownloadUpdates'; Mutating = $true
            # selection, then the "Download updates to N computers?" confirmation
            Answers = { param($p) , $p.Computer; 'y' }
            Help = 'Download updates:  wuu download -Computer SRV01 [-Yes]'
        }
        'install' = @{
            Action = 'EventInstallUpdates'; Mutating = $true
            # selection, then the "Install updates on N computers?" confirmation
            Answers = { param($p) , $p.Computer; 'y' }
            Help = 'Install updates:  wuu install -Computer SRV01 [-Yes]'
        }
        'restart' = @{
            Action = 'EventRestartComputer'; Mutating = $true
            # selection, then the explicit restart confirmation
            Answers = { param($p) , $p.Computer; 'y' }
            Help = 'Restart computers:  wuu restart -Computer SRV01 [-Yes]'
        }
        'add' = @{
            Action = 'EventAddComputer'; Mutating = $false
            Answers = { param($p) , $p.Computer }
            Help = 'Add computers:  wuu add -Computer A,B   (or -FromFile path.csv)'
        }
        'add-file' = @{
            Action = 'EventAddFile'; Mutating = $false
            # path, then the column name for a CSV (blank = first column default)
            Answers = { param($p) , $p.Path; $p.Column }
            Help = 'Add from CSV/TXT:  wuu add-file -Path list.csv [-Column Name]'
        }
        'remove' = @{
            Action = 'EventRemoveSelected'; Mutating = $false
            Answers = { param($p) , $p.Computer }
            Help = 'Remove from the list:  wuu remove -Computer SRV01'
        }
        'clear' = @{
            Action = 'ClearComputerList'; Mutating = $false
            Answers = { param($p) @() }
            Help = 'Clear the computer list:  wuu clear'
        }
        'prune' = @{
            Action = 'EventRemoveOfflineComputer'; Mutating = $false
            Answers = { param($p) 'y' }
            Help = 'Remove unreachable computers:  wuu prune'
        }
        'phase' = @{
            Action = 'EventAssignPhaseInteractive'; Mutating = $false
            # selection, then the phase number
            Answers = { param($p) , $p.Computer; [string]$p.Set }
            Help = 'Assign a phase:  wuu phase -Set 2 -Computer SRV01'
        }
        'show' = @{
            Action = $null; Mutating = $false   # sub-dispatched below
            Answers = { param($p) , $p.Computer }
            Help = 'Show information:  wuu show available|installed|history|errors|phases'
        }
        'audit' = @{
            Action = 'EventAuditWSUSUpdates'; Mutating = $false
            Answers = { param($p) , $p.Computer }
            Help = 'Audit:  wuu audit wsus [-Computer SRV01]  |  wuu audit verify|show|export'
        }
        'logs' = @{
            Action = 'EventViewUpdateLog'; Mutating = $false
            Answers = { param($p) , $p.Computer }
            Help = 'View the Windows Update log:  wuu logs -Computer SRV01'
        }
        'service' = @{
            Action = 'EventWUServiceActionInteractive'; Mutating = $true
            # selection, then the action letter
            Answers = { param($p) , $p.Computer; $p.ServiceAction }
            Help = 'Windows Update service:  wuu service start|stop|restart -Computer SRV01'
        }
        'export' = @{
            Action = 'EventSaveComputerList'; Mutating = $false
            Answers = { param($p) @() }
            Help = 'Export the list to a file:  wuu export -Path out.csv'
        }
        'config' = @{
            Action = $null; Mutating = $false   # sub-dispatched (save/load)
            Answers = { param($p) @() }
            Help = 'Config:  wuu config save | wuu config load'
        }
        'credentials' = @{
            Action = 'EventSetDomainCredentials'; Mutating = $false
            Answers = { param($p) @() }
            Help = 'Set domain credentials:  wuu credentials set'
        }
    }
}

function Get-WuuCommandHelp {
    <#
    .SYNOPSIS Renders usage for the console edition.
    #>
    param([string]$Verb)

    $table = Get-WuuCommandTable
    if ($Verb -and $table.ContainsKey($Verb)) {
        Write-Host ''
        Write-Host ("  {0}" -f $table[$Verb].Help) -ForegroundColor White
        if ($table[$Verb].Mutating) { Write-Host '  (mutating action)' -ForegroundColor DarkGray }
        Write-Host ''
        return
    }

    Write-Host ''
    Write-Host '  WUU2-CLI - Windows Update Utility (console edition)' -ForegroundColor White
    Write-Host '  ==================================================================' -ForegroundColor DarkGray
    Write-Host '  USAGE' -ForegroundColor Cyan
    Write-Host '    wuu                          interactive menu (default)'
    Write-Host '    wuu <verb> [options]         run one operation and exit'
    Write-Host ''
    Write-Host '  VERBS' -ForegroundColor Cyan
    foreach ($k in ($table.Keys | Sort-Object)) {
        Write-Host ("    {0,-13} {1}" -f $k, ($table[$k].Help -replace '^[^:]+:\s*', ''))
    }
    Write-Host ''
    Write-Host '  COMMON OPTIONS' -ForegroundColor Cyan
    Write-Host '    -Computer <names>   comma-separated names, or "all"'
    Write-Host '    -All                shortcut for -Computer all'
    Write-Host '    -Reason <text>      why this change was made (recorded in the audit trail)'
    Write-Host '    -Path <file>        audit verify|show: the log to inspect. audit export: the output destination'
    Write-Host '    -LogPath <file>     audit verify|show|export: the audit log to read (unambiguous)'
    Write-Host '    -Json               machine-readable output (read verbs)'
    Write-Host '    -WhatIf             report what would happen; change nothing'
    Write-Host '    -Async              queue the work and return (exit 6 = accepted, NOT completed)'
    Write-Host '    -Help               this help, or per-verb help with a verb'
    Write-Host ''
    Write-Host '  EXIT CODES' -ForegroundColor Cyan
    Write-Host '    0 success (completed)      4 partial success (reserved, not yet produced)'
    Write-Host '    1 operation failed         5 audit failure (chain broken / unwritable)'
    Write-Host '    2 usage error              6 queued (-Async; accepted, not completed)'
    Write-Host '    3 timeout (still working)  7 refused (e.g. missing -Reason)'
    Write-Host ''
    Write-Host '  AUDIT TRAIL' -ForegroundColor Cyan
    Write-Host '    wuu audit verify                  check the hash chain; non-zero exit if broken'
    Write-Host '    wuu audit show [-Json]            list audit records'
    Write-Host '    wuu audit export                  bundle log + transcripts for handoff'
    Write-Host '    wuu audit wsus -Computer SRV01    audit a TARGET host (not the local trail)'
    Write-Host ''
    Write-Host '  EXAMPLES' -ForegroundColor Cyan
    Write-Host '    wuu check -All'
    Write-Host '    wuu show available -Computer SRV01 -Json'
    Write-Host '    wuu install -Computer SRV01 -WhatIf'
    Write-Host '    wuu install -Computer SRV01 -Reason "CHG-1041 security patches"'
    Write-Host '    wuu add -Computer SRV01,SRV02'
    Write-Host ''
}

function Invoke-WuuCommand {
    <#
    .SYNOPSIS Runs one non-interactive operation. Returns a result object.
    .DESCRIPTION
    Resolves the verb to a handler + the ordered answers its prompts expect, then invokes the
    handler with input switched to non-interactive. Nothing is reimplemented.

    -WhatIf short-circuits mutating verbs BEFORE any handler runs, so no payload is queued and
    no remote state is touched - the same guarantee the menu's confirmation gives a human.
    #>
    param(
        [Parameter(Mandatory)][string]$Verb,
        [Parameter(Mandatory)][hashtable]$Actions,
        [Parameter(Mandatory)][hashtable]$Store,
        [string]$Computer,
        [switch]$All,
        [string]$Path,
        [string]$Column,
        [ValidateRange(0, 5)][int]$Set = 0,
        [ValidateSet('', 'start', 'stop', 'restart')][string]$ServiceAction,
        [string]$SubVerb,
        # The audit log to inspect/export, for `audit verify|show|export`. Distinct from -Path,
        # which is ambiguous (a log for verify/show, an output destination for export).
        [string]$LogPath,
        # Required for mutating verbs once audit is active (Phase 4): records WHY the change was
        # made. Interactive mode prompts; non-interactive mode fails without it.
        [string]$Reason = '',
        [switch]$Json,
        [switch]$WhatIf,
        # Declare that queued-and-returned is the DESIRED outcome (SS10). Without it, a command that
        # finished its bounded wait with work still outstanding is reported as a timeout, because a
        # script must never read "success" for an install that has not run.
        [switch]$Async,
        # Selects the pre-redesign flat interactive menu. Consumed by the caller; kept out of the
        # unknown-option report so `wuu --flat-menu` is not mistaken for a typo.
        [switch]$FlatMenu
    )
    $table = Get-WuuCommandTable
    if (-not $table.ContainsKey($Verb)) {
        return [pscustomobject]@{ Ok = $false; Verb = $Verb; Error = "Unknown verb '$Verb'. Run 'wuu -Help'."; Result = 'UsageError' }
    }
    $entry = $table[$Verb]

    # Resolve the action for sub-dispatched verbs (show / config / audit).
    $actionName = $entry.Action
    if ($Verb -eq 'show') {
        $map = @{
            'available' = 'EventShowAvailableUpdates'
            'installed' = 'EventShowInstalledUpdates'
            'history'   = 'EventShowUpdateHistory'
            'errors'    = 'GetErrors'
            'phases'    = 'EventShowByPhase'
        }
        if (-not $SubVerb -or -not $map.ContainsKey($SubVerb)) {
            return [pscustomobject]@{ Ok = $false; Verb = $Verb; Error = "wuu show needs one of: $($map.Keys -join ', ')"; Result = 'UsageError' }
        }
        $actionName = $map[$SubVerb]
    }
    elseif ($Verb -eq 'config') {
        if ($SubVerb -eq 'save') { $actionName = 'EventSaveConfig' }
        elseif ($SubVerb -eq 'load') { $actionName = 'EventLoadConfig' }
        else { return [pscustomobject]@{ Ok = $false; Verb = $Verb; Error = 'wuu config needs save or load'; Result = 'UsageError' } }
    }
    elseif ($Verb -eq 'audit') {
        # 'wsus' audits a TARGET's WSUS state. verify/show/export inspect the LOCAL audit
        # trail itself (Phase 4) and are handled before the action lookup, since they are not
        # $consoleActions operations.
        if ($SubVerb -in @('verify', 'show', 'export')) {
            return Invoke-WuuAuditCommand -SubVerb $SubVerb -Path $Path -LogPath $LogPath -Json:$Json
        }
        if ($SubVerb -ne 'wsus') {
            return [pscustomobject]@{ Ok = $false; Verb = $Verb; Error = 'wuu audit needs one of: wsus, verify, show, export'; Result = 'UsageError' }
        }
    }

    if (-not $actionName -or -not $Actions.ContainsKey($actionName)) {
        return [pscustomobject]@{ Ok = $false; Verb = $Verb; Error = "Action '$actionName' is not registered."; Result = 'UsageError' }
    }

    # -WhatIf: report intent, change nothing. Deliberately BEFORE any handler call.
    #
    # SS11: this now produces a PER-COMPUTER plan rather than one sentence. A change being reviewed
    # before it touches production needs to say which computers, what each will do, and which requests
    # would not take effect - "would run 'restart' against all computers" is not reviewable, and it is
    # wrong in the most expensive direction when some of those computers are busy (a restart is refused,
    # not deferred - see Get-WuuCommandPlan).
    if ($WhatIf -and $entry.Mutating) {
        $plan = Get-WuuCommandPlan -Verb $Verb -Store $Store -Computer $Computer -All:$All `
            -ServiceAction $ServiceAction -Set $Set

        # -Json so a change pipeline can diff the plan against a previous run. This is the first
        # branch because a caller asking for machine-readable output must not also get prose.
        #
        # The JSON is written to the HOST and also returned as a property, rather than emitted on the
        # output stream.
        #
        # WHY: emitting it made this call return TWO objects - the JSON string AND the result object
        # (measured). Anything consuming the result then has to know which element is which; a caller
        # piping `Invoke-WuuCommand ... | ConvertFrom-Json` would receive an array of two unrelated
        # values, and one of the two carries no Ok/Result at all.
        #
        # A NEAR-MISS WORTH RECORDING: Core reads `$result.Ok` to choose the exit code. On a bare
        # string that is $null, and `-not $null` is $true - i.e. a JSON-only return would have exited
        # 1 for every successful dry run. It did NOT happen here, and the reason is subtle: PowerShell
        # member-enumerates across an ARRAY, so `$result.Ok` found the Ok on the psobject element and
        # the exit code stayed 0. Luck, not design. Returning one object removes the dependency on it.
        $jsonText = $null
        if ($Json) {
            $jsonText = [pscustomobject]@{
                Command        = $Verb
                WhatIf         = $true
                Detail         = $plan.Detail
                Policy         = $plan.Policy
                Selected       = $plan.Selected
                WouldRun       = $plan.WouldRun
                WouldQueue     = $plan.WouldQueue
                WouldSkip      = $plan.WouldSkip
                WouldNoOp      = $plan.WouldNoOp
                Unresolved     = $plan.Unresolved
                Targets        = $plan.Targets
                Would          = $plan.Detail
                Ok             = $true
            } | ConvertTo-Json -Depth 5
            Write-Host $jsonText
        } else {
            Write-WuuCommandPlan -Plan $plan
        }

        # NO AUDIT RECORD IS WRITTEN. -WhatIf is side-effect free in the AUDIT TRAIL as well, and that
        # contract is asserted by tests\Test-AuditTrail.ps1 ("-WhatIf wrote audit records (expected
        # none)").
        #
        # I first added one (session-start + a 'declined' record) on the grounds that ISO 27001 A.8.15
        # covers denied attempts - and the hardening brief describes -WhatIf as "audited already". Both
        # were wrong to act on here:
        #   * the brief's "audited already" is simply not true (the test measures zero records), so it
        #     was an argument from a mistaken premise;
        #   * a SIMULATION is not a denied attempt. Mixing plans into the trail degrades it as evidence:
        #     an auditor reading it cannot distinguish "a change this system refused to make" from "an
        #     operator asking what a change WOULD do", and 'declined' would be actively misleading for
        #     the second case (nothing was declined - the caller asked for a report).
        # A side-effect-free dry run is also more useful than an audited one: it can be run freely,
        # including repeatedly while preparing a change, without leaving artefacts that need explaining.
        #
        # -WhatIf is a SUCCESS: it correctly did what was asked (report the intent, change nothing). It
        # is never 'Queued' (nothing was accepted for later) and never a failure for having skipped busy
        # computers - refusing to touch them is the intended behaviour, and the plan says so.
        return [pscustomobject]@{
            Ok = $true; Verb = $Verb; WhatIf = $true; Would = $plan.Detail; Result = 'Success'
            Plan = $plan; Json = $jsonText
        }
    }

    # Build the parameter bag the answer-builder and handlers expect.
    $p = @{
        Computer      = if ($All) { 'all' } elseif ($Computer) { $Computer } else { $null }
        Path          = $Path
        Column        = $Column
        Set           = if ($Set -gt 0) { $Set } else { $null }
        ServiceAction = if ($ServiceAction) { $ServiceAction.Substring(0, 1) } else { $null }
        Json          = [bool]$Json
    }

    $answers = if ($entry.Answers) { @(& $entry.Answers $p) } else { @() }

    # Mutating actions require a reason once auditing is on: an audit record that says "someone
    # changed 12 servers" without saying why has limited value in a change review. Fail BEFORE
    # running anything, and before the fail-closed intent record, so nothing happens at all.
    #
    # The refusal itself is logged (ISO 27001 A.8.15 expects denied attempts to be recorded, not
    # just successful ones). It uses a throwaway session and a best-effort write: if logging the
    # denial fails we still return the refusal, because the operation was already blocked.
    if ($entry.Mutating -and -not $Reason) {
        $msg = "Mutating action '$Verb' requires -Reason (e.g. -Reason ""CHG-1041 security patches"")."
        Write-Host "  $msg" -ForegroundColor Yellow
        try {
            $denySession = Start-WuuAuditSession -Action ('denied:{0}' -f $Verb)
            Write-WuuAuditDenial -Session $denySession -Action $Verb -DenialReason 'missing -Reason' `
                -Targets $(if ($All) { @('all') } elseif ($Computer) { @($Computer) } else { @() }) `
                -Parameters @{ computer = $p.Computer; serviceAction = $p.ServiceAction; set = $p.Set } | Out-Null
        } catch {
            # Best-effort BY DESIGN: the operation is already blocked, so failing to RECORD the
            # denial must never replace a clean refusal with an exception. The nested try is not
            # paranoia - when only this module is loaded (tests, tooling) the logger itself is
            # absent, and that turned a correct refusal into an unhandled CommandNotFound.
            try { Write-WarningLog ("Could not record denial for '{0}': {1}" -f $Verb, $_.Exception.Message) } catch { }
        }
        return [pscustomobject]@{ Ok = $false; Verb = $Verb; Action = $actionName; Error = $msg; NeedsReason = $true; Result = 'Refused' }
    }

    $prev = Get-WuuInputMode
    $targets = if ($All) { @('all') } elseif ($Computer) { @($Computer -split '[,;]' | ForEach-Object { $_.Trim() }) } else { @() }
    # Every command run produces an audit session, mutating or not, so the read-only record below
    # has a runId/operator/host/pid to inherit. The session-start record itself is best-effort
    # (its own write is SkipFailClosed) - a failure to open a session must not block a read.
    $auditSession = Start-WuuAuditSession -Action $Verb -Reason $Reason
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Initialize-WuuInputMode -NonInteractive -Answers $answers
        if ($entry.Mutating) {
            # Mutating verbs go through the audited choke point: intent is recorded BEFORE the
            # handler runs and FAIL-CLOSED, so if the audit sink is unwritable the change does
            # not happen. An unlogged remote change is worse than a refused one.
            $session = $auditSession
            $audited = Invoke-WuuAuditedAction -Session $session -Action $Verb -Targets $targets `
                -Parameters @{ computer = $p.Computer; serviceAction = $p.ServiceAction; set = $p.Set; json = $p.Json } `
                -Reason $Reason -Body { & $Actions[$actionName] }
            $sw.Stop()
            if (-not $audited.Ok) {
                # The audited choke point only fails when the record could not be written, which is a
                # DIFFERENT failure from the operation failing - hence its own code (SS10).
                $isAuditFailure = $audited.Error -match 'audit'
                return [pscustomobject]@{ Ok = $false; Verb = $Verb; Action = $actionName; Error = $audited.Error; CorrelationId = $audited.CorrelationId; Result = $(if ($isAuditFailure) { 'AuditFailure' } else { 'OperationFailed' }) }
            }
            return [pscustomobject]@{ Ok = $true; Verb = $Verb; Action = $actionName; CorrelationId = $audited.CorrelationId; Audited = $true; Result = 'Success' }
        }
        # READ-ONLY verbs are audited too, but on the opposite footing from mutations: the record
        # is best-effort and NEVER blocks the operation. ISO 27001 A.8.15 covers access to
        # information as well as changes to it - "who inspected which hosts' update state, when"
        # is exactly the question an auditor asks after a breach, and it is unanswerable if only
        # mutations are logged. The trade-off is deliberate: a viewing action must not fail
        # because the audit sink is momentarily unwritable.
        #
        # No -Reason is required (asking why for a read is noise) and no fail-closed intent record
        # is written, so reads produce exactly ONE record instead of two.
        $readCategory = if ($Verb -in @('export', 'save')) { 'configuration_change' } else { 'operational' }
        Write-WuuAuditRecord -Session $auditSession -Action $Verb -Result 'info' -Category $readCategory `
            -Targets $targets -Parameters @{ computer = $p.Computer; column = $p.Column; all = [bool]$All; json = $p.Json } -Mutating:$false | Out-Null
        & $Actions[$actionName]
        # Logged, not Audited: 'Audited' means "went through the mutating choke point (intent +
        # outcome, fail-closed)". A read takes the best-effort path, so it reports a distinct
        # flag - conflating the two would make 'Audited' meaningless for callers.
        return [pscustomobject]@{ Ok = $true; Verb = $Verb; Action = $actionName; Logged = $true; Result = 'Success' }
    } catch {
        Write-ErrorLog "Command '$Verb' failed: $($_.Exception.Message)"
        Write-Host ("  Command failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        return [pscustomobject]@{ Ok = $false; Verb = $Verb; Action = $actionName; Error = $_.Exception.Message; Result = 'OperationFailed' }
    } finally {
        # Always restore interactive input, even on failure.
        Initialize-WuuInputMode -NonInteractive:$prev.NonInteractive
    }
}

function ConvertTo-WuuCommandLine {
    <#
    .SYNOPSIS
    Parses an argument array into verb/subverb + named options.
    .DESCRIPTION
    Hand-rolled (no PowerShell parameter binding) because `wuu` is invoked as a plain word from
    a shell, not as a cmdlet: `wuu check -All`, `wuu show available -Json`. Unknown options are
    reported rather than silently ignored.
    #>
    param([Parameter(Mandatory)][string[]]$Arguments)

    $known = @{
        '-computer' = 'Computer'; '-all' = 'All'; '-json' = 'Json'; '-whatif' = 'WhatIf'
        '-path' = 'Path'; '-column' = 'Column'; '-set' = 'Set'; '-help' = 'Help'
        '-reason' = 'Reason'; '-logpath' = 'LogPath'
        # Declare "queue and return" as the DESIRED outcome (SS10). Without it, a command whose
        # bounded wait expires with work still outstanding exits 3 (timeout) instead of 0, because
        # success must mean completed, not accepted.
        '-async' = 'Async'
        # Interactive-mode switch, consumed by Start-WuuApplication (not a verb option).
        '--flat-menu' = 'FlatMenu'
    }
    # Verbs that take a subverb as their second positional token.
    $subVerbVerbs = @('show', 'config', 'audit', 'service')

    # NOTE: `Unknown` must be an ArrayList, not @(). A fixed-size array in a hashtable literal
    # cannot take .Add() - it throws "Collection was of a fixed size" on the first unknown
    # option, which is exactly the input the reporter exists to handle.
    $result = @{ Verb = $null; SubVerb = $null; Options = @{}; Unknown = (New-Object System.Collections.ArrayList) }
    $positional = New-Object System.Collections.ArrayList
    $i = 0
    while ($i -lt $Arguments.Count) {
        $a = $Arguments[$i]
        if ($a -match '^-') {
            $key = $a.ToLowerInvariant()
            if (-not $known.ContainsKey($key)) { [void]$result.Unknown.Add($a); $i++; continue }
            $name = $known[$key]
            if ($name -in @('Computer', 'Path', 'Column', 'Set', 'Reason')) {
                if ($i + 1 -ge $Arguments.Count) { [void]$result.Unknown.Add("$a (missing value)"); $i++; continue }
                $result.Options[$name] = $Arguments[$i + 1]; $i += 2; continue
            }
            $result.Options[$name] = $true; $i++; continue
        }
        [void]$positional.Add($a)
        $i++
    }

    if ($positional.Count -gt 0) {
        $result.Verb = $positional[0].ToLowerInvariant()
        if ($positional.Count -gt 1 -and $subVerbVerbs -contains $result.Verb) {
            $result.SubVerb = $positional[1].ToLowerInvariant()
        } elseif ($positional.Count -gt 1) {
            # Non-subverb verbs treat a second positional as the computer list (convenience:
            # `wuu check SRV01`). Kept because it is the natural shell idiom.
            if (-not $result.Options.ContainsKey('Computer')) { $result.Options['Computer'] = $positional[1] }
        }
    }
    return $result
}

Export-ModuleMember -Function @(
    'Get-WuuCommandTable'
    'Get-WuuCommandHelp'
    'Get-WuuExitCode'
    'Get-WuuExitCodeMeaning'
    'Get-WuuCommandPlan'
    'Write-WuuCommandPlan'
    'Invoke-WuuCommand'
    'ConvertTo-WuuCommandLine'
    # Exported because the guided UI's Reports/audit category (spec 20) invokes the audit verbs
    # directly. It was previously module-private, which made those menu entries fail at runtime
    # with "not recognized" - the same class of silent dead entry as the unwired EventAddAD
    # handler, and caught by the same static check in tests\Test-Navigation.ps1.
    'Invoke-WuuAuditCommand'
)
