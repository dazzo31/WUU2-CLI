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
   as UpdateWuuComputerRowScript.

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
        # SS16/PHASE 5: REFUSAL RECORDING. A submission can be refused (busy computer, global cap
        # reached, lock not acquirable) and a refusal is currently INVISIBLE to the phase gate: it is
        # not an Error and not a Timeout, so Test-WuuPhaseFailureBlocks does not see it, and the row
        # keeps Pending=$true for ever. The phase then never advances and nothing anywhere says why -
        # a permanent silent stall in a multi-phase rollout.
        #
        # RefusedCount counts consecutive refusals for the CURRENT queued operation (reset when the
        # operation is admitted), RefusedReason says what the last refusal was, and RefusedAt is when
        # it happened. Together they let the phase gate distinguish "still working through the queue"
        # from "this computer has been refused N times and is not making progress".
        RefusedCount    = 0
        RefusedReason   = ''
        RefusedAt       = $null
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
        LastResetOperationId = ''
        LastResetReason      = ''
        LastResetSource      = ''
        LastResetAt          = $null
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
        ViewFilter = 'All'
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

function Get-WuuOperationRemainingSeconds {
    <#
    .SYNOPSIS
    Seconds left before a running operation's deadline, so inner calls can respect the outer budget.
    .DESCRIPTION
    Returns @{ Known; Remaining; Op; ExpiresAt }. Known=$false means no deadline is recorded: the caller
    must keep its own timeout (never treat unknown as 0). Remaining is not clamped; negative = overdue.
    Called from payload scriptblocks, so it must never throw.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()]$Row,
        [datetime]$Now = (Get-Date)
    )

    $result = @{ Known = $false; Remaining = $null; Op = ''; ExpiresAt = $null }

    if ($null -eq $Row) { return $result }
    if (-not $Row.PSObject.Properties['TimeoutExpiresAt']) { return $result }

    $expires = $Row.TimeoutExpiresAt
    if ($null -eq $expires) { return $result }
    # A string that cannot be parsed as a date is treated as "no deadline" rather than as epoch, which
    # would report an enormous remaining budget and silently remove the ceiling.
    try { $expires = [datetime]$expires } catch { return $result }

    if ($Row.PSObject.Properties['OpName']) { $result.Op = [string]$Row.OpName }
    $result.Known = $true
    $result.ExpiresAt = $expires
    # NOT clamped: a negative result is the overshoot, which the caller reports.
    $result.Remaining = [int][math]::Floor(($expires - $Now).TotalSeconds)
    return $result
}

function Get-WuuEffectiveInnerTimeout {
    <#
    .SYNOPSIS
    An inner call's timeout: min(own timeout, remaining budget), floored at FloorSeconds.
    .DESCRIPTION
    Returns @{ Seconds; Capped; Reason }. No recorded deadline leaves the inner timeout unchanged. The
    floor stops an expiring probe getting a timeout too short to answer. Inlined copies exist in the
    payload helpers (no module function is callable there); Test-RemainingBudget asserts they agree.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$InnerTimeoutSeconds,
        [Parameter(Mandatory = $false)][AllowNull()]$Row = $null,
        [Parameter(Mandatory = $false)][int]$FloorSeconds = 5,
        [datetime]$Now = (Get-Date)
    )

    if ($InnerTimeoutSeconds -le 0) {
        return @{ Seconds = $InnerTimeoutSeconds; Capped = $false; Reason = 'no inner timeout to cap' }
    }

    $budget = Get-WuuOperationRemainingSeconds -Row $Row -Now $Now
    if (-not $budget.Known) {
        return @{ Seconds = $InnerTimeoutSeconds; Capped = $false; Reason = 'no deadline recorded - the inner timeout stands' }
    }

    $remaining = [int]$budget.Remaining
    if ($remaining -ge $InnerTimeoutSeconds) {
        return @{ Seconds = $InnerTimeoutSeconds; Capped = $false; Reason = "budget permits the full $InnerTimeoutSeconds s (${remaining}s left)" }
    }

    # Below the ceiling, so cap - but never below the floor.
    $capped = [math]::Max($FloorSeconds, $remaining)
    if ($capped -eq $remaining) {
        return @{ Seconds = $capped; Capped = $true; Reason = "capped to the $remaining s left of operation '$($budget.Op)'" }
    }
    return @{ Seconds = $capped; Capped = $true; Reason = "capped to the ${FloorSeconds}s floor (only $remaining s of operation '$($budget.Op)' remained - the operation is about to expire)" }
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

#region Operation transition layer

# The workflow label a display State implies. Lifted verbatim from Set-ComputerState so the console
# and any other producer report the same sentence for the same state.
$script:WuuStateToStatus = @{
    'Queued'          = 'Waiting to start...'
    'Connecting'      = 'Testing Connectivity.'
    'Connected'       = 'Online.'
    'Checking'        = 'Initializing update session...'
    'Searching'       = 'Checking for updates...'
    'UpdatesFound'    = 'Updates found.'
    'Downloading'     = 'Downloading updates...'
    'Installing'      = 'Installing updates...'
    'RebootRequired'  = 'Reboot required.'
    'Rebooting'       = 'Restarting...'
    'Verifying'       = 'Verifying post-update state...'
    'Complete'        = 'All updates installed.'
    'Timeout'         = 'Operation timed out (recoverable).'
    'Error'           = 'Error occurred.'
}

# Colour implied by a display State. 'Timeout' is recoverable (yellow), 'Error' is terminal (grey) -
# a distinction the console relies on, and one that was previously repeated at every call site.
$script:WuuStateToColor = @{
    'Queued'          = 'Queued'
    'Connecting'      = 'Connecting'
    'Connected'       = 'Connected'
    'Checking'        = 'Searching'
    'Searching'       = 'Searching'
    'UpdatesFound'    = 'UpdatesFound'
    'Downloading'     = 'Downloading'
    'Installing'      = 'Installing'
    'RebootRequired'  = 'RebootRequired'
    'Rebooting'       = 'Rebooting'
    'Verifying'       = 'Verifying'
    'Complete'        = 'Complete'
    'Timeout'         = 'Timeout'
    'Error'           = 'Error'
}

function Get-WuuStateStatusText {
    <#
    .SYNOPSIS The canned human-readable Status sentence for a display State, plus an optional suffix.
    .DESCRIPTION
    One rule for the text the operator reads, so a state cannot be reported with two different
    sentences from two different call sites. Read-only and side-effect free.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$State,
        [string]$Detail = ''
    )
    $base = $script:WuuStateToStatus[$State]
    if (-not $base) { $base = $State }
    if ($Detail) { return "$base $Detail" }
    return $base
}

# THE terminal states (invariant 8.4), read by the transition guard, the outcome classifier and the checker.
# Do not keep a second list anywhere. ORDER IS PRECEDENCE: a stale Complete must not mask a current Error.
# Timeout is terminal yet retryable - a retry is a new operation. RebootRequired is transient, not terminal.
# Cancelled/Refused are deliberately not states; see docs/STATE-MACHINE.md section 2a. Keep this file ASCII.
$script:WuuTerminalStates = @(
    @{ State = 'Error';    Outcome = 'Failed' }
    @{ State = 'Timeout';  Outcome = 'TimedOut' }
    @{ State = 'Complete'; Outcome = 'Success' }
)

function Get-WuuTerminalStates {
    <#
    .SYNOPSIS
    The terminal state names, in precedence order (invariant 8.4). Returns a fresh array.
    #>
    [CmdletBinding()]
    param()
    return @($script:WuuTerminalStates | ForEach-Object { [string]$_.State })
}

function Get-WuuTerminalOutcomeMap {
    <#
    .SYNOPSIS
    Terminal state -> outcome word, as an ORDERED dictionary so the precedence survives.
    #>
    [CmdletBinding()]
    param()
    $map = [ordered]@{}
    foreach ($entry in $script:WuuTerminalStates) {
        # Skip malformed entries: an empty key would match every row with an empty UpdatesStatus.
        $stateName = [string]$entry.State
        $outcomeName = [string]$entry.Outcome
        if ([string]::IsNullOrEmpty($stateName) -or [string]::IsNullOrEmpty($outcomeName)) { continue }
        $map[$stateName] = $outcomeName
    }
    return $map
}

