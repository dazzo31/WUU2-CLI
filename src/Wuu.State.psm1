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
  OpState           [string]  'Idle' | 'Queued' | 'Running'  - may another operation be submitted?
  OperationId       [string]  identity of the operation that CURRENTLY owns this row (SS2/SS3)
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
        # SS2/SS3: OPERATION IDENTITY. A unique token for the operation that currently owns this
        # row, stamped at submission and compared by every writer that acts on behalf of a job.
        #
        # WHY A GENERATED TOKEN AND NOT THE COMPUTER NAME OR OpStartedAt: the row is keyed by
        # computer NAME, and every injected row-writer resolves its target by name from the store.
        # So a writer belonging to a FINISHED operation still finds a valid row - possibly the one
        # a NEWER operation now owns - and writes into it. The computer name cannot distinguish
        # those two operations, and a timestamp is not an identity (two submissions can share one).
        #
        # WHY IT IS NEEDED EVEN THOUGH OpState SERIALIZES OPERATIONS: OpState (8.1) prevents an
        # operation from STARTING while another runs. It does nothing about a writer that has
        # already LEFT - the cleanup loop settling a job out of order, a pipeline force-stopped and
        # still draining, or a job removed out-of-band and re-submitted. Each of those writes on
        # behalf of an operation the row no longer belongs to.
        #
        # See Test-WuuOperationCurrent - the single predicate those writers all consult.
        OperationId     = ''
        # SS12: consecutive connectivity failures. Inventory membership is NOT a connectivity status -
        # a single lost ICMP packet (or a host that simply blocks echo, the Windows Firewall default)
        # used to delete the row, after which the computer silently stopped being patched.
        ConnectivityFailures    = 0
        LastConnectivityError   = ''
        # SS5: per-operation deadline. TimeoutExpiresAt/TimeoutSource were written in TWO places and
        # READ NOWHERE - dead fields, verified by counting uses against assignments. They are now the
        # read side of the cleanup loop's decision (see Test-WuuOperationExpired and
        # Update-WuuOperationHeartbeat below): recorded at submission, consulted by the loop, and
        # reported by the status line. A flat 10-minute stop ignored them entirely.
        TimeoutExpiresAt = $null
        TimeoutSource   = ''
        # What the row was actually asked to do ('Check','InstallAndRecheck',...). Without this the
        # cleanup loop has only Computer + Runspace and cannot know which deadline applies - the
        # flat 10 minutes was the symptom of exactly that missing piece.
        OpName          = ''
        # Heartbeat: refreshed by the job-cleanup loop while the PowerShell instance is still
        # running. The DEADLINE catches a stuck job; the heartbeat is what lets a human (or the
        # status line) tell "slow" from "hung" before the deadline fires, and it is the evidence
        # that the operation is still making progress.
        LastHeartbeatAt = $null
        Heartbeats      = 0
        RetryCount      = 0
        RetryAt         = $null
        # Presentation colour name. This is what Format-WuuTable maps to a console colour, and what
        # makes timeout distinguishable from a terminal error.
        Color           = 'Default'
        # PHASE 1: the credential configuration epoch this row's runspace was built under, and the
        # identity that runspace is actually using. A runspace captures the credential configuration
        # at creation, so without the epoch a credential change would leave the next operation on
        # this computer running under the PREVIOUS identity - silently. Start-UpdateCheckJob compares
        # these against the global epoch and rebuilds the runspace when they differ.
        CredentialEpoch    = -1
        CredentialIdentity = ''
        # SS8: whether the last CHECK reached a conclusion, as a BOOLEAN rather than a display string.
        #
        # WHY THIS EXISTS. Test-PhaseCompletion decided "has this row settled?" from
        # `UpdatesStatus -ne 'All updates installed'`. UpdatesStatus is a DISPLAY string, written from
        # at least eight sites with five different values, and one of them ('Unknown') is set in a
        # path where a check has NOTHING TO REPORT - so an uncheckable row looked like outstanding
        # work forever and blocked its phase indefinitely. Every future wording change to a status
        # message was also a silent change to phase gating.
        #
        # Three states, deliberately: $null = not established (a row loaded from config, or one that
        # has never been checked); $false = a check ran and found no updates (but see RebootRequired);
        # $true = a check ran and there IS work outstanding. Using $false for "not established" would
        # erase the difference between "checked and clean" and "never checked", which is the same
        # class of ambiguity this whole pass exists to remove.
        CheckConcluded  = $null
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
            # SS9 of the hardening brief. What a FAILED or TIMED-OUT computer does to phase
            # progression. Previously there was no policy at all: Test-PhaseCompletion simply
            # SKIPPED errored/timed-out rows, i.e. it always behaved as ContinueOnFailure - the
            # unsafe option. A failed canary therefore silently permitted the next phase.
            #   BlockOnFailure    (DEFAULT) failures and timeouts block the next phase
            #   ContinueOnTimeout           timeouts are tolerated, failures block
            #   ContinueOnFailure           any settled failure permits the next phase
            # Default is the safe one deliberately: for patch deployment, stopping is recoverable
            # and continuing past a failed canary is not.
            PhaseFailurePolicy = 'BlockOnFailure'
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

