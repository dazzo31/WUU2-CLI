#Requires -Version 5.1
<#
.DESCRIPTION
Presentation-agnostic computer state store for WUU2-CLI (Phase 1 keystone).

WHY THIS EXISTS
---------------
In the GUI edition, worker-runspace payloads reported progress by reaching into
WPF: `$uiHash.Listview.Items.EditItem($Computer) ... Refresh()` plus
`$uiHash.ListView.Dispatcher.Invoke(...)` and
`ContainerFromItem(...).Background = [Brushes]::LightGray`. None of that exists
in a console host, and the Dispatcher pattern is also the source of the historical
deadlocks (see repo memory: dispatcher actions must use language constructs only).

This module replaces all of it with a plain synchronized store. The contract is
deliberately the SAME as the GUI code already used for the parts that worked:
payloads mutate the row PSObject's properties directly (`$Computer.Status = '...'`),
which is why that side of the code needed no change. What this module adds is:

  * a thread-safe collection of rows (was: ObservableCollection + ListView)
  * a monotonic revision counter used by renderers to know when to redraw
    (was: Items.CommitEdit()/Refresh())
  * a colour *name* on the row instead of a WPF Brush
    (was: listViewItem.Background = [Brushes]::LightGray)
  * Add/Remove/Find helpers that need no WPF

CRITICAL CONSTRAINTS (inherited from the GUI edition - do not "simplify" away)
-----------------------------------------------------------------------------
1. WORKER RUNSPACES MUST NOT CALL THESE FUNCTIONS.
   Isolated runspaces created by New-ComputerRunspace cannot see module functions
   (see repo memory: "modules imported without -Global ... are invisible"). They
   therefore talk to this store by MUTATING THE ROW OBJECT PROPERTIES directly
   (synchronized hashtable + plain property sets are safe), then calling
   `$stateStore.Touch($Computer)` - where $stateStore is the raw synchronized
   hashtable passed in via SessionStateProxy - to bump the revision so the
   renderer redraws. `Touch` is a METHOD on the store object, not a cmdlet, so it
   resolves fine from a worker runspace. This mirrors how injected scriptblocks
   are used elsewhere in the codebase.
2. NO PIPELINE CMDLETS IN ANY CODE THAT CAN RUN ON A CALLBACK PATH.
   Where a caller may be blocked waiting on the console renderer, use only
   language constructs (foreach/if) - never Where-Object/Select-Object. Same rule
   as SafeUpdateListViewItemScript.

ROW CONTRACT (the computer object all payloads already use)
-----------------------------------------------------------
  Computer          [string]  primary key (case-insensitive)
  Phase             [string]  'Phase 1'..'Phase 5'
  State             [string]  pipeline position (Queued/Connecting/.../Complete/Timeout/Error)
  Status            [string]  free-text detail shown to the operator
  UpdatesStatus     [string]  classification: 'Initializing' | 'Updates required' |
                              'Reboot required' | 'All updates installed' | 'Error' | 'Timeout'
  Available         [int]
  Downloaded        [int]
  InstallErrors     [int]
  RebootRequired    [bool]
  Pending           [bool]
  PendingOp         [string]  'Download' | 'AutoFlow' | 'InstallAndRecheck' | $null
  RetryCount        [int]
  RetryAt           [datetime] $null
  Runspace          [runspace] per-computer runspace (persistent by design)
  Color             [string]  NEW - colour NAME instead of a WPF Brush
                              'Default' | 'Error' (grey) | 'Timeout' (yellow) | 'Success'
  Revision          [int]     NEW - bumped by Touch(); renderers compare to redraw
#>

# Colour names the console renderer understands. Kept as names (not brushes) so the
# store has zero WPF dependency and stays testable headlessly.
$script:WuuColorNames = @{
    Default = 'Default'   # normal
    Error   = 'Error'     # was [Brushes]::LightGray  - terminal/grey
    Timeout = 'Timeout'   # was [Brushes]::LightYellow - recoverable, yellow
    Success = 'Success'   # completed
}

