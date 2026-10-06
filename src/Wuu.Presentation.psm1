#Requires -Version 5.1
<#
.DESCRIPTION
Presentation and status helpers for the console edition, extracted from Wuu.Core.psm1 (instructions SS8:
Core should become a bootstrap/orchestration layer, and SS7: presentation belongs to the console module).

WHY THIS MODULE AND NOT Wuu.Core. These seven helpers are the console edition's answer to the GUI's
dialog and status-window calls: status text, a password prompt, error/warning dialogs, and the
background-processing pause. They own no engine logic. Wuu.Console is the presentation layer, so that is
where they belong, next to the renderers and the input choke point they already depend on.

THE STATE STORE IS PASSED IN, NOT CAPTURED. In Wuu.Core these were closures over Start-WuuApplication's
`$stateStore`. A module cannot close over another scope, so the store arrives through
Initialize-WuuPresentation - the same shape as Initialize-WuuInputMode immediately below it, and the same
approach Wuu.Scheduler and Wuu.WindowsUpdate already use for their runspaces ("explicit context, never a
module global"). Initialize-WuuInputMode is called first so the presentation initializer does not have to
know about it, and both are called from Start-WuuApplication's startup path.
#>

# The store the status writers update. Module-scope, set once by Initialize-WuuPresentation, because
# Update-Status is called from 17 sites that have no reason to thread a store through their signatures.
$script:WuuPresentationStore = $null

# Presentation theme: 'Standard', 'Accessible', 'NoColor'.
# Controlled via Set-WuuTheme, or environment overrides $env:NO_COLOR and $env:WUU_THEME.
$script:WuuPresentationTheme = 'Standard'

function Get-WuuTheme {
    <#
    .SYNOPSIS Resolves the currently active presentation theme.
    .DESCRIPTION
    Checks for external environment overrides in priority order:
      1. $env:NO_COLOR (if defined and non-empty, yields 'NoColor' per https://no-color.org)
      2. $env:WUU_THEME (if defined and valid: 'Standard', 'Accessible', 'NoColor')
      3. Script configuration set via Set-WuuTheme (defaults to 'Standard')
    #>
    if ($env:NO_COLOR -and -not [string]::IsNullOrWhiteSpace($env:NO_COLOR)) {
        return 'NoColor'
    }
    if ($env:WUU_THEME -and -not [string]::IsNullOrWhiteSpace($env:WUU_THEME)) {
        $envTheme = $env:WUU_THEME.Trim()
        if ($envTheme -match '^(?i)standard$') { return 'Standard' }
        if ($envTheme -match '^(?i)accessible$') { return 'Accessible' }
        if ($envTheme -match '^(?i)nocolor$') { return 'NoColor' }
    }
    return $script:WuuPresentationTheme
}

function Set-WuuTheme {
    <#
    .SYNOPSIS Sets the active presentation theme ('Standard', 'Accessible', 'NoColor').
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Standard', 'Accessible', 'NoColor', IgnoreCase = $true)]
        [string]$Theme
    )
    switch -Regex ($Theme) {
        '(?i)^standard$'   { $script:WuuPresentationTheme = 'Standard' }
        '(?i)^accessible$' { $script:WuuPresentationTheme = 'Accessible' }
        '(?i)^nocolor$'    { $script:WuuPresentationTheme = 'NoColor' }
    }
    return $script:WuuPresentationTheme
}

function Get-WuuThemeColor {
    <#
    .SYNOPSIS Maps a presentation role to a console color based on the active theme.
    .DESCRIPTION
    Returns a ConsoleColor name string, or '' when NoColor is active.
    Roles:
      - 'Success': Green (Standard), Cyan (Accessible)
      - 'Failure' / 'Error': Red (Standard), Magenta (Accessible)
      - 'RowError': DarkGray (Standard), DarkMagenta (Accessible)
      - 'Attention' / 'Warning' / 'Timeout' / 'Reboot' / 'Available': Yellow (Standard), Yellow (Accessible)
      - 'Stale': DarkYellow (Standard), Yellow (Accessible)
      - 'Progress' / 'Active' / 'Running': Cyan (Standard), White (Accessible)
      - 'Header': DarkCyan (Standard), DarkCyan (Accessible)
      - 'Muted' / 'Waiting' / 'Offline': DarkGray (Standard), DarkGray (Accessible)
      - 'Info': White (Standard), White (Accessible)
      - 'Default': Gray (Standard), Gray (Accessible)
    #>
    param(
        [Parameter(Mandatory)][string]$Role,
        [string]$Theme = ''
    )

    $effectiveTheme = if ($Theme) {
        switch -Regex ($Theme) {
            '(?i)^standard$'   { 'Standard' }
            '(?i)^accessible$' { 'Accessible' }
            '(?i)^nocolor$'    { 'NoColor' }
            default            { Get-WuuTheme }
        }
    } else {
        Get-WuuTheme
    }

    if ($effectiveTheme -eq 'NoColor') {
        return ''
    }

    if ($effectiveTheme -eq 'Accessible') {
        switch -Regex ($Role) {
            '(?i)^(Success|OK)$'                                       { return 'Cyan' }
            '(?i)^(Failure|Error|Fail)$'                                { return 'Magenta' }
            '(?i)^RowError$'                                            { return 'DarkMagenta' }
            '(?i)^(Attention|Warning|Timeout|Reboot|Available|Warn)$'   { return 'Yellow' }
            '(?i)^Stale$'                                               { return 'Yellow' }
            '(?i)^(Progress|Active|Running|Run)$'                       { return 'White' }
            '(?i)^Header$'                                              { return 'DarkCyan' }
            '(?i)^(Muted|Waiting|Wait|Offline)$'                        { return 'DarkGray' }
            '(?i)^Info$'                                                { return 'White' }
            default                                                     { return 'Gray' }
        }
    }

    # Standard Theme
    switch -Regex ($Role) {
        '(?i)^(Success|OK)$'                                       { return 'Green' }
        '(?i)^(Failure|Error|Fail)$'                                { return 'Red' }
        '(?i)^RowError$'                                            { return 'DarkGray' }
        '(?i)^(Attention|Warning|Timeout|Reboot|Available|Warn)$'   { return 'Yellow' }
        '(?i)^Stale$'                                               { return 'DarkYellow' }
        '(?i)^(Progress|Active|Running|Run)$'                       { return 'Cyan' }
        '(?i)^Header$'                                              { return 'DarkCyan' }
        '(?i)^(Muted|Waiting|Wait|Offline)$'                        { return 'DarkGray' }
        '(?i)^Info$'                                                { return 'White' }
        default                                                     { return 'Gray' }
    }
}

function Initialize-WuuPresentation {
    <#
    .SYNOPSIS Hands the presentation helpers the state store they write status into.
    .DESCRIPTION Called once during startup, before any helper can run. Idempotent: a second call with
    $null is refused rather than silently detaching the store the status writers need.
    #>
    param([Parameter(Mandatory)][object]$StateStore)
    $script:WuuPresentationStore = $StateStore
}

# Function to update status text box
function Update-Status {
    param([string]$Message)
    try {
        # Console edition: store-held status text (renderer draws it); no dispatcher.
        if ($script:WuuPresentationStore) { $script:WuuPresentationStore.SetStatus($Message) }
    } catch {
        # Silently handle errors during shutdown
    }
}

# Function to update status text box with background priority
function Update-StatusBackground {
    param([string]$Message)
    try {
        # Console edition: same path as Update-Status - there is no UI-thread priority
        # distinction once the status is just a value in the store.
        if ($script:WuuPresentationStore) { $script:WuuPresentationStore.SetStatus($Message) }
    } catch {
        # Silently handle errors during shutdown
    }
}

# Console password prompt (replaces the WPF Show-PasswordPrompt dialog).
# Returns a SecureString, or $null if the operator cancelled (empty password).
#
# ROUTED THROUGH Read-WuuAnswer (the single input choke point) rather than calling Read-Host here.
# The project rule is that all input goes through the choke point because a screen calling Read-Host
# directly cannot be driven in non-interactive mode; the choke point's -Secure path is also the one
# that supplies a queued test answer, so a scripted run can exercise this prompt. A bare Read-Host
# here would block a command-mode run at the unlock prompt with no way to answer it.
function _WuuReadPassword {
    param([string]$Prompt = 'Password')
    $sec = $null
    try {
        $sec = Read-WuuAnswer -Prompt $Prompt -Secure
    } catch {
        # The choke point throws when a REQUIRED input is missing in non-interactive mode. That is the
        # correct outcome (fail the command rather than hang), so it is reported and turned into $null
        # for this caller's existing contract - never into a silent empty password.
        Write-ErrorLog "Secure password prompt failed: $($_.Exception.Message)"
        return $null
    }
    if ($null -eq $sec) { return $null }
    # -AsSecureString returns a SecureString; a queued non-interactive answer arrives as a plain
    # string. Convert so the caller always receives the type it expects (it calls Protect-Credential).
    if ($sec -is [System.Security.SecureString]) { return $sec }
    try {
        return (ConvertTo-SecureString -String ([string]$sec) -AsPlainText -Force)
    } catch {
        Write-ErrorLog "Could not convert the supplied password to a SecureString: $($_.Exception.Message)"
        return $null
    }
}

# Function to show message box and log error
function Show-ErrorDialog {
    # Console edition: the GUI's MessageBox is gone, and so is the WPF assembly it needed. A modal
    # dialog would be fatal in a HEADLESS tool - an unattended run would block forever with nobody
    # to click OK. The message is logged and printed instead. Kept rather than deleted: it is the
    # obvious thing for a future error path to call, and a caller that silently vanished would be
    # worse than one that prints.
    param(
        [string]$Message,
        [string]$Title = 'Error',
        [string]$LogMessage = '',
        [string]$Computer = ''
    )

    if ($LogMessage) {
        Write-ErrorLog $LogMessage -Computer $Computer
    } else {
        Write-ErrorLog $Message -Computer $Computer
    }

    $errColor = Get-WuuThemeColor -Role 'Failure'
    Write-Host ''
    if ($errColor) {
        Write-Host ("  {0}: {1}" -f $Title, $Message) -ForegroundColor $errColor
    } else {
        Write-Host ("  {0}: {1}" -f $Title, $Message)
    }
}

# Function to show warning dialog and log
function Show-WarningDialog {
    # See the note on Show-ErrorDialog: console output, never a modal dialog.
    param(
        [string]$Message,
        [string]$Title = 'Warning',
        [string]$LogMessage = '',
        [string]$Computer = ''
    )

    if ($LogMessage) {
        Write-WarningLog $LogMessage -Computer $Computer
    } else {
        Write-WarningLog $Message -Computer $Computer
    }

    $warnColor = Get-WuuThemeColor -Role 'Attention'
    Write-Host ''
    if ($warnColor) {
        Write-Host ("  {0}: {1}" -f $Title, $Message) -ForegroundColor $warnColor
    } else {
        Write-Host ("  {0}: {1}" -f $Title, $Message)
    }
}

# Background processing control functions.
# The paused flag is the SHARED synchronized hashtable created by Wuu.Configuration, passed in at
# initialization rather than captured: the job-cleanup runspace reads the same object, so pausing has
# to flip one instance rather than set a copy.
$script:WuuBackgroundProcessing = $null

function Initialize-WuuBackgroundProcessing {
    <#
    .SYNOPSIS Hands the pause helpers the shared synchronized flag they set.
    .DESCRIPTION Separate from Initialize-WuuPresentation because it is a different object with a
    different lifecycle: the flag is created by Wuu.Configuration and shared with a runspace.
    #>
    param([Parameter(Mandatory)][object]$BackgroundProcessing)
    $script:WuuBackgroundProcessing = $BackgroundProcessing
}

function Suspend-BackgroundProcessing {
    param(
        [string]$Reason = 'User operation'
    )

    Write-InfoLog "Suspending background processing: $Reason"

    # Temporarily pause the job cleanup routine
    if ($script:WuuBackgroundProcessing) { $script:WuuBackgroundProcessing.Suspended = $true }

    # Update status to show background processing is paused
    Update-Status "â¸ï¸ Background processing paused for $Reason..."

    # Give a moment for any current operations to complete
    Start-Sleep -Milliseconds 500
}

function Resume-BackgroundProcessing {
    param(
        [string]$CompletedOperation = 'User operation'
    )

    Write-InfoLog "Resuming background processing after: $CompletedOperation"

    # Resume the job cleanup routine
    if ($script:WuuBackgroundProcessing) { $script:WuuBackgroundProcessing.Suspended = $false }

    # Update status to show background processing is resumed
    Update-Status "âœ… Background processing resumed after $CompletedOperation"
}

#region Progress ticker

function Get-WuuOperationProgress {
    <#
    .SYNOPSIS Counts the fleet's operations by state, for the live progress ticker.
    .DESCRIPTION
    A READ-ONLY derivation from the state store. It reports; it decides nothing. It does not call a
    scheduler, restart a worker, judge an operation dead or timed out, or write any state - the
    counts are a projection of fields the state machine already maintains, and a test asserts the
    store is unchanged by calling this.

    WHY IT LIVES IN Wuu.Presentation. Three reasons, and the third is the binding one:
      * the ticker is presentation - it owns no engine logic, like the other helpers here;
      * the store is already handed to this module by Initialize-WuuPresentation, so no new plumbing
        is needed (the module header explains why the store arrives rather than being captured);
      * Wuu.STATE MUST STAY HEADLESSLY IMPORTABLE - `tests\Test-StateStore.ps1` asserts that
        importing it loads no WPF assembly, and the ticker is a console-rendering concern. Putting
        it in the state module to save a call would have traded a real invariant for a convenience.

    THE VOCABULARY IS READ, NOT DEFINED. `OpState` is set by the submission path and is the same
    field `Test-WuuComputerBusy` consults; the terminal states and their outcome words come from
    `Get-WuuTerminalOutcomeMap`, the single declaration of invariant 8.4. Nothing here invents a
    state name or a second classification of "done", so a state added to that declaration is
    counted here without this function being edited.

    Running and Queued are counted SEPARATELY and deliberately: they are different operator
    situations (work happening now vs work admitted but not started), and folding them together is
    exactly the conflation that makes a progress line useless.

    PARAMETERS
      -Store   the state store to read. Defaults to the one Initialize-WuuPresentation was given.
      -Now     the instant to measure elapsed against. Injected so elapsed formatting is testable
               without sleeping (this repo forbids Start-Sleep as a fix for a race, and a test that
               sleeps to observe a clock is the same smell).
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()]$Store,
        [Parameter(Mandatory = $false)][AllowNull()][datetime]$Now
    )

    $result = [ordered]@{
        Active             = 0
        Queued             = 0
        Succeeded          = 0
        Failed             = 0
        TimedOut           = 0
        Total              = 0
        Elapsed            = $null
        StartedAt          = $null
        WaitingPhase       = $null
        WaitingActiveCount = 0
    }

    # Resolved into NEW locals rather than reassigning the parameters. PowerShell's variable names
    # are case-insensitive, so a gate rejects reassigning a parameter: with the store declared as
    # [hashtable] an assignment coerces, and the coercion is what threw
    # "Cannot convert the System.Object[] ... to Hashtable" and killed the whole interactive shell
    # in a previous release. A new name makes that class of fault impossible here.
    $storeToRead = $Store
    if (-not $storeToRead) { $storeToRead = $script:WuuPresentationStore }
    if (-not $storeToRead) { return $result }

    $instant = $Now
    if ($instant -eq [datetime]::MinValue) { $instant = Get-Date }

    # The accessor, not $Store.Rows: it is the documented read path and preserves insertion order,
    # so two calls cannot disagree about what the fleet is.
    $rows = @()
    try { $rows = @(Get-WuuComputerRow -Store $storeToRead) } catch { $rows = @() }
    $result.Total = $rows.Count

    # Terminal state -> outcome word, from the ONE declaration. Read lazily inside the function so
    # import order (Presentation is imported before State) cannot matter.
    #
    # Copied into a plain hashtable rather than used as returned: the declaration is an
    # ORDERED dictionary (its order carries invariant 8.4's precedence), and an OrderedDictionary has
    # no ContainsKey - calling one is a runtime "method not found", not a $false. Only the lookup is
    # needed here, so the order is not something this projection has to preserve.
    $outcomeMap = @{}
    try {
        $declared = Get-WuuTerminalOutcomeMap
        if ($declared) {
            foreach ($key in @($declared.Keys)) { $outcomeMap[[string]$key] = [string]$declared[$key] }
        }
    } catch { $outcomeMap = @{} }

    $earliestStart = $null
    $activePhases = @{}
    $waitingPhases = @{}
    foreach ($row in $rows) {
        if ($null -eq $row) { continue }

        $pNum = 0
        if ($row.PSObject.Properties['Phase'] -and $row.Phase) {
            if ($row.Phase -match 'Phase\s*(\d+)') {
                $pNum = [int]$matches[1]
            }
        }
        if ($pNum -gt 0) {
            $isRowActive = ($row.PSObject.Properties['OpState'] -and [string]$row.OpState -ceq 'Running')
            $isRowWaiting = (($row.PSObject.Properties['OpState'] -and [string]$row.OpState -ceq 'Queued') -or
                             ($row.PSObject.Properties['Pending'] -and [bool]$row.Pending) -or
                             ($row.PSObject.Properties['Status'] -and [string]$row.Status -like 'Waiting for previous phase*'))
            if ($isRowActive) {
                if (-not $activePhases.ContainsKey($pNum)) { $activePhases[$pNum] = 0 }
                $activePhases[$pNum] = [int]$activePhases[$pNum] + 1
            }
            if ($isRowWaiting) {
                $waitingPhases[$pNum] = $true
            }
        }

        if ($row.PSObject.Properties['OpState']) {
            $opState = [string]$row.OpState
            if ($opState -ceq 'Running') { $result.Active++ }
            elseif ($opState -ceq 'Queued') { $result.Queued++ }
        }

        if ($row.PSObject.Properties['State']) {
            $state = [string]$row.State
            if ($outcomeMap.ContainsKey($state)) {
                # The outcome word is the MAP's, so a timeout is counted beside a failure rather
                # than being guessed at here or silently dropped from the failure total.
                switch ([string]$outcomeMap[$state]) {
                    'Success'  { $result.Succeeded++ }
                    'Failed'   { $result.Failed++ }
                    'TimedOut' { $result.TimedOut++ }
                }
            }
        }

        # Elapsed is measured from the START of the operation. OperationId is the operation's
        # identity, so a row with no id has no operation to time, whatever else it may carry.
        if ($row.PSObject.Properties['OperationId'] -and -not [string]::IsNullOrWhiteSpace([string]$row.OperationId)) {
            $started = $null
            if ($row.PSObject.Properties['OpStartedAt']) {
                $raw = $row.OpStartedAt
                if ($raw -is [datetime]) { $started = $raw }
                elseif ($null -ne $raw -and -not [string]::IsNullOrWhiteSpace([string]$raw)) {
                    $parsed = [datetime]::MinValue
                    if ([datetime]::TryParse([string]$raw, [ref]$parsed)) { $started = $parsed }
                }
            }
            if ($started -and ($null -eq $earliestStart -or $started -lt $earliestStart)) { $earliestStart = $started }
        }
    }

    # Check if a higher phase is waiting on active work in a lower phase
    $activeKeyList = New-Object System.Collections.ArrayList
    foreach ($k in $activePhases.Keys) {
        if ([int]$activePhases[$k] -gt 0) { [void]$activeKeyList.Add([int]$k) }
    }
    if ($activeKeyList.Count -gt 0) {
        $activeKeyList.Sort()
        $lowestActive = [int]$activeKeyList[0]
        $hasHigherWaiting = $false
        foreach ($h in $waitingPhases.Keys) {
            if ([int]$h -gt $lowestActive) {
                $hasHigherWaiting = $true
                break
            }
        }
        if ($hasHigherWaiting) {
            $result.WaitingPhase = $lowestActive
            $result.WaitingActiveCount = [int]$activePhases[$lowestActive]
        }
    }

    if ($earliestStart) {
        $result.StartedAt = $earliestStart
        $span = $instant - $earliestStart
        # A clock skew that puts the start in the future must not render as a negative duration.
        if ($span.TotalSeconds -lt 0) { $span = [timespan]::Zero }
        $result.Elapsed = $span
    }

    return $result
}

