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
# THE INVARIANT: POOL SIZE >= $MaxConcurrentJobs.
#
# Bounded probes (WMI/CIM/service/ping) are dispatched from INSIDE the per-computer worker runspaces,
# and at most $MaxConcurrentJobs of those run at once. If the pool is smaller, the excess probes
# cannot start: $MaxConcurrentJobs already counts them as RUNNING, so the shortfall is invisible -
# there is no refusal to record and no error to log, only a probe that sits queued and presents as a
# SLOW HOST. That failure mode is the reason this is an invariant rather than a tuning note.
#
# THE PREVIOUS VALUES VIOLATED IT. The cap was 10 and the pool 8, so two admitted operations could
# never probe. (This comment used to assert the opposite requirement - that the pool must EXCEED the
# cap - which the numbers below it did not satisfy. Two modules disagreed in writing about whether
# the relationship existed at all; it is now stated once, here, and asserted by the suite and the
# release gate.)
#
# Equality is sufficient because a job's probes are SEQUENTIAL: one job occupies at most one pool slot
# at a time, so a pool of exactly $MaxConcurrentJobs runs every admitted job's next probe without any
# job waiting. Making the pool larger buys nothing - it only raises the per-machine child-process
# ceiling. Making it SMALLER queues probes it has already been told to run.
#
# Raise BOTH together, or neither. Test-PoolCompatibility and the release gate both fail if the pool
# is smaller than the cap.
#
# The pool is created LAZILY on first use (Get-WuuWorkerPool) so import cost
# stays zero until the first bounded probe actually runs.
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
    Whether the worker pool can actually run the operations the concurrency cap admits (P3 close-out).
    .DESCRIPTION
    THE INVARIANT: pool size >= $MaxConcurrentJobs.

    WHY THE DIRECTION IS EXACTLY THIS ONE. Bounded probes are dispatched from inside the per-computer
    worker runspaces, and at most $MaxConcurrentJobs run at once. A SMALLER pool means (cap - pool)
    operations are admitted and counted as RUNNING while their probes can never start. Nothing is
    refused, nothing is logged, and no error is raised - the probe simply queues behind work it was
    admitted ahead of, and the operator sees a slow host and investigates the host.

    A LARGER pool is not a defect, only unused capacity: a job's probes are sequential, so it occupies
    at most one slot at a time and a pool of exactly the cap already runs every job's next probe. It is
    reported as Unnecessary rather than Compatible so it is visible without failing a release.

    THIS EXISTED AS A REAL DEFECT, not a hypothetical one: the cap was 10 and the pool 8. The pool's own
    comment asserted it "must comfortably exceed" the cap while setting a value below it, and
    Test-WuuConcurrencyAvailable's description said the pool was unrelated. Both statements are now
    replaced by this single check.

    Takes the cap as a parameter rather than reading $global:MaxConcurrentJobs, because this module must
    not couple to Wuu.Core: it is called both with the live configured value and, from the gate, with
    the value parsed out of the source. Returns a verdict, never throws.
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

Export-ModuleMember -Function @(
    'Initialize-WuuWorkerPool',
    'Get-WuuWorkerPool',
    'Invoke-WithPoolTimeout',
    'Close-WuuWorkerPool',
    'New-PooledInvokeScript',
    'Test-WuuWorkerPool',
    # P3: pool DIAGNOSTICS. Exported because pool saturation and abandoned wrappers present as "slow
    # hosts" from the caller's side, so the state has to be readable from outside the module - and
    # session-state isolation hides a sibling module's $script: values, which is why these are functions
    # rather than exposed variables.
    'Get-WuuWorkerPoolCapacity',
    'Get-WuuWorkerPoolDiagnostics',
    'Test-WuuWorkerPoolStarved',
    # P3 close-out: the pool-versus-cap invariant. Exported because the value it must be compared against
    # ($global:MaxConcurrentJobs) lives in another module, and session-state isolation hides that.
    'Test-PoolCompatibility'
)