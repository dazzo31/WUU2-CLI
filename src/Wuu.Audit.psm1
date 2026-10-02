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

#region ISO 27001 event categories

function Resolve-WuuAuditCategory {
    <#
    .SYNOPSIS Maps an action to an ISO 27001 A.8.15 event category.
    .DESCRIPTION
    A.8.15 expects activity logging to cover, at minimum: access to systems, changes to
    configuration and data, and privileged/administrative operations. This maps WUU's actions
    onto those buckets so a report can be filtered by category without the caller classifying
    each call site by hand (which would drift).

    Categories used:
      session              - start/end of a WUU session
      access               - authentication / credential configuration
      configuration_change - WUU's own configuration (computer list, save/load, settings)
      data_change          - changes to the TARGET's state (download/install/restart/service)
      operational          - read-only operations (checks, views, exports, audits)
      outcome              - the outcome half of a mutating action (paired by correlationId)
    #>
    param(
        [Parameter(Mandatory)][string]$Action,
        [string]$Result = 'info',
        [switch]$Mutating
    )

    # Session lifecycle is checked first: a session START carries result='started' and must be
    # categorised as a session event, not as the outcome half of a mutation.
    if ($Action -match '^session') { return 'session' }
    # The outcome record of a mutation is categorised the same as its intent, so a filtered
    # report shows the whole operation under one category rather than splitting it in two.
    if ($Result -in @('succeeded', 'failed', 'started', 'denied')) { return 'outcome' }
    if ($Action -match 'credential|access') { return 'access' }
    if ($Action -match 'config|save|load|export|add|remove|clear|phase') { return 'configuration_change' }
    if ($Mutating -or $Action -match 'download|install|restart|service') { return 'data_change' }
    return 'operational'
}

#endregion ISO 27001 event categories

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

#region Session transcript

function Start-WuuAuditTranscript {
    <#
    .SYNOPSIS Starts capturing the session's console output to the transcript file.
    .DESCRIPTION
    The JSONL trail records WHAT was done as structured data; the transcript records what the
    operator SAW, which is what answers "why did they think that was the right thing to do?".

    This is deliberately best-effort and OPT-IN:
      * it never throws (a transcript failure must not stop an operation), and
      * the caller says whether to use it.
    Reason: Start-Transcript captures the host's output stream, which is broad and can interact
    with a redirection the operator set up themselves. Failing an update because transcript
    capture failed would be the wrong trade.

    Console output in this edition is line-oriented (no cursor positioning or progress redraws)
    precisely so the transcript stays readable and diff-able - see docs/CLI_AUDIT_PLAN.md 5.3.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [switch]$Force
    )
    if (-not $Session.TranscriptPath) { return $false }
    if ($Session.PSObject.Properties['TranscriptActive'] -and $Session.TranscriptActive) { return $true }
    try {
        # -Force appends to an existing file if one is already open; harmless for a fresh path.
        Start-Transcript -LiteralPath $Session.TranscriptPath -Append -Force -ErrorAction Stop | Out-Null
        $Session | Add-Member -NotePropertyName TranscriptActive -NotePropertyValue $true -Force
        Write-InfoLog "Audit transcript started: $($Session.TranscriptPath)"
        return $true
    } catch {
        # Expected in some hosts (e.g. already transcribing, or a constrained host). Not fatal.
        Write-DebugLog "Audit transcript unavailable ($($_.Exception.Message)) - continuing without it." -Level 'WARN'
        $Session | Add-Member -NotePropertyName TranscriptActive -NotePropertyValue $false -Force
        return $false
    }
}

function Stop-WuuAuditTranscript {
    <#
    .SYNOPSIS Stops transcript capture if this session started it.
    .DESCRIPTION Only stops what this session started, so WUU never kills a transcript the operator
    started themselves for their own reasons.
    #>
    param([Parameter(Mandatory)]$Session)
    if (-not ($Session.PSObject.Properties['TranscriptActive'] -and $Session.TranscriptActive)) { return }
    try {
        Stop-Transcript -ErrorAction Stop | Out-Null
        Write-InfoLog 'Audit transcript stopped.'
    } catch {
        Write-DebugLog "Audit transcript stop failed: $($_.Exception.Message)" -Level 'WARN'
    }
    $Session.TranscriptActive = $false
}

