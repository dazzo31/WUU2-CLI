#Requires -Version 5.1
<#
.DESCRIPTION
Session / computer-set model for the interactive UI redesign.

Spec: docs/INTERACTIVE_UI_SPEC.md section 6 - "The computer set is the primary object".

WHY THIS IS A THIN LAYER RATHER THAN A SECOND STORE
---------------------------------------------------
The spec models:

    Session
    └── ComputerSet
        ├── Computers[]
        ├── Credentials
        ├── Phases
        ├── Configuration
        └── DeploymentState

The existing Wuu.State store ALREADY holds the computers, their phases, the settings and the
per-row deployment state, and it is the object the worker runspaces mutate directly. Introducing a
parallel ComputerSet object that also owns computers would mean two sources of truth for the same
data - the exact class of bug this project has already been bitten by (the GUI's ListView was the
real source of truth while code assumed the store was; the $actions/$Actions collision; the
deadlock from duplicated ownership).

So a ComputerSet is a NAMED VIEW over the existing store: it carries identity and metadata (name,
created time, whether it has been saved/loaded) and reads computers/phases/settings FROM the store.
That satisfies "the computer set is the primary object, not something the user restates per
operation" without forking the state.

WHAT IS GENUINELY NEW HERE
--------------------------
Name parsing and validation for acquisition (spec 4.1 / 4.2). The spec is explicit:

    "Never silently discard invalid or duplicate entries."

That is why Add-WuuComputerSetNames returns Valid / Duplicates / Invalid as separate, reported
lists rather than quietly filtering. A silently-dropped host during a patching run is how you end
up believing 24 servers are patched when 22 are.
#>

Set-StrictMode -Version 2.0

#region Name parsing and validation

