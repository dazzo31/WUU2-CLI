#Requires -Version 5.1
<#
.DESCRIPTION
Per-computer worker runspaces, job scheduling, phase gating, and update payloads.
#>

function Initialize-WuuWindowsUpdateContext {
    # Shared app state (entry point owns it; modules must not rely on caller scope).
    # Expected keys: UiHash, Jobs, UpdatesHash, PerformanceHash, ErrorSuggestions,
    # Path, LogPath, LogLock, EnableDebugLogging, EnableEnhancedErrorHandling,
    # UseCustomCredentials, CustomCredentials, CredentialCache, PerformanceThreshold,
    # ConfigPaths, SearchTimeout, SessionTimeout, RebootCheckTimeout, MaxConcurrentJobs,
    # GetUpdates, DownloadUpdates, InstallUpdates, RestartComputer,
    param([Parameter(Mandatory)][hashtable]$Context)
    $script:WuuCtx = $Context
}

function New-ComputerRunspace {
    param($ComputerItem)
    $ctx = $script:WuuCtx
    $uiHash = $ctx.UiHash; $updatesHash = $ctx.UpdatesHash; $performanceHash = $ctx.PerformanceHash
    $errorSuggestionsHash = $ctx.ErrorSuggestions; $path = $ctx.Path
    $PerformanceThreshold = $ctx.PerformanceThreshold
    $searchTimeout = $ctx.SearchTimeout; $sessionTimeout = $ctx.SessionTimeout
    $rebootCheckTimeout = $ctx.RebootCheckTimeout
        Write-InfoLog "Creating runspace for computer: $($ComputerItem.Computer)"
            # Create runspace with proper scope isolation to prevent "Global scope cannot be removed" error
            $runspaceConfig = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
            $runspaceConfig.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
            $newRunspace = [runspacefactory]::CreateRunspace($runspaceConfig)
            $newRunspace.ApartmentState = "STA"
            $newRunspace.Open()
            Write-InfoLog "Runspace opened successfully for: $($ComputerItem.Computer)"
        $newRunspace.SessionStateProxy.SetVariable("uiHash",$uiHash)
        # Console edition: worker payloads report progress through the synchronized state
        # store instead of WPF. `stateStore` is a raw synchronized hashtable with a Touch()
        # script method, so workers can use it without module-function access.
        $newRunspace.SessionStateProxy.SetVariable("stateStore",$ctx.StateStore)
        $newRunspace.SessionStateProxy.SetVariable("updatesHash",$updatesHash)
        $newRunspace.SessionStateProxy.SetVariable("performanceHash",$performanceHash)
        $newRunspace.SessionStateProxy.SetVariable("errorSuggestionsHash",$errorSuggestionsHash)
        $newRunspace.SessionStateProxy.SetVariable("path",$pwd)
        $newRunspace.SessionStateProxy.SetVariable("LogPath",$ctx.LogPath)
        $newRunspace.SessionStateProxy.SetVariable("LogLock",$ctx.LogLock)
        $newRunspace.SessionStateProxy.SetVariable("EnableDebugLogging",$ctx.EnableDebugLogging)
        $newRunspace.SessionStateProxy.SetVariable("EnableEnhancedErrorHandling",$ctx.EnableEnhancedErrorHandling)
        # Read runtime-reassignable credential state at creation time (config dialog
        # reassigns the $global: variables; the startup context snapshot would be stale).
        $newRunspace.SessionStateProxy.SetVariable("UseCustomCredentials",$global:UseCustomCredentials)
        $newRunspace.SessionStateProxy.SetVariable("CustomCredentials",$global:CustomCredentials)
        $newRunspace.SessionStateProxy.SetVariable("CredentialCache",$global:CredentialCache)
        $newRunspace.SessionStateProxy.SetVariable("PerformanceThreshold",$PerformanceThreshold)
        $newRunspace.SessionStateProxy.SetVariable("ConfigPaths",$ctx.ConfigPaths)
        $newRunspace.SessionStateProxy.SetVariable("searchTimeout",$searchTimeout)
        $newRunspace.SessionStateProxy.SetVariable("sessionTimeout",$sessionTimeout)
        $newRunspace.SessionStateProxy.SetVariable("rebootCheckTimeout",$rebootCheckTimeout)
        $newRunspace.SessionStateProxy.SetVariable("CimTimeoutSeconds",$ctx.CimTimeoutSeconds)
        $newRunspace.SessionStateProxy.SetVariable("ServiceTimeoutSeconds",$ctx.ServiceTimeoutSeconds)
        $newRunspace.SessionStateProxy.SetVariable("PerformanceTimeoutSeconds",$ctx.PerformanceTimeoutSeconds)
        $newRunspace.SessionStateProxy.SetVariable("CredProbeTimeoutSeconds",$ctx.CredProbeTimeoutSeconds)
        $newRunspace.SessionStateProxy.SetVariable("RebootProbeTimeoutSeconds",$ctx.RebootProbeTimeoutSeconds)
        $newRunspace.SessionStateProxy.SetVariable("OfflineWaitSeconds",$ctx.OfflineWaitSeconds)
        $newRunspace.SessionStateProxy.SetVariable("OnlineWaitSeconds",$ctx.OnlineWaitSeconds)
        # ui/ layout file for the worker-side credential dialog (workers have no $PSScriptRoot)
        # Shared worker pool for bounded probes (isolated runspaces cannot see
        # module functions - the pool OBJECT and an unbound invoke script are
        # injected together; see New-PooledInvokeScript in Wuu.Workers.psm1)
        $newRunspace.SessionStateProxy.SetVariable('WuuWorkerPool', (Get-WuuWorkerPool))
        $newRunspace.SessionStateProxy.SetVariable('InvokePooledScript', (New-PooledInvokeScript))
        
        # Add required functions to runspace by embedding them as script blocks
        # Unbound ([scriptblock]::Create) so invocation binds to the worker runspace where these variables exist
        $newRunspace.SessionStateProxy.SetVariable('WriteDebugLogScript', [scriptblock]::Create({
            param($Message, $Level = 'INFO', $Computer = '', [switch]$ToConsole)
            
            # Skip logging if debug logging is disabled
            if (-not $EnableDebugLogging) {
                return
            }
            
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            $logEntry = "[$timestamp] [$Level]$(if($Computer){" [$Computer]"}) $Message"
            # Fault-tolerant append with retry: OneDrive/sync engines transiently lock
            # the log mid-write ("Stream was not readable" in PS 5.1). Logging must
            # never throw into a worker payload - retry, then give up silently.
            $maxAttempts = 3
            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                $lockTaken = $false
                try {
                    [System.Threading.Monitor]::Enter($LogLock); $lockTaken = $true
                    Add-Content -Path $LogPath -Value $logEntry -Force
                    break
                } catch {
                    if ($attempt -ge $maxAttempts) { return }   # give up silently
                    Start-Sleep -Milliseconds (100 * $attempt)
                } finally {
                    if ($lockTaken) { [System.Threading.Monitor]::Exit($LogLock) }
                }
            }
        }.ToString()))
        
        # Fault-tolerant append for PRE-FORMATTED log lines (worker payload copy).
        # Worker payloads build "$logEntry" inline then call this instead of raw
        # Add-Content: same lock+retry semantics as WriteDebugLogScript, but takes
        # the finished line so payload format strings stay unchanged.
        $newRunspace.SessionStateProxy.SetVariable('WriteLogFileScript', [scriptblock]::Create({
            param([string]$LogEntry)
            $maxAttempts = 3
            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                $lockTaken = $false
                try {
                    [System.Threading.Monitor]::Enter($LogLock); $lockTaken = $true
                    Add-Content -Path $LogPath -Value $LogEntry -Force
                    break
                } catch {
                    if ($attempt -ge $maxAttempts) { return }   # give up silently
                    Start-Sleep -Milliseconds (100 * $attempt)
                } finally {
                    if ($lockTaken) { [System.Threading.Monitor]::Exit($LogLock) }
                }
            }
        }.ToString()))
        
        # Safe row-update helper for worker runspaces (console edition).
        # Replaces the GUI's ListView EditItem/CommitEdit/Refresh + Dispatcher.Invoke with a
        # plain write into the synchronized state store, then a Touch() to signal a redraw.
        #
        # HISTORY / WHY THIS SHAPE: in the GUI edition the dispatcher action executed on the
        # UI thread while this worker runspace was BLOCKED inside Dispatcher.Invoke waiting
        # for it, so any pipeline cmdlet (Where-Object/Select-Object/...) inside the action
        # deadlocked the whole app. The store removes the dispatch entirely, but the rule is
        # kept: LANGUAGE CONSTRUCTS ONLY below. Do not add pipeline cmdlets.
        $newRunspace.SessionStateProxy.SetVariable('SafeUpdateListViewItemScript', [scriptblock]::Create({
            param(
                [string]$ComputerName,
                [hashtable]$Properties
            )

            if (-not $stateStore) { return }
            try {
                # Resolve the row from the store's own synchronized hashtable - worker
                # runspaces cannot see module functions (Get-WuuComputerRow etc.).
                $targetRow = $stateStore.ByName[$ComputerName.ToLowerInvariant()]
                if (-not $targetRow) { return }

                # SS3: STALE-WRITER GUARD. Identical rule to the module-scope SafeUpdateListViewItem
                # in Wuu.Core.psm1 - keep both in sync (tests\Test-OperationIdentity.ps1 drives both
                # and asserts they agree).
                #
                # This is the writer the PAYLOAD uses, so it is the one that can be parked mid-write
                # when the timeout path detaches the runspace. Refuse only a PROVEN staleness: a row
                # that names an operation, and a writer naming a different one. An unattributed write
                # is still allowed (list loading writes rows that have no operation).
                #
                # The writer's identity comes from $WuuOperationId, injected by Start-UpdateCheckJob
                # for the operation THIS runspace is currently running. Reading it here (rather than
                # only from the properties hashtable) is what makes the guard effective: the payload
                # does not pass an OperationId in its property bags.
                $writerOpId = ''
                if ($Properties -and $Properties.ContainsKey('OperationId')) { $writerOpId = [string]$Properties['OperationId'] }
                if ($writerOpId -eq '' -and $WuuOperationId) { $writerOpId = [string]$WuuOperationId }
                $rowOpId = ''
                if ($targetRow.PSObject.Properties['OperationId']) { $rowOpId = [string]$targetRow.OperationId }
                if ($rowOpId -ne '' -and $writerOpId -ne '' -and $rowOpId -cne $writerOpId) {
                    # Language constructs only - no Write-WarningLog here (isolated runspace), so the
                    # refusal goes to the injected log script, which is a plain Add-Content append.
                    try {
                        if ($WriteLogFileScript) {
                            & $WriteLogFileScript ("[{0}] [WARN] [{1}] stale row write refused: the row belongs to operation '{2}', writer is '{3}'" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $ComputerName, $rowOpId, $writerOpId)
                        }
                    } catch { }
                    return
                }

                foreach ($propertyName in $Properties.Keys) {
                    $targetRow.$propertyName = $Properties[$propertyName]
                }
                $stateStore.Touch()
            } catch {
                # Silently ignore row update errors during startup
            }
        }.ToString()))

        # Timeout state helper for worker runspaces. Mirrors Set-ComputerTimeout in
        # Wuu.Core.psm1 but uses only language constructs + the injected $stateStore so
        # it is safe to invoke from an isolated runspace.
        $newRunspace.SessionStateProxy.SetVariable('SetComputerTimeoutScript', [scriptblock]::Create({
            param(
                [Parameter(Mandatory)][object]$Computer,
                [Parameter(Mandatory)][string]$Phase,
                [Parameter(Mandatory)][int]$TimeoutSec,
                [string]$Detail = ''
            )
            try {
                $Computer.TimeoutExpiresAt = [DateTime]::Now.AddSeconds($TimeoutSec)
                $Computer.TimeoutSource    = $Phase
                $Computer.UpdatesStatus    = 'Timeout'
                $Computer.State            = 'Timeout'
                $detailSuffix = if ($Detail) { " $Detail" } else { '' }
                $Computer.Status = "Timeout during $Phase after ${TimeoutSec}s - continuing to monitor.$detailSuffix"
                # Was: listViewItem.Background = [Brushes]::LightYellow (recoverable = yellow)
                $Computer.Color = 'Timeout'
                if ($stateStore) { $stateStore.Touch() }
            } catch { }
        }.ToString()))

        # State machine helper for worker runspaces. Mirrors Set-ComputerState in
        # Wuu.Core.psm1.
        $newRunspace.SessionStateProxy.SetVariable('SetComputerStateScript', [scriptblock]::Create({
            param(
                [Parameter(Mandatory)][object]$Computer,
                [Parameter(Mandatory)][string]$State,
                [string]$StatusDetail = ''
            )
            $stateToStatus = @{
                'Queued'          = 'Waiting to start...'
                'Connecting'      = 'Testing Connectivity.'
                'Connected'       = 'Online.'
                'Checking'        = 'Initializing update session...'
                'Searching'       = 'Checking for updates...'
                'UpdatesFound'    = 'Updates found.'
                'Downloading'     = 'Downloading updates...'
                'Installing'      = 'Installing updates...'
                'RebootRequired'  = 'Reboot required.'
                'Rebooting'       = 'Restarting...'
                'Verifying'       = 'Verifying post-reboot state...'
                'Complete'        = 'All updates installed.'
                'Timeout'         = 'Operation timed out (recoverable).'
                'Error'           = 'Error occurred.'
            }
            $statusString = $stateToStatus[$State]
            if ($StatusDetail) { $statusString += " $StatusDetail" }
            try {
                $Computer.State = $State
                $Computer.Status = $statusString
                if ($stateStore) { $stateStore.Touch() }
            } catch { }
        }.ToString()))

        # Single source of truth lives in Wuu.Remote.psm1; unbound copy so it runs in the worker runspace
        $newRunspace.SessionStateProxy.SetVariable('InvokeRemoteTaskScript', [scriptblock]::Create((Get-Command -Name 'Invoke-WuuRemoteTask' -CommandType Function -ErrorAction Stop).ScriptBlock.ToString()))

        # Add custom credential dialog script to runspace
        # Credential prompt helper for worker runspaces (console edition).
        #
        # The GUI injected a WPF dialog here. A worker runspace is an isolated, non-interactive
        # context - it must NOT try to own the console (that would race the main session's input
        # loop and could interleave prompts into the middle of an unrelated menu action). So this
        # returns the documented 'no UI available' result and the caller falls back to default
        # credentials. Interactive entry happens in the MAIN session before the worker starts
        # (Wuu.Credentials Show-CustomCredentialDialog), which is how the console flow always
        # supplies credentials.
        $newRunspace.SessionStateProxy.SetVariable('ShowCustomCredentialDialogScript', [scriptblock]::Create({
            param(
                [string]$Message = 'Enter your credentials',
                [string]$Username = '',
                [string]$Title = 'Credentials Required'
            )
            # Signal 'cannot prompt from a worker runspace' - see the comment at the injection site.
            return $null
        }.ToString()))
        
        # Add Get-RemoteCredentials function to runspace (with timeout protection to prevent hangs)
        #
        # PHASE 1: this mirrors Resolve-WuuOperationCredential in Wuu.Credentials, which the isolated
        # runspace cannot call. It is duplicated for the same reason the SS5 deadline decision is
        # duplicated in the cleanup loop - module functions do not resolve on a worker thread - and it
        # is guarded the same way: tests\Test-CredentialDeterminism.ps1 drives BOTH implementations on
        # identical inputs and asserts they agree, so the two cannot drift.
        #
        # THE RULE: custom credentials configured -> use them, or FAIL. No fallback to another
        # identity. The previous version fell through to the process identity when the custom
        # credential failed to authenticate, so an operation could run as a different account than the
        # operator configured - silently, because it succeeded.
        $newRunspace.SessionStateProxy.SetVariable('GetRemoteCredentialsScript', [scriptblock]::Create({
            param(
                [string]$ComputerName,
                [string]$Operation = 'WMI access'
            )

            # Inline timeout helper: runs a CIM probe on the shared worker pool with a
            # hard timeout. Was Start-Job (one child process per probe, two per computer).
            # $Cred is always a PSCredential (or $null for default credentials) - typed so a
            # plain-string password can never be passed as a credential.
            # NOTE: PS 5.1's Get-CimInstance has NO -Credential parameter; alternate
            # credentials must go through New-CimSession (DCOM) + Get-CimInstance -CimSession.
            # The probe must actually RUN the query - it validates credentials AND reachability.
            $testCim = {
                # DCOM for both paths - Get-CimInstance -ComputerName implies WinRM and
                # fails on WMI-reachable hosts with no WinRM listener (see Invoke-CimWithTimeout).
                param([string]$ComputerName, [pscredential]$Cred)
                $cimSession = $null
                try {
                    $sessionArgs = @{ ComputerName = $ComputerName; SessionOption = (New-CimSessionOption -Protocol DCOM) }
                    if ($Cred) { $sessionArgs['Credential'] = $Cred }
                    $cimSession = New-CimSession @sessionArgs -ErrorAction Stop
                    $null = Get-CimInstance -CimSession $cimSession -ClassName 'Win32_ComputerSystem' -ErrorAction Stop
                    return @{ Success = $true }
                } catch {
                    return @{ Success = $false; Error = $_.Exception.Message }
                } finally {
                    if ($cimSession) { Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue }
                }
            }

            # Local targets use the process identity: DCOM rejects explicit credentials on the
            # local machine. Decided FIRST, so only ONE branch can produce a non-custom identity.
            $isLocal = ($ComputerName -eq 'localhost' -or $ComputerName -eq $env:COMPUTERNAME)
            $customConfigured = [bool]($UseCustomCredentials -and $CustomCredentials)

            if (-not $customConfigured -or $isLocal) {
                try {
                    $why = if ($isLocal) { 'local machine - process identity' } else { 'custom credentials not configured' }
                    & $WriteDebugLogScript -Message "Credential for $ComputerName : $why" -Level 'DEBUG'
                } catch { }
                return $null
            }

            # Custom credentials are configured: verify them, and NEVER fall back.
            $cred = $CustomCredentials
            $userName = ''
            try { $userName = [string]$cred.UserName } catch { $userName = '' }

            # The cache is only honoured when it holds the configured custom credential ITSELF, so a
            # cached entry can never contradict the configured mode.
            if ($CredentialCache -and $CredentialCache.ContainsKey($ComputerName)) {
                $cached = $CredentialCache[$ComputerName]
                if ($cached -and ([string]$cached.UserName) -eq $userName) {
                    try { & $WriteDebugLogScript -Message "Custom credential for $ComputerName served from cache ('$userName')" -Level 'DEBUG' } catch { }
                    return $cached
                }
            }

            try {
                $result = & $InvokePooledScript -Pool $WuuWorkerPool -ScriptBlock $testCim `
                    -ArgumentList @($ComputerName, $cred) -TimeoutSeconds 5 -OperationName 'Credential verification (custom)'
                if ($result -and $result.Success -and $result.Result -and $result.Result.Success) {
                    if (-not $CredentialCache) { $CredentialCache = @{} }
                    $CredentialCache[$ComputerName] = $cred
                    return $cred
                }
                $detail = ''
                try { if ($result -and $result.Result -and $result.Result.Error) { $detail = [string]$result.Result.Error } } catch { }
                # NO FALLBACK. Report and fail loudly - an unlogged identity substitution is worse
                # than a refused operation.
                try { & $WriteDebugLogScript -Message "Custom credential '$userName' FAILED for $ComputerName ($detail) - operation refused; no fallback to the process identity" -Level 'ERROR' } catch { }
                throw "Custom credentials for '$userName' cannot be used on $ComputerName ($Operation): $detail. No fallback is attempted - fix the credentials or disable custom credentials explicitly."
            } catch {
                if ($_.Exception.Message -match 'No fallback is attempted') { throw }
                try { & $WriteDebugLogScript -Message "Custom credential probe errored for $ComputerName : $($_.Exception.Message) - operation refused; no fallback" -Level 'ERROR' } catch { }
                throw "Custom credential verification failed for $ComputerName ($Operation): $($_.Exception.Message). No fallback is attempted."
            }
        }.ToString()))

        # Add Get-ErrorSuggestions function to runspace
        $newRunspace.SessionStateProxy.SetVariable('GetErrorSuggestionsScript', [scriptblock]::Create({
            param([string]$ErrorMessage)
            
            foreach ($errorCode in $errorSuggestionsHash.Keys) {
                if ($ErrorMessage -match $errorCode) {
                    return $errorSuggestionsHash[$errorCode]
                }
            }
            
            return @{
                Description = 'Unknown error'
                Suggestions = @('Check Windows Event Logs for more details', 'Verify network connectivity', 'Try the operation again')
                AutoFix = $false
            }
        }.ToString()))
        
        # Add Invoke-AutoRecovery function to runspace
        $newRunspace.SessionStateProxy.SetVariable('InvokeAutoRecoveryScript', [scriptblock]::Create({
            param([string]$ComputerName, [string]$ErrorCode)
            
            $errorInfo = & $GetErrorSuggestionsScript -ErrorMessage $ErrorCode
            
            if (-not $errorInfo.AutoFix) {
                return $false
            }
            
            try {
                switch ($ErrorCode) {
                    '800706ba' { # RPC server unavailable
                        # Try to restart RPC service using Invoke-Command
                        if ($ComputerName -eq 'localhost' -or $ComputerName -eq $env:COMPUTERNAME) {
                            Get-Service -Name 'RpcSs' -ErrorAction Stop | Restart-Service -ErrorAction Stop
                            Start-Sleep -Seconds 5
                            Get-Service -Name 'RemoteRegistry' -ErrorAction Stop | Start-Service -ErrorAction Stop
                        } else {
                            # Get appropriate credentials for this computer
                            $credential = Get-RemoteCredentials -ComputerName $ComputerName -Operation 'RPC service restart'
                            
                            if ($credential) {
                                Invoke-Command -ComputerName $ComputerName -Credential $credential -ScriptBlock {
                                    Get-Service -Name 'RpcSs' -ErrorAction Stop | Restart-Service -ErrorAction Stop
                                    Start-Sleep -Seconds 5
                                    Get-Service -Name 'RemoteRegistry' -ErrorAction Stop | Start-Service -ErrorAction Stop
                                } -ErrorAction Stop
                            } else {
                                Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                                    Get-Service -Name 'RpcSs' -ErrorAction Stop | Restart-Service -ErrorAction Stop
                                    Start-Sleep -Seconds 5
                                    Get-Service -Name 'RemoteRegistry' -ErrorAction Stop | Start-Service -ErrorAction Stop
                                } -ErrorAction Stop
                            }
                        }
                        Start-Sleep -Seconds 3
                        
                        return $true
                    }
                    '800706be' { # RPC failed
                        # Wait and retry
                        Start-Sleep -Seconds 10
                        return $true
                    }
                    default {
                        return $false
                    }
                }
            } catch {
                return $false
            }
        }.ToString()))

            return $newRunspace
}

function Start-UpdateCheckJob {
    param(
        $ComputerItem,
        # Optional follow-up operation to chain in a SINGLE pipeline. NEVER BeginInvoke a
        # second pipeline onto a busy per-computer runspace from inside that runspace:
        # the inner payload silently never runs and EndInvoke throws "pipeline already
        # running" (root cause of auto-download/auto-install doing nothing). Chained
        # ops run sequentially inside one BeginInvoke, exactly like $eventInstallUpdates.
        #
        # THIS IS THE ONLY PLACE A PER-COMPUTER OPERATION IS SUBMITTED (SS3/SS4). The console
        # handlers in Wuu.Core used to compose their own [powershell]::Create() + BeginInvoke per
        # computer, which meant: the per-computer gate could not see them (they never set OpState),
        # the global MaxConcurrentJobs cap did not apply to them, and EventGetUpdates took the
        # unguarded branch on every re-check (it only called this function when the row had NO
        # runspace). They now all delegate here.
        [ValidateSet('Check','Download','InstallAndRecheck','AutoFlow','Restart','RemoveOffline','ServiceAction')]
        [string]$Op = 'Check',
        # Only used by 'ServiceAction' (start|stop|restart). Passed through rather than carried on
        # the row, so the op stays explicit at the submission call site.
        [string]$ServiceAction = ''
    )
    $ctx = $script:WuuCtx
    $GetUpdates = $ctx.GetUpdates; $jobs = $ctx.Jobs; $uiHash = $ctx.UiHash
    $PowerShell = $null
    
    try {
        # ---- ONE OPERATION PER COMPUTER (SS3) --------------------------------------------------
        # Refuse to submit while this computer already has an operation in flight. Without this
        # check the submission below is ACCEPTED and then SILENTLY DISCARDED: BeginInvoke returns a
        # handle, the handle completes, and only EndInvoke reports "The pipeline was not run because
        # a pipeline is already running" - by which time the operator has been told the operation
        # was queued. Measured; see Test-ComputerBusy.
        #
        # A refusal here is a normal outcome, not an error: the scheduler re-considers the row on
        # the next tick, and the auto-flow chain sets Pending so it is picked up after the current
        # operation finishes. Logged at INFO so a run can be reconstructed without guessing.
        if (Test-WuuComputerBusy -Row $ComputerItem) {
            Write-InfoLog "[$($ComputerItem.Computer)] submission refused: an operation is already $($ComputerItem.OpState) (op=$Op) - it stays queued for the next scheduler tick"
            return $false
        }

        # PHASE 1: a runspace captures the credential configuration at CREATION and is then reused for
        # every later operation on that computer. So after a credential change, reusing it would run
        # the next operation under the PREVIOUS identity - silently, and deterministically wrong.
        #
        # The epoch makes that impossible without rebuilding a runspace on every submission: a row
        # records the epoch its runspace was built under, and if the global epoch has moved on, the
        # stale runspace is disposed and a fresh one is built. When credentials have not changed the
        # epoch matches and this costs one integer comparison.
        $credEpoch = if ($global:CredentialEpoch) { [int]$global:CredentialEpoch } else { 0 }
        $rowEpoch = -1
        if ($ComputerItem.PSObject.Properties['CredentialEpoch']) { $rowEpoch = [int]$ComputerItem.CredentialEpoch }
        if ($ComputerItem.Runspace -and $rowEpoch -ne $credEpoch) {
            $detail = if ($ComputerItem.PSObject.Properties['CredentialIdentity']) { [string]$ComputerItem.CredentialIdentity } else { 'unknown' }
            Write-InfoLog "[$($ComputerItem.Computer)] credential configuration changed (row epoch $rowEpoch -> $credEpoch): rebuilding the runspace so this operation runs under the CURRENT identity, not the one '$detail' captured"
            try { $ComputerItem.Runspace.Close() } catch { }
            try { $ComputerItem.Runspace.Dispose() } catch { }
            $ComputerItem.Runspace = $null
        }

        if (-not $ComputerItem.Runspace) {
            $ComputerItem.Runspace = New-ComputerRunspace -ComputerItem $ComputerItem
            # Stamp the epoch AND the identity the runspace was built with. The epoch is what the
            # staleness decision above compares; the identity is for the operator - it answers "what
            # is this runspace actually using?" without reading a global that may have moved on.
            if ($ComputerItem.PSObject.Properties['CredentialEpoch']) { $ComputerItem.CredentialEpoch = $credEpoch }
            try {
                $isLocal = ($ComputerItem.Computer -eq 'localhost' -or $ComputerItem.Computer -eq $env:COMPUTERNAME)
                $identity = Resolve-WuuOperationCredential -ComputerName $ComputerItem.Computer -Local:$isLocal
                if ($ComputerItem.PSObject.Properties['CredentialIdentity']) {
                    $ComputerItem.CredentialIdentity = if ($identity.Mode -eq 'Custom') { [string]$identity.Username } else { 'process identity' }
                }
            } catch {
                # Recording the identity is informational; a failure here must not block submission.
                if ($ComputerItem.PSObject.Properties['CredentialIdentity']) { $ComputerItem.CredentialIdentity = 'process identity' }
            }
        }

        # Compose the chain as ONE pipeline (multiple AddScript calls run sequentially
        # in a single BeginInvoke when the runspace is free). DownloadUpdates receives
        # the op so its auto-install tail can skip re-queuing when running mid-AutoFlow.
        $PowerShell = [powershell]::Create()
        switch ($Op) {
            'Download'           { $PowerShell.AddScript($ctx.DownloadUpdates).AddArgument($ComputerItem).AddArgument($Op) | Out-Null }
            'InstallAndRecheck'  {
                $PowerShell.AddScript($ctx.InstallUpdates).AddArgument($ComputerItem) | Out-Null
                $PowerShell.AddScript($ctx.RestartComputer).AddArgument($ComputerItem).AddArgument($true) | Out-Null
                $PowerShell.AddScript($GetUpdates).AddArgument($ComputerItem) | Out-Null
            }
            'AutoFlow'           {
                # Full unattended chain: download, then install/reboot/recheck. DownloadUpdates'
                # own auto-install tail is suppressed by the $Op argument.
                $PowerShell.AddScript($ctx.DownloadUpdates).AddArgument($ComputerItem).AddArgument($Op) | Out-Null
                $PowerShell.AddScript($ctx.InstallUpdates).AddArgument($ComputerItem) | Out-Null
                $PowerShell.AddScript($ctx.RestartComputer).AddArgument($ComputerItem).AddArgument($true) | Out-Null
                $PowerShell.AddScript($GetUpdates).AddArgument($ComputerItem) | Out-Null
            }
            'Restart'            {
                # Manual restart: RestartComputer($false) = "not afterInstall", so the AUTO-reboot
                # setting must not suppress it. Then re-check, matching the old handler which
                # appended a check to the restart pipeline.
                $PowerShell.AddScript($ctx.RestartComputer).AddArgument($ComputerItem).AddArgument($false) | Out-Null
                $PowerShell.AddScript($GetUpdates).AddArgument($ComputerItem) | Out-Null
            }
            'RemoveOffline'      {
                # Connectivity probe; the payload removes the row itself when unreachable.
                $PowerShell.AddScript($ctx.RemoveOfflineComputer).AddArgument($ComputerItem) | Out-Null
            }
            'ServiceAction'      {
                $PowerShell.AddScript($ctx.WUServiceAction).AddArgument($ComputerItem).AddArgument($ServiceAction) | Out-Null
            }
            default              { $PowerShell.AddScript($GetUpdates).AddArgument($ComputerItem) | Out-Null }   # 'Check'
        }
        $PowerShell.Runspace = $ComputerItem.Runspace

        # SS2/SS3: OPERATION IDENTITY, stamped BEFORE the pipeline can run.
        #
        # Order matters: BeginInvoke returns immediately and the payload may start executing on its
        # own thread before this function resumes. Anything the payload or the cleanup loop reads to
        # decide "am I still current?" must therefore already be in place. Setting the id after
        # BeginInvoke would open a window where the row still carries the PREVIOUS operation's id,
        # and a legitimate writer would be judged stale.
        #
        # Set on the ROW (so the gate, the renderer and the cleanup loop can all see it) and copied
        # onto the JOB ENTRY (so the cleanup loop can compare the two without re-deriving anything
        # from timing - the exact defect this phase closes).
        $operationId = New-WuuOperationId -Computer $ComputerItem.Computer
        if ($ComputerItem.PSObject.Properties['OperationId']) { $ComputerItem.OperationId = $operationId }

        # Hand the identity to the WORKER, so the payload's row-writers can attribute their writes.
        # Without this the injected SafeUpdateListViewItemScript has no way to prove which operation
        # it is acting for, and the guard could only ever refuse a write that named a different id
        # explicitly - which no payload does. Set on every submission: the runspace is REUSED, so the
        # value must be refreshed or a later operation would write under the previous identity.
        try {
            if ($ComputerItem.Runspace) {
                $ComputerItem.Runspace.SessionStateProxy.SetVariable('WuuOperationId', $operationId)
            }
        } catch {
            # Informational only: a runspace that refuses the variable leaves the payload's writes
            # unattributed (permitted by the guard's asymmetry), so this must not block submission.
            Write-WarningLog "Could not stamp the operation identity into the runspace for $($ComputerItem.Computer): $($_.Exception.Message)"
        }

        #Save handle so we can later end the runspace
        $temp = New-Object PSObject -Property @{
            PowerShell  = $PowerShell
            Runspace    = $PowerShell.BeginInvoke()
            StartTime   = Get-Date
            Computer    = $ComputerItem.Computer
            # The identity of the operation this job IS. Without it the cleanup loop holds only
            # (Computer, Runspace, StartTime) and cannot tell which operation it is settling - so a
            # job stopped on timeout and settled later would release the lock of whatever operation
            # had since taken the computer.
            OperationId = $operationId
            Op          = $Op
        }

        $jobs.Add($temp) | Out-Null

        # Mark the computer as Running. Cleared by the job-cleanup loop when this pipeline
        # completes, or when the 10-minute timeout path disposes it - both are the only places a
        # job leaves $jobs, so OpState cannot get stuck at Running. Set on the row (not in the runspace)
        # because the gate is consulted from the scheduler thread, not from the worker.
        if ($ComputerItem.PSObject.Properties['OpState']) {
            $ComputerItem.OpState = 'Running'
            $ComputerItem.OpStartedAt = Get-Date
        }
        # SS5: the deadline is recorded HERE, at submission, so it is a property of the INTENT and
        # not recomputed later from a start time the cleanup loop happens to remember. One source of
        # truth: the deadline an operator can inspect is the deadline the loop enforces.
        #
        # The op name is stored on the row too, because the cleanup loop holds only
        # (Computer, Runspace, StartTime) - it cannot otherwise know whether it is looking at a
        # 5-minute service action or a 4-hour AutoFlow chain, which is precisely why the old code
        # had to use one flat 10-minute number for both.
        try {
            $deadline = Set-WuuOperationDeadline -Row $ComputerItem -Op $Op
            Write-InfoLog ("[{0}] op '{1}' deadline {2} from now ({3})" -f `
                $ComputerItem.Computer, $Op, (Format-WuuDuration -Seconds (Get-WuuOperationTimeoutSeconds -Op $Op)), $deadline.ToString('HH:mm:ss'))
        } catch {
            # A missing deadline is not fatal (the loop falls back to start-time), but it must not be
            # silent - that fallback is less precise and an operator should know it was used.
            Write-WarningLog "Could not record the operation deadline for $($ComputerItem.Computer): $($_.Exception.Message)"
        }
        if ($ctx.StateStore) { $ctx.StateStore.Touch() }
        return $true
    } catch {
        # In a catch block $_ is the ErrorRecord, not the computer item
        $errorMessage = $_.Exception.Message
        Write-ErrorLog "Runspace creation failed for $($ComputerItem.Computer): $errorMessage"
        
        # Cleanup on failure - dispose PowerShell instance to prevent leaks
        if ($PowerShell) {
            try {
                $PowerShell.Stop()
                $PowerShell.Dispose()
            } catch {
                Write-WarningLog "Failed to cleanup PowerShell instance for $($ComputerItem.Computer): $($_.Exception.Message)"
            }
        }
        
        # Update the row if runspace creation fails. Console edition: write to the store; no
        # dispatcher and no ListView (this path previously checked Dispatcher existence and
        # walked the visual tree for the row's container, neither of which exists now).
        if ($ctx.StateStore) {
            try {
                $ComputerItem.Status = "Failed to initialize: $errorMessage"
                $ComputerItem.UpdatesStatus = 'Error'
                $ComputerItem.State = 'Error'
                # Errored entries render grey
                $ComputerItem.Color = 'Error'
                $ctx.StateStore.Touch()
            } catch {
                Write-WarningLog "Failed to update row for $($ComputerItem.Computer): $($_.Exception.Message)"
            }
        }
        return $false
    }
}

