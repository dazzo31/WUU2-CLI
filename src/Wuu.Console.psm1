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
    foreach ($r in $Rows) {
        $upd = "A:$($r.Available) D:$($r.Downloaded)"
        if ($r.RebootRequired) { $upd += ' RBT' }
        $name = [string]$r.Computer
        if ($name.Length -gt $ComputerWidth) { $name = $name.Substring(0, $ComputerWidth - 1) + [char]0x2026 }
        $status = [string]$r.Status
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
       so the audit layer (Phase 4) can require a reason for them. #>
    @(
        @{ Key = '1';  Label = 'Check for updates';            Mutating = $false; Run = { param($ctx) & $ctx.EventGetUpdates } }
        @{ Key = '2';  Label = 'Download updates';            Mutating = $true;  Run = { param($ctx) & $ctx.EventDownloadUpdates } }
        @{ Key = '3';  Label = 'Install updates';             Mutating = $true;  Run = { param($ctx) & $ctx.EventInstallUpdates } }
        @{ Key = '4';  Label = 'Restart computer(s)';         Mutating = $true;  Run = { param($ctx) & $ctx.EventRestartComputer } }
        @{ Key = '5';  Label = 'Show available updates';      Mutating = $false; Run = { param($ctx) & $ctx.EventShowAvailableUpdates } }
        @{ Key = '6';  Label = 'Show installed updates';      Mutating = $false; Run = { param($ctx) & $ctx.EventShowInstalledUpdates } }
        @{ Key = '7';  Label = 'Update history';              Mutating = $false; Run = { param($ctx) & $ctx.EventShowUpdateHistory } }
        @{ Key = '8';  Label = 'Audit WSUS updates';          Mutating = $false; Run = { param($ctx) & $ctx.EventAuditWSUSUpdates } }
        @{ Key = '9';  Label = 'Add computer(s) manually';    Mutating = $false; Run = { param($ctx) & $ctx.EventAddComputer } }
        @{ Key = 'a';  Label = 'Add from file (CSV/TXT)';     Mutating = $false; Run = { param($ctx) & $ctx.EventAddFile } }
        @{ Key = 's';  Label = 'Show computers in a phase';   Mutating = $false; Run = { param($ctx) & $ctx.EventShowByPhase } }
        @{ Key = 'p';  Label = 'Assign phase to selection';   Mutating = $false; Run = { param($ctx) & $ctx.EventAssignPhaseInteractive } }
        @{ Key = 'r';  Label = 'Remove computer(s)';          Mutating = $false; Run = { param($ctx) & $ctx.EventRemoveSelected } }
        @{ Key = 'c';  Label = 'Clear computer list';         Mutating = $false; Run = { param($ctx) & $ctx.ClearComputerList } }
        @{ Key = 'x';  Label = 'Export list to file';         Mutating = $false; Run = { param($ctx) & $ctx.EventSaveComputerList } }
        @{ Key = 'v';  Label = 'Save encrypted config';       Mutating = $false; Run = { param($ctx) & $ctx.EventSaveConfig } }
        @{ Key = 'l';  Label = 'Load encrypted config';       Mutating = $false; Run = { param($ctx) & $ctx.EventLoadConfig } }
        @{ Key = 'd';  Label = 'Set domain credentials';      Mutating = $false; Run = { param($ctx) & $ctx.EventSetDomainCredentials } }
        @{ Key = 'o';  Label = 'Remove offline computers';    Mutating = $false; Run = { param($ctx) & $ctx.EventRemoveOfflineComputer } }
        @{ Key = 'e';  Label = 'Show errors';                 Mutating = $false; Run = { param($ctx) & $ctx.GetErrors } }
        @{ Key = 'g';  Label = 'View Windows Update log';     Mutating = $false; Run = { param($ctx) & $ctx.EventViewUpdateLog } }
        @{ Key = 'w';  Label = 'Windows Update service';      Mutating = $true;  Run = { param($ctx) & $ctx.EventWUServiceActionInteractive } }
        @{ Key = 't';  Label = 'Toggle auto download/install/reboot'; Mutating = $false; Run = { param($ctx) & $ctx.EventToggleSettings } }
        @{ Key = '?';  Label = 'Help';                        Mutating = $false; Run = { param($ctx) & $ctx.ShowHelp } }
        @{ Key = 'q';  Label = 'Quit';                        Mutating = $false; Run = { param($ctx) $ctx.Quit = $true } }
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
    $actions = Get-WuuMenuActions
    foreach ($a in $actions) {
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
    $actions = Get-WuuMenuActions
    while (-not $Actions.Quit) {
        # Drain queued work (auto-flow, retries) before waiting for input, then keep draining
        # while waiting - this is the replacement for the GUI's DispatcherTimer.
        try { & $DrainScheduler } catch { Write-Warning "Scheduler tick failed: $($_.Exception.Message)" }

        $pressed = $null
        try {
            if ([Console]::KeyAvailable) {
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
        foreach ($a in $actions) { if ($a.Key -eq $pressed.ToLowerInvariant()) { $chosen = $a; break } }
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

#region Selectors (shared by menu actions)

function Read-WuuSelection {
<# Resolves which computers an action applies to. Accepts '*' for all, a comma list of
   names, or a phase filter - the console equivalent of the GUI's row selection. #>
    param(
        [Parameter(Mandatory)][hashtable]$Store,
        [string]$Prompt = 'Computer(s) - name(s), "all", or Enter to cancel'
    )
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
)