#endregion Session transcript

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
    $session = [pscustomobject]@{
        RunId     = $operatorCtx.RunId
        Operator  = [pscustomobject]@{
            User     = $operatorCtx.User
            Machine  = $operatorCtx.Machine
            Elevated = $operatorCtx.Elevated
        }
        # ISO 27001 A.8.15 / 27002 expects each event to answer: WHO did WHAT, to WHICH target,
        # WHEN, from WHERE, and with WHAT OUTCOME. Host + ProcessId are the "where"; they are
        # captured on the session so every record inherits them without the caller passing them.
        HostName  = $operatorCtx.Machine
        ProcessId = $PID
        StartedUtc = $operatorCtx.StartedUtc
        # Environment context, captured once and emitted on the session-start record. An auditor
        # reconstructing a change needs to know which OS/PowerShell build produced it - a
        # behavioural difference between Windows builds is a common explanation for "why did the
        # same action have a different outcome".
        Environment = [pscustomobject]@{
            OSVersion      = [string][System.Environment]::OSVersion.VersionString
            OSArchitecture = [string][System.Environment]::Is64BitOperatingSystem
            PSVersion      = [string]$PSVersionTable.PSVersion
            PSEdition      = [string]$PSVersionTable.PSEdition
            ClrVersion     = [string]$PSVersionTable.CLRVersion
            Culture        = [string][System.Globalization.CultureInfo]::CurrentCulture.Name
            ComputerName   = [string][System.Environment]::MachineName
            UserName       = [string][System.Environment]::UserName
        }
        Directory  = $dir
        LogPath    = $logPath
        TranscriptPath = Join-Path $dir ("transcript-{0}-{1}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $operatorCtx.RunId.Substring(0, 8))
        # Seq/LastHash are NOT pre-read from the file: the locked writer reads the true chain head
        # inside its exclusive lock and reports back the real seq. Pre-reading here would be a
        # TOCTOU race (another process could append between the read and our first write) and is
        # the bug the concurrency probe demonstrated.
        Seq        = 0
        LastHash   = ''
        Reason     = $Reason
    }
    Write-WuuAuditRecord -Session $session -Action 'session-start' -Result 'started' -Category 'session' `
        -Parameters @{ action = $Action; environment = $session.Environment } -SkipFailClosed | Out-Null
    return $session
}

#region Cross-process append (the correctness-critical part)

<#
WHY THIS IS NOT JUST "Add-Content WITH RETRIES"
-----------------------------------------------
A hash chain requires a read-modify-write cycle: read the previous record's hash, hash our record
against it, append. If two processes do that concurrently they BOTH read the same prevHash, both
compute a valid-looking hash, and both append - so two records claim the same predecessor and
verification reports a chain break. That is a FALSE TAMPERING REPORT on an intact trail, which is
the single worst failure mode for an audit tool: it trains the reader to ignore the alarm.

A probe (Scripts/_probe-concurrency.ps1, 4 processes x 25 records) showed naive appends losing
86 of 100 records AND the chain race above. So the append path takes an EXCLUSIVE OS-level lock
on the log file for the whole read-modify-write:

  * FileShare::None on the log file itself is the cross-process mutex - no separate lock file to
    leak or forget.
  * In-process sessions also serialise on a per-path Monitor lock first, because FileShare::None
    would otherwise make two same-process sessions deadlock on the open.
  * Retry with capped backoff absorbs transient holders (AV scanners, indexers, a slow peer).

This is deliberately NOT the fault-tolerant "log and give up silently" pattern used for debug
logs: a silently-missing audit record is worse than a failed operation.
#>

$script:WuuAuditPathLocks = [hashtable]::Synchronized(@{})
$script:WuuAuditLockTableGate = New-Object object

function Get-WuuAuditPathLock {
    <# Per-path in-process lock so same-process sessions serialise before touching the OS lock. #>
    param([Parameter(Mandatory)][string]$LogPath)
    $key = $LogPath.ToLowerInvariant()
    [System.Threading.Monitor]::Enter($script:WuuAuditLockTableGate)
    try {
        if (-not $script:WuuAuditPathLocks.ContainsKey($key)) {
            $script:WuuAuditPathLocks[$key] = New-Object object
        }
        return $script:WuuAuditPathLocks[$key]
    } finally {
        [System.Threading.Monitor]::Exit($script:WuuAuditLockTableGate)
    }
}

function Read-WuuAuditTailFromStream {
    <#
    .SYNOPSIS Reads the last complete record's Hash + seq from an OPEN stream.
    .DESCRIPTION
    Seeks backwards for the final newline instead of reading the whole file, so appending stays
    O(1) rather than O(n) per write (an O(n^2) audit log would eventually matter). Falls back to
    a full read if the tail window cannot be parsed - correctness over speed.
    #>
    param([Parameter(Mandatory)][System.IO.FileStream]$Stream)

    $empty = [pscustomobject]@{ Hash = ''; Seq = 0 }
    if ($Stream.Length -eq 0) { return $empty }

    $windowSize = 65536
    $len = [int][Math]::Min($windowSize, $Stream.Length)
    $buf = New-Object byte[] $len
    [void]$Stream.Seek(-$len, [System.IO.SeekOrigin]::End)
    $read = $Stream.Read($buf, 0, $len)
    $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)

    # Take the last non-empty line. A partial first line in the window is harmless because we
    # only ever use the LAST line.
    $candidates = @($text -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($candidates.Count -gt 0) {
        $last = $candidates[$candidates.Count - 1].TrimEnd("`r")
        try {
            $rec = $last | ConvertFrom-Json
            return [pscustomobject]@{ Hash = [string]$rec.Hash; Seq = [int]$rec.seq }
        } catch {
            # Window cut a large record, or the file was written by something else - read it all.
            [void]$Stream.Seek(0, [System.IO.SeekOrigin]::Begin)
            $all = New-Object byte[] $Stream.Length
            [void]$Stream.Read($all, 0, $all.Length)
            $whole = [System.Text.Encoding]::UTF8.GetString($all)
            $allLines = @($whole -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($allLines.Count -eq 0) { return $empty }
            try {
                $rec2 = $allLines[$allLines.Count - 1].TrimEnd("`r") | ConvertFrom-Json
                return [pscustomobject]@{ Hash = [string]$rec2.Hash; Seq = [int]$rec2.seq }
            } catch {
                Write-WarningLog "Audit: could not parse the last record; starting a fresh chain segment."
                return $empty
            }
        }
    }
    return $empty
}

