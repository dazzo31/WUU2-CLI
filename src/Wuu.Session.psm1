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

Export-ModuleMember -Function @(
    'Test-WuuComputerName'
    'Split-WuuComputerNames'
    'New-WuuComputerSet'
    'Get-WuuComputerSetComputers'
    'Get-WuuComputerSetCount'
    'Get-WuuComputerSetPhases'
    'Get-WuuComputerSetSummary'
    'Add-WuuComputerSetNames'
)