function Get-WuuOperationTimeoutSeconds {
    <#
    .SYNOPSIS
    How long an operation of this kind may run before it is treated as stuck (SS5).
    .DESCRIPTION
    Falls back to the 'default' entry rather than to a literal, so an op added to Start-UpdateCheckJob
    without a deadline gets a bounded-but-not-punishing number instead of either infinity or a
    number copy-pasted somewhere else. Returns 1800 if the table itself is missing (a partially
    loaded context), because returning 0 would make every job expire the instant it started.
    #>
    [CmdletBinding()]
    param([string]$Op)
    $table = $global:OperationTimeoutSeconds
    if (-not $table) { return 1800 }
    if ($Op -and $table.ContainsKey($Op)) { return [int]$table[$Op] }
    if ($table.ContainsKey('default')) { return [int]$table['default'] }
    return 1800
}

function Format-WuuDuration {
    <#
    .SYNOPSIS
    '45s' / '12m' / '2h05m' - a deadline expressed so a human can compare it with a clock.
    #>
    [CmdletBinding()]
    param([int]$Seconds)
    if ($Seconds -lt 60) { return "${Seconds}s" }
    $m = [math]::Floor($Seconds / 60)
    if ($m -lt 60) { return "${m}m" }
    $h = [math]::Floor($m / 60)
    $rem = $m - ($h * 60)
    return ('{0}h{1:d2}m' -f $h, $rem)
}

function Test-WuuOperationExpired {
    <#
    .SYNOPSIS
    Decides whether a running operation has passed its deadline (SS5).
    .DESCRIPTION
    Two bases, in priority order:

      1. 'row-deadline' - TimeoutExpiresAt recorded on the row at SUBMISSION. Preferred, because it is
         the value the operator was shown: one source of truth for "what was promised" and "what is
         enforced".
      2. 'start-time-fallback' - no deadline on the row (a legacy row, or work not submitted through
         Start-UpdateCheckJob), so the job's own start time plus the default budget is used. This is
         still BETTER than the flat 10 minutes it replaces: it is a named budget, and it is reported
         as a fallback so an operator can tell the operation was not submitted through the normal path.

    Returns a verdict object rather than a boolean so the caller can log the op, the budget, the basis
    and the overshoot - "timed out" without "after how long, doing what, on what basis" is not
    actionable.

    THIS LOGIC IS DUPLICATED IN A RUNSPACE BLOCK in Wuu.Core (the job-cleanup runspace cannot see
    module functions). tests\Test-OperationTimeouts.ps1 runs BOTH on identical inputs and compares the
    verdicts, so the two cannot drift apart unnoticed - the duplication is deliberate and guarded.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$Row,
        [datetime]$Now = (Get-Date),
        # From the job entry. Used only when the row carries no deadline.
        [AllowNull()][Nullable[datetime]]$StartedAt = $null,
        # Budget for the fallback basis. Defaults to the table's 'default' entry.
        [AllowNull()][Nullable[int]]$DefaultBudgetSeconds = $null
    )
    $result = [pscustomobject]@{
        Expired = $false; Basis = 'none'; Source = ''; Op = ''
        BudgetSeconds = 0; ExpiresAt = $null; OvershootSeconds = 0
    }
    if (-not $Row) { return $result }

    $hasDeadline = $false
    $expires = $null
    if ($Row.PSObject.Properties['TimeoutExpiresAt'] -and $Row.TimeoutExpiresAt) {
        $expires = $Row.TimeoutExpiresAt
        $hasDeadline = $true
    }
    if ($Row.PSObject.Properties['TimeoutSource']) { $result.Source = [string]$Row.TimeoutSource }
    if ($Row.PSObject.Properties['OpName']) { $result.Op = [string]$Row.OpName }

    if ($hasDeadline) {
        $result.Basis = 'row-deadline'
        $result.BudgetSeconds = Get-WuuOperationTimeoutSeconds -Op $result.Op
    } elseif ($StartedAt) {
        $budget = if ($DefaultBudgetSeconds) { [int]$DefaultBudgetSeconds } else { Get-WuuOperationTimeoutSeconds -Op 'default' }
        $result.Basis = 'start-time-fallback'
        $result.BudgetSeconds = $budget
        $expires = ([datetime]$StartedAt).AddSeconds($budget)
    } else {
        return $result
    }

    $result.ExpiresAt = $expires
    if ($Now -gt $expires) {
        $result.Expired = $true
        $result.OvershootSeconds = [int]($Now - $expires).TotalSeconds
    }
    return $result
}

