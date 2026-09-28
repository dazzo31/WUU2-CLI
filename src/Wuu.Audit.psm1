#Requires -Version 5.1
<#
.DESCRIPTION
Audit trail for WUU2-CLI (Phase 4 of docs/CLI_AUDIT_PLAN.md section 5).

Produces an append-only, hash-chained record of every action, plus a session transcript.

WHAT THIS GIVES YOU, AND WHAT IT DOES NOT
-----------------------------------------
The chain makes silent edits DETECTABLE, not IMPOSSIBLE. Anyone with write access to the log
file AND the code can recompute a chain over their own edits. That is a property of every
hash-chained log, not a defect in this one. Real non-repudiation needs the chain head anchored
somewhere the operator cannot rewrite - see the plan's section 5.6 (Windows Event Log mirror or a
certificate-signed daily digest). Until that anchor exists, treat this as "tamper-evident to a
careful auditor", not "non-repudiable".

DESIGN DECISIONS
----------------
1. FAIL-CLOSED FOR MUTATING ACTIONS. If the audit record cannot be written, the mutating action
   is NOT performed. An unlogged change to a remote host is worse than a refused one. (Read-only
   actions log on a best-effort basis - failing them would be unhelpful.)
2. INTENT + OUTCOME, TWO RECORDS. A mutating action writes result='started' BEFORE it runs and
   result='succeeded'/'failed' after. Two append-only lines, linked by correlationId. So there is
   evidence the action was attempted even if the process is killed mid-flight - which a single
   write-after-the-fact record cannot give you.
3. HASH OVER THE CANONICAL FORM, NOT THE PRETTY-PRINTED LINE. Record order/whitespace must not
   change the hash, or a reordered-but-identical record would look like tampering. The canonical
   serializer sorts keys and normalises types.
   CRITICAL: the canonical form must distinguish an ARRAY from a STRING. A naive implementation
   collapses ["one"] and "one" to the same text, so two different records hash identically -
   a collision in the very component the chain depends on. There is a regression test for this
   (tests\Test-AuditTrail.ps1, "array vs string must not collide").
   The hash therefore DOES NOT depend on the stored line bytes, which also means verification
   re-serialises each parsed record rather than re-reading the line.
4. NEVER IN A SYNCED FOLDER. Default location is %PROGRAMDATA%\WUU2\audit. Writing logs into a
   OneDrive-synced tree caused real, repeated failures in this codebase (transient file locks
   during placeholder hydration), so the audit log must not live there either.
5. APPEND ONLY. The file is opened with FileMode::Append and never rewritten. Nothing in this
   module edits or deletes an existing record.
#>

#region Paths

function Get-WuuAuditDirectory {
    <#
    .SYNOPSIS The audit directory, created on demand.
    .DESCRIPTION %PROGRAMDATA%\WUU2\audit by default. Falls back to LocalAppData when
    ProgramData is unwritable, and reports which was used so a caller can log it. Deliberately
    never returns anything under a user profile that a sync engine watches (see decision 4).
    #>
    param([string]$Path)

    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $candidates = @(
        (Join-Path $env:ProgramData 'WUU2\audit'),
        (Join-Path $env:LOCALAPPDATA 'WUU2\audit')
    )
    foreach ($c in $candidates) {
        try {
            if (-not (Test-Path -LiteralPath $c)) { New-Item -ItemType Directory -Path $c -Force -ErrorAction Stop | Out-Null }
            # Prove it is actually writable, not just creatable.
            $probe = Join-Path $c ('.wuu-write-probe')
            Set-Content -LiteralPath $probe -Value 'ok' -ErrorAction Stop
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            return (Resolve-Path -LiteralPath $c).Path
        } catch {
            Write-WarningLog "Audit directory not writable: $c - $($_.Exception.Message)"
        }
    }
    throw 'No writable audit directory. Set -Path or grant write access to %PROGRAMDATA%\WUU2\audit.'
}

#endregion Paths

#region Canonical serialisation (the hash input)

