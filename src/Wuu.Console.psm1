#Requires -Version 5.1
<#
.DESCRIPTION
Console presentation layer for WUU2-CLI (Phase 1 final step / Phase 2 seed).

Replaces the WPF shell that lived in Wuu.Core.psm1:
  - MainWindow.xaml / XamlReader          -> Write-WuuStatusTable renderer
  - ListView + items (the row display)    -> reads the state store's rows
  - StatusTextBox                         -> the store's Status value
  - Context menu + Menu items             -> the numbered interactive menu
  - JobTimer (DispatcherTimer on the UI   -> the input loop's tick, which drains the
    thread, pumps the WPF message loop)      pending-job queue each iteration

WHY THE SCHEDULER IS POLLED BY THE INPUT LOOP (design note - do not "fix" this back to a timer)
---------------------------------------------------------------------------------------------
The GUI used a DispatcherTimer: it worked because ShowDialog() pumps a message loop, so a
UI-thread timer could fire while the app sat waiting for the user. A console blocking on
Read-Host has NO message loop, and a runspace-affine scriptblock timer cannot fire while the
runspace is busy inside Read-Host. So a timer would silently never run, and the auto-flow
(queued downloads/installs, Phase-E retries) would stall exactly like the old auto-download
bug.

Instead the menu loop reads the keyboard WITHOUT blocking ([Console]::KeyAvailable) and calls
the scheduler once per tick. Same single runspace, no injection, no affinity problem, and the
auto-flow keeps running while the operator sits at the menu.
#>

#region Rendering

function Get-WuuRowColor {
    <# Maps the store's colour NAME to a console colour. The store deliberately carries
       names ('Error'/'Timeout'/'Success'/'Default'), not WPF brushes, so this is the only
       place that knows about presentation. #>
    param([string]$Color)
    switch ($Color) {
        'Error'   { 'DarkGray' }
        'Timeout' { 'Yellow' }
        'Success' { 'Green' }
        default   { 'Gray' }
    }
}

function Format-WuuTable {
    <# Renders rows as a fixed-width text table.
       Line-oriented on purpose (no cursor repositioning / progress bars) so a session
       transcript stays readable and diff-able - see docs/CLI_AUDIT_PLAN.md section 5.3. #>
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [int]$ComputerWidth = 20,
        [int]$PhaseWidth = 9,
        [int]$StateWidth = 14,
        [int]$UpdWidth = 17
    )
    $sb = New-Object System.Text.StringBuilder
    $fmt = "{0,-$ComputerWidth} {1,-$PhaseWidth} {2,-$StateWidth} {3,-$UpdWidth} {4}"
    [void]$sb.AppendLine(($fmt -f 'COMPUTER', 'PHASE', 'STATE', 'UPDATES', 'STATUS'))
    [void]$sb.AppendLine(('-' * ($ComputerWidth + $PhaseWidth + $StateWidth + $UpdWidth + 4 + 40)))
    # SS5: while an operation is running, show its budget and how long since the last heartbeat.
    # This is the difference between "slow" and "stuck": a deadline alone only says "not finished",
    # whereas "beat 45s ago" says the worker is alive and making its way through a long search. It is
    # the visibility the timeout plan asked for, and it is why the heartbeat exists at all.
    $now = Get-Date
    foreach ($r in $Rows) {
        $upd = "A:$($r.Available) D:$($r.Downloaded)"
        if ($r.RebootRequired) { $upd += ' RBT' }
        $name = [string]$r.Computer
        if ($name.Length -gt $ComputerWidth) { $name = $name.Substring(0, $ComputerWidth - 1) + [char]0x2026 }
        $status = [string]$r.Status
        # Guarded property access: synthetic rows (tests, and any caller building a row by hand) do not
        # carry these fields, and an unguarded read would turn a status table into an error.
        $isRunning = $r.PSObject.Properties['OpState'] -and $r.OpState -eq 'Running'
        if ($isRunning -and $r.PSObject.Properties['TimeoutExpiresAt'] -and $r.TimeoutExpiresAt) {
            $op = if ($r.PSObject.Properties['OpName'] -and $r.OpName) { [string]$r.OpName } else { 'op' }
            $left = [int]($r.TimeoutExpiresAt - $now).TotalMinutes
            $beat = ''
            if ($r.PSObject.Properties['LastHeartbeatAt'] -and $r.LastHeartbeatAt -is [datetime]) {
                $beat = " beat $([int]($now - $r.LastHeartbeatAt).TotalSeconds)s ago"
            }
            $status = "[$op ${left}m left$beat] $status"
        }
        if ($status.Length -gt 60) { $status = $status.Substring(0, 59) + [char]0x2026 }
        [void]$sb.AppendLine(($fmt -f $name, $r.Phase, $r.State, $upd, $status))
    }
    return $sb.ToString()
}