function Test-WuuTerminalStateInvariant {
    <#
    .SYNOPSIS
    Whether the terminal declaration is internally consistent (invariant 8.4).
    .DESCRIPTION
    Non-empty; every entry has State and Outcome; no duplicates; every outcome Get-WuuTargetOutcome can
    return maps to a terminal state; Complete is last. Returns @{ Ok; Violations } and never throws,
    because the release gate calls it.
    #>
    [CmdletBinding()]
    param()

    $violations = New-Object System.Collections.ArrayList
    $entries = @($script:WuuTerminalStates)

    if ($entries.Count -eq 0) {
        $null = $violations.Add('the terminal set is EMPTY - every transition would be legal and the guard would be inert')
    } else {
        $seen = New-Object System.Collections.ArrayList
        foreach ($entry in $entries) {
            if (-not $entry.State)  { $null = $violations.Add('a terminal entry names no State') }
            if (-not $entry.Outcome) { $null = $violations.Add("terminal state '$($entry.State)' names no Outcome") }
            if ($entry.State -and ($seen -contains [string]$entry.State)) {
                $null = $violations.Add("terminal state '$($entry.State)' is declared more than once - the precedence is ambiguous")
            }
            if ($entry.State) { $null = $seen.Add([string]$entry.State) }
        }

        # 4. Every outcome the classifier can produce must come from a terminal state.
        $declaredOutcomes = @($entries | ForEach-Object { [string]$_.Outcome })
        foreach ($expected in 'Success', 'Failed', 'TimedOut') {
            if ($declaredOutcomes -notcontains $expected) {
                $null = $violations.Add("Get-WuuTargetOutcome can return '$expected' but no terminal state maps to it - the classifier would settle a row the transition guard still considers open")
            }
        }

        # 5. A stale 'Complete' must never mask a current failure, so Complete sorts LAST.
        $states = @($entries | ForEach-Object { [string]$_.State })
        if ($states.Count -gt 1) {
            $completeAt = [array]::IndexOf($states, 'Complete')
            if ($completeAt -ge 0 -and $completeAt -ne ($states.Count - 1)) {
                $null = $violations.Add("'Complete' is declared before '$($states[$states.Count - 1])' - a stale completion could then mask a current failure")
            }
        }
    }

    return @{ Ok = ($violations.Count -eq 0); Violations = @($violations) }
}

function Test-WuuTerminalState {
    <#
    .SYNOPSIS
    Whether a state, or a row's state, is terminal (invariant 8.4).
    .DESCRIPTION
    Returns @{ Terminal; State; Set }. $null and unknown states are not terminal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][string]$State,
        [Parameter(Mandatory = $false)][AllowNull()]$Row
    )

    $set = @(Get-WuuTerminalStates)
    $judged = ''

    if ($null -ne $Row -and $Row.PSObject.Properties['State'] -and $Row.State) {
        $judged = [string]$Row.State
    } elseif (-not [string]::IsNullOrEmpty($State)) {
        $judged = $State
    }

    # -contains is case-insensitive, matching every other state comparison here.
    return @{
        Terminal = ($judged -ne '' -and ($set -contains $judged))
        State    = $judged
        Set      = $set
    }
}

function New-WuuResetOperationContext {
    <#
    .SYNOPSIS
    Creates an explicit, attributed ResetOperation context (P0 Hardening, STATE-RESET-OP-01).
    .DESCRIPTION
    A reset is NOT a normal transition and NOT a widened rule: it is an explicit administrative or
    scheduler operation that resets or retires a row's state (e.g. following a submission that failed
    to initialize, or during multi-phase wait bookkeeping).

    Carries mandatory Source, Reason, Actor, and a unique ResetOperationId.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateSet('SubmissionFailure', 'PhaseWaitBookkeeping', 'OperatorReset')][string]$Source,
        [Parameter(Mandatory=$true)][string]$Reason,
        [Parameter(Mandatory=$false)][string]$Actor = 'System',
        [Parameter(Mandatory=$false)][string]$ResetOperationId = ''
    )

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        throw 'ResetOperation requires a non-empty Reason.'
    }
    $effResetId = $ResetOperationId
    if ([string]::IsNullOrEmpty($effResetId)) {
        $effResetId = ('reset-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    }

    [pscustomobject]@{
        ResetOperationId = $effResetId
        Source           = $Source
        Reason           = $Reason
        Actor            = $Actor
        ResetAt          = (Get-Date)
    }
}

function Test-WuuStateTransitionAllowed {
    <#
    .SYNOPSIS Whether a display State change is legal for a row (invariant 8.4).
    .DESCRIPTION
    A terminal row may not change state without an attributed operation; a retry is a new operation and
    is allowed. Identity (staleness) is checked earlier, in Update-WuuOperationState.
    An explicit ResetOperation contract permits targeted resets (SubmissionFailure -> Error,
    PhaseWaitBookkeeping -> Queued, OperatorReset) while preserving invariant 8.4 against accidental rewrites.
    Returns @{ Allowed; Reason }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)][AllowNull()]$Row,
        [Parameter(Mandatory)][string]$ToState,
        [Parameter(Mandatory=$false)][AllowNull()][string]$OperationId = $null,
        [Parameter(Mandatory=$false)][AllowNull()][object]$ResetOperation = $null
    )

    if ($null -eq $Row) { return @{ Allowed = $false; Reason = 'no row' } }
    if (-not $Row.PSObject.Properties['State']) { return @{ Allowed = $false; Reason = 'row has no State property' } }

    $fromState = [string]$Row.State

    # Refuse ANY unattributed change away from a terminal state, including terminal -> terminal
    # (Timeout -> Complete would turn a counted failure into a success). Same-state rewrites are bookkeeping.
    # The id is not matched against the row's: a resubmission is by definition a new id.
    $fromTerminal = Test-WuuTerminalState -State $fromState
    if ($fromTerminal.Terminal -and ($fromState -ne [string]$ToState)) {
        if ($null -ne $ResetOperation) {
            # STATE-RESET-OP-01: An explicit, attributed ResetOperation context authorizes targeted transitions
            # from settled states, strictly restricted by source.
            $rSource = if ($ResetOperation.PSObject.Properties['Source']) { [string]$ResetOperation.Source }
                       elseif ($ResetOperation -is [System.Collections.IDictionary] -and $ResetOperation.Contains('Source')) { [string]$ResetOperation['Source'] }
                       else { '' }
            $rReason = if ($ResetOperation.PSObject.Properties['Reason']) { [string]$ResetOperation.Reason }
                       elseif ($ResetOperation -is [System.Collections.IDictionary] -and $ResetOperation.Contains('Reason')) { [string]$ResetOperation['Reason'] }
                       else { '' }

            if ([string]::IsNullOrWhiteSpace($rSource) -or [string]::IsNullOrWhiteSpace($rReason)) {
                return @{ Allowed = $false; Reason = "ResetOperation refused: Source and Reason must be non-empty (unattributed reset)" }
            }

            switch ($rSource) {
                'SubmissionFailure' {
                    if ($ToState -notin @('Error', 'Failed')) {
                        return @{ Allowed = $false; Reason = "SubmissionFailure reset may only transition to 'Error' (got '$ToState')" }
                    }
                }
                'PhaseWaitBookkeeping' {
                    if ($ToState -ne 'Queued') {
                        return @{ Allowed = $false; Reason = "PhaseWaitBookkeeping reset may only transition to 'Queued' (got '$ToState')" }
                    }
                }
                'OperatorReset' {
                    if ($ToState -in @('Running', 'Checking', 'Searching', 'Downloading', 'Installing', 'Verifying')) {
                        return @{ Allowed = $false; Reason = "OperatorReset cannot transition directly to active running state '$ToState' without scheduling" }
                    }
                }
                default {
                    return @{ Allowed = $false; Reason = "Unknown ResetOperation source '$rSource'" }
                }
            }
            return @{ Allowed = $true; Reason = '' }
        }

        if ([string]::IsNullOrEmpty($OperationId)) {
            return @{ Allowed = $false; Reason = "a settled row ('$fromState') may not move to '$ToState' without a new attributed operation" }
        }
    }

    return @{ Allowed = $true; Reason = '' }
}