function Add-WuuAuditRecordLocked {
    <#
    .SYNOPSIS Appends a record under an exclusive lock, filling in seq/prevHash/Hash atomically.
    .DESCRIPTION
    The caller supplies the record WITHOUT seq, prevHash or Hash. This function takes the lock,
    reads the true chain head, fills those three fields, writes one line, and returns the finished
    record. Doing the head-read INSIDE the lock is the whole point - it is what makes concurrent
    writers chain correctly instead of forking the chain.

    Written BOM-less UTF-8 (JSONL should not carry a BOM mid-file); all readers in this module use
    -Encoding UTF8 explicitly, which decodes both BOM and BOM-less correctly in PS 5.1.
    #>
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Record,
        [int]$MaxAttempts = 60,
        [int]$BaseDelayMs = 25
    )

    $fileLock = Get-WuuAuditPathLock -LogPath $LogPath
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $inProcTaken = $false
        try {
            [System.Threading.Monitor]::Enter($fileLock); $inProcTaken = $true

            # Exclusive cross-process lock for the entire read-modify-write.
            $fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            try {
                $head = Read-WuuAuditTailFromStream -Stream $fs

                $Record['seq'] = [int]$head.Seq + 1
                $Record['prevHash'] = [string]$head.Hash
                $recordObj = [pscustomobject]$Record
                $hash = Get-WuuRecordHash -Record $recordObj -PrevHash ([string]$head.Hash)
                $Record['Hash'] = $hash

                $line = ([pscustomobject]$Record | ConvertTo-Json -Compress -Depth 8)
                $bytes = $utf8NoBom.GetBytes($line + "`n")
                [void]$fs.Seek(0, [System.IO.SeekOrigin]::End)
                $fs.Write($bytes, 0, $bytes.Length)
                $fs.Flush($true)   # flush to disk: a record that is not durable is not evidence
                return [pscustomobject]$Record
            } finally {
                if ($fs) { $fs.Dispose() }
            }
        } catch [System.IO.IOException] {
            # Contended (another process, or a scanner/indexer). Back off with a CAP so we do not
            # grow to multi-second sleeps on a busy file.
            if ($attempt -ge $MaxAttempts) {
                throw "Audit append failed after $MaxAttempts attempts (file locked): $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds ([Math]::Min($BaseDelayMs * $attempt, 500))
        } catch [System.UnauthorizedAccessException] {
            if ($attempt -ge $MaxAttempts) {
                throw "Audit append failed after $MaxAttempts attempts (access denied): $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds ([Math]::Min($BaseDelayMs * $attempt, 500))
        } finally {
            if ($inProcTaken) { [System.Threading.Monitor]::Exit($fileLock) }
        }
    }
    throw 'Audit append failed: exhausted attempts without a definitive error (should be unreachable).'
}

#endregion Cross-process append (the correctness-critical part)

function Write-WuuAuditRecord {
    <#
    .SYNOPSIS Appends one hash-chained record (cross-process safe).
    .DESCRIPTION
    Chain: each record carries the previous record's hash, so any edit, deletion or reordering
    breaks verification from that point on.

    Concurrency: the read-modify-write runs under an exclusive OS file lock (see the region header
    above). Doing the head-read outside that lock is what lets two processes fork the chain and
    produce a FALSE tampering report.

    Fidelity: the record is built here, then seq/prevHash/Hash are filled in by the locked writer,
    which returns the finished record (the caller sees the real seq, not a guess).

    -FailClosed throws when the write fails (used for mutating actions: no audit, no change).
    Without it, a write failure is a warning (read-only actions must not be blocked by logging).
    An audit record is never silently dropped: failure is either an exception (fail-closed) or an
    explicit warning, never a quiet no-op.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Action,
        [string]$Result = 'info',
        # ISO 27001 groups events by category. Inferred from the action name when not supplied
        # (see Resolve-WuuAuditCategory) so every call site gets a category without boilerplate.
        [ValidateSet('', 'session', 'access', 'configuration_change', 'data_change', 'operational', 'outcome')]
        [string]$Category = '',
        [string[]]$Targets = @(),
        [hashtable]$Parameters = @{},
        [string]$CorrelationId = '',
        [int]$DurationMs = 0,
        [hashtable]$Counts = @{},
        # NOTE: not named -Error. $Error is a read-only automatic variable in PowerShell;
        # a parameter of that name cannot be assigned and fails at runtime.
        [string]$ErrorMessage = '',
        [string]$Reason = '',
        # Marks the record as a state-changing operation for category inference. Callers that
        # already know the answer should pass -Category explicitly instead.
        [switch]$Mutating,
        [switch]$FailClosed,
        [switch]$SkipFailClosed
    )

    # seq / prevHash / Hash are filled in by Add-WuuAuditRecordLocked under the file lock.
    #
    # Field set is shaped for ISO 27001 A.8.15 / 27002 event logging: every record answers WHO
    # (operator/runId), WHAT (action/category/parameters), WHICH (targets), WHEN (timestampUtc,
    # and duration for the outcome), WHERE (host/pid), and OUTCOME (result/error/counts). Keep
    # this complete rather than minimal - the whole point of the change from "tamper-evident" to
    # "detailed collection" is that an auditor can reconstruct an action without extra context.
    $record = [ordered]@{
        seq           = 0
        # ISO 8601 with explicit UTC offset ('o' on a UTC DateTime ends in 'Z'), to millisecond
        # precision. Every timestamp in a record uses this same form.
        timestampUtc  = (Get-Date).ToUniversalTime().ToString('o')
        runId         = $Session.RunId
        correlationId = if ($CorrelationId) { $CorrelationId } else { [guid]::NewGuid().ToString('N') }
        operator      = $Session.Operator
        host          = [string]$Session.HostName
        processId     = [int]$Session.ProcessId
        category      = if ($Category) { $Category } else { Resolve-WuuAuditCategory -Action $Action -Result $Result -Mutating:$Mutating }
        action        = $Action
        targets       = @($Targets)
        parameters    = $Parameters
        reason        = if ($Reason) { $Reason } else { $Session.Reason }
        result        = $Result
        error         = $ErrorMessage
        counts        = $Counts
        durationMs    = $DurationMs
        # Read from the single version constant rather than a literal, so a release cannot ship
        # with the audit trail claiming a different version than the app actually is. Falls back
        # only when the module is used standalone (e.g. a unit test importing just Wuu.Audit).
        wuuVersion    = if ($global:WuuVersion) { [string]$global:WuuVersion } else { 'unknown' }
        prevHash      = ''
    }

    try {
        $finished = Add-WuuAuditRecordLocked -LogPath $Session.LogPath -Record $record
        # Keep the session's own view of the chain in step (used by callers that inspect it).
        $Session.Seq = [int]$finished.seq
        $Session.LastHash = [string]$finished.Hash
        return $finished
    } catch {
        $msg = "Audit write failed: $($_.Exception.Message)"
        Write-ErrorLog $msg
        if ($FailClosed -and -not $SkipFailClosed) { throw $msg }
        Write-WarningLog $msg
        return $null
    }
}