function Write-WuuStatusTable {
    <# Writes the current rows. Does not clear the screen unless asked, so past output
       remains in the transcript. #>
    param(
        [Parameter(Mandatory)][hashtable]$Store,
        [switch]$Clear
    )
    if ($Clear) { try { Clear-Host } catch { } }
    $rows = @(Get-WuuComputerRow -Store $Store)
    if ($rows.Count -eq 0) {
        Write-Host '  (no computers in the list)' -ForegroundColor DarkGray
        return
    }
    # Colour per row is applied by writing each line individually.
    Write-Host ''
    $lines = (Format-WuuTable -Rows $rows) -split "`r?`n"
    $headerLines = 2
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -lt $headerLines) { Write-Host $lines[$i] -ForegroundColor DarkCyan; continue }
        $row = $rows[$i - $headerLines]
        Write-Host $lines[$i] -ForegroundColor (Get-WuuRowColor -Color $row.Color)
    }
    Write-Host ''
}

function Write-WuuStatusLine {
    param([Parameter(Mandatory)][hashtable]$Store)
    $s = [string]$Store.Status
    if ($s) { Write-Host "  $s" -ForegroundColor Cyan }
}

#endregion Rendering

#region Menu

function Get-WuuMenuActions {
    <# The operation surface, mirroring the GUI context menu 1:1 (see
       docs/CLI_AUDIT_PLAN.md section 4 for the parity table). Mutating actions are flagged
       so the audit layer (Phase 4) can require a reason for them.

       `Handler` names the $consoleActions key this entry invokes. It is carried as DATA (not just
       closed over inside Run) so the guided workflow - and any test - can dispatch by name, verify
       that every entry points at a handler that actually exists, and route mutating entries
       through the audit choke point. A menu entry whose Run referenced a missing action used to be
       silently unreachable; with Handler present it is a detectable defect. #>
    @(
        @{ Key = '1';  Label = 'Check for updates';            Mutating = $false; Handler = 'EventGetUpdates';                   Run = { param($ctx) & $ctx.EventGetUpdates } }
        @{ Key = '2';  Label = 'Download updates';            Mutating = $true;  Handler = 'EventDownloadUpdates';              Run = { param($ctx) & $ctx.EventDownloadUpdates } }
        @{ Key = '3';  Label = 'Install updates';             Mutating = $true;  Handler = 'EventInstallUpdates';               Run = { param($ctx) & $ctx.EventInstallUpdates } }
        @{ Key = '4';  Label = 'Restart computer(s)';         Mutating = $true;  Handler = 'EventRestartComputer';              Run = { param($ctx) & $ctx.EventRestartComputer } }
        @{ Key = '5';  Label = 'Show available updates';      Mutating = $false; Handler = 'EventShowAvailableUpdates';         Run = { param($ctx) & $ctx.EventShowAvailableUpdates } }
        @{ Key = '6';  Label = 'Show installed updates';      Mutating = $false; Handler = 'EventShowInstalledUpdates';         Run = { param($ctx) & $ctx.EventShowInstalledUpdates } }
        @{ Key = '7';  Label = 'Update history';              Mutating = $false; Handler = 'EventShowUpdateHistory';            Run = { param($ctx) & $ctx.EventShowUpdateHistory } }
        @{ Key = '8';  Label = 'Audit WSUS updates';          Mutating = $false; Handler = 'EventAuditWSUSUpdates';            Run = { param($ctx) & $ctx.EventAuditWSUSUpdates } }
        @{ Key = '9';  Label = 'Add computer(s) manually';    Mutating = $false; Handler = 'EventAddComputer';                 Run = { param($ctx) & $ctx.EventAddComputer } }
        @{ Key = 'a';  Label = 'Add from file (CSV/TXT)';     Mutating = $false; Handler = 'EventAddFile';                     Run = { param($ctx) & $ctx.EventAddFile } }
        @{ Key = 's';  Label = 'Show computers in a phase';   Mutating = $false; Handler = 'EventShowByPhase';                  Run = { param($ctx) & $ctx.EventShowByPhase } }
        @{ Key = 'p';  Label = 'Assign phase to selection';   Mutating = $false; Handler = 'EventAssignPhaseInteractive';       Run = { param($ctx) & $ctx.EventAssignPhaseInteractive } }
        @{ Key = 'r';  Label = 'Remove computer(s)';          Mutating = $false; Handler = 'EventRemoveSelected';               Run = { param($ctx) & $ctx.EventRemoveSelected } }
        @{ Key = 'c';  Label = 'Clear computer list';         Mutating = $false; Handler = 'ClearComputerList';                 Run = { param($ctx) & $ctx.ClearComputerList } }
        @{ Key = 'x';  Label = 'Export list to file';         Mutating = $false; Handler = 'EventSaveComputerList';             Run = { param($ctx) & $ctx.EventSaveComputerList } }
        @{ Key = 'v';  Label = 'Save encrypted config';       Mutating = $false; Handler = 'EventSaveConfig';                   Run = { param($ctx) & $ctx.EventSaveConfig } }
        @{ Key = 'l';  Label = 'Load encrypted config';       Mutating = $false; Handler = 'EventLoadConfig';                   Run = { param($ctx) & $ctx.EventLoadConfig } }
        @{ Key = 'd';  Label = 'Set domain credentials';      Mutating = $false; Handler = 'EventSetDomainCredentials';         Run = { param($ctx) & $ctx.EventSetDomainCredentials } }
        @{ Key = 'o';  Label = 'Remove offline computers';    Mutating = $false; Handler = 'EventRemoveOfflineComputer';        Run = { param($ctx) & $ctx.EventRemoveOfflineComputer } }
        @{ Key = 'y';  Label = 'Deployment report';           Mutating = $false; Handler = 'EventDeploymentReport';            Run = { param($ctx) & $ctx.EventDeploymentReport } }
        @{ Key = 'e';  Label = 'Show errors';                 Mutating = $false; Handler = 'GetErrors';                        Run = { param($ctx) & $ctx.GetErrors } }
        @{ Key = 'g';  Label = 'View Windows Update log';     Mutating = $false; Handler = 'EventViewUpdateLog';                Run = { param($ctx) & $ctx.EventViewUpdateLog } }
        @{ Key = 'w';  Label = 'Windows Update service';      Mutating = $true;  Handler = 'EventWUServiceActionInteractive';   Run = { param($ctx) & $ctx.EventWUServiceActionInteractive } }
        @{ Key = 'n';  Label = 'Add computers from Active Directory'; Mutating = $false; Handler = 'EventAddAD';                 Run = { param($ctx) & $ctx.EventAddAD } }
        @{ Key = 't';  Label = 'Toggle ALL automation (download/install/reboot)'; Mutating = $false; Handler = 'EventToggleSettings';        Run = { param($ctx) & $ctx.EventToggleSettings } }
        @{ Key = '?';  Label = 'Help';                        Mutating = $false; Handler = 'ShowHelp';                         Run = { param($ctx) & $ctx.ShowHelp } }
        @{ Key = 'q';  Label = 'Quit';                        Mutating = $false; Handler = '';                                 Run = { param($ctx) $ctx.Quit = $true } }
    )
}