function Update-WuuOperationState {
    <#
    .SYNOPSIS
    THE SINGLE STATE-MUTATION FUNNEL (SS16). Validates identity and transition, then owns every write.
    .DESCRIPTION
    WHY THIS EXISTS. Before it, six different writers mutated a row's operation state: two guarded
    row-writers and four unguarded state helpers, plus 46 direct `$Computer.<prop> = ...` assignments
    in Wuu.Core that bypassed all of them. The invariant "a superseded operation cannot write" was
    therefore only true of two of six producers - and it was asserted by a gate that looked for the
    word OperationId in one file.

    Identity is checked FIRST, before the transition rule, because a stale writer must be refused even
    when the transition it wants would otherwise be legal. A refusal is an EXPECTED outcome of a
    stopped or superseded operation, not a fault: callers must not treat Refused as an error.

    NOTHING IS WRITTEN WHEN REFUSED. That is the whole contract - not "written then reverted", and not
    "written to a copy". Tests assert the row is byte-identical after a refusal.

    This is a PURE-ish function: it takes the row by reference and mutates only that row, plus the
    optional store Touch(). It performs no lookups, so it is equally callable from the main session and
    (via its inlined twin) from a worker runspace.

    PARAMETERS
      Row         the target row object. $null is a clean refusal.
      OperationId the writer's identity. '' / $null means UNATTRIBUTED - permitted (list loading and
                  startup populate rows that have no operation), which is why identity uses
                  Test-WuuStaleWrite rather than Test-WuuOperationCurrent. See that function's note.
      State       optional display State ('Checking', 'Error', ...). Drives Status and Color.
      Status      optional literal Status text; overrides the canned text for $State.
      StatusSuffix appended to the canned text for $State when Status is not given.
      Color       optional literal colour; defaults to the colour implied by $State.
      OpState     optional 'Idle' | 'Running' | 'Queued'.
      OperationIdNew stamps a NEW operation id (starting or resubmitting an operation).
      OpStartedAt sets OpStartedAt.
      OpName      sets the operation NAME with no deadline change.
      Phase       records a recoverable TIMEOUT: sets State='Timeout', the deadline and its source,
                  and the colour. $TimeoutSec is required with it.
      TimeoutSec  seconds from now for Phase.
      ClearOperation ends the operation: OpState='Idle', clears the deadline, retires the identity
                  and detaches the runspace. This is the copy-pasted 6-line cleanup block, once.
      ClearPendingOp empties the ONE queued-follow-up slot. This is the scheduler CONSUMING the
                  request it just read, so the slot is one-shot and must be emptied in the same step
                  or the operation would run twice. Deliberately NOT expressed as "set PendingOp to
                  $null": the intent is what a reviewer needs to see, and it is NOT a transition -
                  no -State is passed, so the settled-row rule does not apply. A settled row still
                  CARRYING a pending op is invariant 5 (see Test-WuuOperationStateInvariant), so
                  clearing it must stay legal or that violation could not be repaired.
      Heartbeat   when true, refreshes LastHeartbeatAt and increments Heartbeats.
      Runspace    sets the runspace reference ($null to detach).
      UpdatesStatus sets UpdatesStatus.
      Revision    optional expected revision. When supplied and the row's Revision differs, the write
                  is refused - an optimistic-concurrency check for callers that have a snapshot.
      Touch       when true, calls $Store.Touch() after a successful write.
      Store       the state store, needed only when Touch is set.
      Now         injectable clock, so a test can assert a deadline without sleeping.

    RETURNS a hashtable, never a bare boolean, because the caller needs to distinguish an expected
    refusal from a successful write:
      Applied [bool]   whether the row was mutated
      Refused [bool]   whether the write was refused (stale identity, illegal transition, revision)
      Reason  [string] '' when applied, else why it was refused
    A caller that ignores Refused reproduces the original defect, so tests assert both the count of
    refusals and the reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)][AllowNull()]$Row,
        [Parameter(Mandatory=$false)][AllowNull()][string]$OperationId = $null,
        [Parameter(Mandatory=$false)][string]$State = '',
        [Parameter(Mandatory=$false)][string]$Status = '',
        [Parameter(Mandatory=$false)][string]$StatusSuffix = '',
        [Parameter(Mandatory=$false)][string]$Color = '',
        [Parameter(Mandatory=$false)][switch]$ColorFromState,
        [Parameter(Mandatory=$false)][string]$OpState = '',
        [Parameter(Mandatory=$false)][string]$OperationIdNew = '',
        [Parameter(Mandatory=$false)][AllowNull()]$OpStartedAt = $null,
        [Parameter(Mandatory=$false)][string]$OpName = '',
        [Parameter(Mandatory=$false)][string]$Phase = '',
        [Parameter(Mandatory=$false)][int]$TimeoutSec = 0,
        [Parameter(Mandatory=$false)][switch]$ClearOperation,
        [Parameter(Mandatory=$false)][switch]$ClearPendingOp,
        [Parameter(Mandatory=$false)][AllowNull()][object]$ResetOperation = $null,
        [Parameter(Mandatory=$false)][switch]$Heartbeat,
        [Parameter(Mandatory=$false)][AllowNull()]$Runspace = $null,
        [Parameter(Mandatory=$false)][string]$UpdatesStatus = '',
        [Parameter(Mandatory=$false)][AllowNull()]$Revision = $null,
        [Parameter(Mandatory=$false)][switch]$Touch,
        [Parameter(Mandatory=$false)][AllowNull()]$Store = $null,
        [Parameter(Mandatory=$false)][datetime]$Now = (Get-Date)
    )

    $refused = {
        param([string]$Reason)
        return @{ Applied = $false; Refused = $true; Reason = $Reason }
    }

    if ($null -eq $Row) { return (& $refused 'no row') }

    $resetCtx = $null
    if ($null -ne $ResetOperation) {
        if ($ResetOperation -is [System.Collections.IDictionary]) {
            $rSrc = if ($ResetOperation.Contains('Source')) { [string]$ResetOperation['Source'] } else { 'OperatorReset' }
            $rRsn = if ($ResetOperation.Contains('Reason')) { [string]$ResetOperation['Reason'] } else { '' }
            $rAct = if ($ResetOperation.Contains('Actor')) { [string]$ResetOperation['Actor'] } else { 'System' }
            $rId  = if ($ResetOperation.Contains('ResetOperationId')) { [string]$ResetOperation['ResetOperationId'] } else { '' }
            if ([string]::IsNullOrWhiteSpace($rRsn)) {
                return (& $refused 'ResetOperation requires an attributed context with non-empty Reason')
            }
            $resetCtx = New-WuuResetOperationContext -Source $rSrc -Reason $rRsn -Actor $rAct -ResetOperationId $rId
        } elseif ($ResetOperation.PSObject.Properties['ResetOperationId'] -and $ResetOperation.PSObject.Properties['Source']) {
            if ([string]::IsNullOrWhiteSpace($ResetOperation.Reason)) {
                return (& $refused 'ResetOperation requires an attributed context with non-empty Reason')
            }
            $resetCtx = $ResetOperation
        } elseif ($ResetOperation -is [string]) {
            if ([string]::IsNullOrWhiteSpace($ResetOperation)) {
                return (& $refused 'ResetOperation requires an attributed context with non-empty Reason')
            }
            $resetCtx = New-WuuResetOperationContext -Source 'OperatorReset' -Reason $ResetOperation -Actor 'System'
        } else {
            return (& $refused 'ResetOperation requires a valid context object, hashtable, or non-empty reason string')
        }
    }

    # --- 1. IDENTITY, first ----------------------------------------------------------------
    # Test-WuuStaleWrite, not Test-WuuOperationCurrent: a WRITE is refused only when it is PROVEN
    # stale. An unattributed write is permitted, or list loading would be discarded.
    #
    # ADOPTION IS NOT STALENESS. Starting or resubmitting an operation means stamping an identity
    # the row does not carry yet - by definition it differs from the old one. Running that through
    # the stale-writer rule would refuse every resubmission (caught by this suite). Adoption is
    # therefore a separate, EXPLICIT act: it is permitted only when no live operation owns the row,
    # which is the same condition the admission gate (Test-WuuComputerBusy) already enforces. A
    # late writer trying to adopt over a RUNNING operation is refused here.
    $rowOpId = ''
    if ($Row.PSObject.Properties['OperationId']) { $rowOpId = [string]$Row.OperationId }
    $rowIsRunning = ($Row.PSObject.Properties['OpState'] -and ([string]$Row.OpState -eq 'Running'))

    if ($resetCtx) {
        # STATE-RESET-OP-01: ResetOperation is an administrative/orchestrator reset of the row. It
        # supersedes any in-flight operation and fences late workers by retiring the OperationId.
    } elseif ($OperationIdNew) {
        if ($rowIsRunning -and $rowOpId -ne '' -and $rowOpId -cne $OperationIdNew) {
            return (& $refused "cannot adopt '$OperationIdNew': the row is Running under '$rowOpId'")
        }
    } elseif ($Row.PSObject.Properties['LastResetOperationId'] -and $Row.LastResetOperationId -and $OperationId) {
        return (& $refused "stale writer: operation was reset ($($Row.LastResetSource): $($Row.LastResetReason)), writer '$OperationId' is stale")
    } elseif (Test-WuuStaleWrite -Row $Row -OperationId $OperationId) {
        return (& $refused "stale writer: row belongs to operation '$rowOpId', writer is '$OperationId'")
    }

    # --- 2. OPTIONAL REVISION PRECONDITION --------------------------------------------------
    if ($null -ne $Revision -and $Row.PSObject.Properties['Revision']) {
        if ([string]$Row.Revision -ne [string]$Revision) {
            return (& $refused "revision changed: expected '$Revision', row is '$($Row.Revision)'")
        }
    }

    # --- 3. TRANSITION LEGALITY -------------------------------------------------------------
    # Only consulted when a display State is being set; a pure bookkeeping write (deadline,
    # heartbeat) is not a transition and must not be gated by the settled rule.
    if ($State) {
        $legality = Test-WuuStateTransitionAllowed -Row $Row -ToState $State -OperationId $OperationId -ResetOperation $resetCtx
        if (-not $legality.Allowed) { return (& $refused $legality.Reason) }
    }

    # --- 4. APPLY ---------------------------------------------------------------------------
    # A Phase IS a timeout, so it implies the Timeout display state when the caller did not name
    # one. Resolved into LOCALS: parameters are never reassigned (a gated hazard in this codebase).
    $effState = $State
    $effTimeout = $TimeoutSec
    if ($Phase -and -not $effState) { $effState = 'Timeout' }
    if ($Phase -and $effTimeout -le 0) {
        # Defensive: a Phase with no budget would record a deadline in the past and the row would be
        # judged expired on the next cleanup pass. Derive it from the operation instead.
        $effTimeout = [int](Get-WuuOperationTimeoutSeconds -Op $Phase)
    }

    $set = {
        param($Prop, $Value)
        if ($Row.PSObject.Properties[$Prop]) { $Row.$Prop = $Value; return $true }
        return $false
    }

    if ($resetCtx) {
        # STATE-RESET-OP-01: Fencing and retiring previous operation context.
        & $set 'OperationId' ''
        & $set 'OpState' 'Idle'
        & $set 'OpStartedAt' $null
        & $set 'TimeoutExpiresAt' $null
        & $set 'TimeoutSource' ''
        & $set 'OpName' ''
        & $set 'LastHeartbeatAt' $null
        if ($Row.PSObject.Properties['Runspace'] -and $Row.Runspace) {
            try { $Row.Runspace.Close() } catch { }
            try { $Row.Runspace.Dispose() } catch { }
            & $set 'Runspace' $null
        }
        if ($Row.PSObject.Properties['LastResetOperationId']) { $Row.LastResetOperationId = $resetCtx.ResetOperationId }
        if ($Row.PSObject.Properties['LastResetReason'])      { $Row.LastResetReason = $resetCtx.Reason }
        if ($Row.PSObject.Properties['LastResetSource'])      { $Row.LastResetSource = $resetCtx.Source }
        if ($Row.PSObject.Properties['LastResetAt'])          { $Row.LastResetAt = $resetCtx.ResetAt }
    }

    if ($OperationIdNew) {
        & $set 'OperationId' $OperationIdNew
        & $set 'LastResetOperationId' ''
        & $set 'LastResetReason' ''
        & $set 'LastResetSource' ''
        & $set 'LastResetAt' $null
    }

    if ($effState) {
        & $set 'State' $effState
        if ($Status) {
            & $set 'Status' $Status
        } elseif ($Phase) {
            # The timeout sentence, preserved verbatim from Set-ComputerTimeout. A timeout names what
            # timed out and for how long, which the generic canned line cannot - and the operator
            # needs that to tell a slow phase from a stuck one.
            $detailSuffix = if ($StatusSuffix) { " $StatusSuffix" } else { '' }
            & $set 'Status' "Timeout during $Phase after ${effTimeout}s - continuing to monitor.$detailSuffix"
        } else {
            & $set 'Status' (Get-WuuStateStatusText -State $effState -Detail $StatusSuffix)
        }
        if ($Color) {
            & $set 'Color' $Color
        } elseif ($ColorFromState) {
            # Opt-in, NOT the default. Set-ComputerState must never change a row's colour, and making
            # the implied colour automatic would have silently recoloured every row it touched - a
            # behaviour change smuggled in by a refactor. Callers that want it ask for it.
            $implied = $script:WuuStateToColor[$effState]
            if ($implied) { & $set 'Color' $implied }
        }
        if ($Row.PSObject.Properties['StateTimestamp']) { $Row.StateTimestamp = $Now }
    } elseif ($Status) {
        # Literal status with no state change - used by the progress writers.
        & $set 'Status' $Status
    }

    if ($OpState)       { & $set 'OpState' $OpState }
    if ($null -ne $OpStartedAt) { & $set 'OpStartedAt' $OpStartedAt }
    if ($OpName)        { & $set 'OpName' $OpName }
    if ($UpdatesStatus) { & $set 'UpdatesStatus' $UpdatesStatus }
    if ($null -ne $Runspace) { & $set 'Runspace' $Runspace }

    if ($Phase) {
        # A recoverable timeout: deadline + its source + the display state, in one place.
        & $set 'TimeoutExpiresAt' $Now.AddSeconds($effTimeout)
        & $set 'TimeoutSource' $Phase
        & $set 'UpdatesStatus' 'Timeout'
    }

    if ($ClearPendingOp) {
        # ORDER: applied BEFORE ClearOperation, so that a combined call settles the row rather than
        # leaving it Queued for a follow-up that the same call is removing. No caller passes both
        # today; the order is fixed so that one eventually cannot get it wrong.
        & $set 'PendingOp' $null
    }

    if ($ClearOperation) {
        # The copy-pasted cleanup block, once. Order matters only for readability; each set is
        # independently guarded by the & $set helper.
        & $set 'OpState' 'Idle'
        & $set 'OpStartedAt' $null
        & $set 'TimeoutExpiresAt' $null
        & $set 'TimeoutSource' ''
        & $set 'OpName' ''
        & $set 'LastHeartbeatAt' $null
        & $set 'OperationId' ''
        & $set 'Runspace' $null

        # STATE-TERMINAL-RESET-01: Timeout is TERMINAL, so ending its operation must not rewrite the
        # display. The deadline is cleared above while the display stays 'Timeout' - which is correct,
        # because invariant 4 only requires a deadline while the operation is RUNNING (a settled
        # Timeout with no deadline is the normal post-timeout shape; the worker's own timeout path in
        # Wuu.Workers writes exactly that). Rewriting it to 'Queued' here was an unattributed
        # terminal->Queued transition - the very move Test-WuuStateTransitionAllowed refuses - and it
        # laundered a counted timeout into a clean queue. A retry is a NEW operation that re-stamps it.

        # A queued follow-up means the row is NOT finished: that request is its next operation. A
        # settled display would let the outcome/phase accounting count the row as done before it runs.
        if ($Row.PSObject.Properties['PendingOp'] -and $Row.PendingOp) {
            & $set 'State' 'Queued'
            & $set 'Status' (Get-WuuStateStatusText -State 'Queued')
        }
    }

    if ($Heartbeat) {
        if ($Row.PSObject.Properties['LastHeartbeatAt']) { $Row.LastHeartbeatAt = $Now }
        if ($Row.PSObject.Properties['Heartbeats']) { $Row.Heartbeats = [int]$Row.Heartbeats + 1 }
    }

    if ($Touch -and $Store) {
        try { $Store.Touch() } catch { }
    }

    return @{ Applied = $true; Refused = $false; Reason = '' }
}