function New-WuuComputerRow {
    <#
    .SYNOPSIS
    Creates a computer row with the full property contract (matching the GUI's
    New-Object PSObject -Property @{...} creation sites, plus Color/Revision).
    Adding the properties up-front matters: row PSObjects throw on assigning an
    undefined property, so every site must create rows through here.
    #>
    param(
        [Parameter(Mandatory)][string]$Computer,
        [string]$Phase = 'Phase 1',
        [string]$StateSource = 'New-WuuComputerRow'
    )
    [pscustomobject]@{
        State           = 'Queued'
        StateTimestamp  = Get-Date
        StateSource     = $StateSource
        Computer        = $Computer
        Phase           = $Phase
        Available       = 0 -as [int]
        Downloaded      = 0 -as [int]
        InstallErrors   = 0 -as [int]
        Status          = 'Initializing...'
        RebootRequired  = $false -as [bool]
        UpdatesStatus   = 'Initializing'
        Runspace        = $null
        Pending         = $true
        PendingOp       = $null
        # Per-computer OPERATION state (SS3 of the hardening brief). 'Idle' | 'Queued' | 'Running'.
        # Distinct from State, which is the DISPLAY/workflow label ('Queued','Checking',...). This
        # one answers exactly one question - may another operation be submitted to this runspace? -
        # and is what Test-WuuComputerBusy answers.
        #
        # WHY IT IS NEEDED AT ALL: submitting [powershell]::BeginInvoke to a runspace that already
        # has a pipeline running is silently discarded. Measured:
        #     BeginInvoke   -> returns a handle
        #     handle        -> completes normally
        #     EndInvoke     -> throws "The pipeline was not run because a pipeline is already
        #                      running. Pipelines cannot be run concurrently."
        #     InvocationState -> 'Failed'
        #     output/errors -> NONE while running; the discard is invisible until EndInvoke
        # So a second operation on a busy computer does not merely queue - it VANISHES, and the
        # operator sees an operation that was accepted, reported as submitted, and never ran.
        OpState         = 'Idle'
        OpStartedAt     = $null
        TimeoutExpiresAt = $null
        TimeoutSource   = ''
        RetryCount      = 0
        RetryAt         = $null
        Color           = 'Default'
        Revision        = 0
    }
}

function New-WuuStateStore {
    <#
    .SYNOPSIS
    Creates the synchronized, presentation-agnostic state store.
    .DESCRIPTION
    Returns a synchronized hashtable. Keys:
      Rows     [arraylist] synchronized list of computer row objects (ordered)
      ByName   [hashtable] synchronized, case-insensitive Computer -> row
      Settings [hashtable] synchronized operator settings payloads read
      Status   [string]    status-bar text (replaces StatusTextBox)
      Revision [int]       global monotonic counter; renderers poll this

    The whole object is worker-safe: collection ops are synchronized, plain property
    reads/writes are safe, and Touch() is an object method (resolves from isolated
    runspaces where module functions are invisible).

    SETTINGS replaces the GUI checkbox reads in payloads:
      $uiHash.AutoDownloadCheckBox.IsChecked  ->  $stateStore.Settings.AutoDownload
      $uiHash.AutoInstallCheckBox.IsChecked   ->  $stateStore.Settings.AutoInstall
      $uiHash.AutoRebootCheckBox.IsChecked    ->  $stateStore.Settings.AutoReboot

    CORRECTION (2026-09-29). The three lines above were aspirational, not descriptive, and this
    note asserted a migration that had only been half done. The payloads went on READING the
    checkbox members - which are $null in this edition, because $uiHash is created empty
    ([hashtable]::Synchronized(@{})) and no console code ever populates those keys. The result was
    a silent, total failure of all three automatic behaviours:

        AutoDownload:  if ($null -and ...)          -> always $false  -> never downloaded
        AutoInstall:   if ($null -and ...)          -> always $false  -> never installed
        AutoReboot:    if (... -and -not $null)     -> always $true   -> always returned early

    Nothing failed loudly, because Wuu.Core.psm1 has no Set-StrictMode - a missing property on a
    hashtable is $null, not an error. Every other src/ module does set it, which is why the
    omission was easy to miss. All three gates now read $stateStore.Settings.* and there are no
    live reads of a GUI control anywhere in src/.

    Verified by grep: those three WERE the only $uiHash members payloads needed for behaviour -
    every other uiHash member is menu wiring or ListView/Window chrome.
    #>
    $rows = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $byName = [hashtable]::Synchronized(@{})
    $store = [hashtable]::Synchronized(@{
        Rows     = $rows
        ByName   = $byName
        Settings = [hashtable]::Synchronized(@{
            AutoDownload = $false
            AutoInstall  = $false
            AutoReboot   = $false
        })
        Status   = ''
        Revision = 0
    })
    # Worker-safe redraw signal. `Touch` is a SCRIPT METHOD on the store object, so it
    # resolves from an isolated worker runspace (which cannot see module functions).
    # Do not replace with a module-level function - workers would fail to find it.
    $store | Add-Member -MemberType ScriptMethod -Name Touch -Force -Value {
        $this.Revision = [int]$this.Revision + 1
    }
    # Worker-safe status-bar setter (replaces $uiHash.StatusTextBox.Text = $x).
    $store | Add-Member -MemberType ScriptMethod -Name SetStatus -Force -Value {
        param([string]$Message)
        $this.Status = $Message
        $this.Revision = [int]$this.Revision + 1
    }
    return $store
}