function Write-WuuMenu {
    param([Parameter(Mandatory)][hashtable]$Store)
    $dl = if ($Store.Settings.AutoDownload) { 'ON' } else { 'off' }
    $il = if ($Store.Settings.AutoInstall) { 'ON' } else { 'off' }
    $rb = if ($Store.Settings.AutoReboot) { 'ON' } else { 'off' }
    Write-Host ''
    Write-Host ("  Auto download: $dl   Auto install: $il   Auto reboot: $rb") -ForegroundColor DarkGray
    Write-Host '  ------------------------------------------------------------------' -ForegroundColor DarkGray
    # Named $menuActions, not $actions: case-insensitive naming means `$actions` would become a
    # trap for anyone later adding a $Actions parameter to this function (see the collision gate).
    $menuActions = Get-WuuMenuActions
    foreach ($a in $menuActions) {
        $mark = if ($a.Mutating) { '*' } else { ' ' }
        Write-Host ("  [{0}] {1} {2}" -f $a.Key.PadLeft(2), $mark, $a.Label)
    }
    Write-Host '  (* = changes remote state)' -ForegroundColor DarkGray
}

#endregion Menu

#region Input loop

function Start-WuuConsoleLoop {
    <#
    .SYNOPSIS
    Runs the interactive console menu until the operator quits.
    .DESCRIPTION
    Polls the keyboard non-blockingly so the job scheduler can be drained on every tick
    (see the module header for why a timer cannot work here). The scheduler call is supplied
    by the caller as a scriptblock so this module does not depend on Wuu.WindowsUpdate.

    -AuditHook is an OPTIONAL scriptblock the caller supplies to audit mutating menu actions:
        param($ActionName, $Reason, $Body) -> result
    It is injected rather than called directly so Wuu.Console keeps no dependency on Wuu.Audit,
    and so a build without auditing still runs. When absent, mutating actions run unaudited and
    a warning is printed once - an unaudited change should never be silent.

    Menu actions that mutate are marked Mutating=$true in Get-WuuMenuActions; the loop asks for a
    reason (interactive) and passes it to the hook, matching the command surface's -Reason.

    -DenialHook is an OPTIONAL scriptblock called when a mutating action is REFUSED before it
    runs - currently the operator cancelling at the reason prompt:
        param($ActionName, $DenialReason)
    ISO 27001 A.8.15 expects denied attempts to be recorded, not just successful ones, so a
    cancellation is an auditable event. It is best-effort: a failure to record the denial must
    never change the outcome (the operation stays cancelled either way).
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Store,
        [Parameter(Mandatory)][scriptblock]$DrainScheduler,
        [Parameter(Mandatory)][hashtable]$Actions,
        [scriptblock]$AuditHook,
        [scriptblock]$DenialHook,
        [int]$TickMilliseconds = 250
    )
    Write-WuuStatusTable -Store $Store
    Write-WuuStatusLine -Store $Store
    Write-WuuMenu -Store $Store

    $warnedNoAudit = $false
    # NOT `$actions`: PowerShell variable names are CASE-INSENSITIVE, so `$actions` IS the
    # `$Actions` parameter. Assigning the menu array to it tried to coerce Object[] into the
    # declared [hashtable] and threw "Cannot convert the System.Object[] ... to Hashtable" -
    # which killed the shell the moment the menu was drawn, making the interactive edition
    # completely unusable. See the validator's case-insensitive-collision gate.
    $menuActions = Get-WuuMenuActions
    while (-not $Actions.Quit) {
        # Drain queued work (auto-flow, retries) before waiting for input, then keep draining
        # while waiting - this is the replacement for the GUI's DispatcherTimer.
        try { & $DrainScheduler } catch { Write-Warning "Scheduler tick failed: $($_.Exception.Message)" }

        # Live progress, rendered HERE and nowhere else. This is the only place the loop is
        # guaranteed to be between prompts: every menu action and helper below has already returned,
        # so the line cannot overwrite a question the operator is part-way through answering.
        # Observational only - it reads the store and prints; the drain above is still the only
        # thing that moves work along.
        try { Write-WuuProgressTicker -Store $Store | Out-Null } catch { }

        $pressed = $null
        try {
            # Honour non-interactive mode: without this the menu keypress is the ONLY menu input
            # that bypasses the Phase 2 input choke point. A test driving the menu, a redirected
            # stdin, or any scripted run would then block forever inside ReadKey on a terminal
            # nobody is typing into - the loop is unreachable, and the crash this check guards
            # against could never be caught by a test.
            if ((Get-WuuInputMode).NonInteractive) {
                $pressed = [string](Read-WuuAnswer -Prompt 'Select' -Default 'q')
            } elseif ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                $pressed = [string]$key.KeyChar
            }
        } catch {
            # No console (redirected input / ISE): fall back to a blocking prompt
            $pressed = Read-Host 'Select'
        }

        if (-not $pressed) {
            Start-Sleep -Milliseconds $TickMilliseconds
            continue
        }
        if ([string]::IsNullOrWhiteSpace($pressed)) { continue }

        $chosen = $null
        foreach ($a in $menuActions) { if ($a.Key -eq $pressed.ToLowerInvariant()) { $chosen = $a; break } }
        if (-not $chosen) {
            Write-Host "  Unknown selection '$pressed' - press ? for help." -ForegroundColor Yellow
            continue
        }

        if ($chosen.Key -eq 'q') { break }

        Write-Host ''
        Write-Host ("  > {0}" -f $chosen.Label) -ForegroundColor White
        try {
            if ($chosen.Mutating -and $AuditHook) {
                # Ask WHY before a change - the same information the command surface requires
                # via -Reason, so the two surfaces produce comparable audit records.
                $reason = Read-WuuAnswer -Prompt '  Reason for this change (recorded in the audit trail)' -Default ''
                if ([string]::IsNullOrWhiteSpace([string]$reason)) {
                    Write-Host '  A reason is required for audited changes - operation cancelled.' -ForegroundColor Yellow
                    # Record the refusal. Best-effort by design: the action is cancelled either
                    # way, so a logging failure here must not surface as an operation failure.
                    if ($DenialHook) {
                        try { & $DenialHook $chosen.Label 'reason not supplied (cancelled at prompt)' | Out-Null }
                        catch { Write-WarningLog "Could not record denial for '$($chosen.Label)': $($_.Exception.Message)" }
                    }
                } else {
                    & $AuditHook $chosen.Label $reason $chosen.Run | Out-Null
                }
            } elseif ($chosen.Mutating -and -not $warnedNoAudit) {
                $warnedNoAudit = $true
                Write-Host '  WARNING: auditing is not active, so this change will not be recorded.' -ForegroundColor Yellow
                & $chosen.Run $Actions
            } else {
                & $chosen.Run $Actions
            }
        } catch {
            Write-Host ("  Operation failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
            Write-ErrorLog "$($chosen.Label) failed: $($_.Exception.Message)"
        }

        Write-WuuStatusTable -Store $Store
        Write-WuuStatusLine -Store $Store
        Write-WuuMenu -Store $Store
    }
    Write-Host ''
    Write-Host '  Shutting down...' -ForegroundColor DarkGray
}