function Get-WuuAuditChainHead {
    <#
    .SYNOPSIS Returns the latest hash and sequence number in a log file.
    .DESCRIPTION
    Reads with FileShare::ReadWrite (NOT FileShare::None): taking an exclusive lock just to READ
    would block a concurrent writer and turn a harmless question into contention. A reader that
    only ever takes the last complete line cannot be corrupted by an append in progress - it may
    miss the very newest record, which is correct for an advisory read.

    Used by tests and diagnostics. Write-WuuAuditRecord does NOT call this: it reads the head
    inside the exclusive lock instead, so its read-modify-write cannot race.
    #>
    param([Parameter(Mandatory)][string]$LogPath)
    $result = [pscustomobject]@{ Hash = ''; Seq = 0 }
    if (-not (Test-Path -LiteralPath $LogPath)) { return $result }
    try {
        $fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            return Read-WuuAuditTailFromStream -Stream $fs
        } finally {
            if ($fs) { $fs.Dispose() }
        }
    } catch {
        Write-WarningLog "Audit: could not read the chain head from $LogPath - $($_.Exception.Message)"
        return $result
    }
}

#endregion Session + record writing

#region External anchoring

function New-WuuAuditAnchor {
    <#
    .SYNOPSIS
    Produces a CHAIN-HEAD ANCHOR: the evidence needed to prove, later and OUT OF BAND, that the log has
    not been rewritten (reviewer P3: "external audit anchoring").
    .DESCRIPTION
    THE PROBLEM THIS ADDRESSES, stated plainly because the module's own header already admits it. A
    hash-chained log is tamper-EVIDENT only to someone who already knows what the head was. Anyone with
    write access to the log AND the code can recompute a complete, internally consistent chain over
    their own edits - every hash matches, and verification reports a clean log. That is a property of
    every hash chain, not a defect here, and the fix is not more hashing: it is putting the head
    SOMEWHERE THE LOG'S EDITOR DOES NOT CONTROL.

    WHAT AN ANCHOR IS. A small record - sequence number, head hash, timestamp, log size - written to a
    SEPARATE location. It proves nothing on its own. Its value is entirely in the comparison that
    becomes possible later: if the head recorded in the anchor at time T is not on the chain that the
    log presents now, then everything before that point was rewritten. Without an anchor there is
    nothing to compare against, and a perfectly forged chain is indistinguishable from a real one.

    WHY IT IS A SEPARATE FILE AND NOT A ROW IN THE LOG. An anchor inside the log it anchors is worthless:
    the same write access that rewrites the log rewrites the anchor with it. The whole value is
    SEPARATION, so the caller must place the anchor file on a different volume, a share the audited
    operator cannot write, or in source control - somewhere this process's log-write path does not reach.
    The file's own location is therefore part of the control, and the note on every anchor says so.

    WHAT IT IS NOT. It is NOT non-repudiation, and this comment will not pretend otherwise: an operator
    who can rewrite the anchor too has the same power as before. Anchoring raises the cost from
    "rewrite one file" to "rewrite two files in two places, and any copy anyone else already holds", and
    that is the honest claim. Real non-repudiation needs a trusted timestamp or a signature by a key the
    operator does not have - both deliberately out of scope for a tool that must run unattended with no
    external service.

    Returns a hashtable describing the anchor, and never throws: an anchor that cannot be written must
    not fail the operation that produced the log entry. The caller decides whether to treat that as fatal
    (an audited change with no anchor is weaker evidence, and an operator may want to know).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$AnchorPath,
        [Parameter(Mandatory = $false)][string]$Operator = '',
        [datetime]$Now = (Get-Date)
    )

    $result = @{ Written = $false; Seq = 0; Hash = ''; Reason = '' }

    if (-not (Test-Path -LiteralPath $LogPath)) {
        $result.Reason = "log file not found: $LogPath"
        return $result
    }
    if (-not $AnchorPath) {
        $result.Reason = 'no anchor path supplied'
        return $result
    }

    # REFUSE TO ANCHOR INTO THE LOG'S OWN DIRECTORY. An anchor beside the log is written by the same
    # access path as the log, so it adds no separation and creates a false sense of one. Refusing is the
    # honest behaviour: silently writing a useless anchor is worse than not writing one, because the
    # operator would believe they had an external anchor.
    try {
        $logDir = [System.IO.Path]::GetFullPath((Split-Path -Parent $LogPath))
        $anchorDir = [System.IO.Path]::GetFullPath((Split-Path -Parent $AnchorPath))
        if ($logDir -eq $anchorDir) {
            $result.Reason = "anchor refused: the anchor directory is the log's own directory ('$logDir'), so it offers no separation from the log it anchors"
            return $result
        }
    } catch {
        # A path we cannot normalise is a caller error; reported rather than guessed at.
        $result.Reason = "anchor refused: paths could not be normalised - $($_.Exception.Message)"
        return $result
    }

    try {
        $head = Get-WuuAuditChainHead -LogPath $LogPath
        $size = 0
        try { $size = (Get-Item -LiteralPath $LogPath).Length } catch { }

        $anchor = [ordered]@{
            Schema      = 'wuu.audit.anchor.v1'
            AnchoredUtc = $Now.ToUniversalTime().ToString('o')
            LogPath     = [System.IO.Path]::GetFullPath($LogPath)
            LogBytes    = $size
            Seq         = $head.Seq
            HeadHash    = $head.Hash
            Operator    = $Operator
            # The claim is recorded WITH the artifact so nobody has to infer it from documentation.
            Claim       = 'tamper-evident to the extent that this file is held separately from the log; NOT non-repudiation'
            Note        = 'Hold this file somewhere the audited operator cannot write (another volume, a protected share, source control). If this file and the log are both writable by the same account, it proves nothing.'
        }

        $anchorDirPath = Split-Path -Parent $AnchorPath
        if ($anchorDirPath -and -not (Test-Path -LiteralPath $anchorDirPath)) {
            $null = New-Item -ItemType Directory -Path $anchorDirPath -Force -ErrorAction Stop
        }
        # UTF8 WITHOUT a BOM: this is an interchange artifact read by other tooling, and a BOM is a parse
        # error in some JSON readers. (Source files in this repo DO need BOMs; this is not a source file.)
        $json = $anchor | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($AnchorPath, $json, (New-Object System.Text.UTF8Encoding($false)))

        $result.Written = $true
        $result.Seq = $head.Seq
        $result.Hash = $head.Hash
        $result.Reason = "anchored seq $($head.Seq) to $AnchorPath"
    } catch {
        $result.Reason = "anchor write failed: $($_.Exception.Message)"
    }

    return $result
}

