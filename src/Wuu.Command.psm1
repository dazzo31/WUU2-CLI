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
            return [pscustomobject]@{ Ok = $false; Verb = 'audit'; SubVerb = $SubVerb; Error = 'no audit log' }
        }
        $resolvedLog = $candidates[0].FullName
    }
    if (-not (Test-Path -LiteralPath $resolvedLog)) {
        Write-Host ("  Audit log not found: {0}" -f $resolvedLog) -ForegroundColor Red
        return [pscustomobject]@{ Ok = $false; Verb = 'audit'; SubVerb = $SubVerb; Error = "audit log not found: $resolvedLog" }
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
            # Non-zero exit on a broken chain so a pipeline can gate on it.
            if (-not $v.Ok) { $script:CommandExitCode = 1 }
            return [pscustomobject]@{ Ok = $v.Ok; Verb = 'audit'; SubVerb = $SubVerb; Checked = $v.Checked; FirstBreak = $v.FirstBreak }
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
            return [pscustomobject]@{ Ok = $true; Verb = 'audit'; SubVerb = $SubVerb; Count = $recs.Count }
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
                return [pscustomobject]@{ Ok = $false; Verb = 'audit'; SubVerb = $SubVerb; Error = "export bundle unreadable: $($_.Exception.Message)" }
            }
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host ("  Exported audit bundle: {0} ({1} entries)" -f $outPath, $entryCount) -ForegroundColor Green
            Write-Host '  NOTE: the bundle carries the hash chain but NO external anchor, so it is' -ForegroundColor DarkGray
            Write-Host '        tamper-EVIDENT, not non-repudiable. See docs/ISO_27001_A815_MAPPING.md 8.' -ForegroundColor DarkGray
            return [pscustomobject]@{ Ok = $true; Verb = 'audit'; SubVerb = $SubVerb; Path = $outPath; Entries = $entryCount }
        }
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
    Write-Host '    -Help               this help, or per-verb help with a verb'
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
        [switch]$WhatIf
    )

    $table = Get-WuuCommandTable
    if (-not $table.ContainsKey($Verb)) {
        return [pscustomobject]@{ Ok = $false; Verb = $Verb; Error = "Unknown verb '$Verb'. Run 'wuu -Help'." }
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
            return [pscustomobject]@{ Ok = $false; Verb = $Verb; Error = "wuu show needs one of: $($map.Keys -join ', ')" }
        }
        $actionName = $map[$SubVerb]
    }
    elseif ($Verb -eq 'config') {
        if ($SubVerb -eq 'save') { $actionName = 'EventSaveConfig' }
        elseif ($SubVerb -eq 'load') { $actionName = 'EventLoadConfig' }
        else { return [pscustomobject]@{ Ok = $false; Verb = $Verb; Error = 'wuu config needs save or load' } }
    }
    elseif ($Verb -eq 'audit') {
        # 'wsus' audits a TARGET's WSUS state. verify/show/export inspect the LOCAL audit
        # trail itself (Phase 4) and are handled before the action lookup, since they are not
        # $consoleActions operations.
        if ($SubVerb -in @('verify', 'show', 'export')) {
            return Invoke-WuuAuditCommand -SubVerb $SubVerb -Path $Path -LogPath $LogPath -Json:$Json
        }
        if ($SubVerb -ne 'wsus') {
            return [pscustomobject]@{ Ok = $false; Verb = $Verb; Error = 'wuu audit needs one of: wsus, verify, show, export' }
        }
    }

    if (-not $actionName -or -not $Actions.ContainsKey($actionName)) {
        return [pscustomobject]@{ Ok = $false; Verb = $Verb; Error = "Action '$actionName' is not registered." }
    }

    # -WhatIf: report intent, change nothing. Deliberately BEFORE any handler call.
    if ($WhatIf -and $entry.Mutating) {
        $targets = if ($All) { 'all computers' } elseif ($Computer) { $Computer } else { '(unspecified)' }
        $detail = "would run '$Verb' against $targets"
        if ($Verb -eq 'service') { $detail += " (service $ServiceAction)" }
        if ($Verb -eq 'phase') { $detail += " (phase $Set)" }
        Write-Host ("  [WhatIf] $detail - no changes made.") -ForegroundColor Yellow
        return [pscustomobject]@{ Ok = $true; Verb = $Verb; WhatIf = $true; Would = $detail }
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
            Write-WarningLog ("Could not record denial for '{0}': {1}" -f $Verb, $_.Exception.Message)
        }
        return [pscustomobject]@{ Ok = $false; Verb = $Verb; Action = $actionName; Error = $msg; NeedsReason = $true }
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
                return [pscustomobject]@{ Ok = $false; Verb = $Verb; Action = $actionName; Error = $audited.Error; CorrelationId = $audited.CorrelationId }
            }
            return [pscustomobject]@{ Ok = $true; Verb = $Verb; Action = $actionName; CorrelationId = $audited.CorrelationId; Audited = $true }
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
        return [pscustomobject]@{ Ok = $true; Verb = $Verb; Action = $actionName; Logged = $true }
    } catch {
        Write-ErrorLog "Command '$Verb' failed: $($_.Exception.Message)"
        Write-Host ("  Command failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        return [pscustomobject]@{ Ok = $false; Verb = $Verb; Action = $actionName; Error = $_.Exception.Message }
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
    'Invoke-WuuCommand'
    'ConvertTo-WuuCommandLine'
)
