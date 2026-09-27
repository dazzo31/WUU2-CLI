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
    # BackgroundProcessing, CredDialogXamlPath, StateStore (console edition)
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
        $newRunspace.SessionStateProxy.SetVariable("CredDialogXamlPath", $ctx.CredDialogXamlPath)
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
        $newRunspace.SessionStateProxy.SetVariable('ShowCustomCredentialDialogScript', [scriptblock]::Create({
            param(
                [string]$Message = "Enter your credentials",
                [string]$Username = "",
                [string]$Title = "Credentials Required"
            )
            
            Add-Type -AssemblyName PresentationFramework
            Add-Type -AssemblyName PresentationCore
            Add-Type -AssemblyName WindowsBase
            
            # Layout lives in ui/CredentialDialog.xaml - single source of truth, loaded via
            # the injected $CredDialogXamlPath variable (workers have no $PSScriptRoot).
            $xamlCredentialDialog = Get-Content -Path $CredDialogXamlPath -Raw
            $xamlCredentialDialog = $xamlCredentialDialog -replace '\$Title\b', $Title -replace '\$Message\b', $Message
            
            try {
                $reader = [System.Xml.XmlNodeReader]::new([xml]$xamlCredentialDialog)
                $dialog = [Windows.Markup.XamlReader]::Load($reader)
                
                # Get dialog controls
                $usernameTextBox = $dialog.FindName('UsernameTextBox')
                $passwordBox = $dialog.FindName('PasswordBox')
                $rememberCheckBox = $dialog.FindName('RememberCheckBox')
                $okButton = $dialog.FindName('OKButton')
                $cancelButton = $dialog.FindName('CancelButton')
                
                # Set initial username if provided
                if ($Username) {
                    $usernameTextBox.Text = $Username
                }
                
                # Set focus to appropriate control when dialog opens
                $dialog.Add_Loaded({
                    if ([string]::IsNullOrWhiteSpace($usernameTextBox.Text)) {
                        $usernameTextBox.Focus()
                    } else {
                        $passwordBox.Focus()
                    }
                })
                
                # OK button click handler
                $okButton.Add_Click({
                    if ([string]::IsNullOrWhiteSpace($usernameTextBox.Text)) {
                        [System.Windows.MessageBox]::Show("Please enter a username.", "Credential Error", 'OK', 'Warning')
                        $usernameTextBox.Focus()
                        return
                    }
                    
                    if ($passwordBox.SecurePassword.Length -eq 0) {
                        [System.Windows.MessageBox]::Show("Please enter a password.", "Credential Error", 'OK', 'Warning')
                        $passwordBox.Focus()
                        return
                    }
                    
                    # Store results in dialog tag
                    $dialog.Tag = @{
                        Username = $usernameTextBox.Text
                        Password = $passwordBox.SecurePassword.Copy()
                        Remember = $rememberCheckBox.IsChecked
                    }
                    $dialog.DialogResult = $true
                    $dialog.Close()
                })
                
                # Cancel button click handler
                $cancelButton.Add_Click({
                    $dialog.DialogResult = $false
                    $dialog.Close()
                })
                
                # Handle Enter key in both text boxes
                $usernameTextBox.Add_KeyDown({
                    if ($_.Key -eq 'Enter') {
                        $passwordBox.Focus()
                    }
                })
                
                $passwordBox.Add_KeyDown({
                    if ($_.Key -eq 'Enter') {
                        $okButton.RaiseEvent([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
                    }
                })
                
                # Set dialog owner to main window if available
                if ($uiHash.Window) {
                    $dialog.Owner = $uiHash.Window
                }
                
                # Show dialog
                $result = $dialog.ShowDialog()
                
                if ($result -eq $true) {
                    $credential = New-Object System.Management.Automation.PSCredential($dialog.Tag.Username, $dialog.Tag.Password)
                    return $credential
                } else {
                    return $null
                }
                
            } catch {
                # Fallback to Get-Credential if custom dialog fails
                return Get-Credential -Message $Message -ErrorAction SilentlyContinue
            }
        }.ToString()))
        
        # Add Get-RemoteCredentials function to runspace (with timeout protection to prevent hangs)
        $newRunspace.SessionStateProxy.SetVariable('GetRemoteCredentialsScript', [scriptblock]::Create({
            param(
                [string]$ComputerName,
                [string]$Operation = 'WMI access'
            )
            
            # Initialize CredentialCache if it doesn't exist
            if (-not $CredentialCache) {
                $CredentialCache = @{}
            }
            
            # Check cache first
            if ($CredentialCache.ContainsKey($ComputerName)) {
                return $CredentialCache[$ComputerName]
            }
            
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
            
            # Try custom credentials first if configured
            if ($UseCustomCredentials -and $CustomCredentials) {
                try {
                    $result = & $InvokePooledScript -Pool $WuuWorkerPool -ScriptBlock $testCim `
                        -ArgumentList @($ComputerName, $CustomCredentials) -TimeoutSeconds 5 -OperationName 'Credential probe (custom)'
                    if ($result -and $result.Success -and $result.Result -and $result.Result.Success) {
                        if (-not $CredentialCache) { $CredentialCache = @{} }
                        $CredentialCache[$ComputerName] = $CustomCredentials
                        return $CustomCredentials
                    }
                } catch {
                    try {
                        & $WriteDebugLogScript -Message "Custom credentials failed for $ComputerName : $($_.Exception.Message)" -Level 'WARN'
                    } catch { }
                }
            }
            
            # Custom credentials failed or not configured, try default credentials
            try {
                $result = & $InvokePooledScript -Pool $WuuWorkerPool -ScriptBlock $testCim `
                    -ArgumentList @($ComputerName, $null) -TimeoutSeconds 5 -OperationName 'Credential probe (default)'
                if ($result -and $result.Success -and $result.Result -and $result.Result.Success) {
                    if (-not $CredentialCache) { $CredentialCache = @{} }
                    $CredentialCache[$ComputerName] = $null  # null means use default credentials
                    return $null
                }
            } catch {
                try {
                    & $WriteDebugLogScript -Message "Default credentials failed for $ComputerName : $($_.Exception.Message)" -Level 'WARN'
                } catch { }
            }
            
            # Cannot prompt for credentials from a background runspace (deadlocks UI thread)
            # Return $null to indicate auth failed; the caller will handle the error
            return $null
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
        [ValidateSet('Check','Download','InstallAndRecheck','AutoFlow')]
        [string]$Op = 'Check'
    )
    $ctx = $script:WuuCtx
    $GetUpdates = $ctx.GetUpdates; $jobs = $ctx.Jobs; $uiHash = $ctx.UiHash
    $PowerShell = $null
    
    try {
        if (-not $ComputerItem.Runspace) {
            $ComputerItem.Runspace = New-ComputerRunspace -ComputerItem $ComputerItem
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
            default              { $PowerShell.AddScript($GetUpdates).AddArgument($ComputerItem) | Out-Null }   # 'Check'
        }
        $PowerShell.Runspace = $ComputerItem.Runspace

        #Save handle so we can later end the runspace
        $temp = New-Object PSObject -Property @{
            PowerShell = $PowerShell
            Runspace = $PowerShell.BeginInvoke()
            StartTime = Get-Date
            Computer = $ComputerItem.Computer
        }

        $jobs.Add($temp) | Out-Null
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
        
        # Update status if runspace creation fails (guard: dispatcher may be absent
        # during shutdown or in test rigs)
        if ($uiHash.ListView -and $uiHash.ListView.Dispatcher) {
            $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
                $uiHash.Listview.Items.EditItem($ComputerItem)
                $ComputerItem.Status = "Failed to initialize: $errorMessage"
                $ComputerItem.UpdatesStatus = 'Error'
                # Set background color to grey for errored entries
                $listViewItem = $uiHash.Listview.ItemContainerGenerator.ContainerFromItem($ComputerItem)
                if($listViewItem) {
                    $listViewItem.Background = [System.Windows.Media.Brushes]::LightGray
                }
                $uiHash.Listview.Items.CommitEdit()
                $uiHash.Listview.Items.Refresh()
            })
        }
        return $false
    }
}

function Start-PendingUpdateCheck {
    $ctx = $script:WuuCtx
    $backgroundProcessing = $ctx.BackgroundProcessing; $uiHash = $ctx.UiHash
    $jobs = $ctx.Jobs; $MaxConcurrentJobs = $ctx.MaxConcurrentJobs
    if ($backgroundProcessing.Suspended) { return }
    # Promote due Phase-E timeout retries (RetryAt set by $GetUpdates) back into the pending queue
    $now = [DateTime]::Now
    foreach ($item in @($uiHash.Listview.Items)) {
        if ($item.PSObject.Properties['RetryAt'] -and $item.RetryAt -and $item.RetryAt -le $now) {
            $item.RetryAt = $null
            $item.Pending = $true
        }
    }
    $pendingItems = @($uiHash.Listview.Items | Where-Object { $_.Pending })
    foreach ($item in $pendingItems) {
        if ($jobs.Count -ge $MaxConcurrentJobs) { break }
        if (-not (Test-PhaseReady -Phase $item.Phase)) {
            if ($item.Status -notlike 'Waiting for previous phase*') {
                $item.Status = "Waiting for previous phase to complete. Current phase: $($item.Phase)"
                if ($item.PSObject.Properties['State']) { $item.State = 'Queued' }
                $uiHash.Listview.Items.Refresh()
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
    param([string]$Phase)
    $uiHash = $script:WuuCtx.UiHash
    $phaseComputers = @($uiHash.Listview.Items | Where-Object { $_.Phase -eq $Phase })
    
    if ($phaseComputers.Count -eq 0) {
        return $true  # No computers in this phase, consider it complete
    }
    
    foreach ($computer in $phaseComputers) {
        # Errored/timed-out computers are settled - they must not block later phases forever
        if ($computer.UpdatesStatus -eq 'Error' -or $computer.UpdatesStatus -eq 'Timeout') {
            continue
        }
        # Not yet checked (queued for the job scheduler)
        if ($computer.Pending) {
            return $false
        }
        if ($computer.Available -gt 0 -or $computer.Downloaded -gt 0 -or $computer.RebootRequired -or $computer.UpdatesStatus -ne 'All updates installed') {
            return $false
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