function Test-WuuAuditAnchor {
    <#
    .SYNOPSIS
    Compares an anchor against the chain as it stands now (reviewer P3).
    .DESCRIPTION
    THE COMPARISON THE ANCHOR EXISTS FOR. It answers one question: is the hash the anchor recorded still
    ON the chain the log presents? Three outcomes, and the distinction between them is the whole value:

      Consistent  the anchored head is the current head, or the current head's chain reaches back to it
                  intact. Nothing before the anchor point has changed.
      Rewritten   the chain no longer contains the anchored hash at the anchored sequence number. THIS IS
                  THE FINDING: the log was rebuilt after the anchor was taken, and a rebuilt log verifies
                  cleanly on its own terms, so no amount of chain verification would have found it.
      Unavailable the anchor is missing, unreadable, or does not cover this log.

    Deliberately does NOT re-verify the whole log - that is Test-WuuAuditChain's job, and doing both here
    would conflate two findings: "the chain is broken" and "the chain was rebuilt". A rewritten chain is
    perfectly valid arithmetic; that is exactly why it needs an external comparison to detect.

    A TRUNCATION is reported as Rewritten, not as a special case: a log whose head moved BACKWARD lost
    records, and "the log no longer contains what it did" is the finding regardless of direction. An
    anchor whose Seq exceeds the current head's Seq is the clearest form of it, and gets its own message.

    Never throws: this is called from a release gate and a status command, and neither may fail because
    the anchor is a day old or was written by a different host.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$AnchorPath
    )

    $verdict = @{
        Available = $false; Consistent = $false; Rewritten = $false
        AnchoredSeq = 0; AnchoredHash = ''; CurrentSeq = 0; CurrentHash = ''
        Reason = ''
    }

    if (-not (Test-Path -LiteralPath $AnchorPath)) {
        $verdict.Reason = "no anchor at $AnchorPath - nothing to compare against, so a rewritten log would be undetectable"
        return $verdict
    }
    if (-not (Test-Path -LiteralPath $LogPath)) {
        $verdict.Reason = "log file not found: $LogPath"
        return $verdict
    }

    try {
        $anchorRaw = Get-Content -LiteralPath $AnchorPath -Raw
        $anchor = $anchorRaw | ConvertFrom-Json
    } catch {
        $verdict.Reason = "anchor could not be read: $($_.Exception.Message)"
        return $verdict
    }

    if (-not $anchor.PSObject.Properties['HeadHash'] -or -not $anchor.PSObject.Properties['Seq']) {
        $verdict.Reason = 'anchor is malformed (no HeadHash/Seq) - it cannot be compared'
        return $verdict
    }

    $verdict.Available = $true
    $verdict.AnchoredSeq = [int]$anchor.Seq
    $verdict.AnchoredHash = [string]$anchor.HeadHash

    # An anchor with no sequence number records nothing yet; treat as unavailable rather than as a break.
    if ($verdict.AnchoredSeq -le 0 -or -not $verdict.AnchoredHash) {
        $verdict.Reason = 'anchor records no records yet (seq 0) - nothing was anchored to compare'
        $verdict.Available = $false
        return $verdict
    }

    try {
        $head = Get-WuuAuditChainHead -LogPath $LogPath
        $verdict.CurrentSeq = [int]$head.Seq
        $verdict.CurrentHash = [string]$head.Hash

        if ($verdict.CurrentSeq -lt $verdict.AnchoredSeq) {
            $verdict.Rewritten = $true
            $verdict.Reason = "the log is SHORTER than when it was anchored (anchor seq $($verdict.AnchoredSeq), log now $($verdict.CurrentSeq)) - records were removed"
            return $verdict
        }

        if ($verdict.CurrentSeq -eq $verdict.AnchoredSeq) {
            if ($verdict.CurrentHash -ceq $verdict.AnchoredHash) {
                $verdict.Consistent = $true
                $verdict.Reason = "the log is unchanged since the anchor (seq $($verdict.AnchoredSeq))"
            } else {
                # Same length, different head: the log was replaced with a log of the same size. The
                # most deliberate-looking form of tampering, and the one a length check alone would miss.
                $verdict.Rewritten = $true
                $verdict.Reason = "the log has the anchored LENGTH but a different head hash at seq $($verdict.AnchoredSeq) - it was replaced, not merely appended to"
            }
            return $verdict
        }

        # The log has grown. The anchored hash must still appear at the anchored sequence number.
        $found = Get-WuuAuditRecordAtSeq -LogPath $LogPath -Seq $verdict.AnchoredSeq
        if ($null -eq $found) {
            $verdict.Rewritten = $true
            $verdict.Reason = "the anchored sequence $($verdict.AnchoredSeq) is gone, though the log is longer now (seq $($verdict.CurrentSeq)) - the earlier records were rebuilt"
        } elseif ([string]$found.Hash -ceq $verdict.AnchoredHash) {
            $verdict.Consistent = $true
            $verdict.Reason = "the anchored record is intact at seq $($verdict.AnchoredSeq); the log has since grown to seq $($verdict.CurrentSeq)"
        } else {
            $verdict.Rewritten = $true
            $verdict.Reason = "seq $($verdict.AnchoredSeq) now hashes to a DIFFERENT value than when it was anchored - the record was rewritten"
        }
    } catch {
        $verdict.Reason = "comparison failed: $($_.Exception.Message)"
    }

    return $verdict
}