function Add-WuuComputerRow {
    <#
    .SYNOPSIS
    Adds a row to the store (replacing any existing row with the same Computer).
    Returns the row that is now in the store.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Store,
        [Parameter(Mandatory)]$Row
    )
    $key = $Row.Computer.ToLowerInvariant()
    $existing = $Store.ByName[$key]
    if ($existing) {
        Remove-WuuComputerRow -Store $Store -Computer $Row.Computer | Out-Null
    }
    $Store.Rows.Add($Row) | Out-Null
    $Store.ByName[$key] = $Row
    $Store.Revision = [int]$Store.Revision + 1
    return $Row
}

function Remove-WuuComputerRow {
    <#
    .SYNOPSIS
    Removes a row by computer name. Returns $true if a row was removed.
    .DESCRIPTION
    Uses only language constructs inside the enumeration - this can be called from
    a path where another thread is blocked waiting on us.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Store,
        [Parameter(Mandatory)][string]$Computer
    )
    $key = $Computer.ToLowerInvariant()
    $row = $Store.ByName[$key]
    if (-not $row) { return $false }
    $Store.ByName.Remove($key)
    # Snapshot-free removal: iterate the synchronized list directly by index backwards.
    $i = $Store.Rows.Count - 1
    while ($i -ge 0) {
        if ([object]::ReferenceEquals($Store.Rows[$i], $row)) {
            $Store.Rows.RemoveAt($i)
            break
        }
        $i--
    }
    $Store.Revision = [int]$Store.Revision + 1
    return $true
}

function Get-WuuComputerRow {
    <#
    .SYNOPSIS
    Returns all rows (snapshot copy) or one row by name. No pipeline cmdlets.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Store,
        [string]$Computer
    )
    if ($Computer) { return $Store.ByName[$Computer.ToLowerInvariant()] }
    $snapshot = New-Object System.Collections.ArrayList
    foreach ($r in $Store.Rows) { $snapshot.Add($r) | Out-Null }
    return $snapshot
}

function Set-WuuComputerRowColor {
    <#
    .SYNOPSIS
    Sets the presentation colour by NAME (no WPF Brush). Safe from a worker runspace
    because it only sets a property on the row object.
    .DESCRIPTION
    Replaces:
      $listViewItem.Background = [System.Windows.Media.Brushes]::LightGray
    with:
      Set-WuuComputerRowColor -Row $Computer -Color 'Error'
    The GUI mapping preserved: Error -> LightGray (grey row), Timeout -> LightYellow
    (yellow row). 'Default' clears it.
    #>
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)]
        [ValidateSet('Default', 'Error', 'Timeout', 'Success')]
        [string]$Color
    )
    $Row.Color = $Color
}

function Set-WuuSetting {
    <#
    .SYNOPSIS
    Sets an operator setting payloads read (replaces checkbox .IsChecked assignments).
    .DESCRIPTION
    Console-shell only - workers just READ $stateStore.Settings.<Name>. Kept as a
    function so the setting names/validation live in one place.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Store,
        [Parameter(Mandatory)]
        [ValidateSet('AutoDownload', 'AutoInstall', 'AutoReboot')]
        [string]$Name,
        [Parameter(Mandatory)][bool]$Value
    )
    $Store.Settings[$Name] = $Value
    return $Value
}