function Get-WuuCanonicalJson {
    <#
    .SYNOPSIS Deterministic JSON text for hashing.
    .DESCRIPTION
    Sorts object keys, uses invariant formatting for numbers, and - critically - renders arrays
    as arrays. Order of type checks matters: [string] is IEnumerable, so it must be handled
    BEFORE the IEnumerable branch or every string would serialise as a character array.
    #>
    param($InputObject)

    if ($null -eq $InputObject) { return 'null' }

    if ($InputObject -is [string]) {
        $escaped = $InputObject.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
        return '"' + $escaped + '"'
    }
    if ($InputObject -is [bool]) { return $(if ($InputObject) { 'true' } else { 'false' }) }
    if ($InputObject -is [int] -or $InputObject -is [long] -or $InputObject -is [int16] -or $InputObject -is [byte]) {
        return [string]$InputObject
    }
    if ($InputObject -is [double] -or $InputObject -is [decimal] -or $InputObject -is [single]) {
        return ([System.Convert]::ToDecimal($InputObject)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($InputObject -is [datetime]) {
        return '"' + $InputObject.ToUniversalTime().ToString('o') + '"'
    }
    # Hashtable / Dictionary
    if ($InputObject -is [System.Collections.IDictionary]) {
        $keys = @($InputObject.Keys | ForEach-Object { [string]$_ } | Sort-Object -Culture ([System.Globalization.CultureInfo]::InvariantCulture))
        $parts = foreach ($k in $keys) { (Get-WuuCanonicalJson $k) + ':' + (Get-WuuCanonicalJson $InputObject[$k]) }
        return '{' + ($parts -join ',') + '}'
    }
    # PSCustomObject (and anything else with properties but no dictionary interface)
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $names = @($InputObject.PSObject.Properties.Name | Sort-Object -Culture ([System.Globalization.CultureInfo]::InvariantCulture))
        $parts = foreach ($n in $names) { (Get-WuuCanonicalJson $n) + ':' + (Get-WuuCanonicalJson $InputObject.$n) }
        return '{' + ($parts -join ',') + '}'
    }
    # Arrays / lists - MUST come after [string].
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = foreach ($i in $InputObject) { Get-WuuCanonicalJson $i }
        return '[' + (@($items) -join ',') + ']'
    }
    # Fallback: stringify (also keeps unexpected types from producing invalid JSON).
    return (Get-WuuCanonicalJson ([string]$InputObject))
}

function Get-WuuRecordHash {
    <#
    .SYNOPSIS hash = SHA256(canonical(record without its hash field) + '|' + prevHash)
    .DESCRIPTION The record's own Hash field is excluded so the hash can be recomputed; PrevHash is
    included so removing or reordering a record breaks the chain at that point.
    #>
    param(
        [Parameter(Mandatory)]$Record,
        [string]$PrevHash = ''
    )
    # Build an ordered copy without Hash (and without the mutable result-update field).
    $payload = [ordered]@{}
    foreach ($p in $Record.PSObject.Properties) {
        if ($p.Name -eq 'Hash') { continue }
        $payload[$p.Name] = $p.Value
    }
    $canonical = Get-WuuCanonicalJson $payload
    $material = $canonical + '|' + $PrevHash
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($material)
        return ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally { $sha.Dispose() }
}

#endregion Canonical serialisation

#region Session + record writing

