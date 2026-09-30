# Wuu.Scheduler - worker-runspace construction for the scheduling and cleanup machinery.
#
# WHY THIS MODULE EXISTS
# ----------------------
# Worker runspaces are ISOLATED: an injected scriptblock cannot resolve a module function, cannot see a
# sibling module's variables, and cannot be written as a literal `{ }` (a literal captures the defining
# session state and sees nothing from SetVariable). So every helper a payload needs must be built as a
# STRING and SetVariable'd in.
#
# That constraint caused two problems this module fixes:
#
#   1. DUPLICATION. The fault-tolerant log appender - the one helper every payload and the cleanup loop
#      needs - was written TWICE, once in Wuu.Core for the cleanup runspace and once in Wuu.WindowsUpdate
#      for each per-computer runspace. The two copies were byte-identical after whitespace normalisation
#      (verified), and each carried a comment telling the reader to keep them in sync. They are now built
#      by ONE factory, so agreement is a construction guarantee rather than a discipline.
#
#   2. NO SINGLE PLACE TO REVIEW. The set of helpers a worker receives is the worker's actual capability
#      surface. Reading it required searching two modules at call sites. It is now one function.
#
# SCOPE: this module owns HOW a worker runspace is wired - the injected helper set and the log appender
# they share. It deliberately does NOT own WHEN work is submitted or how capacity is decided: that is the
# submission point (Wuu.WindowsUpdate) and the concurrency contract (Wuu.State). Extracting the 349-line
# Start-UpdateCheckJob was considered and rejected for this slice - it holds the credential epoch, the
# pipeline composition and the reservation, and moving it would make this change far larger than the
# dedupe it exists to perform.

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

Export-ModuleMember -Function @(
    'Get-WuuWorkerLogAppender'
    'Add-WuuWorkerHelper'
    'Test-WuuWorkerHelperSurface'
    'Test-WuuWorkerVariableDefined'
    'Test-WuuWorkerVariableState'
)