function Update-WuuOperationHeartbeat {
    <#
    .SYNOPSIS
    Records that a running operation is still alive (SS5).
    .DESCRIPTION
    Called on each cleanup-loop pass for a job that has not completed. Refreshes LastHeartbeatAt and
    counts beats. Deliberately does NOT extend the deadline: a heartbeat proves liveness, not progress,
    and letting it extend the deadline would mean a genuinely hung operation could never be stopped -
    the failure mode the deadline exists to prevent.

    This is what separates "slow" from "stuck" for a human: a deadline alone only says "not finished",
    while a heartbeat that has not moved says the job has stopped making progress.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$Row,
        [datetime]$Now = (Get-Date)
    )
    if (-not $Row) { return $false }
    if (-not $Row.PSObject.Properties['LastHeartbeatAt']) { return $false }
    $Row.LastHeartbeatAt = $Now
    if ($Row.PSObject.Properties['Heartbeats']) { $Row.Heartbeats = [int]$Row.Heartbeats + 1 }
    return $true
}

function Set-WuuOperationDeadline {
    <#
    .SYNOPSIS
    Records the deadline for an operation on a row, at submission time (SS5).
    .DESCRIPTION
    The single place the deadline is computed, so the value the operator sees is the value the
    cleanup loop enforces. Returns the deadline so the caller can log it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$Op,
        [datetime]$Now = (Get-Date)
    )
    $budget = Get-WuuOperationTimeoutSeconds -Op $Op
    $expires = $Now.AddSeconds($budget)
    if ($Row.PSObject.Properties['TimeoutExpiresAt']) { $Row.TimeoutExpiresAt = $expires }
    if ($Row.PSObject.Properties['TimeoutSource']) { $Row.TimeoutSource = $Op }
    if ($Row.PSObject.Properties['OpName']) { $Row.OpName = $Op }
    # A new operation starts a new liveness window: stale beats from a previous op would make an
    # instantly-hung job look healthy.
    if ($Row.PSObject.Properties['LastHeartbeatAt']) { $Row.LastHeartbeatAt = $Now }
    if ($Row.PSObject.Properties['Heartbeats']) { $Row.Heartbeats = 0 }
    return $expires
}