function Start-WuuAuditSession {
    <#
    .SYNOPSIS Opens an audit session: operator identity, run id, log file, transcript.
    .DESCRIPTION Returns a session object the caller passes to Write-WuuAuditRecord. The run id
    is per-process so concurrent sessions never share one, which keeps "which run did this"
    unambiguous when several operators work at once.
    #>
    param(
        [string]$Directory,
        [string]$Action = 'session',
        [string]$Reason = ''
    )
    $dir = Get-WuuAuditDirectory -Path $Directory
    $operatorCtx = New-WuuOperatorContext
    $logPath = Join-Path $dir ("audit-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd'))
    # Continue the existing chain when appending to a file that already has records: both the
    # hash AND the sequence must resume, or verification would flag the join as tampering
    # (seq restarting at 1 reads as a deleted record).
    $head = Get-WuuAuditChainHead -LogPath $logPath
    $session = [pscustomobject]@{
        RunId     = $operatorCtx.RunId
        Operator  = [pscustomobject]@{
            User     = $operatorCtx.User
            Machine  = $operatorCtx.Machine
            Elevated = $operatorCtx.Elevated
        }
        StartedUtc = $operatorCtx.StartedUtc
        Directory  = $dir
        LogPath    = $logPath
        TranscriptPath = Join-Path $dir ("transcript-{0}-{1}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $operatorCtx.RunId.Substring(0, 8))
        Seq        = [int]$head.Seq
        LastHash   = [string]$head.Hash
        Lock       = New-Object object
        Reason     = $Reason
    }
    Write-WuuAuditRecord -Session $session -Action 'session-start' -Result 'started' -Parameters @{ action = $Action } -SkipFailClosed | Out-Null
    return $session
}

function Write-WuuAuditRecord {
    <#
    .SYNOPSIS Appends one hash-chained record.
    .DESCRIPTION
    Appends a single JSON line. Chain: each record carries the previous record's hash, so any
    edit, deletion or reordering breaks verification from that point on.

    -FailClosed throws when the write fails (used for mutating actions: no audit, no change).
    Without it, a write failure is a warning (read-only actions must not be blocked by logging).

    The write is retried because transient locks are real on Windows (see the OneDrive lesson
    in this codebase) - but for audit, three failures is a hard error, not a silent give-up:
    a silently-missing audit record is worse than a failed operation.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Action,
        [string]$Result = 'info',
        [string[]]$Targets = @(),
        [hashtable]$Parameters = @{},
        [string]$CorrelationId = '',
        [int]$DurationMs = 0,
        [hashtable]$Counts = @{},
        # NOTE: not named -Error. $Error is a read-only automatic variable in PowerShell;
        # a parameter of that name cannot be assigned and fails at runtime.
        [string]$ErrorMessage = '',
        [string]$Reason = '',
        [switch]$FailClosed,
        [switch]$SkipFailClosed
    )

    $record = [ordered]@{
        seq           = ++$Session.Seq
        timestampUtc  = (Get-Date).ToUniversalTime().ToString('o')
        runId         = $Session.RunId
        correlationId = if ($CorrelationId) { $CorrelationId } else { [guid]::NewGuid().ToString('N') }
        operator      = $Session.Operator
        action        = $Action
        targets       = @($Targets)
        parameters    = $Parameters
        reason        = if ($Reason) { $Reason } else { $Session.Reason }
        result        = $Result
        error         = $ErrorMessage
        counts        = $Counts
        durationMs    = $DurationMs
        wuuVersion    = 'v1.3.4-cli'
        prevHash      = $Session.LastHash
    }
    $recordObj = [pscustomobject]$record
    $hash = Get-WuuRecordHash -Record $recordObj -PrevHash $Session.LastHash
    $recordObj | Add-Member -NotePropertyName Hash -NotePropertyValue $hash

    $line = $recordObj | ConvertTo-Json -Compress -Depth 8

    $written = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $lockTaken = $false
        try {
            [System.Threading.Monitor]::Enter($Session.Lock); $lockTaken = $true
            Add-Content -LiteralPath $Session.LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
            $written = $true
            break
        } catch {
            if ($attempt -ge 3) {
                $msg = "Audit write failed after 3 attempts: $($_.Exception.Message)"
                Write-ErrorLog $msg
                if ($FailClosed -and -not $SkipFailClosed) { throw $msg }
                Write-WarningLog $msg
            } else {
                Start-Sleep -Milliseconds (100 * $attempt)
            }
        } finally {
            if ($lockTaken) { [System.Threading.Monitor]::Exit($Session.Lock) }
        }
    }
    if ($written) { $Session.LastHash = $hash }
    return $recordObj
}

function Get-WuuAuditChainHead {
    <#
    .SYNOPSIS Returns the latest hash and sequence number in a log file.
    .DESCRIPTION
    Lets a NEW session continue an existing chain instead of starting a fresh one, so a chain
    spans sessions rather than resetting daily.

    The SEQUENCE matters as much as the hash: verification asserts seq is contiguous, so if a
    new session restarted at 1 while appending to the same daily file, every later record would
    look like a deleted one. Returns both so a session can continue from the true position.
    #>
    param([Parameter(Mandatory)][string]$LogPath)
    $result = [pscustomobject]@{ Hash = ''; Seq = 0 }
    if (-not (Test-Path -LiteralPath $LogPath)) { return $result }
    $last = $null
    foreach ($line in (Get-Content -LiteralPath $LogPath)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $last = $line }
    }
    if (-not $last) { return $result }
    try {
        $rec = $last | ConvertFrom-Json
        return [pscustomobject]@{ Hash = [string]$rec.Hash; Seq = [int]$rec.seq }
    } catch {
        Write-WarningLog "Audit: could not read the last record's hash/seq from $LogPath - starting a fresh chain."
        return $result
    }
}

#endregion Session + record writing

#region Verification