#endregion Input loop

#region Non-interactive input provider

<#
WHY THIS EXISTS
---------------
Phase 2 needs `wuu check -Computer SRV01` etc. to run the SAME operations as the menu. The
action handlers obtain input through Read-WuuSelection / Read-WuuYesNo / Read-Host, so rather
than duplicating 23 handlers for scripted use, this module provides ONE choke point that those
helpers consult:

  * interactive (default)      -> prompt on the console, as before
  * non-interactive (command)  -> take the next pre-supplied answer from a queue; if the queue
                                  is exhausted use the caller's default; if there is no default,
                                  FAIL LOUDLY ("required input missing") instead of hanging

That last property is the point: a scripted/CI run must never block on a prompt. It is also the
whole reason the handlers could be reused unchanged - no handler knows it is being scripted.
#>

$script:WuuNonInteractive = $false
$script:WuuAnswers = New-Object System.Collections.Queue
$script:WuuAnswersUsed = 0

function Initialize-WuuInputMode {
    <#
    .SYNOPSIS Switches input between interactive prompting and scripted answers.
    .PARAMETER NonInteractive Enqueue-answers mode; no console reads.
    .PARAMETER Answers Ordered answers for successive input requests (selection, yes/no, etc.).
    #>
    param(
        [switch]$NonInteractive,
        [object[]]$Answers = @()
    )
    $script:WuuNonInteractive = [bool]$NonInteractive
    $script:WuuAnswers = New-Object System.Collections.Queue
    $script:WuuAnswersUsed = 0
    # Clearing the guided target override here matters for scripted runs: a target list left set by
    # a previous scenario would silently narrow the NEXT operation's selection, which is the kind
    # of cross-test leak that makes a failing assertion look like a product bug.
    $global:WuuGuidedTargets = $null
    if ($Answers) { foreach ($a in $Answers) { $script:WuuAnswers.Enqueue($a) } }
}

