# Wuu.Scheduler - worker-runspace construction for the scheduling and cleanup machinery.
#
# WHY THIS MODULE EXISTS. A worker runspace is ISOLATED: an injected scriptblock cannot resolve a module
# function, cannot see a sibling module's variables, and cannot be written as a literal `{ }` (a literal
# captures the defining session state and sees nothing from SetVariable). Every helper a payload needs
# must therefore be built as a STRING and SetVariable'd in. That set IS the worker's capability surface,
# so it must be assembled in one place rather than copied per call site - a copy makes agreement a
# discipline instead of a construction guarantee.
#
# SCOPE: this module owns HOW a worker runspace is wired and the scheduler tick / admission queueing.

$script:WuuSchedulerCtx = $null

function Initialize-WuuSchedulerContext {
    param([Parameter(Mandatory)][hashtable]$Context)
    $script:WuuSchedulerCtx = $Context
}

function Add-WuuWorkerHelper {
    <#
    .SYNOPSIS
    Wires the standard helper set into a worker runspace's session state.
    .DESCRIPTION
    The single place the worker capability surface is declared, so "what can a payload call?" is
    answerable by reading one function instead of searching call sites in two modules.

    $StateStore is injected as $stateStore, $LogPath/$LogLock as themselves, and the log appender via
    Get-WuuWorkerLogAppender. A $null store is tolerated: the appender and the store-touching helpers
    check it, because the cleanup runspace can exist before a store does.

    Deliberately does NOT inject the row-writers, the credential helpers or Invoke-RemoteTask - those are
    per-computer capability (a worker may only write for the computer it was built for) and live with
    New-ComputerRunspace, which owns that distinction.

    Returns the number of helpers wired, so a caller (or a test) can assert the surface is not silently
    empty.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SessionState,
        [Parameter(Mandatory = $false)][AllowNull()]$StateStore = $null,
        [Parameter(Mandatory = $false)][AllowNull()]$LogPath = $null,
        [Parameter(Mandatory = $false)][AllowNull()]$LogLock = $null,
        [Parameter(Mandatory = $false)][AllowNull()]$BackgroundProcessing = $null,
        # Extra helpers a specific caller needs, as @{ Name = value }. Kept explicit so the standard
        # set above stays the same for every worker.
        [Parameter(Mandatory = $false)][AllowNull()][hashtable]$Extra = $null
    )

    $wired = 0
    $SessionState.SetVariable('stateStore', $StateStore)
    $wired++
    $SessionState.SetVariable('LogPath', $LogPath)
    $wired++
    $SessionState.SetVariable('LogLock', $LogLock)
    $wired++
    $SessionState.SetVariable('WriteLogFileScript', (Get-WuuWorkerLogAppender))
    $wired++

    if ($null -ne $BackgroundProcessing) {
        # The cleanup loop checks $backgroundProcessing.Suspended every pass; a payload does not need it,
        # so it is only wired when supplied rather than defaulted to something inert.
        $SessionState.SetVariable('backgroundProcessing', $BackgroundProcessing)
        $wired++
    }

    if ($Extra) {
        foreach ($k in $Extra.Keys) {
            $SessionState.SetVariable([string]$k, $Extra[$k])
            $wired++
        }
    }

    return $wired
}