function Test-WuuAuditChain {
    <#
    .SYNOPSIS Verifies a chain, reporting the FIRST break.
    .DESCRIPTION
    Walks the log recomputing each hash from the record's canonical form plus the previous hash.
    Reports every problem found but flags the first, because after the first break every later
    record is unreliable - a single early edit invalidates the remainder by design.

    Detects: a modified record, a deleted record, a reordered record, and a malformed line.
    Does NOT detect a full rewrite where the attacker recomputes every hash (see the module
    header - that needs an external anchor).
    #>
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [switch]$Quiet
    )

    if (-not (Test-Path -LiteralPath $LogPath)) {
        return [pscustomobject]@{ Ok = $false; Checked = 0; FirstBreak = 1; Problems = @("Log not found: $LogPath") }
    }

    $lines = @(Get-Content -LiteralPath $LogPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $problems = New-Object System.Collections.ArrayList
    $prevHash = ''
    $expectedSeq = 1
    $lineNo = 0

    foreach ($line in $lines) {
        $lineNo++
        $rec = $null
        try { $rec = $line | ConvertFrom-Json } catch {
            [void]$problems.Add("line ${lineNo}: malformed JSON - $($_.Exception.Message)")
            continue
        }
        # Sequence must be contiguous: catches a deleted record even if the chain were repaired.
        if ([int]$rec.seq -ne $expectedSeq) {
            [void]$problems.Add("line ${lineNo}: sequence gap (expected $expectedSeq, found $($rec.seq)) - record deleted or reordered")
        }
        $expectedSeq = [int]$rec.seq + 1

        if ([string]$rec.prevHash -ne $prevHash) {
            [void]$problems.Add("line ${lineNo}: prevHash mismatch (expected '$prevHash', found '$($rec.prevHash)')")
        }

        $stored = [string]$rec.Hash
        $recomputed = Get-WuuRecordHash -Record $rec -PrevHash $prevHash
        if ($stored -ne $recomputed) {
            [void]$problems.Add("line ${lineNo}: hash mismatch - record contents were altered (stored $stored, computed $recomputed)")
        }

        $prevHash = $stored   # follow the STORED chain so one edit does not cascade into noise
    }

    $firstBreak = 0
    if ($problems.Count -gt 0) {
        # First break = line number parsed out of the earliest problem message.
        $firstBreak = [int](($problems[0] -split ':')[0] -replace '[^0-9]', '')
        if (-not $Quiet) {
            foreach ($p in $problems) { Write-Host "  $p" -ForegroundColor Red }
        }
    }

    return [pscustomobject]@{
        Ok        = ($problems.Count -eq 0)
        Checked   = $lineNo
        FirstBreak = $firstBreak
        Problems  = @($problems)
    }
}

#endregion Verification

#region Audited action wrapper

function Invoke-WuuAuditedAction {
    <#
    .SYNOPSIS Runs a mutating action with intent+outcome audit records (fail-closed).
    .DESCRIPTION
    The single choke point for audited mutations. Order is deliberate:
      1. write result='started'   - if this FAILS the action does NOT run (fail-closed)
      2. run the action
      3. write result='succeeded'/'failed'
    A process killed between 1 and 3 still leaves evidence that the action was attempted, which
    write-after-the-fact logging cannot provide.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][scriptblock]$Body,
        [string[]]$Targets = @(),
        [hashtable]$Parameters = @{},
        [string]$Reason = '',
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-WuuAuditRecord -Session $Session -Action $Action -Result 'whatif' -Targets $Targets `
            -Parameters $Parameters -Reason $Reason | Out-Null
        Write-Host ("  [WhatIf] audited intent recorded for '{0}' - action not run." -f $Action) -ForegroundColor Yellow
        return [pscustomobject]@{ Ok = $true; WhatIf = $true }
    }

    $correlationId = [guid]::NewGuid().ToString('N')
    # Step 1 - fail-closed intent record.
    Write-WuuAuditRecord -Session $Session -Action $Action -Result 'started' -Targets $Targets `
        -Parameters $Parameters -CorrelationId $correlationId -Reason $Reason -FailClosed | Out-Null

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = $false; $errMsg = ''
    try {
        & $Body
        $ok = $true
    } catch {
        $errMsg = $_.Exception.Message
        Write-ErrorLog "Audited action '$Action' failed: $errMsg"
    } finally {
        $sw.Stop()
        # Step 3 - outcome record. Best-effort here: the action already happened, and throwing
        # now would misreport it as failed.
        Write-WuuAuditRecord -Session $Session -Action $Action `
            -Result $(if ($ok) { 'succeeded' } else { 'failed' }) `
            -Targets $Targets -Parameters $Parameters -CorrelationId $correlationId `
            -DurationMs ([int]$sw.ElapsedMilliseconds) -ErrorMessage $errMsg -Reason $Reason | Out-Null
    }
    return [pscustomobject]@{ Ok = $ok; Error = $errMsg; CorrelationId = $correlationId }
}

#endregion Audited action wrapper

Export-ModuleMember -Function @(
    'Get-WuuAuditDirectory'
    'Get-WuuCanonicalJson'
    'Get-WuuRecordHash'
    'Start-WuuAuditSession'
    'Write-WuuAuditRecord'
    'Get-WuuAuditChainHead'
    'Test-WuuAuditChain'
    'Invoke-WuuAuditedAction'
)