function Write-WuuAuditEventLogAnchor {
    <#
    .SYNOPSIS
    Mirrors a chain head into the Windows Event Log - a store the log's editor does not own (P3/SS26).
    .DESCRIPTION
    WHY A SECOND STORE. `New-WuuAuditAnchor` writes a file, and a file is only as strong as wherever it
    is kept: the note on every anchor says to hold it beyond the audited operator's reach, which in
    practice is a policy the operator must follow rather than a property of the artifact. The Event Log
    needs no such discipline - it is written through a different mechanism, by a different service, and
    an unprivileged account cannot rewrite it. SS26 names this mechanism by name, and it is the one the
    application can use unattended.

    WHAT IT ADDS, ACCURATELY. It raises the cost of hiding a rewrite from "edit the log" to "edit the
    log, edit the anchor file, AND clear the event log" - and a copy of any of those held by a third
    party still catches it. It is NOT non-repudiation: a local administrator can still clear the event
    log. The event it writes says so, so nobody has to infer the boundary from documentation.

    IT MUST NEVER THROW OR FAIL THE OPERATION IT AUDITS. Registering an event source requires elevation,
    and this runs unattended on machines where the source was never registered - so every failure is
    turned into Written=$false with a Reason and returned. A control that can fail the audited operation
    is worse than the gap it closes, and the caller decides whether absence is fatal.

    THE SOURCE IS DEREGISTERED BY NOBODY, DELIBERATELY. An event source is a machine-wide registration
    and removing it would break the audit trail of every earlier run. Re-registering an existing source
    throws, and that is treated as success: the source already being present is the normal steady state.
    #>
    [CmdletBinding()]
    param(
        # NOT [Parameter(Mandatory)]: a Mandatory [string] rejects an EMPTY string at BINDING time, so the
        # guard below never ran and the function THREW - violating its own "never throws" contract.
        # Measured. Optional + AllowEmptyString moves the decision into the body where it is reportable.
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$HeadHash = '',
        [Parameter(Mandatory = $false)][int]$Seq = 0,
        [Parameter(Mandatory = $false)][string]$LogPath = '',
        [Parameter(Mandatory = $false)][string]$Operator = '',
        [Parameter(Mandatory = $false)][string]$LogName = 'Application',
        [Parameter(Mandatory = $false)][string]$Source = 'WUU2-CLI-Audit',
        [datetime]$Now
    )

    $result = @{ Written = $false; Reason = ''; LogName = ''; Source = '' }
    # A LOCAL, not the $Now parameter: reassigning a parameter is banned in this codebase (a gated rule -
    # type coercion on reassignment can throw). Resolved once, then used.
    $stamp = if ($Now) { $Now } else { Get-Date }

    if ([string]::IsNullOrWhiteSpace($HeadHash)) {
        $result.Reason = 'no chain head supplied - there is nothing to anchor'
        return $result
    }
    if ($Seq -le 0) {
        $result.Reason = 'the chain has no records yet (seq 0) - nothing to anchor'
        return $result
    }

    # The cmdlets are Windows-only. A non-Windows or constrained host reports rather than throwing, so a
    # cross-platform caller can treat an unavailable sink the same way it treats an unwritable one.
    if (-not (Get-Command -Name 'Write-EventLog' -ErrorAction SilentlyContinue)) {
        $result.Reason = 'the Windows Event Log is not available on this host (Write-EventLog not found)'
        return $result
    }

    # Registration is best-effort: an already-registered source throws, which is the steady state and
    # must not be reported as a failure. A registration that fails for another reason (no elevation) is
    # not fatal either - Write-EventLog below is the real test and will report the true cause.
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) {
            [System.Diagnostics.EventLog]::CreateEventSource($Source, $LogName)
        }
    } catch {
        # DELIBERATELY BEST-EFFORT (SS27). Registration needs elevation and an already-registered
        # source throws, so both outcomes are normal here and neither is actionable at this point.
        # The Write-EventLog below is the real test and reports the true cause if the source is
        # genuinely unusable - swallowing this cannot turn a fault into apparent success.
    }

    try {
        $payload = [ordered]@{
            Schema      = 'wuu.audit.anchor.eventlog.v1'
            AnchoredUtc = $stamp.ToUniversalTime().ToString('o')
            Seq         = $Seq
            HeadHash    = $HeadHash
            LogPath     = $LogPath
            Operator    = $Operator
            Claim       = 'chain head held in a store the log editor does not own; tamper-evident, NOT non-repudiation (a local administrator can clear this log)'
        }
        # -RawData would be more faithful (a byte-for-byte copy), but it is only readable back by a tool
        # that knows its encoding, and the value here is a HUMAN and machine readable head hash that any
        # operator can compare with `wuu audit verify`. The message therefore states the hash in full.
        $message = ($payload | ConvertTo-Json -Compress -Depth 4)
        Write-EventLog -LogName $LogName -Source $Source -EventId 5100 `
            -EntryType Information -Message $message -ErrorAction Stop
        $result.Written = $true
        $result.LogName = $LogName
        $result.Source = $Source
        $result.Reason = "mirrored seq $Seq to the '$LogName' event log as source '$Source'"
    } catch {
        # NAME THE REAL CAUSE. Registering an event source needs elevation, and without it the platform
        # reports only "The source was not found, but some or all event logs could not be searched" - a
        # message that sends an operator looking for a missing source when the actual requirement is an
        # elevated registration. The sink is still reported as unwritten; only the explanation changes.
        $exMsg = $_.Exception.Message
        if ($exMsg -match 'could not be searched|Inaccessible logs|source was not found') {
            $result.Reason = "event log write failed: source '$Source' is not registered and it could not be registered without elevation (register it once from an elevated prompt with New-EventLog -LogName $LogName -Source $Source). Underlying error: $exMsg"
        } else {
            $result.Reason = "event log write failed: $exMsg"
        }
    }

    return $result
}

function Get-WuuAuditEventLogAnchor {
    <#
    .SYNOPSIS
    Reads back the most recent chain-head event a given source wrote, or $null (P3/SS26).
    .DESCRIPTION
    The other half of the Event Log mirror: an anchor that is written and never read back is a log, not
    a control. Returns the newest event from the source that parses as an anchor, so a caller can compare
    it against the file anchor and the chain.

    Returns $null - never throws - when the log is unavailable or holds no anchor event. A missing sink
    is a finding the caller reports, not an error that stops a verification run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][string]$LogName = 'Application',
        [Parameter(Mandatory = $false)][string]$Source = 'WUU2-CLI-Audit'
    )

    if (-not (Get-Command -Name 'Get-WinEvent' -ErrorAction SilentlyContinue)) { return $null }

    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName = $LogName; ProviderName = $Source } `
            -MaxEvents 25 -ErrorAction Stop
    } catch {
        # No events from that provider is the ordinary "never anchored here" case, not a fault.
        return $null
    }

    foreach ($e in @($ev)) {
        # READ Properties[0], NOT Message. For an event written with a GENERIC id (the only kind a
        # custom source can write without a registered message DLL), Windows has no message template,
        # so Message comes back EMPTY and the text lands in Properties[0]. Reading Message alone made
        # this function return nothing for events this module had just written - measured: the write
        # succeeded, Get-WinEvent returned the event, and Message was []. A sink that cannot be read
        # back is a log, not a control. Message is still tried first so a future template-based event
        # would also work.
        $text = [string]$e.Message
        if ([string]::IsNullOrWhiteSpace($text) -and $e.Properties.Count -gt 0) {
            $text = [string]$e.Properties[0].Value
        }
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        try {
            $obj = $text | ConvertFrom-Json
        } catch {
            continue
        }
        if ($obj.PSObject.Properties['HeadHash'] -and $obj.PSObject.Properties['Seq']) {
            return [pscustomobject]@{
                AnchoredUtc = [string]$obj.AnchoredUtc
                Seq         = [int]$obj.Seq
                HeadHash    = [string]$obj.HeadHash
                LogPath     = [string]$obj.LogPath
                Operator    = [string]$obj.Operator
                LogName     = $LogName
                Source      = $Source
            }
        }
    }

    return $null
}