function Start-PendingUpdateCheck {
    <#
    .SYNOPSIS The scheduler tick: promotes due retries and starts queued operations.
    .DESCRIPTION
    Reads the queue from the STATE STORE, not from a GUI control.

    This function previously iterated `$uiHash.Listview.Items`. In this edition `$uiHash` is an
    empty synchronized hashtable (Wuu.Core.psm1: `$global:uiHash = [hashtable]::Synchronized(@{})`)
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
    $ctx = $script:WuuCtx
    $backgroundProcessing = $ctx.BackgroundProcessing
    $jobs = $ctx.Jobs; $MaxConcurrentJobs = $ctx.MaxConcurrentJobs
    $store = $ctx.StateStore
    if ($backgroundProcessing.Suspended) { return }
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
                $item.Status = "Waiting for previous phase to complete. Current phase: $($item.Phase)"
                if ($item.PSObject.Properties['State']) { $item.State = 'Queued' }
                # Was $uiHash.Listview.Items.Refresh() - the store's redraw signal replaces it.
                $store.Touch()
            }
            continue
        }
        $item.Pending = $false
        # Consume and clear any queued follow-up op so this item starts the right chain.
        $op = 'Check'
        if ($item.PSObject.Properties['PendingOp'] -and $item.PendingOp) {
            $op = $item.PendingOp
            $item.PendingOp = $null
        }
        [void](Start-UpdateCheckJob -ComputerItem $item -Op $op)
    }
}