function Clear-WuuOperationDeadline {
    <#
    .SYNOPSIS
    Clears the deadline/heartbeat state when an operation ends (SS5).
    .DESCRIPTION
    Called wherever OpState returns to 'Idle'. Without it a finished row keeps a deadline in the past,
    so the NEXT operation would be treated as expired on its first loop pass (the deadline is read,
    not recomputed) - i.e. every operation after the first would be killed immediately.
    #>
    [CmdletBinding()]
    param([AllowNull()]$Row)
    if (-not $Row) { return }
    if ($Row.PSObject.Properties['TimeoutExpiresAt']) { $Row.TimeoutExpiresAt = $null }
    if ($Row.PSObject.Properties['TimeoutSource']) { $Row.TimeoutSource = '' }
    if ($Row.PSObject.Properties['OpName']) { $Row.OpName = '' }
    if ($Row.PSObject.Properties['LastHeartbeatAt']) { $Row.LastHeartbeatAt = $null }
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

function New-WuuOperationId {
    <#
    .SYNOPSIS
    Creates a unique operation identity (SS2).
    .DESCRIPTION
    Every submitted operation gets one of these, stamped on the row AND on the job entry, so a
    writer can prove which operation it is acting for.

    Deliberately NOT the computer name (a computer runs many operations over its life) and not a
    timestamp (two submissions can share one, and clock resolution is not an identity). The counter
    exists so two ids created inside the same clock tick are still distinct; the GUID is what makes
    collision across processes and restarts impossible.

    Language constructs only: this may be called from the submission point, which can be reached
    from a console handler.
    #>
    param([string]$Computer = '')

    $n = 1
    if ($script:WuuOperationSequence) { $n = [int]$script:WuuOperationSequence + 1 }
    $script:WuuOperationSequence = $n


    $prefix = if ($Computer) { $Computer.ToLowerInvariant() } else { 'op' }
    return ('{0}:{1}:{2}:{3}' -f $prefix, $PID, $n, ([guid]::NewGuid().ToString('N').Substring(0, 12)))
}

function Test-WuuOperationCurrent {
    <#
    .SYNOPSIS
    Whether the operation identified by $OperationId still owns this row (SS3).
    .DESCRIPTION
    The single staleness predicate. Every writer that acts on behalf of a JOB - the cleanup loop's
    three exit paths, and the row-writers injected into worker runspaces - asks this before
    mutating, so a writer belonging to a superseded operation cannot overwrite the state of the
    operation that replaced it.

    THE DEFECT THIS CLOSES: the cleanup loop settles jobs in the order it notices them, and holds
    no identity - only (Computer, Runspace, StartTime). If operation A is force-stopped on timeout
    and the computer is resubmitted as B before the loop next visits A's entry, A's pass releases
    the row's OpState ('Idle'), clears B's deadline and writes A's terminal status - onto B. B is
    then unguarded: a third submission is admitted while B still runs, and the runspace discards it
    silently. Nothing in that sequence inspects an identity, so nothing detects it.

    FALSE MEANS 'DO NOT WRITE'. Callers must treat $false as a refusal, not as an error: a stale
    writer is an expected outcome of a stopped or superseded operation, not a fault to report.

    Returns $false when either side is empty. Two unknowns are not evidence of a match - the whole
    point of this predicate is to refuse a write that cannot be PROVEN current.

    Read-only, side-effect free and $null-tolerant: it is called from the cleanup thread and from
    tests, and a lookup miss must be a clean $false rather than an exception.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()]$Row,
        [Parameter(Mandatory = $false)][AllowNull()][string]$OperationId
    )

    if ($null -eq $Row) { return $false }
    if ($null -eq $Row.PSObject.Properties['OperationId']) { return $false }
    if ([string]::IsNullOrEmpty($OperationId)) { return $false }

    $rowId = [string]$Row.OperationId
    if ([string]::IsNullOrEmpty($rowId)) { return $false }

    return ($rowId -ceq $OperationId)
}

function Test-WuuStaleWrite {
    <#
    .SYNOPSIS
    Whether a row write must be REFUSED because the writer belongs to a superseded operation (SS3).
    .DESCRIPTION
    The second of the two identity rules, and deliberately NOT the same as Test-WuuOperationCurrent.
    Conflating them is a real hazard, so the difference is stated explicitly:

      Test-WuuOperationCurrent  - "is this writer still the owner?"  ($true only when the ids MATCH)
      Test-WuuStaleWrite        - "is this write PROVEN stale?"      ($true only when both ids exist
                                    and DIFFER)

    They disagree in exactly one direction, on purpose. When the row carries no operation (a row
    loaded from configuration, or a startup path) Test-WuuOperationCurrent says 'not current' - which
    is correct for a RELEASE decision, because an unattributed job must not unlock a row whose owner
    it cannot name. But a WRITE must still be permitted in that case, or list loading and initial
    population would be silently discarded.

    So: releases use "proven current"; writes use "not proven stale". A write is refused only when
    the row names an operation AND the writer names a different one - the case that is provably a
    superseded operation overwriting its replacement.

    Returns $false (permit) whenever either side is unknown. That asymmetry is the whole point; do
    not 'simplify' this into a negation of Test-WuuOperationCurrent.

    Read-only, side-effect free, $null-tolerant: called from the injected worker writer, whose own
    inlined copy is asserted against this function by tests\Test-OperationIdentity.ps1.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()]$Row,
        [Parameter(Mandatory = $false)][AllowNull()][string]$OperationId
    )

    if ($null -eq $Row) { return $false }
    if ($null -eq $Row.PSObject.Properties['OperationId']) { return $false }
    if ([string]::IsNullOrEmpty($OperationId)) { return $false }

    $rowId = [string]$Row.OperationId
    if ([string]::IsNullOrEmpty($rowId)) { return $false }

    return ($rowId -cne $OperationId)
}