function Test-WuuWorkerHelperSurface {
    <#
    .SYNOPSIS
    Reports which standard worker helpers a runspace actually exposes (P2 verification).
    .DESCRIPTION
    Injected scriptblocks are readable from an IDLE runspace via SessionStateProxy.GetVariable, so the
    capability surface is INSPECTABLE rather than assumed. That matters because a helper that failed to
    inject is silent: the payload simply reports "cannot call a method on a null-valued expression" much
    later, or writes nothing at all.

    A BUSY runspace refuses these calls ("A pipeline is already running"), which is reported as Busy
    rather than as missing - conflating the two would make an in-flight worker look broken.

    Returns @{ Busy; Present; Missing } - never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()]$Runspace = $null
    )

    $required = @('stateStore', 'LogPath', 'LogLock', 'WriteLogFileScript')
    if ($null -eq $Runspace) {
        return @{ Busy = $false; Present = @(); Missing = $required; Note = 'no runspace supplied' }
    }

    $present = @()
    $missing = @()
    foreach ($name in $required) {
        try {
            $v = $Runspace.SessionStateProxy.GetVariable($name)
        } catch {
            # A BUSY runspace refuses the call. Reported as Busy, not as missing - conflating the two
            # would make an in-flight worker look broken.
            return @{ Busy = $true; Present = $present; Missing = $missing; Note = $_.Exception.Message }
        }

        if ($null -ne $v) {
            $present += $name
        } else {
            # GetVariable returns $null for BOTH "absent" and "defined but null", so the distinction has
            # to be made inside the runspace. A null $stateStore is legitimate (the cleanup runspace can
            # start before a store exists); an absent one is a broken worker. An earlier version called
            # this helper only as a fallback for the null case and asked the OUTER session whether the
            # variable existed, which can never see the worker's own variables - so it reported a
            # correctly-wired null store as MISSING.
            $state = Test-WuuWorkerVariableState -Runspace $Runspace -Name $name
            if ($state -eq 'DEFINED') { $present += $name } else { $missing += $name }
        }
    }

    return @{ Busy = $false; Present = $present; Missing = $missing; Note = '' }
}

function Test-WuuWorkerVariableDefined {
    <#
    .SYNOPSIS Whether a name is DEFINED in a runspace, distinguishing "absent" from "null" (P2).
    .DESCRIPTION
    SessionStateProxy.GetVariable returns $null for both an undefined name and a defined-but-null one.
    The two mean different things here - a worker with a null $stateStore is correctly wired, a worker
    with no $stateStore at all is broken - so the distinction has to be made explicitly.

    Delegates to Test-WuuWorkerVariableState so there is ONE implementation of the probe.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Runspace,
        [Parameter(Mandatory)][string]$Name
    )

    return ((Test-WuuWorkerVariableState -Runspace $Runspace -Name $Name) -eq 'DEFINED')
}

function Test-WuuWorkerVariableState {
    <#
    .SYNOPSIS Returns 'DEFINED', 'ABSENT' or 'BUSY' for a variable in a worker runspace (P2).
    .DESCRIPTION
    Runs the probe INSIDE the target runspace, which is the only place the answer exists: an outer
    session cannot see a worker's variables, so asking from outside (an earlier version did) can never
    distinguish a wired-but-null variable from an absent one and reports both as missing.

    'BUSY' is separate from 'ABSENT' on purpose: a runspace running a pipeline refuses the probe, and
    reporting that as absent would make an in-flight worker look broken - exactly when an operator is
    most likely to be inspecting it.

    Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Runspace,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Runspace) { return 'ABSENT' }

    # A BUSY runspace refuses concurrent SessionStateProxy calls, so the state is checked first rather
    # than relying on the probe to fail cleanly.
    try {
        $state = $Runspace.RunspaceStateInfo.State
        if ($state -ne 'Opened') { return 'BUSY' }
    } catch {
        return 'ABSENT'
    }

    $probe = [powershell]::Create()
    try {
        $probe.Runspace = $Runspace
        $null = $probe.AddScript('param($n) if (Get-Variable -Name $n -ErrorAction SilentlyContinue) { "DEFINED" } else { "ABSENT" }').AddArgument($Name)
        $res = @($probe.Invoke())
        $text = ($res -join '').Trim()
        if ($text -eq 'DEFINED' -or $text -eq 'ABSENT') { return $text }
        return 'ABSENT'
    } catch {
        return 'BUSY'
    } finally {
        try { $probe.Dispose() } catch { }
    }
}