function Test-WuuOperationStateInvariant {
    <#
    .SYNOPSIS
    Checks the row contract's invariants and returns the VIOLATIONS found (SS16).
    .DESCRIPTION
    This exists so the invariant is assertable rather than merely intended, and so a gate can call it
    against real rows instead of grepping for source text. Returns a list of violation strings - empty
    means the row satisfies the contract. Never throws.

    The invariants, each one a defect that was reachable before the transition layer:
      1. No OperationId while running      - an operation is running, so a writer must be able to name
                                             it. Without it the timeout path can be bypassed.
      2. OperationId while Idle            - an identity outliving its operation lets a late writer
                                             present a valid token for a job that no longer exists.
      3. Deadline while no operation       - a stale deadline in the past kills the NEXT operation on
                                             its first cleanup pass.
      4. Timeout state without a deadline  - a RUNNING Timeout display with no deadline means nothing
                                             will ever settle the row: it hangs in yellow forever. A
                                             SETTLED timeout (OpState Idle) has no deadline by design.
      5. Settled plus PendingOp            - a settled row is finished, yet still advertises queued work.
      6. Settled plus Running              - a finished operation must not hold the runspace lock.
      7. TimeoutSource without deadline    - half-cleared timeout state.
      8. Heartbeat count without a timestamp - counts nothing, tells a human nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)][AllowNull()]$Row
    )

    $violations = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Row) { $violations.Add('row is $null'); return $violations }

    $get = {
        param([string]$Prop)
        if ($Row.PSObject.Properties[$Prop]) { return $Row.$Prop }
        return $null
    }

    $name  = [string](& $get 'Computer')
    $state = [string](& $get 'State')
    $opState = [string](& $get 'OpState')
    $opId  = [string](& $get 'OperationId')
    $expires = & $get 'TimeoutExpiresAt'
    $source  = [string](& $get 'TimeoutSource')
    $hbAt    = & $get 'LastHeartbeatAt'
    $hbCount = & $get 'Heartbeats'
    $pending = & $get 'Pending'
    $pendingOp = [string](& $get 'PendingOp')
    $tag = if ($name) { " [$name]" } else { '' }

    $settled = @(Get-WuuTerminalStates)

    if ($opState -eq 'Running' -and [string]::IsNullOrEmpty($opId)) {
        $violations.Add("$tag running OpState with no OperationId - a writer cannot prove ownership")
    }
    if ($opState -eq 'Idle' -and -not [string]::IsNullOrEmpty($opId)) {
        $violations.Add("$tag OperationId '$opId' survives an Idle row - a late writer could present a valid token")
    }
    if ($opState -eq 'Idle' -and $null -ne $expires) {
        $violations.Add("$tag a deadline is recorded while no operation is running - the next operation would be judged expired immediately")
    }
    if ($state -eq 'Timeout' -and $opState -eq 'Running' -and $null -eq $expires) {
        $violations.Add("$tag State='Timeout' with no deadline while the operation is RUNNING - nothing can settle this row")
    }
    if ($settled -contains $state -and $pendingOp) {
        $violations.Add("$tag settled row ('$state') still queues PendingOp '$pendingOp' - the row is reported finished while its next operation is still queued")
    }
    if ($settled -contains $state -and $opState -eq 'Running') {
        $violations.Add("$tag settled row ('$state') still holds the runspace lock (OpState='Running')")
    }
    if (-not [string]::IsNullOrEmpty($source) -and $null -eq $expires) {
        $violations.Add("$tag TimeoutSource '$source' is set but the deadline is empty - half-cleared timeout state")
    }
    if ($null -ne $hbCount -and ([int]$hbCount -gt 0) -and $null -eq $hbAt) {
        $violations.Add("$tag Heartbeats=$hbCount but LastHeartbeatAt is empty")
    }

    return $violations
}

