#Requires -Version 5.1
<#
.DESCRIPTION
Thread-safe debug logging and level wrappers.
#>

function Write-WuuLogEntry {
    <#
    .SYNOPSIS
    Fault-tolerant append of one log line. NEVER throws into the caller.
    .DESCRIPTION
    Debug logs written into OneDrive-synced folders hit "Stream was not
    readable" when the sync engine transiently locks/hydrates the file
    mid-write (PS 5.1 Add-Content opens with restrictive sharing). A logging
    failure must never kill a timer tick, a runspace creation, or a worker
    payload, so: take $LogLock, retry briefly, swallow the rest.
    Inline payload writes should delegate here instead of raw Add-Content.
    .NOTES
    Reads $global:LogPath / $global:LogLock (main session); callers inside
    isolated runspaces should pass -LogPath/-LogLock explicitly.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$LogPath = $global:LogPath,
        [object]$LogLock = $global:LogLock,
        [int]$MaxAttempts = 3
    )
    
    if (-not $LogPath) { return }

    # DELEGATES TO THE ONE APPENDER. This function used to carry its own copy of the lock-and-retry
    # loop; it now calls the shared factory (Wuu.Scheduler), which the injected worker scriptblocks and
    # the cleanup runspace also use. Four copies became one, so the retry behaviour cannot differ
    # between the main session and a worker - which is what "inline payload writes should delegate
    # here instead of raw Add-Content" was trying to achieve by convention, now achieved structurally.
    #
    # The lock is passed through: the factory falls back to the session-state $LogLock when not given,
    # so a null here still yields a working append rather than a silent no-op.
    $appender = Get-WuuWorkerLogAppender
    $null = & $appender -LogEntry $Message -Path $LogPath -Lock $LogLock -MaxAttempts $MaxAttempts
}

function Write-DebugLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO',
        [string]$Computer = '',
        [switch]$ToConsole
    )
    
    # Skip logging if debug logging is disabled
    if (-not $global:EnableDebugLogging) {
        return
    }
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $logEntry = "[$timestamp] [$Level]$(if($Computer){" [$Computer]"}) $Message"
    
    # Fault-tolerant append (never throws - see Write-WuuLogEntry)
    Write-WuuLogEntry -Message $logEntry
    
    if ($ToConsole) {
        Write-Host $logEntry -ForegroundColor $(switch($Level){
            'ERROR' {'Red'}
            'WARN' {'Yellow'}
            'SUCCESS' {'Green'}
            'DEBUG' {'Cyan'}
            default {'White'}
        })
    }
}

function Write-InfoLog {
    param([string]$Message, [string]$Computer = '')
    Write-DebugLog $Message -Level 'INFO' -Computer $Computer
}

function Write-WarningLog {
    param([string]$Message, [string]$Computer = '')
    Write-DebugLog $Message -Level 'WARN' -Computer $Computer
}

function Write-ErrorLog {
    param([string]$Message, [string]$Computer = '')
    Write-DebugLog $Message -Level 'ERROR' -Computer $Computer
}

function Write-SuccessLog {
    param([string]$Message, [string]$Computer = '')
    Write-DebugLog $Message -Level 'SUCCESS' -Computer $Computer
}

# The single fault-tolerant log appender, built here because logging owns it. Wuu.Scheduler injects the
# scriptblock this returns into worker runspaces; Write-WuuLogEntry (above) delegates to it; the cleanup
# runspace in Wuu.Core and the per-computer runspaces in Wuu.WindowsUpdate both call it. Four copies of
# the retry loop became one.

function Get-WuuWorkerLogAppender {
    <#
    .SYNOPSIS
    The single fault-tolerant log appender, built once and used by every logging path (P2 dedupe).
    .DESCRIPTION
    Returns a [scriptblock] built from a STRING, ready for SessionStateProxy.SetVariable. Built this way
    rather than written as a literal because a literal `{ }` captures the defining session state and
    would see neither the injected variables nor the caller's - the failure mode that is SILENT rather
    than loud, and the reason this whole module exists.

    FOUR COPIES BECAME ONE. The same retry loop was written in Wuu.Logging's Write-WuuLogEntry, in
    Wuu.Core's cleanup runspace, in Wuu.WindowsUpdate's per-computer runspace, and inline inside
    Wuu.WindowsUpdate's WriteDebugLogScript - each with a comment telling the reader to keep them in
    step. (The suite that guards this reported three, which is how the fourth - the one inlined in
    WriteDebugLogScript - was noticed.)

    TAKES $Path / $Lock BY NAME, DELIBERATELY NOT $LogPath / $LogLock. An injected caller sets the
    variables $LogPath and $LogLock in the worker; a main-session caller passes them explicitly. Naming
    the parameters $LogPath/$LogLock would SHADOW those session-state variables, leaving the fallback
    with nothing to read. With distinct names, an unbound read resolves to the injected variable - which
    is exactly why the fallback is a plain read and not a Get-Variable dance.

    WHY IT IS FAULT-TOLERANT. Logging is the one operation that must not be able to break the operation
    it describes. A log write contends for the same file across every runspace in the process, so it
    takes the lock, retries with backoff, then GIVES UP rather than throwing: a payload that cannot log
    must still complete its work, and the failure to log is itself unreportable through the same channel.

    Takes the line pre-formatted. The payloads already build their own format, and re-formatting here
    would change every line they write.

    Returns @{ Succeeded; Attempts } when invoked, so a caller that wants to know can ask - the payloads
    ignore it.
    #>
    [CmdletBinding()]
    param()

    return [scriptblock]::Create({
        param([string]$LogEntry, [string]$Path = '', [object]$Lock = $null, [int]$MaxAttempts = 3)

        # Fall back to the session-state values when not passed explicitly. These names are NOT parameters
        # (see the description), so an unbound read finds the injected variable.
        $effectivePath = if ($Path) { $Path } else { $LogPath }
        $effectiveLock = if ($Lock) { $Lock } else { $LogLock }
        if (-not $effectivePath) { return @{ Succeeded = $false; Attempts = 0 } }
        if (-not $effectiveLock) { $effectiveLock = New-Object System.Object }

        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            $lockTaken = $false
            try {
                [System.Threading.Monitor]::Enter($effectiveLock); $lockTaken = $true
                Add-Content -Path $effectivePath -Value $LogEntry -Force
                return @{ Succeeded = $true; Attempts = $attempt }
            } catch {
                # Give up silently rather than throw: see the description above. The comment inside this
                # scriptblock matters because it becomes the only documentation a reader of the INJECTED
                # copy sees.
                if ($attempt -ge $MaxAttempts) { return @{ Succeeded = $false; Attempts = $attempt } }
                Start-Sleep -Milliseconds (100 * $attempt)
            } finally {
                if ($lockTaken) { [System.Threading.Monitor]::Exit($effectiveLock) }
            }
        }
        return @{ Succeeded = $false; Attempts = $MaxAttempts }
    }.ToString())
}


Export-ModuleMember -Function @('Write-WuuLogEntry', 'Get-WuuWorkerLogAppender', 'Write-DebugLog', 'Write-InfoLog', 'Write-WarningLog', 'Write-ErrorLog', 'Write-SuccessLog')

