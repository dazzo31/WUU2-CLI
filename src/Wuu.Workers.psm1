#Requires -Version 5.1
<#
.DESCRIPTION
Bounded remote operations executed on a module-scoped runspace pool.

Replaces the per-call create/wait/receive/destroy pattern:
    $job = Start-Job ... ; Wait-Job -Timeout ... ; Receive-Job ... ; Remove-Job ...
which spawns a full child PowerShell process (its own runspace, profile-less
but heavyweight) for EVERY bounded probe. The pool pays that cost once: worker
runspaces are created lazily on first use and reused across operations.

Threading model mirrors New-ComputerRunspace (Wuu.WindowsUpdate.psm1):
    InitialSessionState::CreateDefault(), STA, UseNewThread.

All public helpers return @{ Success = <bool>; Result = <object>; Error = <string> }.
Result/Error may be $null when Success is $true/$false respectively - callers
already follow this convention (see Invoke-CimWithTimeout callers).

PowerShell 5.1 compatibility notes:
- No ForEach-Object -Parallel (PS7+). Pools + BeginInvoke/EndInvoke only.
- RunspacePool max is clamped by MAX_POOL_SIZE; PS 5.1 has no MinRunspaces=0
  lazy option, so MinRunspaces=2 keeps cold-start cost bounded.

IMPORTANT: never route Windows Update COM (WUA) objects through this pool.
Those objects carry live COM interfaces that cannot cross runspace/process
boundaries - WUA work stays in the per-computer runspaces in
Wuu.WindowsUpdate.psm1 (see the Start-Job note at Wuu.Core.psm1 ~line 1749).
This pool is for bounded remote WMI/CIM/service/ping/network operations only.
#>

# --- Pool configuration -----------------------------------------------------
# INVARIANT: MaxPoolSize >= $MaxConcurrentJobs (Wuu.Core). Bounded probes run on this pool from inside the
# admitted workers, so a smaller pool leaves admitted operations with probes that never start - silently,
# presenting as slow hosts. Equal is enough: a job's probes are sequential. Raise both together.
# Enforced by Test-PoolCompatibility and gate block (ax). The pool is created lazily on first use.
[int]$script:MaxPoolSize = 10
[int]$script:MinPoolSize = 2

# --- Pool state (module scope) ----------------------------------------------
$script:WorkerPool = $null
# Abandoned wrappers from uninterruptible-timeout paths (see Invoke-WithPoolTimeout).
# Kept referenced so the GC finalizer - which calls Stop() and could block a
# finalizer thread - never runs while a pipeline is still stuck.
$script:Abandoned = $null

function Initialize-WuuWorkerPool {
    <#
    .SYNOPSIS
    Creates the module-scoped runspace pool. Idempotent: an open pool is reused.
    #>
    if ($script:WorkerPool -and $script:WorkerPool.RunspacePoolStateInfo.State -eq 'Opened') {
        return $script:WorkerPool
    }
    if ($script:WorkerPool) {
        # Previous pool exists but is broken/closed - discard and rebuild
        try { $script:WorkerPool.Dispose() } catch { }
    }

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
    # PS 5.1 has no (min, max, ISS) overload; the verified working recipe is
    # the 4-arg overload with the LIVE $host (probed 2026-09-21: null host is
    # rejected, InitialSessionState property is read-only after construction).
    $pool = [runspacefactory]::CreateRunspacePool($script:MinPoolSize, $script:MaxPoolSize, $iss, $host)
    $pool.ApartmentState = 'STA'
    $pool.Open()
    $script:WorkerPool = $pool
    return $pool
}