function Get-WuuInputMode {
    [pscustomobject]@{
        NonInteractive = $script:WuuNonInteractive
        AnswersQueued  = $script:WuuAnswers.Count
        AnswersUsed    = $script:WuuAnswersUsed
    }
}

function Read-WuuAnswer {
    <#
    .SYNOPSIS The single input choke point used by every interactive helper.
    .DESCRIPTION
    Interactive: prompts with Read-Host (or Read-Host -AsSecureString).
    Non-interactive: dequeues the next supplied answer, else returns -Default, else THROWS.
    The throw is deliberate - a missing required input must fail the command, not hang it.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [object]$Default = $null,
        [switch]$Secure,
        [switch]$HasDefault
    )
    if ($script:WuuNonInteractive) {
        if ($script:WuuAnswers.Count -gt 0) {
            $script:WuuAnswersUsed++
            $a = $script:WuuAnswers.Dequeue()
            Write-Host ("  {0} => {1}" -f $Prompt.Trim(), $(if ($Secure) { '(supplied)' } else { $a })) -ForegroundColor DarkGray
            return $a
        }
        if ($HasDefault -or $null -ne $Default) {
            Write-Host ("  {0} => (default) {1}" -f $Prompt.Trim(), $Default) -ForegroundColor DarkGray
            return $Default
        }
        throw "Required input missing in non-interactive mode: '$($Prompt.Trim())'. Supply it as a parameter (e.g. -Computer) or drop -NonInteractive."
    }

    if ($Secure) {
        try {
            $sec = Read-Host -Prompt $Prompt -AsSecureString
        } catch {
            Write-ErrorLog "Secure input unavailable: $($_.Exception.Message)"
            return $null
        }
        if ($null -eq $sec -or $sec.Length -eq 0) { return $null }
        return $sec
    }
    return (Read-Host $Prompt)
}