function Test-PhaseCompletion {
    <#
    .SYNOPSIS Whether every computer in a phase has settled SUCCESSFULLY, per the failure policy.
    .DESCRIPTION
    Reads the store, not `$uiHash.Listview.Items`. The old source made `@($null)` empty, so
    `$phaseComputers.Count -eq 0` was true and this returned `$true` for EVERY phase - i.e. phase
    gating never blocked anything. That is the opposite of the intended behaviour, and it is why a
    Phase 2 job could start while Phase 1 was still running.

    FAILURE POLICY (SS9). The previous behaviour was to `continue` past an errored or timed-out
    computer, which silently made ContinueOnFailure the only policy - the unsafe one. A failed canary
    therefore permitted the next phase with nothing in the UI or the audit trail saying why.

    The decision now comes from Test-WuuPhaseFailureBlocks, driven by
    $stateStore.Settings.PhaseFailurePolicy (default BlockOnFailure). The two failure kinds are
    reported separately so the caller can say *which* computers stopped it.
    #>
    param([string]$Phase)
    $store = $script:WuuCtx.StateStore
    if (-not $store) { return $true }
    $phaseComputers = @(Get-WuuComputerRow -Store $store | Where-Object { $_.Phase -eq $Phase })
    
    if ($phaseComputers.Count -eq 0) {
        return $true  # No computers in this phase, consider it complete
    }

    # Policy is read from the store so the setting has ONE home. Falling back to the safe default when
    # absent means an older/partial Settings hashtable cannot silently become ContinueOnFailure.
    $policy = 'BlockOnFailure'
    if ($store.Settings.ContainsKey('PhaseFailurePolicy') -and $store.Settings['PhaseFailurePolicy']) {
        $policy = [string]$store.Settings['PhaseFailurePolicy']
    }
    
    foreach ($computer in $phaseComputers) {
        # A row that has settled in a FAILED or TIMED-OUT state is handled here and nowhere else.
        #
        # This early `continue` is load-bearing and its absence made the policy DEAD CONFIGURATION.
        # Without it, a failed row fell through to the outstanding-work check below, where the old
        # `UpdatesStatus -ne 'All updates installed'` test was true for an errored row - so the phase
        # could never complete even when the policy TOLERATED the failure. ContinueOnFailure and
        # ContinueOnTimeout therefore had no effect on the only case they exist for. Found by the
        # policy test, not by reading the code.
        #
        # SS8: decided from STATE only. This used to also test `$status -in @('Error','Timeout')`, i.e.
        # the display string - and every production site that sets UpdatesStatus='Error' or 'Timeout'
        # sets the matching State on the adjacent line (State is set at all 11 UpdatesStatus sites), so
        # the extra test could only ADD disagreement, never catch a case State alone missed. Removing
        # it makes this predicate depend on one field, which is the point of SS8.
        $state = if ($computer.PSObject.Properties['State']) { [string]$computer.State } else { '' }
        $settledFailure = ($state -in @('Error', 'Timeout'))
        if ($settledFailure) {
            if (Test-WuuPhaseFailureBlocks -Row $computer -Policy $policy) {
                return $false   # policy says stop progression for this kind of failure
            }
            continue            # tolerated: settled, so it is not outstanding work
        }

        # Not yet checked (queued for the job scheduler)
        if ($computer.Pending) {
            return $false
        }

        # --- SS8: the WORK is decided from workflow state, the STRING only decides the wording ---
        #
        # The old test was `UpdatesStatus -ne 'All updates installed'`, i.e. a DISPLAY string used as
        # the workflow predicate. That string is written from eight sites with five different values,
        # so it can disagree with the row's actual work - and then it decides phase gating. The
        # production-reachable case: a row with Available=3 whose UpdatesStatus still reads
        # 'All updates installed' (stale wording, e.g. after an update appeared) was considered
        # SETTLED, and its phase advanced with updates outstanding. Verified by test.
        #
        # CheckConcluded is a three-state boolean ($null = not established, $false = concluded clean,
        # $true = concluded with work outstanding). $null is NOT "clean".
        $concluded = $null
        if ($computer.PSObject.Properties['CheckConcluded']) { $concluded = $computer.CheckConcluded }
        if ($null -eq $concluded) {
            # NOT ESTABLISHED. Advance ONLY if the row is visibly settled: nothing to download, nothing
            # waiting on a restart, and not mid-operation.
            #
            # A row loaded from config is exactly this case: New-WuuComputerRow gives it State='Queued'
            # and Wuu.Core sets UpdatesStatus='Unknown' with a "run wuu check to refresh" message. It
            # therefore does NOT settle here, and that is deliberate - a phase must not pass on
            # machines nobody has checked. (The previous display-string predicate also blocked it, but
            # for the wrong reason and unknowably: the same string would block a row forever after any
            # wording change.) It is logged either way so a skipped row is visible, not silent.
            if ($computer.Available -gt 0 -or $computer.Downloaded -gt 0 -or $computer.RebootRequired) {
                return $false
            }
            if ($state -in @('Queued', 'Checking', 'Searching', 'Downloading', 'Installing', 'Rebooting', 'Verifying', 'Unknown')) {
                return $false   # not settled: never checked, or the workflow is mid-operation
            }
            if ($state -in @('Complete', '')) {
                Write-InfoLog "Phase gate: '$($computer.Computer)' has no recorded check result in $Phase - treating it as settled (no work outstanding)"
                continue
            }
            # Any other workflow state is unresolved: refuse rather than guess.
            return $false
        }
        if ($concluded) {
            return $false   # a check concluded that there IS work outstanding
        }
    }
    
    return $true
}

function Get-NextAvailablePhase {
    $maxPhase = 5
    for ($phase = 1; $phase -le $maxPhase; $phase++) {
        $phaseComplete = Test-PhaseCompletion -Phase "Phase $phase"
        if (-not $phaseComplete) {
            return $phase
        }
    }
    return $null  # All phases complete
}

function Test-PhaseReady {
    param([string]$Phase)
    
    if ($Phase -eq "Phase 1") {
        return $true  # Phase 1 is always ready
    }
    
    # Check if previous phase is complete
    $phaseNumber = [int]($Phase -replace "Phase ", "")
    $previousPhase = "Phase $($phaseNumber - 1)"
    
    return Test-PhaseCompletion -Phase $previousPhase
}

Export-ModuleMember -Function @('Initialize-WuuWindowsUpdateContext','New-ComputerRunspace','Start-UpdateCheckJob','Start-PendingUpdateCheck','Test-PhaseCompletion','Get-NextAvailablePhase','Test-PhaseReady')