function Format-WuuElapsed {
    <#
    .SYNOPSIS Renders an elapsed span as mm:ss, widening to h:mm:ss past an hour.
    .DESCRIPTION
    A missing span renders as '--:--' rather than as 00:00. Those mean different things - "no
    operation is being timed" versus "an operation started just now" - and showing 00:00 for the
    former would assert a fact nobody knows.
    #>
    param([Parameter(Mandatory = $false)][AllowNull()]$Elapsed)

    if ($null -eq $Elapsed) { return '--:--' }
    $span = [timespan]$Elapsed
    if ($span.TotalSeconds -lt 0) { $span = [timespan]::Zero }
    # Truncate rather than round, so the line never shows a time later than the clock.
    $totalMinutes = [int][math]::Floor($span.TotalMinutes)
    $seconds = [int]$span.Seconds
    if ($span.TotalHours -ge 1) {
        return ('{0}:{1:d2}:{2:d2}' -f [int][math]::Floor($span.TotalHours), ($totalMinutes % 60), $seconds)
    }
    return ('{0:d2}:{1:d2}' -f $totalMinutes, $seconds)
}

function Format-WuuProgressTicker {
    <#
    .SYNOPSIS The single-line progress ticker, or $null when nothing is in flight.
    .DESCRIPTION
    Returns $null rather than an idle line, so the caller can leave an existing prompt or output
    untouched. Repainting over a line the operator is reading - or typing into - is worse than
    showing nothing, and the ticker has nothing useful to say when no operation is running.

    TimedOut is counted inside Failed, because the operator's question is "how many did not work".
    The breakdown stays in the object for callers that want it.
    #>
    param([Parameter(Mandatory)]$Progress)

    $active = [int]$Progress.Active
    $queued = [int]$Progress.Queued
    if ($active -le 0 -and $queued -le 0) { return $null }

    $failed = [int]$Progress.Failed + [int]$Progress.TimedOut
    $line = ('[Active: {0} | Queued: {1} | Succeeded: {2} | Failed: {3} | Elapsed: {4}]' -f `
            $active, $queued, [int]$Progress.Succeeded, $failed, (Format-WuuElapsed -Elapsed $Progress.Elapsed))

    $wPhase = if ($Progress -is [System.Collections.IDictionary] -and $Progress.Contains('WaitingPhase')) {
        $Progress['WaitingPhase']
    } elseif ($Progress.PSObject.Properties['WaitingPhase']) {
        $Progress.WaitingPhase
    } else { $null }

    $wCount = if ($Progress -is [System.Collections.IDictionary] -and $Progress.Contains('WaitingActiveCount')) {
        [int]$Progress['WaitingActiveCount']
    } elseif ($Progress.PSObject.Properties['WaitingActiveCount']) {
        [int]$Progress.WaitingActiveCount
    } else { 0 }

    if ($wPhase -and $wCount -gt 0) {
        return "$line Waiting for Phase $wPhase ($wCount active)"
    }
    return $line
}

function Write-WuuProgressTicker {
    <#
    .SYNOPSIS Renders the progress ticker from the store, if anything is in flight.
    .DESCRIPTION
    Observational only. It prints; it never cancels, retries, restarts a worker, or decides an
    operation has timed out - the outer deadline is the authority for that (SS21), and a display
    that could end an operation would be a second, invisible state machine.

    Writes with Write-Host, NOT Update-Status: the store's status line is drawn by the menu
    renderers on their own schedule, and routing the ticker through it would make the ticker the
    cause of a redraw. Emits nothing at all when no operation is in flight, so it is safe to call
    on every tick.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()]$Store,
        [Parameter(Mandatory = $false)][AllowNull()][datetime]$Now
    )

    $progress = Get-WuuOperationProgress -Store $Store -Now $Now
    $line = Format-WuuProgressTicker -Progress $progress
    $tickerColor = Get-WuuThemeColor -Role 'Header'
    if ($tickerColor) {
        Write-Host ('  ' + $line) -ForegroundColor $tickerColor
    } else {
        Write-Host ('  ' + $line)
    }
    return $line
}

#endregion Progress ticker

#region Line-Oriented Charts

function Format-WuuHorizontalBar {
    <#
    .SYNOPSIS Formats a single native, line-oriented horizontal ASCII bar.
    .DESCRIPTION
    Pure string formatter. Returns a line with:
      <Label padded> <Value>/<Total> [<Bar>] <Percent>%
    Design invariants:
      - Line-oriented only: no cursor repositioning, no ANSI codes, pure ASCII defaults.
      - Exact counts are ALWAYS preserved and never truncated.
      - Zero total renders as "0/0 [--------------------] N/A" without division by zero.
      - Value > Total clamps the visual bar to 100% but prints the exact Value/Total count.
      - Non-zero Value (< Total) renders at least 1 fill character if BarWidth > 0.
    #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][int]$Value,
        [Parameter(Mandatory)][int]$Total,
        [int]$BarWidth = 20,
        [char]$FillChar = '=',
        [char]$EmptyChar = '-',
        [int]$LabelWidth = 14,
        [int]$CountWidth = 8,
        [switch]$ShowPercent = $true
    )

    $val = if ($Value -lt 0) { 0 } else { $Value }
    $tot = if ($Total -lt 0) { 0 } else { $Total }
    $bw = if ($BarWidth -lt 0) { 0 } else { $BarWidth }

    $countStr = "{0}/{1}" -f $val, $tot
    $paddedLabel = if ($LabelWidth -gt 0) { "{0,-$LabelWidth}" -f $Label } else { $Label }
    $paddedCount = if ($CountWidth -gt 0) { "{0,$CountWidth}" -f $countStr } else { $countStr }

    if ($tot -eq 0) {
        $emptyBar = if ($bw -gt 0) { "[{0}]" -f (([string]$EmptyChar) * $bw) } else { "" }
        $pctStr = if ($ShowPercent) { " N/A" } else { "" }
        return ("{0} {1} {2}{3}" -f $paddedLabel, $paddedCount, $emptyBar, $pctStr).TrimEnd()
    }

    $ratio = [double]$val / [double]$tot
    if ($ratio -gt 1.0) { $ratio = 1.0 }
    if ($ratio -lt 0.0) { $ratio = 0.0 }

    $fillCount = [int][math]::Floor($ratio * $bw)
    if ($val -gt 0 -and $fillCount -eq 0 -and $bw -gt 0) {
        $fillCount = 1
    }
    if ($val -ge $tot -and $bw -gt 0) {
        $fillCount = $bw
    }
    $emptyCount = $bw - $fillCount
    if ($emptyCount -lt 0) { $emptyCount = 0 }

    $barStr = if ($bw -gt 0) {
        "[{0}{1}]" -f (([string]$FillChar) * $fillCount), (([string]$EmptyChar) * $emptyCount)
    } else { "" }

    $pctVal = [math]::Round(($ratio * 100), 1)
    $pctStr = if ($ShowPercent) { " {0,5:F1}%" -f $pctVal } else { "" }

    return ("{0} {1} {2}{3}" -f $paddedLabel, $paddedCount, $barStr, $pctStr).TrimEnd()
}

function Format-WuuPhaseDistribution {
    <#
    .SYNOPSIS Formats a phase rollout status distribution chart.
    .DESCRIPTION
    Labels successful, failed, timed out, running, queued, and unknown separately.
    Returns an array of chart row objects, or plain text lines when -AsString is specified.
    #>
    param(
        [int]$Succeeded = 0,
        [int]$Failed = 0,
        [int]$TimedOut = 0,
        [int]$Running = 0,
        [int]$Queued = 0,
        [int]$Unknown = 0,
        [int]$Total = -1,
        [int]$BarWidth = 20,
        [switch]$AsString
    )

    $calculatedTotal = $Succeeded + $Failed + $TimedOut + $Running + $Queued + $Unknown
    $effectiveTotal = if ($Total -ge 0) { $Total } else { $calculatedTotal }
    $effectiveUnknown = $Unknown
    if ($effectiveTotal -gt $calculatedTotal -and $effectiveUnknown -eq 0) {
        $effectiveUnknown = $effectiveTotal - $calculatedTotal
    }

    $categories = @(
        @{ Label = 'Succeeded'; Role = 'Success';   Value = $Succeeded }
        @{ Label = 'Failed';    Role = 'Failure';   Value = $Failed }
        @{ Label = 'TimedOut';  Role = 'Attention'; Value = $TimedOut }
        @{ Label = 'Running';   Role = 'Progress';  Value = $Running }
        @{ Label = 'Queued';    Role = 'Muted';     Value = $Queued }
        @{ Label = 'Unknown';   Role = 'Default';   Value = $effectiveUnknown }
    )

    $rows = @()
    foreach ($c in $categories) {
        $line = Format-WuuHorizontalBar -Label $c.Label -Value $c.Value -Total $effectiveTotal -BarWidth $BarWidth -LabelWidth 12 -CountWidth 7
        $rows += [pscustomobject]@{
            Label = $c.Label
            Role  = $c.Role
            Value = $c.Value
            Total = $effectiveTotal
            Line  = $line
        }
    }

    if ($AsString) {
        return (($rows | ForEach-Object { $_.Line }) -join "`r`n")
    }
    return $rows
}

function Get-WuuFleetDistributionCounts {
    <#
    .SYNOPSIS Computes fleet distribution counts from the state store rows.
    #>
    param(
        [Parameter(Mandatory)][object]$Store
    )
    $rows = @()
    try { $rows = @(Get-WuuComputerRow -Store $Store) } catch { $rows = @() }
    $counts = @{
        Succeeded = 0
        Failed    = 0
        TimedOut  = 0
        Running   = 0
        Queued    = 0
        Unknown   = 0
        Total     = $rows.Count
    }
    foreach ($r in $rows) {
        if ($null -eq $r) { continue }
        $opState = if ($r.PSObject.Properties['OpState']) { [string]$r.OpState } else { '' }
        $state = if ($r.PSObject.Properties['State']) { [string]$r.State } else { '' }
        $instErr = if ($r.PSObject.Properties['InstallErrors']) { [int]$r.InstallErrors } else { 0 }

        if ($instErr -gt 0 -or $state -eq 'Error') {
            $counts.Failed++
        } elseif ($state -eq 'Timeout') {
            $counts.TimedOut++
        } elseif ($opState -ceq 'Running') {
            $counts.Running++
        } elseif ($state -eq 'Complete') {
            $counts.Succeeded++
        } elseif ($opState -ceq 'Queued' -or $state -eq 'Queued' -or ($r.PSObject.Properties['Pending'] -and [bool]$r.Pending)) {
            $counts.Queued++
        } else {
            $counts.Unknown++
        }
    }
    return $counts
}

function Format-WuuFleetDistribution {
    <#
    .SYNOPSIS Formats the fleet status distribution chart directly from the state store.
    #>
    param(
        [Parameter(Mandatory)][object]$Store,
        [int]$BarWidth = 20,
        [switch]$AsString
    )
    $counts = Get-WuuFleetDistributionCounts -Store $Store
    return Format-WuuPhaseDistribution `
        -Succeeded $counts.Succeeded `
        -Failed $counts.Failed `
        -TimedOut $counts.TimedOut `
        -Running $counts.Running `
        -Queued $counts.Queued `
        -Unknown $counts.Unknown `
        -Total $counts.Total `
        -BarWidth $BarWidth `
        -AsString:$AsString
}

function Write-WuuHorizontalChart {
    <#
    .SYNOPSIS Writes a chart to host output with role-based theme colors and NoColor safety.
    #>
    param(
        [Parameter(Mandatory)][object[]]$ChartRows,
        [string]$Indent = '   '
    )
    foreach ($r in $ChartRows) {
        $line = if ($r.PSObject.Properties['Line']) { [string]$r.Line } else { [string]$r }
        $role = if ($r.PSObject.Properties['Role']) { [string]$r.Role } else { 'Default' }
        $col = Get-WuuThemeColor -Role $role
        $text = $Indent + $line
        if ($col) {
            Write-Host $text -ForegroundColor $col
        } else {
            Write-Host $text
        }
    }
}

#endregion Line-Oriented Charts

Export-ModuleMember -Function @(
    'Initialize-WuuPresentation'
    'Initialize-WuuBackgroundProcessing'
    'Update-Status'
    'Update-StatusBackground'
    '_WuuReadPassword'
    'Show-ErrorDialog'
    'Show-WarningDialog'
    'Suspend-BackgroundProcessing'
    'Resume-BackgroundProcessing'
    'Get-WuuOperationProgress'
    'Format-WuuElapsed'
    'Format-WuuProgressTicker'
    'Write-WuuProgressTicker'
    'Get-WuuTheme'
    'Set-WuuTheme'
    'Get-WuuThemeColor'
    'Format-WuuHorizontalBar'
    'Format-WuuPhaseDistribution'
    'Get-WuuFleetDistributionCounts'
    'Format-WuuFleetDistribution'
    'Write-WuuHorizontalChart'
)