function Start-PendingUpdateCheck {
    <#
    .SYNOPSIS The scheduler tick: promotes due retries and starts queued operations.
    .DESCRIPTION
    Reads the queue from the STATE STORE, not from a GUI control.

    This function previously iterated `$uiHash.Listview.Items`. In this edition the store is the only
    render source, and $uiHash has been REMOVED entirely (it was created, passed around and injected
    while nothing read it - see Wuu.Core's Synchronized collections region).
    and NOTHING in src/ ever assigns a ListView to it - the only assignments in the repository are in
    tests, which hand-built a fake one. So `@($null)` was empty on every tick and this function did
    NOTHING in production. Consequences, all silent:

      * an operation queued by the auto-download / auto-install chain (Pending=$true, PendingOp set)
        was never started - the automatic behaviours could not work even once the settings gates
        were corrected, because nothing consumed what they queued;
      * Phase-E retries (RetryAt) were never promoted, so a timed-out computer never retried;
      * phase gating never applied to queued items.

    That is why Test-PendingDrain could pass for two releases while the queue was dead: it built the
    very object the production code was missing. The test now populates the store instead.

    Get-WuuComputerRow is an exported Wuu.State function; all modules are imported -Global, so it
    resolves here at call time (the same cross-module visibility Test-PendingDrain asserts).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][hashtable]$Context = $null
    )
    $ctx = if ($Context) { $Context } elseif ($script:WuuSchedulerCtx) { $script:WuuSchedulerCtx } else { $global:WuuCtx }
    if (-not $ctx) { return }
    $backgroundProcessing = $ctx.BackgroundProcessing
    $jobs = $ctx.Jobs; $MaxConcurrentJobs = $ctx.MaxConcurrentJobs
    $store = $ctx.StateStore
    if ($backgroundProcessing -and $backgroundProcessing.Suspended) { return }
    if (-not $store) { return }   # no store = nothing to schedule; never fatal on a timer tick

    # Promote due Phase-E timeout retries (RetryAt set by $GetUpdates) back into the pending queue
    $now = [DateTime]::Now
    $rows = @(Get-WuuComputerRow -Store $store)
    foreach ($item in $rows) {
        if ($item.PSObject.Properties['RetryAt'] -and $item.RetryAt -and $item.RetryAt -le $now) {
            $item.RetryAt = $null
            $item.Pending = $true
        }
    }
    $pendingItems = @($rows | Where-Object { $_.Pending })
    foreach ($item in $pendingItems) {
        if ($jobs.Count -ge $MaxConcurrentJobs) { break }
        # ONE OPERATION PER COMPUTER: if this row already has an operation in flight, leave it
        # Pending and try again on the next tick. -IgnorePending because this function IS the
        # consumer of the Pending flag: treating it as "busy" here would make the scheduler skip
        # every row it was handed, for ever.
        # The check must come BEFORE $item.Pending is cleared, or a refusal would lose the request.
        if (Test-WuuComputerBusy -Row $item -IgnorePending) { continue }
        if (-not (Test-PhaseReady -Phase $item.Phase)) {
            if ($item.Status -notlike 'Waiting for previous phase*') {
                # STATE-RESET-OP-01: Phase-wait bookkeeping parking a pending row while previous
                # phase finishes. Uses ResetOperation to safely park in State='Queued' via funnel.
                $resetCtx = New-WuuResetOperationContext -Source 'PhaseWaitBookkeeping' `
                    -Reason "Waiting for previous phase to complete. Current phase: $($item.Phase)" `
                    -Actor 'Scheduler'
                $null = Update-WuuOperationState -Row $item -ResetOperation $resetCtx `
                    -State 'Queued' -ColorFromState `
                    -Status "Waiting for previous phase to complete. Current phase: $($item.Phase)" `
                    -Touch -Store $store
            }
            continue
        }
        $item.Pending = $false
        # Consume and clear any queued follow-up op so this item starts the right chain. The clear goes
        # through the mutation funnel (SS16) rather than assigning the property: the scheduler is the
        # CONSUMER of the slot, and PendingOp is operation state, so the write belongs to Wuu.State.
        # Unattributed on purpose - the scheduler is not a worker and holds no operation id, which
        # Test-WuuStaleWrite permits (a write is refused only when PROVEN stale).
        $op = 'Check'
        if ($item.PSObject.Properties['PendingOp'] -and $item.PendingOp) {
            $op = $item.PendingOp
            [void](Update-WuuOperationState -Row $item -ClearPendingOp)
        }
        [void](Start-UpdateCheckJob -ComputerItem $item -Op $op)
    }
}

Export-ModuleMember -Function @(
    'Get-WuuWorkerLogAppender'
    'Add-WuuWorkerHelper'
    'Test-WuuWorkerHelperSurface'
    'Test-WuuWorkerVariableDefined'
    'Test-WuuWorkerVariableState'
    'Initialize-WuuSchedulerContext'
    'Start-PendingUpdateCheck'
)