function Get-WuuAuditRecordAtSeq {
    <#
    .SYNOPSIS The recorded Hash of the record with a given sequence number, or $null (P3).
    .DESCRIPTION
    Used only by Test-WuuAuditAnchor, to check that an anchored record survives in a log that has since
    grown. Reads the file ONCE and scans it; the log is line-delimited JSON, so this is a simple scan
    rather than a second implementation of the chain walk.

    Returns $null when the sequence number is absent, which the caller reports as a rewrite rather than
    as an error: a missing record in a log that claims to be longer is a finding.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][int]$Seq
    )

    if (-not (Test-Path -LiteralPath $LogPath)) { return $null }
    try {
        $lines = [System.IO.File]::ReadAllLines($LogPath)
    } catch {
        return $null
    }

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $rec = $line | ConvertFrom-Json
        } catch {
            continue   # a partially written trailing line is normal; skip it
        }
        if ($rec.PSObject.Properties['Seq'] -and [int]$rec.Seq -eq $Seq) {
            return [pscustomobject]@{
                Seq  = [int]$rec.Seq
                Hash = if ($rec.PSObject.Properties['Hash']) { [string]$rec.Hash } else { '' }
            }
        }
    }
    return $null
}

#endregion External anchoring

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
        [string]$Category = 'data_change',
        [switch]$WhatIf
    )

    if ($WhatIf) {
        # A dry run is still an event an auditor may want to see ("who asked for what"), but it is
        # distinctly NOT a change, so it gets its own result value rather than 'started'.
        Write-WuuAuditRecord -Session $Session -Action $Action -Result 'whatif' -Category $Category `
            -Targets $Targets -Parameters $Parameters -Reason $Reason | Out-Null
        Write-Host ("  [WhatIf] audited intent recorded for '{0}' - action not run." -f $Action) -ForegroundColor Yellow
        return [pscustomobject]@{ Ok = $true; WhatIf = $true }
    }

    $correlationId = [guid]::NewGuid().ToString('N')
    # Step 1 - fail-closed intent record.
    Write-WuuAuditRecord -Session $Session -Action $Action -Result 'started' -Category $Category `
        -Targets $Targets -Parameters $Parameters -CorrelationId $correlationId -Reason $Reason -Mutating -FailClosed | Out-Null

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
        Write-WuuAuditRecord -Session $Session -Action $Action -Result $(if ($ok) { 'succeeded' } else { 'failed' }) `
            -Category $Category -Targets $Targets -Parameters $Parameters -CorrelationId $correlationId `
            -DurationMs ([int]$sw.ElapsedMilliseconds) -ErrorMessage $errMsg -Reason $Reason -Mutating | Out-Null
    }
    return [pscustomobject]@{ Ok = $ok; Error = $errMsg; CorrelationId = $correlationId }
}