#endregion Operation transition layer

#region Submission critical section

# The gate object for the submission critical section. A plain reference type is all Monitor needs -
# its identity is the lock, not its contents.
$script:WuuSubmissionGate = New-Object System.Object

function Enter-WuuSubmissionLock {
    <#
    .SYNOPSIS
    Acquires sole right to read-and-reserve a concurrency slot (SS4).
    .DESCRIPTION
    WHY A LOCK AND NOT A SIMPLER CHECK. The global cap was enforced by
    `Test-WuuConcurrencyAvailable` at the TOP of Start-UpdateCheckJob, but the job entry that the cap
    COUNTS was appended 141 lines later, after the credential-epoch check, runspace creation, pipeline
    composition, the identity claim and the runspace variable stamp. Two submissions arriving during
    that span both see the same `$jobs.Count` and both admit - so a cap of 10 admits 12, and the
    overshoot grows with the work done in between.

    Adding the entry is what CONSUMES capacity, so the check and the add must be one indivisible step.
    Everything between them is per-submission work that does not need to be serialised, so the lock is
    taken only at the end: capacity is re-tested immediately before the append. A submission that
    prepared while another thread consumed the last slot then finds no room and rolls back.

    NOT-A-SENTINEL, DELIBERATELY. The obvious alternative - append a placeholder at the top and fill it
    in later - keeps `$jobs.Count` truthful without a lock, but the cleanup loop enumerates a SNAPSHOT
    (`@($jobs)`), so a placeholder would be observed and processed as if it were a real job. A lock
    leaves the collection containing only complete entries.

    Monitor rather than a SemaphoreSlim: Monitor is RE-ENTRANT on the same thread, so a nested
    submission (a payload that eventually re-enters the submission point) cannot deadlock against
    itself, and it costs no allocation per acquisition.

    A caller that cannot take the lock in time must treat it as "no capacity" and refuse: blocking
    indefinitely on a lock held by a thread that may have died would hang the whole submission path.
    Refusing is recoverable - the row stays Pending and the scheduler retries the next tick.

    -Gate EXISTS FOR TESTABILITY, AND IT IS LOAD-BEARING. `$script:` state is per MODULE INSTANCE, so
    a test that imports this module into each of N runspaces gets N gate objects and proves nothing -
    it would observe perfect "mutual exclusion" that in fact never shared a lock. Production imports
    the modules -Global exactly once, so every caller shares one gate. Passing the gate explicitly
    lets a test share ONE object across real threads and observe genuine exclusion, without any
    change to production call sites (which omit the parameter).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)][int]$TimeoutMs = 30000,
        # The lock object. Identity is what matters, not contents. Omit to use the module's gate.
        [Parameter(Mandatory=$false)][AllowNull()]$Gate = $null
    )

    # Resolved into a LOCAL, never by reassigning $Gate: reassigning a parameter is a documented
    # hazard in this codebase and a gate failure (this gate has now caught the same mistake twice).
    $gateObject = $Gate
    if ($null -eq $gateObject) { $gateObject = $script:WuuSubmissionGate }
    if ($null -eq $gateObject) { return $false }
    try {
        return [System.Threading.Monitor]::TryEnter($gateObject, $TimeoutMs)
    } catch {
        return $false
    }
}

function Exit-WuuSubmissionLock {
    <#
    .SYNOPSIS
    Releases the submission critical section (SS4). Idempotent and never throws.
    .DESCRIPTION
    Swallows its own failure on purpose. This is called from a `finally`, and a throw here would
    replace whatever exception was propagating - turning a real diagnosis into a lock-release error.
    A failed release means the lock was not held (a double release), which is a defect in the caller
    and is reported by tests\Test-SubmissionAtomicity.ps1 rather than by an exception mid-flight.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)][AllowNull()]$Gate = $null
    )

    $gateObject = $Gate
    if ($null -eq $gateObject) { $gateObject = $script:WuuSubmissionGate }
    if ($null -eq $gateObject) { return }
    try { [System.Threading.Monitor]::Exit($gateObject) } catch { }
}

function Test-WuuSubmissionLockHeld {
    <#
    .SYNOPSIS
    Whether the CALLING thread currently holds the submission lock (SS4).
    .DESCRIPTION
    Exists so a test can assert the critical section really excludes, rather than asserting that a
    lock function was called. Also useful to a caller that wants to know whether a nested submission
    is already inside the section.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)][AllowNull()]$Gate = $null
    )

    $gateObject = $Gate
    if ($null -eq $gateObject) { $gateObject = $script:WuuSubmissionGate }
    if ($null -eq $gateObject) { return $false }
    try { return [System.Threading.Monitor]::IsEntered($gateObject) } catch { return $false }
}