#endregion Non-interactive input provider

#region Fatal exit
function Stop-WuuFatal {
    <#
    .SYNOPSIS
    Exits on a fatal startup error, without waiting for a keypress.

    .DESCRIPTION
    WHY THIS REPLACES `Read-Host "Press Enter to exit"`.

    Four startup failure paths ended with that prompt. It violates the project's own input rule (all
    input goes through Read-WuuAnswer / Read-WuuYesNo / Read-WuuSelection), and the failure mode is
    worse than an untestable prompt: **it hangs every unattended caller**. A scheduled task, a CI job,
    or an agent-driven test has nobody to press Enter, so a startup error became a hung process -
    the operator sees no failure, just a job that never finishes.

    The prompt was presumably meant to keep a double-clicked window open so a human could read the
    message. That intent is kept WITHOUT blocking: write the error, and wait only when there is a real
    interactive console attached. Redirection, `-NonInteractive`, and a missing console all return
    immediately.

    THE EXIT CODE IS PART OF THIS. The bare `exit` these paths used exits 0, so a failed startup
    reported SUCCESS to the caller - a script would treat "could not validate the environment" as a
    clean run. Fatal startup is exit 1, matching the documented contract (see docs/EXIT_CODES.md;
    startup faults are operation failures, not usage errors).

    -WhatHappened names the failure for the log and the console, so the two agree.
    #>
    param(
        [Parameter(Mandatory)][string]$WhatHappened,
        [Parameter(Mandatory = $false)][int]$ExitCode = 1
    )

    # Best-effort logging: this runs on a path where logging itself may be broken.
    try { Write-ErrorLog "Fatal: $WhatHappened" } catch { }

    Write-Host ''
    Write-Host ("  $WhatHappened") -ForegroundColor Red
    Write-Host "  See the debug log for details." -ForegroundColor Red

    # Wait ONLY for a human at a real console. Every unattended caller must continue.
    if (-not $script:WuuNonInteractive) {
        try {
            if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
                Write-Host '  Press Enter to close...' -ForegroundColor DarkGray
                [void][Console]::ReadLine()
            }
        } catch {
            # Best-effort convenience only. A console that cannot be read must not prevent the exit, and
            # the exit code below is the contract a wrapper actually reads - so there is nothing to
            # recover here and nothing the caller could act on.
        }
    }

    exit $ExitCode
}