function Write-WuuAuditDenial {
    <#
    .SYNOPSIS Records a REFUSED operation as a first-class event.
    .DESCRIPTION
    ISO 27001 A.8.15 (and A.8.16 monitoring) expects unsuccessful and denied attempts to be
    logged, not just successful ones - a run of refusals is exactly the signal an auditor looks
    for. This is deliberately separate from the fail-closed write path: a refusal MUST be logged,
    but the refusal itself must never be blocked by a logging problem, otherwise the operator
    sees a confusing "audit failed" for an action that was already denied.

    Examples of refusals recorded: a mutating command with no -Reason, and a menu action
    cancelled at the reason prompt.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$DenialReason,
        [string[]]$Targets = @(),
        [hashtable]$Parameters = @{},
        [string]$Reason = ''
    )
    $rec = Write-WuuAuditRecord -Session $Session -Action $Action -Result 'denied' -Category 'outcome' `
        -Targets $Targets -Parameters $Parameters -Reason $Reason -ErrorMessage $DenialReason -Mutating
    if ($rec) { Write-InfoLog ("Audit: '{0}' DENIED - {1}" -f $Action, $DenialReason) }
    return $rec
}

#endregion Audited action wrapper

Export-ModuleMember -Function @(
    'Get-WuuAuditDirectory'
    'Get-WuuCanonicalJson'
    'Get-WuuRecordHash'
    'Add-WuuAuditRecordLocked'
    'Start-WuuAuditSession'
    'Write-WuuAuditRecord'
    'Get-WuuAuditChainHead'
    'Test-WuuAuditChain'
    # P3: EXTERNAL ANCHORING. Exported because the anchor must be written and compared by callers that
    # HOLD IT SOMEWHERE ELSE - a release gate, a status command, a scheduled job that copies it off-box.
    # The separation is the control, so the functions cannot be private to this module.
    'New-WuuAuditAnchor'
    'Test-WuuAuditAnchor'
    'Write-WuuAuditEventLogAnchor'
    'Get-WuuAuditEventLogAnchor'
    'Get-WuuAuditRecordAtSeq'
    'Invoke-WuuAuditedAction'
    'Write-WuuAuditDenial'
    'Resolve-WuuAuditCategory'
    'Start-WuuAuditTranscript'
    'Stop-WuuAuditTranscript'
)