#endregion Submission critical section

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

function Get-WuuPendingOpRank {
    <#
    .SYNOPSIS
    The SEMANTIC rank of a queued operation, for pending-request precedence (SS16).
    .DESCRIPTION
    WHY A RANK AND NOT NEWEST-WINS. Newest-wins is a plausible rule that loses work in the direction
    that is easiest to miss: `install` then `download` on a busy computer replaced the install with a
    download, so an operator who asked for MORE got LESS. Reporting the displacement made it visible
    but still did it.

    The ordering is the one SS16 recommends - each rank SUBSUMES the work of the one below it, which
    is what makes replacing upward safe and replacing downward a loss:

        Check  <  Download  <  InstallAndRecheck  <  Restart

    AutoFlow ranks WITH Restart: it is the full download + install + reboot chain, so it is the widest
    request there is. `InstallAndRecheck` is the install handler's verb and ranks with Install.

    AN UNKNOWN OPERATION RANKS 0. Refusing an unrecognised request in favour of one this function
    cannot compare would make a typo in a new caller look like a policy decision, so the unknown value
    ranks lowest and is therefore DECLINED whenever anything is already queued - which is the safe
    direction: nothing that was asked for is abandoned.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][string]$Op = ''
    )

    if ([string]::IsNullOrWhiteSpace($Op)) { return 0 }
    switch -Regex ($Op.Trim()) {
        '^Check$'               { return 1 }
        '^Download$'            { return 2 }
        '^Install(AndRecheck)?$' { return 3 }
        '^(Restart|AutoFlow)$'  { return 4 }
        default                 { return 0 }
    }
}

function Set-WuuPendingOperation {
    <#
    .SYNOPSIS
    Sets a row's queued follow-up OPERATION, applying the pending-request policy (SS7/SS16).
    .DESCRIPTION
    POLICY: ONE SLOT, SEMANTIC PRECEDENCE, AND EVERY DECISION IS REPORTED.

    A row has a single PendingOp slot, so a busy computer cannot hold two outstanding requests. A
    second request must therefore be refused or replace the first. Which one it is, is the policy.

    WHY PRECEDENCE AND NOT NEWEST-WINS. See Get-WuuPendingOpRank for the ordering and the reasoning.
    In short: an UPGRADE still replaces (the higher request performs the lower one), but a DOWNGRADE
    is DECLINED and the higher request is KEPT. Equal ranks are genuinely ambiguous, so the newer
    request wins within its rank.

    WHY DECLINING A DOWNGRADE LOSES NOTHING. An earlier note here warned that "refusing a second
    request would make `download` then `install` silently do nothing". That is true of an UPGRADE and
    is exactly why R3 still replaces. It is NOT true of a DOWNGRADE: the queued download is still
    going to run and is still what the operator asked for. The defect was never the overwrite alone -
    it was doing LESS than asked while implying MORE.

    -OnlyIfEmpty is for INTERNAL callers. An automatic follow-up queued by the download/check payloads
    is not an operator request, so it must never displace one: if the slot is already held the
    follow-up is skipped (Set = $false, and Refused stays $false because nothing was lost). The
    payloads INLINE this rule rather than calling here - they run in an isolated worker runspace where
    no module function resolves (see the note at the top of this file) - so
    tests\Test-PendingPolicy.ps1 asserts both copies agree.

    RETURNS a hashtable, never a bare boolean, because the caller must distinguish three outcomes that
    all leave the row without the request it just made:
      Set      [bool]   whether the slot was CHANGED.
      Refused  [bool]   the request was DECLINED in favour of the higher-ranked request already queued.
                        Not the same as Set=$false with Refused=$false, which means an internal
                        follow-up stood aside (nothing was lost) or the call was a degenerate no-op.
      Op       [string] the operation now queued ($null when nothing is queued).
      Replaced [string] the request this call DISPLACED ($null when nothing was lost).
      Existing [string] what the slot held, so a caller can report what was KEPT without re-reading.
      Reason   [string] why the request was not accepted.
    ADDITIVE ONLY (SS34): Set/Op/Replaced keep their former meaning exactly, so a caller that reads
    only them is unaffected. A caller that ignores Replaced still reproduces the original silence
    defect, so the tests assert that a replacement is SURFACED, not merely performed.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()]$Row,
        [Parameter(Mandatory = $false)][string]$Op = '',
        [switch]$OnlyIfEmpty
    )

    $noChange = @{ Set = $false; Refused = $false; Op = $null; Replaced = $null; Existing = $null; Reason = '' }

    if ($null -eq $Row) { return $noChange }
    if ([string]::IsNullOrWhiteSpace($Op)) { return $noChange }
    if ($null -eq $Row.PSObject.Properties['PendingOp']) { return $noChange }

    # A queued follow-up presupposes an operation to follow, so a SETTLED row cannot take one: the
    # request would be a promise about a finished row, and its display state is what the outcome and
    # phase accounting read. Refused with a reason, so the caller can say why nothing was queued.
    if ($Row.PSObject.Properties['State'] -and (@(Get-WuuTerminalStates) -contains [string]$Row.State)) {
        return @{ Set = $false; Refused = $false; Op = $null; Replaced = $null; Existing = $null; Reason = "the row has settled ('$($Row.State)') - there is no operation for a follow-up to follow" }
    }

    $existing = ''
    if ($Row.PendingOp) { $existing = [string]$Row.PendingOp }

    # An internal follow-up must not displace an operator request (and loses nothing if skipped).
    if ($OnlyIfEmpty -and $existing -ne '') { return $noChange }

    # Same request again: refresh Pending (it may have been cleared) but nothing is replaced.
    if ($existing -ceq $Op) {
        if ($Row.PSObject.Properties['Pending']) { $Row.Pending = $true }
        return @{ Set = $true; Refused = $false; Op = $Op; Replaced = $null; Existing = $existing; Reason = '' }
    }

    # SEMANTIC PRECEDENCE (SS16). A request ranking BELOW what is already queued is DECLINED and the
    # higher request is kept, so the operator never ends up doing less than they asked for. Equal
    # ranks replace - the ambiguity is settled by arrival order, which is the newest-wins behaviour
    # and is why an upgrade below still replaces.
    if ($existing -ne '' -and (Get-WuuPendingOpRank -Op $Op) -lt (Get-WuuPendingOpRank -Op $existing)) {
        return @{ Set = $false; Refused = $true; Op = $null; Replaced = $null; Existing = $existing
            Reason = "'$Op' ranks below the '$existing' already queued for $($Row.Computer) - the queued request is kept, or the computer would do less than was asked of it"
        }
    }

    $Row.PendingOp = $Op
    if ($Row.PSObject.Properties['Pending']) { $Row.Pending = $true }

    $replaced = $null
    if ($existing -ne '') { $replaced = $existing }
    return @{ Set = $true; Refused = $false; Op = $Op; Replaced = $replaced; Existing = $existing; Reason = '' }
}

