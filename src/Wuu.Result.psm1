#Requires -Version 5.1
<#
.DESCRIPTION
The COMMAND RESULT MODEL (instructions SS33/SS34): one structured result per command, from which both
the human-readable output and the JSON output are derived.

WHY THIS EXISTS. `-Json` was emitted from two unrelated places - Core's command shell and
Invoke-WuuCommand's -WhatIf branch - each hand-building its own object. Two shapes meant a consumer had
to know which shape it was given, and adding a field to one did nothing for the other. SS33 asks for one
model; SS34 asks for the JSON to be a versioned API.

WHAT IS PRESERVED, DELIBERATELY. The documented JSON contract is PascalCase and is asserted in
docs/EXIT_CODES.md. Renaming a field is a BREAKING change to an automation interface (SS34), so the
existing names - Command, Ok, ExitCode, Completed, Outstanding, Computers - keep their spelling and
meaning. The model adds to the contract; it does not rewrite it. A new `SchemaVersion` field tells a
consumer which revision of the contract it is reading, without changing any field it already reads.
#>

$script:WuuResultSchemaVersion = 1

function Get-WuuResultSchemaVersion {
    <#
    .SYNOPSIS The schema version stamped on every command result.
    .DESCRIPTION Bumped when the SHAPE changes in a way a consumer must know about - a renamed, removed
    or re-typed field. Adding a field is compatible and does not bump it. Kept in one place so the JSON
    and any consumer's expectation cannot drift.
    #>
    return $script:WuuResultSchemaVersion
}

function Get-WuuCommandCounts {
    <#
    .SYNOPSIS Per-status target counts for a command result (SS33: requestedCount, completedCount, ...).
    .DESCRIPTION
    Computed from the per-target verdicts, using the SAME predicate the exit code uses
    (Get-WuuTargetOutcome), so the headline counts and the exit code cannot disagree about what
    "failed" means - the defect class SS10 closed for the exit code itself.

    Settled and outstanding are counted separately on purpose. A target still running or still queued
    has NOT failed; counting it as one would make a long `check -All` report failures merely for working
    through an estate, which is the reason Get-WuuAggregateOutcome ignores unsettled targets.

    'refused' is counted from the stored refusal record rather than inferred: a refusal is a submission
    that was declined (a busy computer, the global cap), and the row keeps `RefusedCount` for exactly
    this reason. 'timedOut' is a settled outcome, not the same thing as "still outstanding".

    Returns a hashtable, never a bare number, so a caller cannot confuse one count for another.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Rows = @()
    )

    # A LOCAL, not the parameter: assigning back to $Rows would be a parameter reassignment, which this
    # codebase bans outright (a gated rule - type coercion on reassignment can throw). The gate caught
    # this on the first run.
    $rowList = @($Rows | Where-Object { $_ })
    $n = @{ requested = $rowList.Count; completed = 0; failed = 0; timedOut = 0; refused = 0; queued = 0; started = 0; outstanding = 0 }

    foreach ($row in $rowList) {
        $outcome = Get-WuuTargetOutcome -Row $row
        switch ($outcome) {
            'Success' { $n.completed++ }
            'Failed'  { $n.failed++ }
            'TimedOut' { $n.timedOut++ }
        }

        $opState = if ($row.PSObject.Properties['OpState']) { [string]$row.OpState } else { '' }
        $pending = if ($row.PSObject.Properties['Pending']) { [bool]$row.Pending } else { $false }

        # `outstanding` USES THE EXISTING DOCUMENTED PREDICATE - OpState='Running' OR Pending - and not a
        # new one. It is already in the JSON contract (docs/EXIT_CODES.md, and Core computes it that way
        # for Completed/Outstanding), so redefining it would silently change a field a consumer reads.
        # A first version of this function instead derived "outstanding" from the settlement verdict and
        # reported 1 where the documented predicate says 3 - a breaking change smuggled in as an
        # improvement, which is exactly what SS34 warns about.
        if ($opState -eq 'Running' -or $pending) { $n.outstanding++ }

        # SS33's finer split, ADDED to the contract rather than replacing it: a target that is RUNNING
        # has started; one that is only queued (Pending, not yet admitted) has not.
        if ($opState -eq 'Running') { $n.started++ }
        elseif ($pending) { $n.queued++ }

        # A refusal is recorded on the row by Update-WuuRefusalRecord; read it rather than re-deriving it.
        if ($row.PSObject.Properties['RefusedCount'] -and [int]$row.RefusedCount -gt 0) { $n.refused++ }
    }
    return $n
}