function Get-WuuWorkerPoolCapacity {
    <#
    .SYNOPSIS The pool's configured min/max worker counts (P3).
    .DESCRIPTION
    Exposed so a consumer can compare the pool against $MaxConcurrentJobs without reading module-scoped
    variables it cannot see (session-state isolation hides a sibling module's $script: values).
    #>
    [CmdletBinding()]
    param()
    return @{ Min = [int]$script:MinPoolSize; Max = [int]$script:MaxPoolSize }
}

function Get-WuuWorkerPoolDiagnostics {
    <#
    .SYNOPSIS
    The pool's live state: capacity, utilisation, and abandoned wrappers (reviewer P3).
    .DESCRIPTION
    WHY THIS IS NEEDED, AND WHY IT IS NOT DECORATION. The pool is a HARD CAP on concurrent bounded probes
    (WMI/CIM/service/ping). When it saturates, probes queue - and a queued probe looks exactly like a SLOW
    host from the caller's side. Two of the failure modes an operator actually hits are invisible without
    this:
      * POOL EXHAUSTION - every worker waiting on a probe that cannot start, with no error anywhere.
      * ABANDONED WRAPPERS - a probe whose DCOM/RPC call would not abort is deliberately left running
        (disposing it could block a finalizer thread). Each one permanently removes a pool slot until the
        stuck call returns. Sustained abandonment walks capacity to zero, which then presents as "every
        host is slow" rather than as the pool running out.

    Reported as a flat, ordered set of values because the consumers are a status line and a gate, not a
    human reading prose. Fields:
      Available      the pool object exists and is Open
      State          the RunspacePoolStateInfo state name, or 'NotCreated'
      Min / Max      configured capacity
      Capacity       alias for Max, so a consumer has one obvious name for "how many can run"
      Abandoned      wrappers deliberately left running (each holds a slot until its call returns)
      AbandonedLimit the cap on retained references (see Invoke-WithPoolTimeout)
      Utilisation    Max/Abandoned expressed as a readable ratio, e.g. '2/8'
      Note           '' unless the pool is unusable, in which case why

    Read-only and never throws: it is called from a status render and from a release gate, and neither
    may fail because the pool is in a strange state - that is exactly when it is consulted.
    #>
    [CmdletBinding()]
    param()

    $state = 'NotCreated'
    $created = $false
    try {
        if ($script:WorkerPool) {
            $created = $true
            $state = [string]$script:WorkerPool.RunspacePoolStateInfo.State
        }
    } catch {
        $state = 'Unknown'
    }

    $abandoned = 0
    try {
        if ($script:Abandoned) { $abandoned = [int]$script:Abandoned.Count }
    } catch {
        $abandoned = -1   # -1 = could not be determined, deliberately distinct from 0 = none
    }

    $note = ''
    if (-not $created) { $note = 'pool not created yet (created lazily on first bounded probe)' }
    elseif ($state -ne 'Opened') { $note = "pool is not Open (state '$state') - probes will be attempted without pooling" }

    # ActivePoolWorkers is the number of slots currently in use. It is derived, not measured: the pool
    # exposes no per-slot occupancy on PS 5.1, so the honest value is Abandoned (slots provably held by
    # stuck calls) plus a lower bound of zero for slots whose status cannot be read. Reported as $null
    # rather than 0 when it cannot be determined - 0 means "none in use", which would be a claim.
    $active = if ($abandoned -ge 0) { $abandoned } else { $null }

    return [ordered]@{
        Available      = ($created -and $state -eq 'Opened')
        State          = $state
        Min            = [int]$script:MinPoolSize
        Max            = [int]$script:MaxPoolSize
        Capacity       = [int]$script:MaxPoolSize
        Abandoned      = $abandoned
        AbandonedLimit = 32
        Utilisation    = ("{0}/{1}" -f $abandoned, [int]$script:MaxPoolSize)
        # The reviewer's field names, kept verbatim so a consumer written against them works.
        ActivePoolWorkers = $active
        AbandonedWorkers  = $abandoned
        PoolCapacity      = [int]$script:MaxPoolSize
        PoolUtilisation   = ("{0}/{1}" -f $abandoned, [int]$script:MaxPoolSize)
        Note           = $note
    }
}

function Test-WuuWorkerPoolStarved {
    <#
    .SYNOPSIS
    Whether the pool's abandoned wrappers are consuming a significant share of capacity (P3).
    .DESCRIPTION
    Returns @{ Starved; Abandoned; Capacity; Threshold; Reason }. Starved when abandoned wrappers reach
    the threshold - meaning most of the pool is held by calls that would not abort, and new probes are
    competing for the remainder.

    The threshold is a SHARE of capacity rather than an absolute count, because an absolute number cannot
    stay right when $MaxPoolSize changes: 4 abandoned wrappers is half of 8 and a twentieth of 80.

    Never throws and treats an undeterminable count as NOT starved - an unknown cannot be evidence of a
    problem, and reporting one would make the advisory fire on every run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][double]$ThresholdFraction = 0.5
    )

    $diag = Get-WuuWorkerPoolDiagnostics
    $capacity = [int]$diag.Capacity
    $abandoned = [int]$diag.Abandoned
    $threshold = if ($capacity -gt 0) { [int][math]::Ceiling($capacity * $ThresholdFraction) } else { 0 }

    $starved = ($abandoned -ge 0) -and ($capacity -gt 0) -and ($abandoned -ge $threshold)

    return @{
        Starved   = $starved
        Abandoned = $abandoned
        Capacity  = $capacity
        Threshold = $threshold
        Reason    = if ($starved) { "$abandoned of $capacity pool slots are held by abandoned wrappers (threshold $threshold)" } else { '' }
    }
}