function Resolve-WuuVersion {
    <#
    .SYNOPSIS
    The ONE authoritative version, with provenance (SS18).
    .DESCRIPTION
    WHY THIS EXISTS. The version is recorded on every audit record, so a wrong value is a provenance
    defect rather than a cosmetic one: a reviewer reading `wuuVersion: v1.5.0-beta.1-cli` on evidence
    produced by beta.2 cannot tell which build made it. That mismatch has already happened once in
    this repository's history, which is why the version is now RESOLVED rather than merely declared.

    PRECEDENCE, and the reason for each step:
      1. `-Override` (an explicit caller value - used by tests, and by anything that needs to pin it)
      2. a real git TAG at HEAD     - provenance for an operator, and it self-corrects on a tag
      3. the value EMBEDDED in source

    A mismatch between (2) and (3) is REPORTED, never silently resolved. Choosing a winner quietly
    would recreate the original bug: the caller would not know the two disagreed. The returned object
    carries `Source` and `Mismatch` so a gate, a test, or a log line can act on the disagreement
    instead of trusting a number.

    A tag is normalised to the version form: `v1.5.0-beta.3-cli` stays as it is, and a tag without
    the leading `v` gains one, so `git describe` and an embedded literal can be compared directly.

    The `git` lookup is BEST-EFFORT and never fatal: a release zip has no `.git` directory, so an
    operator running the packaged build will legitimately fall back to the embedded value with
    `Source='embedded'`. Treating that as an error would make the packaged build refuse to start.

    Pure apart from the read-only git probe, and safe to call from a gate or a test.
    #>
    param(
        [Parameter(Mandatory = $false)][string]$Embedded = '',
        [Parameter(Mandatory = $false)][string]$Override = '',
        [Parameter(Mandatory = $false)][string]$RepoRoot = '',
        [Parameter(Mandatory = $false)][switch]$SkipGit
    )

    $result = [pscustomobject]@{
        Version  = $Embedded
        Source   = 'embedded'
        Tag      = ''
        Mismatch = $false
        Note     = ''
    }

    # 1. explicit override wins outright, and says so.
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $result.Version = $Override.Trim()
        $result.Source = 'override'
        $result.Note = 'version supplied by the caller; provenance is the caller''s responsibility'
        return $result
    }

    # 2. a real tag at HEAD, best-effort. No repo (packaged build) is an expected case, not an error.
    if ($SkipGit -or [string]::IsNullOrWhiteSpace($RepoRoot)) { return $result }

    $tag = ''
    try {
        if (Test-Path (Join-Path $RepoRoot '.git')) {
            $tag = (& git -C $RepoRoot describe --tags --exact-match HEAD 2>$null | Select-Object -First 1)
            if (-not $tag) {
                # Not exactly on a tag - report the last one as context, but do NOT adopt it as the
                # version: a commit between two releases is not that release, and labelling it so would
                # make the audit record claim a release that does not contain the code.
                $nearest = (& git -C $RepoRoot describe --tags --abbrev=0 HEAD 2>$null | Select-Object -First 1)
                if ($nearest) { $result.Note = "HEAD is not on a tag; nearest is $nearest" }
            }
        }
    } catch {
        $tag = ''
    }

    if (-not $tag) { return $result }

    $tag = [string]$tag.Trim()
    $normalised = if ($tag.StartsWith('v')) { $tag } else { "v$tag" }
    $result.Tag = $normalised
    $result.Version = $normalised
    $result.Source = 'tag'

    # 3. report a disagreement rather than hiding it.
    if (-not [string]::IsNullOrWhiteSpace($Embedded) -and $Embedded.Trim() -ne $normalised) {
        $result.Mismatch = $true
        $result.Note = "tag $normalised disagrees with the embedded version $($Embedded.Trim())"
    }
    return $result
}

function Get-WuuTargetOutcome {
    <#
    .SYNOPSIS
    The settled outcome of ONE target, as a single word (SS10).
    .DESCRIPTION
    Returns 'Success', 'Failed', 'TimedOut' or 'Unknown'. This is what makes exit code 4
    (PartialSuccess) producible: without a per-target verdict, "A worked and B failed" is not
    observable anywhere, which is why the code was reserved-but-unused.

    'Unknown' means NOT SETTLED YET - still running, still queued, or never touched. It is
    deliberately distinct from 'Failed': a row that has not been attempted is not a failure, and
    counting it as one would turn an ordinary in-progress run into a partial failure.

    Order matters. Failure is checked BEFORE completion because a row can carry
    `State='Complete'` from an earlier operation while its CURRENT operation errored; the error is
    the outcome, not the stale completion. Timeout is checked before success for the same reason.

    Reads the same two fields the rest of the code uses for settlement - `State` (workflow label)
    and `UpdatesStatus` (classification) - and checks BOTH, because different paths write one or
    the other. That pairing is the same one Test-WuuPhaseFailureBlocks uses, so gating and exit
    classification cannot disagree about what "failed" means.

    Pure, side-effect free, $null-tolerant: called in a loop over every selected target.
    #>
    param([Parameter(Mandatory = $false)][AllowNull()]$Row)

    if ($null -eq $Row) { return 'Unknown' }

    if ($Row.PSObject.Properties['InstallErrors'] -and [int]$Row.InstallErrors -gt 0) {
        return 'Failed'
    }

    $state = ''
    if ($Row.PSObject.Properties['State'] -and $Row.State) { $state = [string]$Row.State }
    $updatesStatus = ''
    if ($Row.PSObject.Properties['UpdatesStatus'] -and $Row.UpdatesStatus) { $updatesStatus = [string]$Row.UpdatesStatus }

    # State-major on purpose: each terminal state is judged across BOTH fields before the next, so a
    # current UpdatesStatus='Error' beats a stale State='Complete'.
    $outcomeMap = Get-WuuTerminalOutcomeMap
    foreach ($terminalState in @($outcomeMap.Keys)) {
        if ($updatesStatus -eq $terminalState -or $state -eq $terminalState) {
            return [string]$outcomeMap[$terminalState]
        }
    }
    return 'Unknown'
}

function Get-WuuAggregateOutcome {
    <#
    .SYNOPSIS
    The outcome across a set of targets, for the exit-code contract (SS10).
    .DESCRIPTION
    Returns 'Success', 'PartialSuccess', 'OperationFailed' or 'Unknown', from the per-target
    verdicts of Get-WuuTargetOutcome.

    THE RULE: unsettled targets are ignored, and a MIX of settled successes and settled failures is
    'PartialSuccess'. That is the only case where 4 is produced, and it is the case the brief asks
    for:

        A = Success, B = Success, C = Failed   ->  PartialSuccess

    Deliberately CONSERVATIVE in the other direction: if every settled target failed the answer is
    'OperationFailed', not partial (there is nothing partly-successful about it), and if nothing has
    settled the answer is 'Unknown' so the caller keeps its existing code rather than inventing a
    verdict from no evidence. An empty set is 'Unknown' for the same reason.

    WHY NOT COUNT UNSETTLED AS FAILURES: a `wuu check -All` still working through a large estate
    would otherwise report PartialSuccess merely because it had not finished. The caller has a
    separate, measured signal for "work is still outstanding" (the bounded wait), and that decision
    stays where it is.

    Pure and side-effect free.
    #>
    param([Parameter(Mandatory = $false)][AllowNull()][object[]]$Rows)

    if ($null -eq $Rows) { return 'Unknown' }
    $settled = @($Rows | ForEach-Object { Get-WuuTargetOutcome -Row $_ } | Where-Object { $_ -ne 'Unknown' })
    if ($settled.Count -eq 0) { return 'Unknown' }

    $ok = @($settled | Where-Object { $_ -eq 'Success' }).Count
    if ($ok -eq $settled.Count) { return 'Success' }
    if ($ok -eq 0) { return 'OperationFailed' }
    return 'PartialSuccess'
}

function Test-WuuConcurrencyAvailable {
    <#
    .SYNOPSIS
    Whether a new operation may be admitted under the global concurrency cap (SS4).
    .DESCRIPTION
    The gate for INVARIANT 8.6. It exists because the cap used to be applied in exactly one place -
    the scheduler tick - while every console handler called the submission point DIRECTLY. So
    `-All check` over a large estate could start an unbounded number of pipelines; the per-computer
    gate bounds each computer to one operation but says nothing about how many computers run at once.

    WHAT THE CAP COUNTS: in-flight operations across the WHOLE estate, i.e. the number of entries in
    `$jobs`. Because invariant 8.1 permits at most one operation per computer, `jobs.Count` is also
    the number of computers currently working - the two readings coincide by construction, not by
    assumption. It is NOT a per-computer bound - that is Test-WuuComputerBusy.

    The worker pool must be at least this cap (probes run on it); that is checked by
    Test-PoolCompatibility, not here, so this function stays free of cross-module coupling.

    FAIL-CLOSED ON A MISSING JOB LIST, and REFUSE AT A NON-POSITIVE CAP. The second of those is
    deliberate consistency, not an oversight: the scheduler has always tested `$jobs.Count -ge
    $MaxConcurrentJobs`, so a cap of 0 refuses everything there. If this function treated 0 as
    "unlimited" the two admission paths would disagree, and which one you hit would decide whether
    the estate ran. A misconfigured cap therefore stops work visibly rather than quietly removing the
    limit - the safe direction for a patching tool (same reasoning as Test-PhaseFailureBlocks).

    Pure, side-effect free and $null-tolerant: called from the submission point and from tests.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()]$Jobs,
        [Parameter(Mandatory = $false)][int]$MaxConcurrentJobs = 0
    )

    if ($null -eq $Jobs) { return $false }
    if ($MaxConcurrentJobs -le 0) { return $false }

    return ([int]$Jobs.Count -lt $MaxConcurrentJobs)
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