function Test-WuuComputerBusy {
    <#
    .SYNOPSIS Whether an operation may be submitted for this computer right now (SS3).
    .DESCRIPTION
    The single authority on "is this computer already running an operation?". Every submission path
    consults it, so the answer cannot differ between the console, the guided workflow and the
    command surface.

    WHY A GATE RATHER THAN TRUSTING THE RUNSPACE: the runspace does NOT protect itself. Submitting
    BeginInvoke while a pipeline is active is ACCEPTED, the handle completes normally, and the work is
    DISCARDED - EndInvoke then throws "The pipeline was not run because a pipeline is already
    running. Pipelines cannot be run concurrently." (measured; see the OpState field note). Nothing
    about that failure is visible at submission time, so the check has to happen beforehand.

    Deliberately consults BOTH signals:
      * OpState - set by Start-UpdateCheckJob for every real submission;
      * Pending - set by the auto-download / auto-install tails, which queue a FOLLOW-UP operation
                  rather than submitting one immediately. A queued follow-up must block a direct
                  submission too, or the direct one wins the runspace and the queued one is then
                  discarded.

    -IgnorePending exists for the SCHEDULER, and without it the scheduler deadlocks. Its input queue
    IS "the rows with Pending set", so treating Pending as busy would make it skip every row it was
    given, for ever, and nothing would ever run. The scheduler is the consumer of Pending - it
    clears the flag and submits - so for it the only question is whether an OpState is already in
    flight. Direct submissions (console handlers) keep the default behaviour and defer to the
    queued follow-up.

    Read-only and side-effect free on purpose: it is called from the scheduler, from console
    handlers, and from tests, so it must never mutate. The CALLER decides what to do about a busy
    computer (queue it, skip it, or tell the operator) because those differ per caller.

    NOT [Parameter(Mandatory)]: a $null row is the ordinary result of a lookup miss in a loop, and
    Mandatory rejects it at BINDING time - before the null guard below can run - with "Cannot bind
    argument to parameter 'Row' because it is null". The guard is what makes a miss a clean $false
    instead of an exception in the middle of a dispatch loop.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()]$Row,
        [switch]$IgnorePending
    )

    if ($null -eq $Row) { return $false }
    if ($null -eq $Row.PSObject.Properties['OpState']) { return $false }

    $state = [string]$Row.OpState
    if ($state -eq 'Running' -or $state -eq 'Queued') { return $true }

    # A queued follow-up (the auto chain) also means the runspace is spoken for - unless the caller
    # IS the scheduler that is about to consume that flag.
    if (-not $IgnorePending) {
        if ($Row.PSObject.Properties['Pending'] -and $Row.Pending) { return $true }
    }

    return $false
}

function New-WuuOperatorContext {
    <#
    .SYNOPSIS
    Captures operator identity once per run for the audit trail (Phase 4 use).
    Stamped onto every audit record: user, machine, elevated flag, run id.
    #>
    param([string]$RunId)
    $identity = $null
    try { $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { $identity = "$env:USERDOMAIN\$env:USERNAME" }
    $elevated = $false
    try {
        $elevated = ([System.Security.Principal.WindowsPrincipal]::new(
            [System.Security.Principal.WindowsIdentity]::GetCurrent()
        )).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $elevated = $false }
    [pscustomobject]@{
        User     = $identity
        Machine  = $env:COMPUTERNAME
        Elevated = $elevated
        RunId    = if ($RunId) { $RunId } else { [guid]::NewGuid().ToString('N') }
        StartedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

Export-ModuleMember -Function @(
    'New-WuuComputerRow'
    'New-WuuStateStore'
    'Add-WuuComputerRow'
    'Remove-WuuComputerRow'
    'Get-WuuComputerRow'
    'Set-WuuComputerRowColor'
    'Set-WuuSetting'
    'Test-WuuComputerBusy'
    'New-WuuOperatorContext'
)