function Test-WuuComputerName {
    <#
    .SYNOPSIS Validates one computer name (NetBIOS or FQDN).
    .DESCRIPTION
    Deliberately permissive about what it ACCEPTS (a real estate contains odd names) and precise
    about what it REJECTS, because a false rejection means a host silently never gets patched.
    Rejected: empty/whitespace, anything with characters that cannot appear in a host name, a
    length that cannot be a NetBIOS name or FQDN label, and obvious pasted noise (an IP-like or
    decimal-only token is accepted; a line of prose is not).
    #>
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $n = $Name.Trim()

    # NetBIOS / host label: letters, digits, hyphen; not starting/ending with hyphen.
    # FQDN: the same, dot-separated, optional trailing dot.
    if ($n.EndsWith('.')) { $n = $n.TrimEnd('.') }
    if ($n.Length -gt 253) { return $false }

    $labels = $n -split '\.'
    foreach ($label in $labels) {
        if ($label.Length -lt 1 -or $label.Length -gt 63) { return $false }
        if ($label -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$') { return $false }
    }
    return $true
}

function Split-WuuComputerNames {
    <#
    .SYNOPSIS Splits pasted/imported text into candidate computer names.
    .DESCRIPTION
    Spec 4.1: "You can enter multiple names separated by commas, spaces, or new lines."
    Also tolerates semicolons and tabs. Blank tokens are dropped (that is not "discarding an
    entry", it is discarding whitespace) but nothing else is filtered here - validation and
    duplicate detection happen in Add-WuuComputerSetNames so they can be REPORTED.

    CONVENTION - and this one bit twice, so it is worth stating precisely: a function returns an
    array PLAINLY, and every call site wraps the call in @(). Do NOT try to make the function
    "always return an array" with `return ,$x` or `Write-Output -NoEnumerate`: when the caller ALSO
    wraps (which the convention requires), that produces a NESTED array whose single element is
    itself an array - so $names[0] becomes an Object[] instead of a computer name. Pick one side
    of the fence: plain return here, @() at the call sites.
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $parts = $Text -split '[,;\s]+'
    return @($parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
}

#endregion Name parsing and validation

#region Computer set

function New-WuuComputerSet {
    <#
    .SYNOPSIS Creates the named view over the state store that the interactive UI operates on.
    .PARAMETER Store The Wuu.State store. NOT copied - the set reads through to it.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Store,
        [string]$Name = 'Unsaved computer set'
    )
    [pscustomobject]@{
        Name        = $Name
        CreatedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        Store       = $Store
        # Whether this set corresponds to a saved config on disk. Drives the "save before you
        # lose it" prompt in the review screen; it is presentation state, not engine state.
        IsSaved     = $false
    }
}

function Get-WuuComputerSetComputers {
    <# The computers in the set - read through to the store, never a copy. #>
    param([Parameter(Mandatory)]$Set)
    return @(Get-WuuComputerRow -Store $Set.Store)
}

function Get-WuuComputerSetCount {
    param([Parameter(Mandatory)]$Set)
    return @(Get-WuuComputerSetComputers -Set $Set).Count
}

function Get-WuuComputerSetPhases {
    <#
    .SYNOPSIS Per-phase rollup used by the dashboard and the phase screens (spec 8 / 13).
    .DESCRIPTION
    Returns every phase 1..5, including empty ones, so the UI can show "Phase 3: 0 computers"
    rather than omitting a phase and making the estate look like it has three phases instead of
    five. Ordered by phase number.

    NOTE the @() around the pipeline: a PowerShell function returning a single-element array
    UNWRAPS it to a scalar, so a function that returns one computer would silently lose .Count
    (and strict mode turns that into a hard error). Always re-wrap at the point of use.
    #>
    param([Parameter(Mandatory)]$Set)

    $computers = @(Get-WuuComputerSetComputers -Set $Set)
    $out = New-Object System.Collections.ArrayList
    foreach ($p in 1..5) {
        $inPhase = @($computers | Where-Object { [string]$_.Phase -eq "Phase $p" })
        $complete = @($inPhase | Where-Object { [string]$_.State -eq 'Complete' }).Count
        $failed = @($inPhase | Where-Object { [string]$_.State -eq 'Error' -or [string]$_.State -eq 'Timeout' }).Count
        $rebootClean = @($inPhase | Where-Object { [string]$_.State -eq 'Complete' -and -not $_.RebootRequired }).Count
        [void]$out.Add([pscustomobject]@{
            Phase        = $p
            Label        = "Phase $p"
            Computers    = $inPhase.Count
            Complete     = $complete
            Failed       = $failed
            RebootClean  = $rebootClean
            # A phase is eligible to START when it holds computers and has not been completed.
            IsEmpty      = ($inPhase.Count -eq 0)
            IsComplete   = ($inPhase.Count -gt 0 -and $complete -eq $inPhase.Count)
        })
    }
    # Plain array return - see the convention note on Split-WuuComputerNames. Callers wrap with @().
    return $out.ToArray()
}

function Get-WuuComputerSetSummary {
    <#
    .SYNOPSIS Counts by state, for the dashboard header and the results screen.
    #>
    param([Parameter(Mandatory)]$Set)

    $computers = @(Get-WuuComputerSetComputers -Set $Set)
    # Explicit per-state counting rather than a helper scriptblock: `& $sb @('Complete')` reads as
    # argument splatting and produces a scalar, which then makes `-contains` behave differently
    # from the array case. A count that silently uses the wrong comparison is exactly how a
    # results screen reports "0 failures" on a run that failed.
    $complete = 0; $errored = 0; $timedOut = 0; $offline = 0; $pending = 0; $reboot = 0; $withUpdates = 0
    foreach ($c in $computers) {
        switch ([string]$c.State) {
            'Complete' { $complete++ }
            'Error'    { $errored++ }
            'Timeout'  { $timedOut++ }
            'Offline'  { $offline++ }
        }
        if ($c.Pending) { $pending++ }
        if ($c.RebootRequired) { $reboot++ }
        if ([int]$c.Available -gt 0) { $withUpdates++ }
    }

    [pscustomobject]@{
        Name           = $Set.Name
        Total          = $computers.Count
        IsEmpty        = ($computers.Count -eq 0)
        Complete       = $complete
        Error          = $errored
        Timeout        = $timedOut
        Offline        = $offline
        Pending        = $pending
        RebootRequired = $reboot
        WithUpdates    = $withUpdates
    }
}

#endregion Computer set

#region Acquisition (spec 4.1 / 4.2)

function Add-WuuComputerSetNames {
    <#
    .SYNOPSIS Adds names to the set, reporting valid / duplicate / invalid separately.
    .DESCRIPTION
    Spec 4.2: "Never silently discard invalid or duplicate entries."

    Returns the three buckets rather than just the count added, so the caller can SHOW the operator
    what happened:

        Imported 47 computers.
          Valid:       44
          Duplicates:   2
          Invalid:      1

    Duplicate detection covers both names already in the set and names repeated within the same
    input. Comparison is case-insensitive, because Windows host names are.
    #>
    param(
        [Parameter(Mandatory)]$Set,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Names,
        [string]$Phase = 'Phase 1',
        [string]$StateSource = 'Acquisition'
    )

    $valid = New-Object System.Collections.ArrayList
    $duplicates = New-Object System.Collections.ArrayList
    $invalid = New-Object System.Collections.ArrayList

    # Existing membership, case-insensitive.
    $existing = @{}
    foreach ($r in @(Get-WuuComputerSetComputers -Set $Set)) { $existing[[string]$r.Computer.ToLowerInvariant()] = $true }
    $seenThisCall = @{}

    foreach ($raw in $Names) {
        $n = [string]$raw
        if (-not (Test-WuuComputerName -Name $n)) { [void]$invalid.Add($n); continue }
        $key = $n.Trim().ToLowerInvariant()
        if ($existing.ContainsKey($key) -or $seenThisCall.ContainsKey($key)) {
            [void]$duplicates.Add($n.Trim()); continue
        }
        $seenThisCall[$key] = $true
        [void]$valid.Add($n.Trim())
    }

    foreach ($n in $valid) {
        $row = New-WuuComputerRow -Computer $n -Phase $Phase -StateSource $StateSource
        Add-WuuComputerRow -Store $Set.Store -Row $row | Out-Null
    }

    return [pscustomobject]@{
        Added      = @($valid.ToArray())
        Duplicates = @($duplicates.ToArray())
        Invalid    = @($invalid.ToArray())
        AddedCount = $valid.Count
    }
}

#endregion Acquisition

#region Prerequisites, pre-flight and operation plans (spec 7 / 11 / 12)

function Test-WuuPrerequisite {
    <#
    .SYNOPSIS Decides whether one operation's prerequisites are met for one computer (spec 7).
    .DESCRIPTION
    Spec 7 requires pre-flight to evaluate "operation-specific prerequisites". This is the single
    decision point for "may this operation run against this computer", expressed as PURE STATE -
    no I/O, no console - so it can be tested by building a row and asserting the verdict.

    The verdict is three-valued (Ok | Warning | Blocking) rather than a boolean, because those are
    genuinely different things to an operator:
      Warning  - a soft signal they may accept ("no update has been found yet")
      Blocking - the operation cannot do anything useful ("install with nothing downloaded")
    Collapsing both into $false is how a pre-flight list becomes noise that people learn to skip.

    An unrecognised operation reports Blocking on purpose. Defaulting to Ok would mean a typo'd
    operation name passes pre-flight with its prerequisites unchecked - the exact failure pre-flight
    exists to prevent.
    #>
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$Op
    )

    # A row already known to be offline can satisfy nothing, whatever the operation.
    if ([string]$Row.State -eq 'Offline') {
        return @{ State = 'Blocking'; Reason = 'offline' }
    }

    $available  = [int]$Row.Available
    $downloaded = [int]$Row.Downloaded
    $updStatus  = [string]$Row.UpdatesStatus

    switch ($Op.ToLowerInvariant()) {
        'check' {
            if ($Row.Pending) { return @{ State = 'Warning'; Reason = 'a check is already queued' } }
            return @{ State = 'Ok'; Reason = '' }
        }
        'review' {
            if ($available -eq 0 -and $updStatus -ne 'Updates required') {
                return @{ State = 'Warning'; Reason = 'no update search has found anything yet' }
            }
            return @{ State = 'Ok'; Reason = '' }
        }
        'download' {
            if ($available -eq 0) { return @{ State = 'Warning'; Reason = 'no updates available to download' } }
            if ($downloaded -ge $available) { return @{ State = 'Warning'; Reason = 'all available updates are already downloaded' } }
            return @{ State = 'Ok'; Reason = '' }
        }
        'install' {
            if ($downloaded -eq 0) { return @{ State = 'Blocking'; Reason = 'nothing downloaded to install' } }
            return @{ State = 'Ok'; Reason = '' }
        }
        'restart' {
            if (-not $Row.RebootRequired) { return @{ State = 'Warning'; Reason = 'no reboot is pending' } }
            return @{ State = 'Ok'; Reason = '' }
        }
        # The service action operates on wuauserv itself, so it has no update-state precondition.
        'service' { return @{ State = 'Ok'; Reason = '' } }
        'deploy' {
            if ([int]$Row.InstallErrors -gt 0) { return @{ State = 'Warning'; Reason = "$([int]$Row.InstallErrors) recorded install error(s)" } }
            if ($available -gt 0 -and $available -eq $downloaded -and [string]$Row.State -eq 'Complete' -and -not $Row.RebootRequired) {
                return @{ State = 'Warning'; Reason = 'already at the end of the update lifecycle' }
            }
            return @{ State = 'Ok'; Reason = '' }
        }
        default {
            return @{ State = 'Blocking'; Reason = "unknown operation '$Op'" }
        }
    }
}

function Get-WuuOperationLabel {
    <# Human label for an operation id - used by the plan, confirmation and results screens. #>
    param([Parameter(Mandatory)][string]$Operation)
    switch ($Operation.ToLowerInvariant()) {
        'check'    { 'Check for updates' }
        'review'   { 'Review available updates' }
        'download' { 'Download updates' }
        'install'  { 'Install updates' }
        'restart'  { 'Restart computers' }
        'service'  { 'Windows Update service action' }
        'deploy'   { 'Full deployment' }
        default    { $Operation }
    }
}

function Test-WuuOperationRequiresReason {
    <#
    .SYNOPSIS Whether this operation needs a change reason before it may run (spec 12 / audit).
    .DESCRIPTION
    Must agree with the mutating flags in the flat menu and the command verb table, which are the
    same set: download, install, restart, service. 'deploy' is a guided-only composite that runs
    those same mutating steps, so it requires a reason too.
    #>
    param([Parameter(Mandatory)][string]$Operation)
    return (@('download', 'install', 'restart', 'service', 'deploy') -contains $Operation.ToLowerInvariant())
}

function Get-WuuPreflightReport {
    <#
    .SYNOPSIS Evaluates reachability, credentials, WU service, OS, reboot and prerequisites (spec 7).
    .DESCRIPTION
    Spec 7: "Before any disruptive operation, evaluate reachability, credentials, Windows Update
    service, OS compatibility, pending reboot, existing errors, phase configuration,
    operation-specific prerequisites." This composes the LIVE probes rather than reimplementing
    any of them:

      reachability - the same Test-Connection check $RemoveOfflineComputer uses
      credentials  - Invoke-CimWithTimeout, the codebase's bounded DCOM probe
      WU service   - Invoke-ServiceWithTimeout -Action Check
      OS / reboot  - the Win32_OperatingSystem and Microsoft.Update.SystemInfo queries the update
                     engine already uses

    WHY EVERY PROBE IS INJECTED. Two reasons, both structural rather than stylistic:
      1. Spec 23 - session/presentation code sits ABOVE the engine and must not reach into it.
         Injection is how Wuu.Navigate and Wuu.Session stay engine-free (the release validator
         fails the build if this module calls an engine function directly).
      2. It makes the whole report deterministic in a test. Without it, verifying "offline hosts
         are reported offline and excluded from the availability count" would need a genuinely
         unreachable host and a several-second ping timeout per assertion.

    Probes are only run against computers that answered Ping. Probing credentials and services on
    a host that is not there is a guaranteed multi-second timeout, so doing it anyway would make
    pre-flight cost scale with the number of offline machines - the opposite of what an operator
    wants to discover at 02:00.

    Availability (how many computers would actually be targeted) is reported separately from the
    row count, so spec 7's "Continue with N available computers" is a real N.
    #>
    param(
        [Parameter(Mandatory)]$Set,
        [Parameter(Mandatory)][string]$Operation,
        [scriptblock]$PingProbe = $null,
        [scriptblock]$CredentialProbe = $null,
        [scriptblock]$ServiceProbe = $null,
        [scriptblock]$OsProbe = $null,
        [scriptblock]$RebootProbe = $null,
        # Called between computers so the caller can drain queued work while pre-flight runs; the
        # workflow loop cannot tick during a synchronous screen otherwise.
        [scriptblock]$Tick = $null
    )

    $rows = @(Get-WuuComputerSetComputers -Set $Set)
    $results = New-Object System.Collections.ArrayList
    $problems = New-Object System.Collections.ArrayList
    $reachable = 0; $credentialsValid = 0; $serviceOk = 0; $rebootPending = 0
    $blocking = 0; $warnings = 0; $available = 0

    foreach ($r in $rows) {
        if ($Tick) { try { & $Tick } catch { } }

        $verdict = Test-WuuPrerequisite -Row $r -Op $Operation
        $prereqState = [string]$verdict.State
        $problem = [string]$verdict.Reason

        $row = [pscustomobject]@{
            Computer       = $r.Computer
            Phase          = $r.Phase
            Reachable      = $false
            ProbeState     = 'not tested'
            Credentials    = 'not tested'
            WuService      = 'not tested'
            OS             = ''
            PendingReboot  = $false
            Prerequisite   = $prereqState
            Problem        = $problem
        }

        # Reachability. No ping probe supplied means "cannot tell" - so attempt the rest rather
        # than declaring every host offline.
        $reachableKnown = $true
        if ($PingProbe) {
            try { $row.Reachable = [bool](& $PingProbe $r.Computer) } catch { $row.Reachable = $false }
        } else {
            $reachableKnown = $false
        }

        if ($row.Reachable) { $reachable++ }

        if ($row.Reachable -or -not $reachableKnown) {
            $row.ProbeState = 'probed'
            if ($CredentialProbe) {
                try { $row.Credentials = [string](& $CredentialProbe $r.Computer) } catch { $row.Credentials = 'failed' }
            }
            if ($row.Credentials -eq 'valid') { $credentialsValid++ }
            if ($ServiceProbe) {
                try { $row.WuService = [string](& $ServiceProbe $r.Computer) } catch { $row.WuService = 'unknown' }
            }
            if ($row.WuService -eq 'Running') { $serviceOk++ }
            if ($OsProbe) {
                try { $row.OS = [string](& $OsProbe $r.Computer) } catch { $row.OS = '' }
            }
            if ($RebootProbe) {
                try { $row.PendingReboot = [bool](& $RebootProbe $r.Computer) } catch { $row.PendingReboot = $false }
            }
            if ($row.PendingReboot) { $rebootPending++ }
        } else {
            # Offline overrides the prerequisite verdict: nothing about this computer can be
            # satisfied while it is unreachable, and saying "Ok" here would put an offline host
            # into the "continue with N" count.
            $row.ProbeState = 'skipped (offline)'
            $row.Credentials = 'not tested (offline)'
            $row.WuService = 'not tested (offline)'
            $prereqState = 'Blocking'
            $problem = 'offline'
        }

        $row.Prerequisite = $prereqState
        $row.Problem = $problem
        if ($prereqState -eq 'Blocking') { $blocking++ } elseif ($prereqState -eq 'Warning') { $warnings++ }
        # A computer counts as available when it is reachable (or reachability is unknown) and
        # nothing blocking stands in the way.
        if ($prereqState -ne 'Blocking' -and ($row.Reachable -or -not $reachableKnown)) { $available++ }

        if ($problem) { [void]$problems.Add(("{0}: {1}" -f $row.Computer, $problem)) }
        [void]$results.Add($row)
    }

    [pscustomobject]@{
        Operation        = $Operation
        Label            = Get-WuuOperationLabel -Operation $Operation
        Computers        = $rows.Count
        Targets          = @($rows | ForEach-Object { $_.Computer })
        Reachable        = $reachable
        # ONLY meaningful when reachability was actually probed. Deriving it as
        # (total - reachable) unconditionally reported EVERY computer as offline whenever no ping
        # probe was supplied - which is precisely the "cannot tell" case, not a fleet of dead
        # machines. Reporting 0 here keeps the number honest; the screen states separately that
        # these checks were not performed.
        Offline          = $(if ($PingProbe) { $rows.Count - $reachable } else { 0 })
        CredentialsValid = $credentialsValid
        ServiceOk        = $serviceOk
        RebootPending    = $rebootPending
        Blocking         = $blocking
        Warnings         = $warnings
        Available        = $available
        Results          = $results.ToArray()
        Problems         = $problems.ToArray()
        ProbedOffline    = (-not $PingProbe)
    }
}

function New-WuuOperationPlan {
    <#
    .SYNOPSIS The explicit execution plan shown before a mutating operation (spec 12).
    .DESCRIPTION
    Spec 12: "show the complete execution plan (computer count, update breakdown, expected reboots,
    per-phase plan, change reason) and require explicit confirmation."

    The lifecycle steps are stated, not implied, because that is the whole point of spec 10/11 -
    the operator should not have to infer CHECK -> DOWNLOAD -> INSTALL -> REBOOT -> VERIFY from a
    list of separate commands.

    Targets default to the entire computer set. That is spec 6: "Operations operate against the
    current computer set. Do not make users re-specify the same computers for every interactive
    operation." A caller passes -Targets only for the retry-failed path, where the set is
    deliberately narrowed to the computers that failed.
    #>
    param(
        [Parameter(Mandatory)]$Set,
        [Parameter(Mandatory)][string]$Operation,
        [string]$Reason = '',
        [AllowEmptyCollection()][string[]]$Targets = @(),
        $Preflight = $null
    )

    $rows = @(Get-WuuComputerSetComputers -Set $Set)
    # Both branches wrapped separately and assigned explicitly. An `if` expression whose branch
    # emits a ONE-element array is unwrapped by the pipeline, so `$targetRows.Count` would throw
    # under strict mode for a narrowed single-computer plan (the retry-failed path). This is the
    # same unwrapping class that crashed manual entry on a single computer name.
    $targetRows = @()
    if (@($Targets).Count -gt 0) {
        $targetRows = @($rows | Where-Object { $Targets -contains $_.Computer })
    } else {
        $targetRows = @($rows)
    }

    # Explicit rather than derived: 'install' really does re-check afterwards (the console
    # adapter appends the check), and 'deploy' is the full spec-11 sequence.
    $lifecycle = switch ($Operation.ToLowerInvariant()) {
        'check'    { @('Check') }
        'review'   { @('Review') }
        'download' { @('Download') }
        'install'  { @('Install', 'Re-check') }
        'restart'  { @('Restart', 'Re-check') }
        'service'  { @('Service action') }
        'deploy'   { @('Check', 'Download', 'Install', 'Restart where required', 'Re-check', 'Verify') }
        default    { @($Operation) }
    }

    $updatesToDownload = 0
    $updatesToInstall = 0
    $reboots = 0
    foreach ($t in $targetRows) {
        $updatesToDownload += [Math]::Max(0, [int]$t.Available - [int]$t.Downloaded)
        $updatesToInstall += [Math]::Max(0, [int]$t.Downloaded)
        if ($t.RebootRequired) { $reboots++ }
    }

    $perPhase = New-Object System.Collections.ArrayList
    foreach ($p in 1..5) {
        $inPhase = @($targetRows | Where-Object { [string]$_.Phase -eq "Phase $p" })
        if ($inPhase.Count -eq 0) { continue }
        [void]$perPhase.Add([pscustomobject]@{
            Phase     = "Phase $p"
            Computers = $inPhase.Count
            Names     = @($inPhase | ForEach-Object { $_.Computer })
        })
    }

    # When pre-flight ran, its availability figure is the honest one to show - the row count
    # includes computers pre-flight just proved cannot be reached.
    $available = $targetRows.Count
    if ($Preflight) { $available = [int]$Preflight.Available }

    [pscustomobject]@{
        Operation         = $Operation
        Label             = Get-WuuOperationLabel -Operation $Operation
        Lifecycle         = $lifecycle
        Targets           = @($targetRows | ForEach-Object { $_.Computer })
        TargetCount       = $targetRows.Count
        AvailableCount    = $available
        UpdatesToDownload = $updatesToDownload
        UpdatesToInstall  = $updatesToInstall
        ExpectedReboots   = $reboots
        PerPhase          = $perPhase.ToArray()
        Reason            = $Reason
        RequiresReason    = (Test-WuuOperationRequiresReason -Operation $Operation)
    }
}

#endregion Prerequisites, pre-flight and operation plans

Export-ModuleMember -Function @(
    'Test-WuuComputerName'
    'Split-WuuComputerNames'
    'New-WuuComputerSet'
    'Get-WuuComputerSetComputers'
    'Get-WuuComputerSetCount'
    'Get-WuuComputerSetPhases'
    'Get-WuuComputerSetSummary'
    'Add-WuuComputerSetNames'
    'Test-WuuPrerequisite'
    'Get-WuuOperationLabel'
    'Test-WuuOperationRequiresReason'
    'Get-WuuPreflightReport'
    'New-WuuOperationPlan'
)