# The number of consecutive refusals after which a queued operation is treated as STALLED rather than
# merely waiting. Chosen so a transient condition (a busy estate, a full cap that frees up) has many
# chances to clear - the scheduler ticks about once a second, and a refusal normally clears within one
# or two ticks - while a permanent one (a computer that can never be admitted) surfaces within about
# a minute instead of never.
$script:WuuRefusalStallThreshold = 60

function Update-WuuRefusalRecord {
    <#
    .SYNOPSIS
    Records that a submission was REFUSED, or clears the record when one is admitted (PHASE 5/SS16).
    .DESCRIPTION
    WHY A REFUSAL NEEDS RECORDING AT ALL. Before this, a refused submission returned $false and the
    row kept Pending=$true. Nothing on the row changed, so:
      * the phase gate saw only "Pending" and waited - correctly, for a queue that is moving;
      * nothing distinguished a queue that is moving from a computer that can NEVER be admitted;
      * an operator had no way to tell "waiting its turn" from "stuck", because both look identical.

    THE FAILURE MODE THIS CLOSES is a PERMANENT SILENT STALL: a computer refused every tick (a row
    whose runspace can never be built, a computer that stays busy) keeps the whole phase from
    advancing for ever, with the phase gate reporting nothing and the audit trail recording nothing.

    A refusal is NOT an error. The operation never started, the computer is undamaged, and retrying is
    the right response - which is exactly why it must not be reported as a failure. It is a distinct
    third outcome, and this function is where it is recorded so the gate can act on it without
    conflating it with Error.

    -Admitted clears the record: an operation that got in has made progress, so the consecutive count
    restarts. Only CONSECUTIVE refusals indicate a stall; a refusal interleaved with progress is
    ordinary contention.

    Returns the record so a caller can log it without re-reading the row.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)][AllowNull()]$Row,
        [Parameter(Mandatory=$false)][string]$Reason = '',
        [Parameter(Mandatory=$false)][switch]$Admitted,
        [Parameter(Mandatory=$false)][datetime]$Now = (Get-Date)
    )

    if ($null -eq $Row) { return $null }

    if ($Admitted) {
        if ($Row.PSObject.Properties['RefusedCount'])  { $Row.RefusedCount = 0 }
        if ($Row.PSObject.Properties['RefusedReason']) { $Row.RefusedReason = '' }
        if ($Row.PSObject.Properties['RefusedAt'])     { $Row.RefusedAt = $null }
        return @{ Count = 0; Reason = ''; At = $null; Stalled = $false }
    }

    $count = 0
    if ($Row.PSObject.Properties['RefusedCount']) { $count = [int]$Row.RefusedCount + 1 }
    if ($Row.PSObject.Properties['RefusedCount'])  { $Row.RefusedCount = $count }
    if ($Row.PSObject.Properties['RefusedReason']) { $Row.RefusedReason = $Reason }
    if ($Row.PSObject.Properties['RefusedAt'])     { $Row.RefusedAt = $Now }

    return @{
        Count   = $count
        Reason  = $Reason
        At      = $Now
        Stalled = ($count -ge $script:WuuRefusalStallThreshold)
    }
}

function Get-WuuRefusalStallThreshold {
    <#
    .SYNOPSIS The consecutive-refusal count at which a queued operation is treated as stalled (PHASE 5).
    .DESCRIPTION
    Exposed as a function rather than read as a variable so the value cannot be silently retyped at a
    call site, and so a test can assert the gate and the recorder agree on ONE threshold.
    #>
    [CmdletBinding()]
    param()
    return $script:WuuRefusalStallThreshold
}

function Test-WuuRefusalStalled {
    <#
    .SYNOPSIS Whether a queued row has been refused so many times that it is stalled, not waiting (PHASE 5).
    .DESCRIPTION
    The predicate the phase gate uses. Returns a hashtable rather than a boolean because the caller
    must be able to SAY WHY a phase is blocked - "N consecutive refusals, last reason X" is actionable;
    "the phase did not advance" is not.

    A null or fresh row is never stalled: with no refusal recorded there is no evidence of a stall, and
    treating absent evidence as a stall would block every phase the moment it started.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)][AllowNull()]$Row
    )

    if ($null -eq $Row) { return @{ Stalled = $false; Count = 0; Reason = ''; Threshold = $script:WuuRefusalStallThreshold } }

    $count = 0
    if ($Row.PSObject.Properties['RefusedCount']) { $count = [int]$Row.RefusedCount }
    $reason = ''
    if ($Row.PSObject.Properties['RefusedReason']) { $reason = [string]$Row.RefusedReason }

    return @{
        Stalled   = ($count -ge $script:WuuRefusalStallThreshold)
        Count     = $count
        Reason    = $reason
        Threshold = $script:WuuRefusalStallThreshold
    }
}

function Set-WuuPhaseFailurePolicy {    <#
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
    # SS7: the pending-request policy. Exported because the OPERATOR-facing handlers (Wuu.Core) own
    # the reporting of a replacement, while the policy itself must live in one place; and because
    # the payloads inline the -OnlyIfEmpty half, which tests assert against this function.
    'Set-WuuPendingOperation'
    # SS16: the semantic precedence that policy consults. Exported so a caller can explain a decision
    # ("that ranks below what is already queued") without restating the table, and so the gate and the
    # tests can drive the ordering rather than matching it as text.
    'Get-WuuPendingOpRank'
    # SS18: the authoritative version. Exported so the release gate can assert tag == embedded ==
    # package, and so a test can drive the precedence without starting the application.
    'Resolve-WuuVersion'
    # SS10: per-target and aggregate outcomes. Exported because the exit-code decision lives in
    # Wuu.Core (command mode) and the classification must be one rule, not two.
    'Get-WuuTargetOutcome'
    'Get-WuuAggregateOutcome'
    # 8.4: the single terminal-state declaration, read by the guard, the classifier, the gate and tests.
    'Get-WuuTerminalStates'
    'Get-WuuTerminalOutcomeMap'
    'Test-WuuTerminalState'
    'Test-WuuTerminalStateInvariant'
    # SS4: the global concurrency cap. Exported because it is consulted at the SUBMISSION POINT
    # (Wuu.WindowsUpdate) and in the scheduler tick, and both must agree on what the cap means.
    'Test-WuuConcurrencyAvailable'
    # SS2/SS3: operation identity. Exported because the id is CREATED at the submission point
    # (Wuu.WindowsUpdate), ENFORCED in the cleanup loop (Wuu.Core) and in the row-writers injected
    # into worker runspaces, and asserted by tests - four places that must agree on the same rule.
    'New-WuuOperationId'
    'Test-WuuOperationCurrent'
    'Test-WuuStaleWrite'
    # SS16: the single state-mutation funnel. Exported because mutation happens from the main session
    # (Wuu.Core handlers, the cleanup loop) and must be reachable wherever a row is written.
    'Update-WuuOperationState'
    'Test-WuuStateTransitionAllowed'
    'Test-WuuOperationStateInvariant'
    'Get-WuuStateStatusText'
    # SS4: the submission critical section. Exported because the reservation happens in
    # Wuu.WindowsUpdate (the single submission point) while the gate object lives here with the rest of
    # the state contract, and a test must be able to drive the exclusion directly.
    'Enter-WuuSubmissionLock'
    'Exit-WuuSubmissionLock'
    'Test-WuuSubmissionLockHeld'
    # PHASE 5: refusal semantics. Exported because the RECORDING happens at the submission point
    # (Wuu.WindowsUpdate) and the DECISION happens in the phase gate (the same module), and a test must
    # be able to drive both without a store or a network.
    'Update-WuuRefusalRecord'
    'Test-WuuRefusalStalled'
    'Get-WuuRefusalStallThreshold'
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
    # P3: REMAINING-BUDGET PROPAGATION. Exported because the inner probes that need capping live in
    # payload scriptblocks, and the rule has to be applied at each call site - one place for the rule,
    # many places that ask for it.
    'Get-WuuOperationRemainingSeconds'
    'Get-WuuEffectiveInnerTimeout'
    'New-WuuOperatorContext'
    'New-WuuResetOperationContext'
)