function Test-PoolCompatibility {
    <#
    .SYNOPSIS
    Whether the pool can run every operation the concurrency cap admits (pool size >= cap).
    .DESCRIPTION
    Returns @{ Compatible; PoolSize; MaxConcurrentJobs; Unnecessary; Reason }. A larger pool is reported
    as Unnecessary, not incompatible. An unknown cap (<= 0) is never compatible. Takes the cap as a
    parameter so this module does not couple to Wuu.Core. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][int]$MaxConcurrentJobs = 0
    )

    $capacity = [int]$script:MaxPoolSize
    $compatible = ($MaxConcurrentJobs -gt 0) -and ($capacity -ge $MaxConcurrentJobs)

    return @{
        Compatible        = $compatible
        PoolSize          = $capacity
        MaxConcurrentJobs = $MaxConcurrentJobs
        Unnecessary       = ($MaxConcurrentJobs -gt 0) -and ($capacity -gt $MaxConcurrentJobs)
        Reason            = if ($MaxConcurrentJobs -le 0) {
            'no concurrency cap was supplied, so compatibility cannot be judged'
        } elseif ($compatible) {
            "the pool ($capacity) can run every operation the cap ($MaxConcurrentJobs) admits"
        } else {
            "the pool is SMALLER than the concurrency cap by $($MaxConcurrentJobs - $capacity): $($MaxConcurrentJobs - $capacity) admitted operation(s) would have probes that can never start, counted as running with no refusal and no error - they present as slow hosts"
        }
    }
}

function Get-WuuWorkerPool {
    <#
    .SYNOPSIS
    Returns the module-scoped pool, creating it on first use.
    #>
    if (-not $script:WorkerPool -or $script:WorkerPool.RunspacePoolStateInfo.State -ne 'Opened') {
        return (Initialize-WuuWorkerPool)
    }
    return $script:WorkerPool
}

function Invoke-WithPoolTimeout {
    <#
    .SYNOPSIS
    Executes a scriptblock on the shared worker pool with a hard timeout.
    .DESCRIPTION
    The pool equivalent of the Start-Job/Wait-Job/Receive-Job/Remove-Job dance.
    Returns @{ Success; Result; Error }. On timeout the PowerShell instance is
    stopped (the runspace survives and returns to the pool - its pipeline is
    aborted, which is the same guarantee Remove-Job -Force gave us).
    .NOTES
    A pooled runspace keeps session state between invocations. That means
    variables leaked by an earlier ScriptBlock (e.g. $cimSession from a CIM
    probe) PERSIST in that runspace until it is disposed. The ScriptBlocks
    passed here must therefore be self-cleaning: create resources in try/finally
    with Remove-* / Dispose calls (the existing helpers already do this - see
    Invoke-CimWithTimeout's finally { Remove-CimSession }).
    #>
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory=$false)]
        [object]$ArgumentList = $null,

        [Parameter(Mandatory=$false)]
        [int]$TimeoutSeconds = 300,

        [Parameter(Mandatory=$false)]
        [string]$OperationName = 'Pooled operation'
    )

    $ps = $null
    $abandoned = $false
    try {
        $pool = Get-WuuWorkerPool
        $ps = [powershell]::Create()
        # CRITICAL: bind the instance to the pool BEFORE BeginInvoke - without
        # this line it spins up its own private runspace and the pool silently
        # does nothing.
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($ScriptBlock)
        if ($null -ne $ArgumentList) {
            # Positional binding, mirroring Start-Job -ArgumentList semantics:
            # array -> one parameter per element; scalar -> single parameter.
            $argItems = if ($ArgumentList -is [array]) { $ArgumentList } else { @($ArgumentList) }
            foreach ($arg in $argItems) { [void]$ps.AddArgument($arg) }
        }

        $handle = $ps.BeginInvoke()

        $completed = $handle.AsyncWaitHandle.WaitOne([System.TimeSpan]::FromSeconds($TimeoutSeconds))
        if ($completed) {
            $result = $ps.EndInvoke($handle)
            # PSDataCollection flattening: 0 -> $null, 1 -> the item, N -> keep collection
            $resultValue = if ($result.Count -eq 1) { $result[0] } elseif ($result.Count -eq 0) { $null } else { $result }
            return @{ Success = $true; Result = $resultValue; Error = $null }
        }

        # Hard timeout. The old Start-Job pattern killed the whole child process
        # (Remove-Job -Force) - instant, guaranteed reclamation. In-process we
        # cannot kill a thread, so: request a bounded stop, and if the pipeline
        # refuses to abort (black-holed DCOM/RPC call), ABANDON the wrapper
        # instead of blocking. The caller still gets its timeout error exactly
        # as before; the busy runspace frees itself whenever the OS call returns
        # and pool capacity shrinks by one in the meantime (8 >> 0, graceful).
        $stopHandle = $ps.BeginStop($null, $null)
        if ($stopHandle.AsyncWaitHandle.WaitOne([System.TimeSpan]::FromSeconds(10))) {
            try { $ps.EndStop($stopHandle) } catch { }
        } else {
            $abandoned = $true
            if (-not $script:Abandoned) { $script:Abandoned = [System.Collections.Generic.List[object]]::new() }
            $script:Abandoned.Add($ps)
            if ($script:Abandoned.Count -gt 32) { $script:Abandoned.RemoveAt(0) }
        }
        return @{ Success = $false; Result = $null; Error = "$OperationName timed out after $TimeoutSeconds seconds" }
    } catch {
        return @{ Success = $false; Result = $null; Error = "$OperationName error: $($_.Exception.Message)" }
    } finally {
        # Disposing a still-running instance calls Stop() synchronously - the
        # exact block we must avoid - so never dispose an abandoned wrapper.
        if ($ps -and -not $abandoned) { $ps.Dispose() }
    }
}