function New-WuuCommandResult {
    <#
    .SYNOPSIS Builds the one structured result a command produces (SS33).
    .DESCRIPTION
    Both the human output and the JSON are rendered FROM this object, so a field cannot exist in one
    and not the other - which is the SS33 requirement, and the defect the two hand-built JSON shapes had.

    Fields, and why each is present:
      SchemaVersion   which contract revision this is (SS34)
      Command         the verb, so a pipeline of commands is self-describing
      Ok              whether the command itself succeeded (not whether every target did)
      ExitCode        the documented code; the JSON carries it so a script need not trust the
                      exit alone (docs/EXIT_CODES.md states this explicitly)
      Status          the exit-code vocabulary name, so the JSON is readable without a lookup table
      Completed       whether the bounded wait saw the work finish (NOT "every target succeeded")
      Outstanding     how many targets still had work when the wait ended
      Counts          the per-status counts (requested/completed/failed/timedOut/refused/queued)
      Computers       the per-target snapshot, unchanged from the documented contract
      ErrorMessage    present only on failure. NOT named `$Error: that is a PowerShell AUTOMATIC
                      variable, so a parameter of that name cannot be bound - and this codebase has hit
                      that collision before.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][bool]$Ok,
        [Parameter(Mandatory)][int]$ExitCode,
        [string]$Status = '',
        [bool]$Completed = $false,
        [int]$Outstanding = 0,
        [hashtable]$Counts = @{},
        [AllowEmptyCollection()][object[]]$Computers = @(),
        [string]$ErrorMessage = ''
    )

    # Status defaults to the vocabulary name for the code, so the two cannot drift apart in the output.
    # Written to a LOCAL, not back to the parameter: assigning to a parameter is banned in this codebase
    # (gated), and the gate caught this too.
    $statusName = if ($Status) { $Status } else { Get-WuuExitCodeName -Code $ExitCode }

    [pscustomobject]@{
        SchemaVersion = Get-WuuResultSchemaVersion
        Command       = $Command
        Ok            = $Ok
        ExitCode      = $ExitCode
        Status        = $statusName
        Completed     = $Completed
        Outstanding   = $Outstanding
        RequestedCount  = [int]$Counts['requested']
        StartedCount    = [int]$Counts['started']
        CompletedCount  = [int]$Counts['completed']
        FailedCount     = [int]$Counts['failed']
        TimedOutCount   = [int]$Counts['timedOut']
        RefusedCount    = [int]$Counts['refused']
        QueuedCount     = [int]$Counts['queued']
        Computers     = @($Computers)
        ErrorMessage  = $ErrorMessage
    }
}

function Get-WuuExitCodeName {
    <#
    .SYNOPSIS The vocabulary NAME for an exit code (the inverse of Get-WuuExitCode).
    .DESCRIPTION
    Kept next to Get-WuuExitCode's own table so the number and the name cannot drift. Returns '' for an
    unknown code rather than inventing a name - an unknown code is a defect worth seeing, not something
    to paper over with a plausible label.
    #>
    param([Parameter(Mandatory)][int]$Code)
    switch ($Code) {
        0 { 'Success' }
        1 { 'OperationFailed' }
        2 { 'UsageError' }
        3 { 'Timeout' }
        4 { 'PartialSuccess' }
        5 { 'AuditFailure' }
        6 { 'Queued' }
        7 { 'Refused' }
        default { '' }
    }
}

function ConvertTo-WuuResultObject {
    <#
    .SYNOPSIS The JSON-ready form of a command result (SS34).
    .DESCRIPTION
    A separate step because PowerShell's ConvertTo-Json renders a hashtable differently from a
    PSCustomObject, and the documented contract is an object with named fields. Field ORDER is stable so a
    diff of two runs is readable, and every field the documented contract promises is present even when
    empty - a field that vanishes when it has no value is a field a consumer crashes on.
    #>
    param([Parameter(Mandatory)][object]$Result)

    $ordered = [ordered]@{}
    foreach ($name in @(
            'SchemaVersion', 'Command', 'Ok', 'ExitCode', 'Status', 'Completed', 'Outstanding',
            'RequestedCount', 'StartedCount', 'CompletedCount', 'FailedCount', 'TimedOutCount', 'RefusedCount', 'QueuedCount',
            'Computers', 'ErrorMessage')) {
        if ($Result.PSObject.Properties[$name]) { $ordered[$name] = $Result.$name }
    }
    return [pscustomobject]$ordered
}

function Format-WuuJsonDocument {
    <#
    .SYNOPSIS
    Renders ANY command's JSON output: a versioned envelope, then the command's own fields (SS34).
    .DESCRIPTION
    WHY EVERY COMMAND NEEDS THIS. The result model covers the mutating verbs, but the READ verbs
    published their own shapes with no version field at all - `audit verify` emitted Command/LogPath/Ok/
    Checked/FirstBreak/Problems, `audit show` emitted Command/LogPath/Count/Records, and `-WhatIf` emitted
    a plan object. A consumer therefore had to know which command it had called before it could parse
    the answer, and had no way to detect a schema change. That is the same class of defect the
    command-result model closed for the mutating verbs, and SS34 requires it be closed for all of them.

    THE SHAPE IS ADDITIVE. Every field each verb already published keeps its exact spelling and meaning.
    Two fields are PREPENDED:
      SchemaVersion  which revision of the contract this is (SS34). A consumer can now detect a change
                     instead of discovering it.
      Command        the verb, so a document is self-describing. Commands that already published
                     `Command` are unaffected: this sets the value they were already setting.
    Field ORDER is stable (envelope first, then the caller's fields in the order given) so a diff of two
    runs is readable, and the `Computers` array is kept as an array even when it holds one element or
    none - unwrapping to a scalar is what breaks a consumer's iteration.

    DEPTH DEFAULTS TO 6, not the ConvertTo-Json default of 2. At depth 2 a nested record is rendered as a
    type name rather than as data, so a consumer silently receives a string where it expected an object.
    The deepest shipped shape (a plan carrying per-target detail) needs 6.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][AllowNull()][object]$Fields,
        [int]$Depth = 6
    )

    $doc = [ordered]@{}
    $doc['SchemaVersion'] = Get-WuuResultSchemaVersion
    $doc['Command'] = $Command

    # Copy the caller's fields in the order given. A null/absent bag yields an envelope-only document,
    # which is still valid and still versioned - a command with nothing to report must not emit nothing.
    if ($null -ne $Fields) {
        $names = @()
        if ($Fields -is [System.Collections.IDictionary]) {
            $names = @($Fields.Keys)
        } elseif ($Fields -is [System.Management.Automation.PSCustomObject]) {
            $names = @($Fields.PSObject.Properties | ForEach-Object { $_.Name })
        } else {
            $names = @($Fields.PSObject.Properties | ForEach-Object { $_.Name })
        }
        foreach ($name in $names) {
            if ($name -eq 'SchemaVersion') { continue }   # the envelope owns this; a caller cannot override it
            # AN EXPLICIT if-STATEMENT, never `$value = if (...) {...} else {...}`. An if used as an
            # EXPRESSION runs its branch through the pipeline, which UNROLLS a collection: an empty
            # array becomes $null and a one-element array becomes a bare scalar. Measured - the
            # expression form rendered `"P": { }` where the statement form renders `"P": []`, and a
            # single-element list was silently downgraded from a list to a value.
            if ($Fields -is [System.Collections.IDictionary]) { $value = $Fields[$name] }
            else { $value = $Fields.$name }
            # Plain assignment, not `, $value`: comma-wrapping an array DOUBLE-NESTS it (an empty one
            # became [[]], which parses back as one element rather than zero). Assignment already
            # preserves an empty array as [] and a populated one as [ ... ].
            $doc[$name] = $value
        }
    }

    return ([pscustomobject]$doc | ConvertTo-Json -Depth $Depth)
}

function Format-WuuResultJson {
    <#
    .SYNOPSIS Renders a command result as JSON text (the -Json output).
    .DESCRIPTION One renderer, so the call sites that used to hand-build JSON cannot diverge again.
    Delegates to Format-WuuJsonDocument for the versioned envelope, so the command result and every other
    command's document carry the SAME schema version from the SAME place.
    #>
    param(
        [Parameter(Mandatory)][object]$Result,
        [int]$Depth = 6
    )
    $obj = ConvertTo-WuuResultObject -Result $Result
    $command = if ($obj.PSObject.Properties['Command']) { [string]$obj.Command } else { '' }
    $fields = [ordered]@{}
    foreach ($p in $obj.PSObject.Properties) {
        if ($p.Name -eq 'SchemaVersion' -or $p.Name -eq 'Command') { continue }
        $fields[$p.Name] = $p.Value
    }
    return (Format-WuuJsonDocument -Command $command -Fields $fields -Depth $Depth)
}

function Get-WuuJsonSchemaVersion {
    <#
    .SYNOPSIS The schema version of the whole command-JSON contract (an alias of the result version).
    .DESCRIPTION Exists so a caller asking about JSON need not know that the version is defined by the
    result model. One number, two entry points, no second constant to drift.
    #>
    return (Get-WuuResultSchemaVersion)
}

Export-ModuleMember -Function @(
    'Get-WuuResultSchemaVersion'
    'Get-WuuJsonSchemaVersion'
    'Get-WuuCommandCounts'
    'New-WuuCommandResult'
    'Get-WuuExitCodeName'
    'ConvertTo-WuuResultObject'
    'Format-WuuJsonDocument'
    'Format-WuuResultJson'
)