function Test-WuuPhaseFailureBlocks {
    <#
    .SYNOPSIS Whether a settled failure on this row should BLOCK the next phase (SS9).
    .DESCRIPTION
    Pure and side-effect free, so the policy can be tested without a store, a scheduler or a network.

    A row "blocks" when it has settled in a failed state and the active policy says that must stop
    progression. An unrecognised policy returns $true (block) on purpose: an unknown policy is a
    configuration error, and the safe response to a configuration error in a patching tool is to stop
    rather than to proceed past a canary that failed.

    Deliberately checks BOTH signals. UpdatesStatus is what the update payloads set; State is what the
    timeout/error paths set. Relying on one alone missed failures written the other way, which is how
    a failed computer could look "settled but fine".
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()]$Row,
        [string]$Policy = 'BlockOnFailure'
    )

    if ($null -eq $Row) { return $false }

    $status = [string]$Row.UpdatesStatus
    $state = if ($Row.PSObject.Properties['State']) { [string]$Row.State } else { '' }

    $failed = ($status -eq 'Error') -or ($state -eq 'Error')
    $timedOut = ($status -eq 'Timeout') -or ($state -eq 'Timeout')
    if (-not ($failed -or $timedOut)) { return $false }

    switch -CaseSensitive ($Policy) {
        'ContinueOnFailure' { return $false }
        'ContinueOnTimeout' { return $failed }   # timeouts tolerated, failures block
        'BlockOnFailure' { return $true }
        default { return $true }                  # unknown policy -> stop (safe)
    }
}

function Set-WuuPhaseFailurePolicy {
    <#
    .SYNOPSIS Sets the phase failure policy with validation (SS9).
    .DESCRIPTION
    Separate from Set-WuuSetting because that function's ValidateSet is boolean settings; keeping the
    policy here means the three valid values live next to the decision function that consumes them.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Store,
        [Parameter(Mandatory)]
        [ValidateSet('BlockOnFailure', 'ContinueOnTimeout', 'ContinueOnFailure')]
        [string]$Policy
    )
    $Store.Settings['PhaseFailurePolicy'] = $Policy
    return $Policy
}