#endregion Fatal exit

#region Selectors (shared by menu actions)

function Read-WuuSelection {
<# Resolves which computers an action applies to. Accepts '*' for all, a comma list of
   names, or a phase filter - the console equivalent of the GUI's row selection.

   GUIDED-TARGET OVERRIDE. The guided workflow confirms an explicit target list and must be able
   to answer the selection question itself, so an operation can be narrowed to the computers that
   FAILED (spec 15's "retry failed") rather than re-prompting for a set the operator just
   authorised. It therefore sets $global:WuuGuidedTargets and this function honours it.

   WHY A GLOBAL RATHER THAN A PARAMETER. The selection is consumed inside the $consoleActions
   handlers in Wuu.Core, which have no parameters and are shared verbatim with the command surface
   (spec 23/24). Threading a new argument through every handler would either fork those handlers or
   change the shape of the object the verb table dispatches into. The global is module-visible
   because every module is imported with -Global, and it is cleared by its setter after a single
   use, so it cannot leak into an unrelated operation.

   An EMPTY list is respected as "the caller already decided nothing is targeted" - it must not
   fall through to prompting, or a retry with no failures would silently become an all-computers
   operation. Only $null means "no guided decision; ask as usual". #>
    param(
        [Parameter(Mandatory)][hashtable]$Store,
        [string]$Prompt = 'Computer(s) - name(s), "all", or Enter to cancel'
    )
    if ($null -ne $global:WuuGuidedTargets) {
        $guided = @($global:WuuGuidedTargets)
        $global:WuuGuidedTargets = $null
        $rows = New-Object System.Collections.ArrayList
        foreach ($n in $guided) {
            $row = Get-WuuComputerRow -Store $Store -Computer $n
            if ($row) { [void]$rows.Add($row) }
        }
        return $rows.ToArray()
    }
    $all = @(Get-WuuComputerRow -Store $Store)
    if ($all.Count -eq 0) { Write-Host '  No computers in the list.' -ForegroundColor Yellow; return @() }
    $ans = Read-WuuAnswer -Prompt "  $Prompt" -Default ''
    if ([string]::IsNullOrWhiteSpace($ans)) { return @() }
    $ans = ([string]$ans).Trim()
    if ($ans -match '^(all|\*)$') { return $all }
    $wanted = $ans -split '[,;]'
    $picked = New-Object System.Collections.ArrayList
    foreach ($w in $wanted) {
        $n = $w.Trim()
        if (-not $n) { continue }
        $row = Get-WuuComputerRow -Store $Store -Computer $n
        if ($row) { $pick = $row } else {
            # allow unambiguous prefix match
            # NOTE: $matches is an automatic variable (regex results) - never reuse that name.
            $prefixHits = @()
            foreach ($r in $all) { if ($r.Computer -like "$n*") { $prefixHits += $r } }
            if ($prefixHits.Count -eq 1) { $pick = $prefixHits[0] }
            else { Write-Host "  '$n' not found (or ambiguous) - skipped." -ForegroundColor Yellow; continue }
        }
        $picked.Add($pick) | Out-Null
    }
    return $picked.ToArray()
}

function Read-WuuYesNo {
    param([string]$Prompt, [bool]$Default = $false)
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $ans = Read-WuuAnswer -Prompt "  $Prompt $suffix" -Default '' -HasDefault
    if ([string]::IsNullOrWhiteSpace([string]$ans)) { return $Default }
    return (([string]$ans).Trim() -match '^(y|yes)$')
}

#endregion Selectors

Export-ModuleMember -Function @(
    'Get-WuuRowColor'
    'Format-WuuTable'
    'Write-WuuStatusTable'
    'Write-WuuStatusLine'
    'Get-WuuMenuActions'
    'Write-WuuMenu'
    'Start-WuuConsoleLoop'
    'Initialize-WuuInputMode'
    'Get-WuuInputMode'
    'Read-WuuAnswer'
    'Read-WuuSelection'
    'Read-WuuYesNo'
    'Stop-WuuFatal'
)