function Close-WuuWorkerPool {
    <#
    .SYNOPSIS
    Tears down the pool (app shutdown / tests). Safe to call repeatedly.
    #>
    if ($script:WorkerPool) {
        try {
            if ($script:WorkerPool.RunspacePoolStateInfo.State -eq 'Opened') {
                $script:WorkerPool.Close()
            }
            $script:WorkerPool.Dispose()
        } catch { }
        $script:WorkerPool = $null
    }
}

function New-PooledInvokeScript {
    <#
    .SYNOPSIS
    Returns an unbound scriptblock for injection into isolated per-computer
    runspaces (New-ComputerRunspace), mirroring Invoke-WithPoolTimeout.
    .DESCRIPTION
    Isolated runspaces have default session state - they cannot resolve this
    module's functions ("command not found"). Inject this script and the pool
    OBJECT (as $WuuWorkerPool) via SessionStateProxy.SetVariable, then call:
        & $InvokePooledScript -Pool $WuuWorkerPool -ScriptBlock {...} `
            -ArgumentList @($ComputerName) -TimeoutSeconds 5 -OperationName '...'
    Returns @{ Success; Result; Error } identical to Invoke-WithPoolTimeout.
    #>
    return [scriptblock]::Create(@'
param($Pool, $ScriptBlock, $ArgumentList, $TimeoutSeconds, $OperationName)
$ps = $null
$abandoned = $false
try {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $Pool
    [void]$ps.AddScript($ScriptBlock)
    if ($null -ne $ArgumentList) {
        $argItems = if ($ArgumentList -is [array]) { $ArgumentList } else { @($ArgumentList) }
        foreach ($arg in $argItems) { [void]$ps.AddArgument($arg) }
    }
    $handle = $ps.BeginInvoke()
    if ($handle.AsyncWaitHandle.WaitOne([System.TimeSpan]::FromSeconds($TimeoutSeconds))) {
        $result = $ps.EndInvoke($handle)
        $resultValue = if ($result.Count -eq 1) { $result[0] } elseif ($result.Count -eq 0) { $null } else { $result }
        return @{ Success = $true; Result = $resultValue; Error = $null }
    }
    $stopHandle = $ps.BeginStop($null, $null)
    if ($stopHandle.AsyncWaitHandle.WaitOne([System.TimeSpan]::FromSeconds(10))) {
        try { $ps.EndStop($stopHandle) } catch { }
    } else {
        # Uninterruptible native call: abandon the wrapper; keep a reference
        # per-runspace so the GC finalizer never blocks on Stop().
        $abandoned = $true
        $script:AbandonedPoolWrappers = @($script:AbandonedPoolWrappers) + @($ps)
        if ($script:AbandonedPoolWrappers.Count -gt 32) {
            $script:AbandonedPoolWrappers = $script:AbandonedPoolWrappers[-32..-1]
        }
    }
    return @{ Success = $false; Result = $null; Error = "$OperationName timed out after $TimeoutSeconds seconds" }
} catch {
    return @{ Success = $false; Result = $null; Error = "$OperationName error: $($_.Exception.Message)" }
} finally {
    if ($ps -and -not $abandoned) { $ps.Dispose() }
}
'@)
}

function Test-WuuWorkerPool {
    <#
    .SYNOPSIS
    Self-check: verifies bounded success AND bounded timeout. Returns $true
    when both behave. Used by tests/Test-WorkerPool.ps1 and Validate-Release.
    #>
    try {
        $ok = Invoke-WithPoolTimeout -ScriptBlock { param($n) Start-Sleep -Milliseconds 200; "ok-$n" } `
            -ArgumentList 42 -TimeoutSeconds 10 -OperationName 'Pool self-check'
        if (-not $ok.Success -or $ok.Result -ne 'ok-42') { return $false }

        $slow = Invoke-WithPoolTimeout -ScriptBlock { Start-Sleep -Seconds 30 } `
            -TimeoutSeconds 1 -OperationName 'Pool timeout-check'
        if ($slow.Success) { return $false }
        if ($slow.Error -notlike '*timed out*') { return $false }
        return $true
    } catch {
        return $false
    }
}

function Get-WuuJobCleanupPayload {
    <#
    .SYNOPSIS The background job-cleanup loop body, run in its own runspace by WUU.ps1 startup.
    .DESCRIPTION
    Extracted from Wuu.Core (instructions SS8; SS7 places worker cleanup in Wuu.Workers).

    THE PAYLOAD CONTRACT IS WHY THIS CAN LIVE IN A MODULE. The body is handed to
    [PowerShell]::Create().AddScript() in a runspace whose InitialSessionState is CreateDefault(),
    so the module is NOT imported there and no module function is callable - which is why the rest
    of this file's worker logic is duplicated or inlined rather than shared. This body happens to
    satisfy that contract: it reads ONLY variables injected with SessionStateProxy.SetVariable
    (jobCleanup, jobs, stateStore, LogPath, LogLock, backgroundProcessing,
    OperationTimeoutSeconds, OperationHeartbeatSeconds, WriteLogFileScript) and calls only the
    built-in Get-Date, Out-Null and Start-Sleep. Verified by AST analysis, not assumed.

    IF YOU EDIT THIS BODY: do not call a module function, and do not add a variable that is not
    injected by the caller in Start-WuuApplication. Either one fails SILENTLY at runtime, in a
    background loop, which is the worst place to find out.
    #>
    return {
    #Routine to handle completed runspaces
    Do {
        try {
            # Check if background processing is suspended
            if ($backgroundProcessing.Suspended) {
                Start-Sleep -Seconds 1
                continue
            }

            $jobsToRemove = @()
            # Snapshot first: enumerating a synchronized ArrayList is not thread-safe while other threads add/remove
            ForEach($runspace in @($jobs)){
                If ($runspace.Runspace.isCompleted){
                    try {
                        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                        $logEntry = "[$timestamp] [INFO] Job completed for computer: $($runspace.Computer)"
                        & $WriteLogFileScript $logEntry

                        $runspace.powershell.EndInvoke($runspace.Runspace) | Out-Null

                        $logEntry = "[$timestamp] [INFO] Successfully cleaned up job for computer: $($runspace.Computer)"
                        & $WriteLogFileScript $logEntry
                    } catch {
                        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                        $logEntry = "[$timestamp] [ERROR] Failed to cleanup job for computer $($runspace.Computer): $($_.Exception.Message)"
                        & $WriteLogFileScript $logEntry

                        # A failed EndInvoke is how a SILENTLY DISCARDED pipeline surfaces (the
                        # runspace was already busy, so the work never ran - see Test-ComputerBusy).
                        # The log line above is not enough: the row must say so too, or the operator
                        # sees an operation that was accepted and then simply never happened.
                        # Written with language constructs only, from the store's own hashtable -
                        # this runs on the cleanup thread, where no module function resolves.
                        try {
                            if ($stateStore) {
                                $failedRow = $stateStore.ByName[[string]$runspace.Computer.ToLowerInvariant()]
                                if ($failedRow) {
                                    # SS3: STALE-WRITER GUARD. This pass settles a job that FAILED,
                                    # but the row may already belong to a different operation (the
                                    # job was stopped and the computer resubmitted before the loop
                                    # next visited this entry). Writing here would clear the NEW
                                    # operation's lock and overwrite its status.
                                    #
                                    # Inlined rather than calling Test-WuuOperationCurrent: this runs
                                    # on the cleanup thread, an isolated runspace where no module
                                    # function resolves. The rule mirrors the function exactly, and
                                    # tests\Test-OperationIdentity.ps1 compares the two on identical
                                    # inputs so they cannot drift.
                                    $jobOpId = ''
                                    if ($runspace.PSObject.Properties['OperationId']) { $jobOpId = [string]$runspace.OperationId }
                                    $rowOpId = ''
                                    if ($failedRow.PSObject.Properties['OperationId']) { $rowOpId = [string]$failedRow.OperationId }
                                    if ($rowOpId -ne '' -and $jobOpId -ne '' -and $rowOpId -ceq $jobOpId) {
                                    $failedRow.State = 'Error'
                                    $failedRow.UpdatesStatus = 'Error'
                                    $failedRow.Status = "Operation did not run - another operation held the computer's runspace. Retry when it is idle."
                                    $failedRow.Color = 'Error'
                                    $failedRow.OpState = 'Idle'
                                    $failedRow.OpStartedAt = $null
                                    # SS5: clear the deadline with the lock. A finished row keeping a
                                    # past deadline would mark the NEXT operation expired immediately.
                                    if ($failedRow.PSObject.Properties['TimeoutExpiresAt']) { $failedRow.TimeoutExpiresAt = $null }
                                    if ($failedRow.PSObject.Properties['TimeoutSource']) { $failedRow.TimeoutSource = '' }
                                    if ($failedRow.PSObject.Properties['OpName']) { $failedRow.OpName = '' }
                                    if ($failedRow.PSObject.Properties['LastHeartbeatAt']) { $failedRow.LastHeartbeatAt = $null }
                                    if ($failedRow.PSObject.Properties['OperationId']) { $failedRow.OperationId = '' }
                                    $stateStore.Touch()
                                    } else {
                                        # A refusal is not silence. Without this line the operator
                                        # cannot tell "the guard refused a stale write" from "the
                                        # operation never ended".
                                        & $WriteLogFileScript "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [WARN] [$($runspace.Computer)] stale operation '$jobOpId' refused: the row now belongs to '$rowOpId' - its lock and status are left untouched"
                                    }
                                }
                            }
                        } catch { }
                    }
                    # Always dispose and drop the job so a failed EndInvoke is not retried forever
                    try { $runspace.powershell.dispose() } catch { $null = $_ }
                    $runspace.Runspace = $null
                    $runspace.powershell = $null
                    $jobsToRemove += $runspace

                    # Release the per-computer operation lock on EVERY completion path (success or
                    # failure). This is the pair to Start-UpdateCheckJob setting OpState='Running';
                    # if it is missed here the computer would be permanently 'busy' and never
                    # schedulable again. Language constructs only - runs on the cleanup thread.
                    #
                    # SS3: IDENTITY-GUARDED. "Release on every completion path" is only correct for
                    # the operation that OWNS the row. This job may have finished after another
                    # operation had already taken the computer (it was stopped and settled late), in
                    # which case releasing here grants a second operation while the current one still
                    # runs - and the runspace silently discards it. The guard is what makes the
                    # release safe on every path rather than merely present on every path.
                    try {
                        if ($stateStore) {
                            $doneRow = $stateStore.ByName[[string]$runspace.Computer.ToLowerInvariant()]
                            if ($doneRow -and $doneRow.PSObject.Properties['OpState']) {
                                $jobOpId2 = ''
                                if ($runspace.PSObject.Properties['OperationId']) { $jobOpId2 = [string]$runspace.OperationId }
                                $rowOpId2 = ''
                                if ($doneRow.PSObject.Properties['OperationId']) { $rowOpId2 = [string]$doneRow.OperationId }
                                if ($rowOpId2 -ne '' -and $jobOpId2 -ne '' -and $rowOpId2 -ceq $jobOpId2) {
                                $doneRow.OpState = 'Idle'
                                $doneRow.OpStartedAt = $null
                                # SS5: the operation is over, so its deadline goes with it. Leaving
                                # it behind would make the next operation look expired on the first
                                # cleanup pass (the deadline is read, never recomputed).
                                if ($doneRow.PSObject.Properties['TimeoutExpiresAt']) { $doneRow.TimeoutExpiresAt = $null }
                                if ($doneRow.PSObject.Properties['TimeoutSource']) { $doneRow.TimeoutSource = '' }
                                if ($doneRow.PSObject.Properties['OpName']) { $doneRow.OpName = '' }
                                if ($doneRow.PSObject.Properties['LastHeartbeatAt']) { $doneRow.LastHeartbeatAt = $null }
                                if ($doneRow.PSObject.Properties['OperationId']) { $doneRow.OperationId = '' }
                                $stateStore.Touch()
                                } else {
                                    & $WriteLogFileScript "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [WARN] [$($runspace.Computer)] stale operation '$jobOpId2' finished but the row belongs to '$rowOpId2' - lock NOT released (releasing it would admit a second operation while the current one still runs)"
                                }
                            }
                        }
                    } catch { }
                    
                }
                # SS5: OPERATION-SPECIFIC DEADLINE - this was a flat "timeout after 10 minutes" for
                # every op. One number cannot be right for a 5-minute service action, a 45-minute
                # search and a 4-hour AutoFlow chain whose reboot waits ALONE total 40 minutes:
                #   * healthy long operations were killed and reported as timeouts;
                #   * a hung short operation held a runspace for ten minutes before anyone noticed.
                # The budget now comes from the op recorded at submission (Set-WuuOperationDeadline),
                # with the job's own start time as a fallback. The deadline is READ, not recomputed,
                # so the value an operator can inspect is the value enforced here.
                #
                # Language constructs and plain property access only: this runs on the cleanup thread,
                # where no module function resolves. The decision mirrors Test-WuuOperationExpired,
                # and tests\Test-OperationTimeouts.ps1 compares the two on identical inputs.
                ElseIf ($runspace.StartTime) {
                    $nowTs = Get-Date
                    $hbRow = $null
                    try {
                        if ($stateStore) { $hbRow = $stateStore.ByName[[string]$runspace.Computer.ToLowerInvariant()] }
                    } catch { $hbRow = $null }

                    # Resolve the budget: the op the row was asked to perform, else the default entry.
                    # Never a literal, so an op added without its own entry is bounded by the table.
                    $opName = ''
                    if ($hbRow -and $hbRow.PSObject.Properties['OpName']) { $opName = [string]$hbRow.OpName }
                    $budget = 1800
                    if ($OperationTimeoutSeconds) {
                        if ($opName -and $OperationTimeoutSeconds.ContainsKey($opName)) {
                            $budget = [int]$OperationTimeoutSeconds[$opName]
                        } elseif ($OperationTimeoutSeconds.ContainsKey('default')) {
                            $budget = [int]$OperationTimeoutSeconds['default']
                        }
                    }

                    # Prefer the submission-time deadline; fall back to start time + budget.
                    $expires = $null
                    $basis = 'start-time-fallback'
                    if ($hbRow -and $hbRow.PSObject.Properties['TimeoutExpiresAt'] -and $hbRow.TimeoutExpiresAt) {
                        $expires = $hbRow.TimeoutExpiresAt
                        $basis = 'row-deadline'
                    } else {
                        $expires = $runspace.StartTime.AddSeconds($budget)
                    }
                    $elapsedMin = [math]::Round(($nowTs - $runspace.StartTime).TotalMinutes, 2)

                    if (-not ($expires -and $nowTs -gt $expires)) {
                        # STILL WITHIN ITS DEADLINE - record liveness. The heartbeat is what separates
                        # "slow" from "stuck" for a human: a deadline alone only says "not finished".
                        # It deliberately does NOT extend the deadline - a heartbeat proves the thread
                        # is alive, not that progress is being made, and letting it extend would mean
                        # a hung operation could never be stopped.
                        # Written at most once per interval so the store is not touched four times a
                        # second (each Touch() bumps Revision and triggers a redraw).
                        $hbEvery = 30
                        if ($OperationHeartbeatSeconds) { $hbEvery = [int]$OperationHeartbeatSeconds }
                        $hbDue = $true
                        if ($hbRow -and $hbRow.PSObject.Properties['LastHeartbeatAt'] -and $hbRow.LastHeartbeatAt -is [datetime]) {
                            $hbDue = (($nowTs - $hbRow.LastHeartbeatAt).TotalSeconds -ge $hbEvery)
                        }
                        if ($hbDue -and $hbRow) {
                            try {
                                $hbRow.LastHeartbeatAt = $nowTs
                                if ($hbRow.PSObject.Properties['Heartbeats']) { $hbRow.Heartbeats = [int]$hbRow.Heartbeats + 1 }
                                $stateStore.Touch()
                            } catch { }
                        }
                    } else {
                    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                    $logEntry = "[$timestamp] [WARN] [$($runspace.Computer)] Job timeout detected for $($runspace.Computer) - op '$opName' ran $elapsedMin min against a $(if ($budget -ge 3600) { "$([math]::Round($budget/3600,1))h" } else { "$([math]::Round($budget/60,1))m" }) deadline (basis=$basis, overshoot $([math]::Round(($nowTs - $expires).TotalMinutes,2)) min)"
                    & $WriteLogFileScript $logEntry

                    $timedOutComputer = $runspace.Computer
                    try { $runspace.powershell.Stop() } catch { $null = $_ }
                    try { $runspace.powershell.dispose() } catch { $null = $_ }
                    $runspace.Runspace = $null
                    $runspace.powershell = $null
                    $jobsToRemove += $runspace

                    # Release the per-computer operation lock when a job is force-stopped on
                    # timeout. Without this the row stays 'Running' forever and Test-WuuComputerBusy
                    # refuses every future submission for that computer - a permanently unschedulable
                    # machine, which is worse than the timeout it was recovering from.
                    #
                    # SS3: IDENTITY-GUARDED. This is the path that MAKES the stale-writer race
                    # reachable, so the guard matters most here. A job is stopped and queued for
                    # removal, but its runspace may take seconds to tear down - and the cleanup loop
                    # keeps running throughout. If the computer is resubmitted in that window, the
                    # row belongs to the NEW operation by the time this pass settles the old one. An
                    # unguarded release here would admit a third submission against a runspace that
                    # is still draining, and the runspace discards it silently.
                    try {
                        if ($stateStore) {
                            $toRow = $stateStore.ByName[[string]$timedOutComputer.ToLowerInvariant()]
                            if ($toRow -and $toRow.PSObject.Properties['OpState']) {
                                $toOpId = ''
                                if ($runspace.PSObject.Properties['OperationId']) { $toOpId = [string]$runspace.OperationId }
                                $toRowId = ''
                                if ($toRow.PSObject.Properties['OperationId']) { $toRowId = [string]$toRow.OperationId }
                                if ($toRowId -ne '' -and $toOpId -ne '' -and $toRowId -ceq $toOpId) {
                                    # SS3 (the half that makes this path SAFE, not just guarded):
                                    # detach the runspace from the row BEFORE releasing the lock.
                                    #
                                    # The guard below only stops a stale WRITER. It does not stop the
                                    # row from pointing at a runspace we have just torn down - and
                                    # $PowerShell.Stop() is asynchronous, so the payload may still be
                                    # draining. A resubmission arriving in that window would find
                                    # Runspace=$null, build a FRESH one, and the computer's row would
                                    # then hold a new runspace while the old payload was still writing
                                    # into it through its own module-scope $StateStore. Two writers,
                                    # one row, different runspaces - the case the per-computer
                                    # runspace normally prevents by construction.
                                    #
                                    # Clearing it means a resubmission cannot silently inherit a
                                    # dying runspace, and the superseded payload writes into a
                                    # detached object rather than the live row.
                                    if ($toRow.PSObject.Properties['Runspace']) { $toRow.Runspace = $null }
                                    $toRow.OpState = 'Idle'
                                    $toRow.OpStartedAt = $null
                                    $stateStore.Touch()
                                } else {
                                    & $WriteLogFileScript "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [WARN] [$timedOutComputer] stale operation '$toOpId' timed out but the row belongs to '$toRowId' - lock NOT released"
                                }
                            }
                        }
                    } catch { }
                    

                    # Update computer status to show timeout.
                    # Console edition: no dispatcher needed - write straight into the
                    # synchronized state store and Touch() to signal a redraw. This runs in
                    # the cleanup runspace, which cannot see module functions, so the row is
                    # resolved from the store's own hashtable.
                    # Language constructs only - a pipeline cmdlet here would bind to the busy
                    # cleanup runspace (the GUI edition deadlocked on exactly that).
                    try {
                        $timedOutRow = $stateStore.ByName[$timedOutComputer.ToLowerInvariant()]
                        if ($timedOutRow) {
                            # SS3: the terminal status is written ONLY if this job still owns the row.
                            # The lock-release above is guarded separately and the two must agree: a
                            # row that kept its lock must not have been given another operation's
                            # timeout text either, or the operator sees "Timed out" on a computer that
                            # is actively running the replacement operation.
                            $toStatusOpId = ''
                            if ($runspace.PSObject.Properties['OperationId']) { $toStatusOpId = [string]$runspace.OperationId }
                            $toStatusRowId = ''
                            if ($timedOutRow.PSObject.Properties['OperationId']) { $toStatusRowId = [string]$timedOutRow.OperationId }
                            if ($toStatusRowId -eq '' -or $toStatusOpId -eq '' -or $toStatusRowId -cne $toStatusOpId) {
                                throw "stale timeout write refused for '$($timedOutComputer)': the row belongs to '$toStatusRowId', not '$toStatusOpId'"
                            }
                            # SS5: report WHICH operation and WHICH budget, not a bare "10 minutes".
                            # "Timed out" without "doing what, after how long" is not actionable -
                            # the operator cannot tell a genuinely stuck service action from an
                            # estate-wide search that needs a larger budget.
                            $budgetLabel = if ($budget -ge 3600) { "$([math]::Round($budget/3600,1))h" } else { "$([math]::Round($budget/60,1))m" }
                            $opLabel = if ($opName) { $opName } else { 'operation' }
                            $timedOutRow.Status = "Timed out: $opLabel exceeded its $budgetLabel deadline (ran $elapsedMin min). Still queued; retry or raise the budget."
                            $timedOutRow.UpdatesStatus = 'Timeout'
                            $timedOutRow.State = 'Timeout'
                            # Timeout is recoverable - yellow, matching Set-ComputerTimeout
                            $timedOutRow.Color = 'Timeout'
                            # Clear the deadline with the lock: a finished row that kept a deadline in
                            # the past would make the NEXT operation look expired on its first pass,
                            # i.e. every operation after the first would be killed immediately.
                            if ($timedOutRow.PSObject.Properties['TimeoutExpiresAt']) { $timedOutRow.TimeoutExpiresAt = $null }
                            if ($timedOutRow.PSObject.Properties['TimeoutSource']) { $timedOutRow.TimeoutSource = '' }
                            if ($timedOutRow.PSObject.Properties['OpName']) { $timedOutRow.OpName = '' }
                            if ($timedOutRow.PSObject.Properties['LastHeartbeatAt']) { $timedOutRow.LastHeartbeatAt = $null }
                            if ($timedOutRow.PSObject.Properties['OperationId']) { $timedOutRow.OperationId = '' }
                            $stateStore.Touch()
                        }
                    } catch {
                        # If the row update fails, just log it
                        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                        $logEntry = "[$timestamp] [WARN] Timeout row update skipped for ${timedOutComputer}: $($_.Exception.Message)"
                        & $WriteLogFileScript $logEntry
                    } finally {
                        if ($toRow -and $toRow.PSObject.Properties['OpState'] -and [string]$toRow.OpState -eq 'Idle') {
                            if ($toRow.PSObject.Properties['OperationId'] -and [string]$toRow.OperationId -eq $toOpId) {
                                $toRow.OperationId = ''
                            }
                        }
                    }
                    }
                }
            }

            # Remove completed/timed out jobs
            if ($jobsToRemove.Count -gt 0) {
                $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                $logEntry = "[$timestamp] [INFO] Removing $($jobsToRemove.Count) completed job(s)"
                & $WriteLogFileScript $logEntry
            }

            ForEach($job in $jobsToRemove) {
                $jobs.remove($job)
            }
        } catch {
            # Never let the cleanup loop die - a dead cleanup loop starves the job throttle
            try {
                $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                $logEntry = "[$timestamp] [ERROR] Job cleanup loop iteration failed: $($_.Exception.Message)"
                & $WriteLogFileScript $logEntry
            } catch { $null = $_ }
        }

        Start-Sleep -Seconds 1
    } While ($jobCleanup.Flag)
    }
}

Export-ModuleMember -Function @(
    'Initialize-WuuWorkerPool',
    'Get-WuuWorkerPool',
    'Invoke-WithPoolTimeout',
    'Close-WuuWorkerPool',
    'New-PooledInvokeScript',
    'Test-WuuWorkerPool',
    # Diagnostics are functions because session-state isolation hides $script: values from other modules.
    'Get-WuuWorkerPoolCapacity',
    'Get-WuuWorkerPoolDiagnostics',
    'Get-WuuJobCleanupPayload'
    'Test-WuuWorkerPoolStarved',
    'Test-PoolCompatibility'
)