function Update-WuuConnectivityState {
    <#
    .SYNOPSIS Applies a connectivity probe result to a row (hardening brief SS12).
    .DESCRIPTION
    Inventory membership is NOT a connectivity status. This function is the single place that decides
    what a probe result means for a row, so the policy cannot differ between callers.

    BEFORE: one `Test-Connection -Count 1` whose failure DELETED the row. A single lost ICMP packet -
    or a host that simply blocks echo, which is the Windows Firewall default - evicted a healthy
    server from the managed set, after which it silently stopped being patched.

    AFTER, three outcomes:
      reachable                     -> Status online, failure counter RESET
      unreachable, below threshold  -> Status unreachable, ROW KEPT (pending work cancelled)
      unreachable, at threshold     -> removed from the set, with the reason recorded

    Extracted from the worker payload deliberately. As inline payload code it was only reachable from
    inside Wuu.Core's module scope, so it could not be tested at all - which is how a one-packet
    delete survived. As a pure function it takes a probe RESULT, so the whole decision table is
    testable without a network, a runspace or a scheduler.

    Returns a verdict object rather than only mutating, so a caller (and a test) can assert what was
    decided without inferring it from side effects.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()]$Row,
        [Parameter(Mandatory = $false)][AllowNull()]$ProbeResult,
        [Parameter(Mandatory)][hashtable]$Store,
        [Parameter(Mandatory = $false)]$UpdatesHash = $null,
        [int]$FailuresBeforeRemoval = 2
    )

    if ($null -eq $Row) { return [pscustomobject]@{ Action = 'skip'; Reason = 'no row' } }

    # A probe that could not run at all is NOT evidence the computer is down. Treating "I could not
    # tell" as "offline" is the mistake that made an unprobed fleet look dead.
    $reachable = $false
    $reason = 'management endpoint unreachable'
    if ($ProbeResult) {
        # NOTE: there used to be a bare `$ProbeResult.Contains('Resolves')` here, and it made the
        # PSCustomObject branch below UNREACHABLE: .Contains is a STRING/collection method that a
        # PSCustomObject does not have, so it threw
        #   "Method invocation failed because [PSCustomObject] does not contain a method named 'Contains'"
        # before the shape test ever ran (verified). The function therefore claimed to accept two
        # shapes and only worked with one. Test-WuuManagementEndpoint happens to return an ordered
        # hashtable today, so production never hit it - but the dead branch was a trap for any caller
        # that round-trips a probe result through JSON (which converts it to a PSCustomObject).
        $resolves = $false; $endpoint = $false
        if ($ProbeResult -is [hashtable] -or $ProbeResult -is [System.Collections.Specialized.OrderedDictionary]) {
            if ($ProbeResult.Contains('Resolves')) { $resolves = [bool]$ProbeResult['Resolves'] }
            if ($ProbeResult.Contains('Endpoint')) { $endpoint = [bool]$ProbeResult['Endpoint'] }
            if ($ProbeResult.Contains('Reason') -and $ProbeResult['Reason']) { $reason = [string]$ProbeResult['Reason'] }
        } else {
            if ($ProbeResult.PSObject.Properties['Resolves']) { $resolves = [bool]$ProbeResult.Resolves }
            if ($ProbeResult.PSObject.Properties['Endpoint']) { $endpoint = [bool]$ProbeResult.Endpoint }
            if ($ProbeResult.PSObject.Properties['Reason'] -and $ProbeResult.Reason) { $reason = [string]$ProbeResult.Reason }
        }
        $reachable = ($resolves -and $endpoint)
    }

    if ($reachable) {
        if ($Row.PSObject.Properties['ConnectivityFailures']) { $Row.ConnectivityFailures = 0 }
        if ($Row.PSObject.Properties['LastConnectivityError']) { $Row.LastConnectivityError = '' }
        $Row.Status = 'Online.'
        $Row.State = 'Connected'
        $Store.Revision = [int]$Store.Revision + 1
        return [pscustomobject]@{ Action = 'online'; Failures = 0; Reason = '' }
    }

    $prior = 0
    if ($Row.PSObject.Properties['ConnectivityFailures']) { $prior = [int]$Row.ConnectivityFailures }
    $count = $prior + 1
    if ($Row.PSObject.Properties['ConnectivityFailures']) { $Row.ConnectivityFailures = $count }
    if ($Row.PSObject.Properties['LastConnectivityError']) { $Row.LastConnectivityError = $reason }
    $Row.State = 'Offline'
    $Row.Color = 'Error'
    # A row that is unreachable is not a candidate for scheduled work - clear the request so the
    # scheduler does not spin against a host that is not there.
    if ($Row.PSObject.Properties['Pending']) { $Row.Pending = $false }

    if ($count -ge $FailuresBeforeRemoval) {
        if ($UpdatesHash) { try { $UpdatesHash.Remove($Row.Computer) } catch { } }
        $Row.Status = "Unreachable $count time(s) ($reason) - removed from the set. Re-add it when the host is back."
        Remove-WuuComputerRow -Store $Store -Computer $Row.Computer | Out-Null
        return [pscustomobject]@{ Action = 'removed'; Failures = $count; Reason = $reason }
    }

    $Row.Status = "Unreachable ($reason) - kept in the set; removal needs $FailuresBeforeRemoval consecutive failures."
    $Store.Revision = [int]$Store.Revision + 1
    return [pscustomobject]@{ Action = 'kept'; Failures = $count; Reason = $reason }
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
    # SS2/SS3: operation identity. Exported because the id is CREATED at the submission point
    # (Wuu.WindowsUpdate), ENFORCED in the cleanup loop (Wuu.Core) and in the row-writers injected
    # into worker runspaces, and asserted by tests - four places that must agree on the same rule.
    'New-WuuOperationId'
    'Test-WuuOperationCurrent'
    'Test-WuuStaleWrite'
    'Test-WuuPhaseFailureBlocks'
    'Set-WuuPhaseFailurePolicy'
    'Update-WuuConnectivityState'
    # SS5: operation-specific deadlines. Exported because the deadline is recorded at the SUBMISSION
    # POINT (Wuu.WindowsUpdate) and enforced in the cleanup loop (Wuu.Core), and both need to agree.
    'Get-WuuOperationTimeoutSeconds'
    'Format-WuuDuration'
    'Test-WuuOperationExpired'
    'Set-WuuOperationDeadline'
    'Clear-WuuOperationDeadline'
    'Update-WuuOperationHeartbeat'
    'New-WuuOperatorContext'
)
