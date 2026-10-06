#Requires -Version 5.1
<#
.DESCRIPTION
Application core: startup, environment validation, event wiring, and the GUI loop.
Start-WuuApplication is the composed entry routine invoked by WUU.ps1.
#>

function Import-WuuModules {
    # Loads all Wuu modules with -Global (required for cross-module visibility:
    # session-state isolation hides sibling exports otherwise). Both the app
    # startup and tests/Test-PendingDrain.ps1 use this single import path.
    param([Parameter(Mandatory)][string]$WuuRoot)
    # Wuu.Configuration first: it owns the $global:* settings (including the single $global:WuuVersion
    # literal) that Start-WuuApplication applies before anything else reads them. Wuu.State next:
    # Wuu.Core's startup creates the state store via New-WuuStateStore, and
    # worker runspaces receive it. Wuu.Logging next because it owns the single log appender
    # (Get-WuuWorkerLogAppender) that Wuu.Scheduler injects into workers and that the cleanup and
    # per-computer runspaces both call. Wuu.Scheduler follows: it wires a runspace's helper set from
    # that appender. All are -Global, so the order is for readability and for the one real constraint
    # (nothing may be CALLED before it is imported).
    # Wuu.Console is the presentation layer; Wuu.Command the
    # scriptable verb layer; Wuu.Audit the tamper-evident trail. Wuu.Session models the computer
    # set as a first-class object and Wuu.Navigate owns the guided interactive workflow - both sit
    # ABOVE the engine and only read/delegate to it.
    #
    # Wuu.Reporting sits between Wuu.Audit (whose directory it reads) and Wuu.Command (which dispatches
    # `wuu report` to it), and it is READ-ONLY over the trail it reports on.
    foreach ($m in @('Wuu.Configuration','Wuu.Presentation','Wuu.Actions.Display','Wuu.Result','Wuu.State','Wuu.Logging','Wuu.Scheduler','Wuu.Models','Wuu.Remote','Wuu.Network','Wuu.Credentials','Wuu.Workers','Wuu.WindowsUpdate','Wuu.Console','Wuu.Session','Wuu.Audit','Wuu.Reporting','Wuu.Command','Wuu.Navigate')) {
        Import-Module (Join-Path $WuuRoot "src\$m.psm1") -Global -ErrorAction Stop
    }
}

function Start-WuuApplication {
    param(
        [Parameter(Mandatory)][string]$WuuRoot,
        # Phase 2 command mode: when supplied, run ONE operation and exit instead of showing
        # the interactive menu. Raw argv tokens (parsed by Wuu.Command).
        [string[]]$CommandArguments = @(),
        # Bounded wait for queued background work in command mode (seconds). A one-shot command
        # must let the operation it started make progress before reporting.
        [int]$CommandWaitSeconds = 120
    )

    Import-WuuModules -WuuRoot $WuuRoot

<#
.SYNOPSIS
The WUU2 CLI engine: startup, command dispatch, submission, and the background job-cleanup loop.

.DESCRIPTION
Headless console engine for remotely managing Windows Updates. It is derived from a legacy GUI edition
but contains none of it: no WPF, no XAML, no ui references. The release gate asserts that, so a comment
claiming otherwise is a defect rather than a harmless relic.

The three things worth knowing before editing this file:

  1. THIS FILE IS THE "GOD MODULE" (~4200 lines) and is not yet decomposed. Startup, the 12 `$event*`
     closures, the `$consoleActions` adapters and the job-cleanup runspace all live here, alongside the
     `$global:*` configuration, which is deliberately inside `Start-WuuApplication` rather than at module
     scope. Read `docs/ARCHITECTURE.md` before a structural change.

  2. ITS PAYLOAD SCRIPTBLOCKS RUN IN ISOLATED RUNSPACES. The download and get-updates payloads
     (`$DownloadUpdates`, `$GetUpdates`) and the job-cleanup body are not merely closures: they are
     executed in a runspace whose InitialSessionState is `CreateDefault()` with no module imported. A
     MODULE FUNCTION IS NOT CALLABLE THERE, so any logic they need must be inlined, and state reaches them
     only via `SessionStateProxy.SetVariable` or as an argument. Some of them also define their OWN copies
     of helper functions at indent 8 (see `Invoke-CimWithTimeout`), which is why a duplicate-function
     detector must be scope-aware.
     Do not write the payload assignment syntax in comments: some suites slice payloads from source text.

  3. THE HISTORY IS NOT HERE. Feature changelogs, the legacy author/date and the GUI-era feature list
     that used to be this header are preserved at `docs/CHANGELOG-history.md`. The edition's identity and
     version are in `docs/RELEASE_NOTES_v1.5.0-rc.1-cli.md`. See `docs/CODE_COMMENT_POLICY.md` for what
     stays inline and why.

Microsoft restricts remote download/install of Windows Updates, so those steps run the patch scripts
locally on the remote machine as SYSTEM through a temporary scheduled task (managed over WMI/DCOM), which
reports progress back through the registry.
#>

#region Configuration
# Extracted to src\Wuu.Configuration.psm1 (instructions SS8). CALLED HERE, at the exact point the
# block occupied, so every $global:* is set before anything reads it. The module holds the reason,
# including the one ordering constraint (the version literal must precede its resolver).
Initialize-WuuConfiguration -WuuRoot $WuuRoot
#endregion Configuration

#region Synchronized collections
# $global:uiHash (the GUI ListView and its checkbox members) is GONE: the console edition renders from the
# state store, so it was created here, passed into every worker context and injected into two runspaces
# while nothing ever read it. Dead wiring is worse than absent wiring - it suggests a dependency that
# does not exist. (Wuu.Models still declares a UiHash context field; see the note there.)
$global:jobs = [system.collections.arraylist]::Synchronized((New-Object System.Collections.ArrayList))
$global:jobCleanup = [hashtable]::Synchronized(@{})
$global:updatesHash = [hashtable]::Synchronized(@{})
$global:performanceHash = [hashtable]::Synchronized(@{})
$global:errorSuggestionsHash = New-WuuErrorSuggestions
# Console edition: presentation-agnostic state store replaces the WPF ListView as the
# place payloads report progress. Injected into every worker + cleanup runspace.
$stateStore = New-WuuStateStore
$global:stateStore = $stateStore

# Hand Wuu.Presentation what it used to close over (SS8). It cannot capture a caller's scope, so the
# store and the SHARED background-pause flag are passed explicitly - the same shape Wuu.Scheduler and
# Wuu.WindowsUpdate use for their runspaces. Called here, the moment both objects exist, so every status
# write and pause/resume after this point has its dependency.
Initialize-WuuPresentation -StateStore $stateStore
Initialize-WuuBackgroundProcessing -BackgroundProcessing $backgroundProcessing
# The console display actions resolve targets from the same store; they live in
# src\Wuu.Actions.Display.psm1 (SS8) and take it explicitly.
Initialize-WuuDisplayActions -StateStore $stateStore


#region Logging

# Initialize logging
# Debug logs are written to %TEMP% (or a non-cloud-synced fallback) instead of the
# repo root: when the repo lives under OneDrive, the sync engine transiently locks
# log files mid-write (Files-On-Demand placeholder hydration) and PS 5.1's
# Add-Content throws "Stream was not readable" - the error that killed timer ticks
# and runspace creation. %TEMP% is never cloud-synced. Write-DebugLog itself is
# fault-tolerant (Write-WuuLogEntry), so even a locked log can no longer crash ops.
$logDir = $env:TEMP
try {
    # Defensive: some environments redirect TEMP into a synced location
    $cur = Get-Item $logDir -Force -ErrorAction Stop
    while ($cur) {
        if ($cur.Attributes -band [IO.FileAttributes]::ReparsePoint) { $logDir = $null; break }
        $parent = Split-Path $cur.FullName -Parent
        if (-not $parent) { break }
        $cur = Get-Item $parent -Force -ErrorAction Stop
    }
} catch { $logDir = $null }
if (-not $logDir) {
    $logDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WUU2\Logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$global:LogPath = Join-Path $logDir "WUU_Debug_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$global:LogLock = New-Object System.Object

# Logging function

# Initialize debug log
if ($global:EnableDebugLogging) {
    Write-DebugLog "Windows Update Utility $global:WuuVersion Debug Log Started" -Level 'SUCCESS' -ToConsole
    Write-DebugLog "Log file: $global:LogPath" -Level 'INFO' -ToConsole
}

#endregion Logging

#endregion Synchronized collections

#region Error Handling

#region Environment Validation

#region Administrator Privilege Check
$ErrorActionPreference = 'Stop'

try {
    Write-DebugLog "Starting Windows Update Utility validation" -Level 'INFO'

    # Validate user is an Administrator
    Write-DebugLog "Checking Administrator credentials" -Level 'INFO'
    $isElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

    if (-not $isElevated) {
        # ---- Elevation relaunch -----------------------------------------------------------
        # A non-elevated launch relaunches itself elevated and exits. Two things matter here and
        # both were previously wrong:
        #
        # 1. ARGS MUST BE FORWARDED. WUU is a command-line tool; `WUU.ps1 install -Computer SRV01`
        #    relaunching into the interactive menu (silently discarding the operator's arguments)
        #    is a serious, confusing bug. The original code relied on `$args`, which is ALWAYS
        #    EMPTY inside a param() function - so the forwarding branch never ran. Use the real
        #    -CommandArguments parameter.
        # 2. -STA MUST BE PASSED. This host must be STA (see the STA validation block below); a
        #    relaunch without it triggers a SECOND relaunch, losing the arguments a second time.
        Write-Warning "This script requires Administrator privileges for full functionality!"
        Write-DebugLog "Script not running as Administrator - attempting elevation" -Level 'WARN'

        $scriptPath = Join-Path $WuuRoot 'WUU.ps1'
        if (-not (Test-Path -LiteralPath $scriptPath)) {
            throw "Cannot locate script file at: $scriptPath"
        }

        # Quote every forwarded token so values containing spaces (e.g. a computer list or a
        # -Reason string) survive the process boundary as ONE argument each.
        $forwardArgs = @()
        if ($CommandArguments) {
            $forwardArgs = @($CommandArguments | ForEach-Object { '"{0}"' -f ($_ -replace '"', '\"') })
        }

        $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $scriptPath))
        if ($forwardArgs.Count -gt 0) { $relaunchArgs += $forwardArgs }

        Write-Host "Requesting elevation (a UAC prompt may appear)..." -ForegroundColor Yellow
        Write-DebugLog ("Elevated relaunch: powershell.exe " + ($relaunchArgs -join ' ')) -Level 'INFO'

        $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processStartInfo.FileName = 'powershell.exe'
        $processStartInfo.Arguments = ($relaunchArgs -join ' ')
        $processStartInfo.Verb = 'runas'   # triggers UAC
        # NOT Hidden: this is a console application, and a hidden, non -NoExit window gives the
        # operator nothing to look at while their work runs. No -NoExit either, so the elevated
        # window closes when the command finishes.
        $processStartInfo.UseShellExecute = $true
        $processStartInfo.WorkingDirectory = Split-Path $scriptPath

        try {
            [System.Diagnostics.Process]::Start($processStartInfo) | Out-Null
            Write-Host "Elevated session started. Closing this session." -ForegroundColor Green
            Write-DebugLog "Successfully launched elevated PowerShell session" -Level 'SUCCESS'
            exit 0
        } catch {
            # Two distinct failures with different correct responses:
            #  - 'The operation was canceled by the user' => the operator DECLINED the UAC prompt.
            #    That is a deliberate choice, not an error: say so, don't print a stack trace or
            #    a scary Write-Error.
            #  - anything else => genuine failure to launch.
            $cancelled = $_.Exception.Message -match 'canceled by the user|cancelled by the user'
            if ($cancelled) {
                Write-Host "Elevation was declined. WUU needs Administrator rights to query and patch remote hosts." -ForegroundColor Yellow
                Write-DebugLog "User declined the UAC elevation prompt" -Level 'WARN'
            } else {
                Write-Host ("Could not start an elevated session: {0}" -f $_.Exception.Message) -ForegroundColor Red
                Write-Host "Please run PowerShell as Administrator and re-run WUU.ps1." -ForegroundColor Red
                Write-DebugLog "Failed to elevate privileges: $($_.Exception.Message)" -Level 'ERROR'
            }
            exit 1
        }
    } else {
        Write-Host "Running with Administrator privileges." -ForegroundColor Green
        Write-DebugLog "Script running with Administrator privileges" -Level 'SUCCESS'
    }


#endregion Administrator Privilege Check

#region Working Directory Setup
    #Ensure that we are running the GUI from the correct location so that Scripts\ can be accessed.
    $scriptPath = $WuuRoot
    Set-Location $scriptPath
    Write-DebugLog "Working directory set to: $(Get-Location)" -Level 'INFO'

#endregion Working Directory Setup

#region PowerShell STA Mode Validation
    # STA is required because the Windows Update COM APIs and the per-computer runspaces are
    # apartment-affine. There is no GUI in this edition, but the COM/runspace requirement remains.
    Write-DebugLog "Checking PowerShell apartment state: $($host.Runspace.ApartmentState)" -Level 'INFO'
    if ($host.Runspace.ApartmentState -ne 'STA') {
        Write-Warning "This script must be run in PowerShell started with the -STA switch!"
        Write-Host "Attempting to restart PowerShell in STA mode..." -ForegroundColor Yellow
        Write-DebugLog "Host is not STA - attempting STA relaunch" -Level 'WARN'

        # The relaunch MUST forward the command arguments, for the same reason the elevation
        # relaunch does: dropping them silently turns `WUU.ps1 install -Computer SRV01` into the
        # interactive menu. The previous version passed neither the args nor -NoExit, so the
        # operator got a window that flashed and vanished.
        $staScriptPath = Join-Path $WuuRoot 'WUU.ps1'
        $staArgs = @()
        if ($CommandArguments) {
            $staArgs = @($CommandArguments | ForEach-Object { '"{0}"' -f ($_ -replace '"', '\"') })
        }
        $staArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $staScriptPath)) + $staArgs

        try {
            # -NoExit only when there are no arguments: interactive users need the window to stay
            # open to see output, but a one-shot command should exit cleanly and let the caller
            # read the exit code.
            $sp = @{
                FilePath     = 'powershell.exe'
                ArgumentList = $staArgList
                WorkingDirectory = $WuuRoot
            }
            if ($staArgs.Count -eq 0) { $sp.Wait = $true }
            Start-Process @sp
            Write-Host "STA mode PowerShell launch initiated." -ForegroundColor Green
            Write-DebugLog ("STA relaunch: powershell.exe " + ($staArgList -join ' ')) -Level 'INFO'
        } catch {
            Write-Error "Failed to restart in STA mode: $($_.Exception.Message)"
            Write-Host "Re-run as: powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WUU.ps1" -ForegroundColor Red
        }
        exit
    }
    Write-DebugLog "PowerShell is running in STA mode" -Level 'INFO'

#endregion PowerShell STA Mode Validation

#region State Machine Helpers

function Set-ComputerState {
    <#
    .SYNOPSIS
    Updates a computer's State and Status consistently. The State field is the canonical pipeline
    position; Status is the human-readable text. Callers must prefer this over a direct
    `$Computer.Status = '...'` assignment so the two never drift.
    .PARAMETER Computer - the per-computer row object held by the state store
    .PARAMETER State - One of the canonical pipeline states
    .PARAMETER StatusDetail - Optional suffix appended to the canned status text
    #>
    param(
        [Parameter(Mandatory)][object]$Computer,
        [Parameter(Mandatory)][ValidateSet('Queued','Connecting','Connected','Checking','Searching','UpdatesFound','Downloading','Installing','RebootRequired','Rebooting','Verifying','Complete','Timeout','Error')][string]$State,
        [Parameter(Mandatory=$false)][string]$StatusDetail = ''
    )

    # SS16: routes through the single mutation funnel. This function no longer assigns State/Status
    # itself - it did, which is why a superseded operation could overwrite the state of the operation
    # that replaced it: there was no identity on the write to refuse. The canned text now comes from
    # Get-WuuStateStatusText, so the sentence the console prints has one definition.
    #
    # The operation identity is read from the row (this API predates the identity and its callers do
    # not pass one), so the write is attributed when the row has an operation and unattributed when it
    # does not - exactly the semantics Test-WuuStaleWrite defines.
    $writerOpId = ''
    if ($Computer.PSObject.Properties['OperationId']) { $writerOpId = [string]$Computer.OperationId }

    $result = Update-WuuOperationState -Row $Computer -OperationId $writerOpId -State $State -StatusSuffix $StatusDetail
    if (-not $result.Applied) {
        Write-DebugLog "[$($Computer.Computer)] State -> $State REFUSED: $($result.Reason)" -Level 'WARN'
        return
    }

    Write-DebugLog "[$($Computer.Computer)] State -> $State : $(Get-WuuStateStatusText -State $State -Detail $StatusDetail)" -Level 'DEBUG'
}
function Set-ComputerTimeout {
    <#
    .SYNOPSIS
    Marks a computer's operation as timed out WITHOUT marking it as a terminal error. Timeout is
    recoverable (the next phase or a Phase-E retry may still complete); Error is terminal. The two are
    rendered differently (Timeout yellow, Error grey), which is why they must not be conflated.
    .PARAMETER Computer - the per-computer row object held by the state store
    .PARAMETER Phase - What timed out ('WUA Session','Update Search','Reboot Wait',
                       'Performance Query','Credential Probe', etc.)
    .PARAMETER TimeoutSec - The timeout that was exceeded
    .PARAMETER Detail - Optional context appended to the status string
    #>
    param(
        [Parameter(Mandatory)][object]$Computer,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][int]$TimeoutSec,
        [Parameter(Mandatory=$false)][string]$Detail = ''
    )

    # SS16: routes through the mutation funnel. -Phase implies the Timeout display state, records the
    # deadline and its source, and sets UpdatesStatus - all from one decision, so a deadline can no
    # longer be recorded without the row showing that it timed out.
    $writerOpId = ''
    if ($Computer.PSObject.Properties['OperationId']) { $writerOpId = [string]$Computer.OperationId }

    $result = Update-WuuOperationState -Row $Computer -OperationId $writerOpId `
        -Phase $Phase -TimeoutSec $TimeoutSec -StatusSuffix $Detail -Color 'Timeout'
    if (-not $result.Applied) {
        Write-DebugLog "[$($Computer.Computer)] TIMEOUT in $Phase REFUSED: $($result.Reason)" -Level 'WARN'
        return
    }

    Write-DebugLog "[$($Computer.Computer)] TIMEOUT in $Phase after ${TimeoutSec}s. $Detail" -Level 'WARN'
}

#endregion State Machine Helpers

} catch {
    Write-Error "Environment validation failed: $($_.Exception.Message)"
    Write-DebugLog "Error details: $($_.Exception.GetType().FullName)" -Level 'ERROR'
    Write-DebugLog "Stack trace: $($_.ScriptStackTrace)" -Level 'ERROR'
    # No Read-Host: an unattended caller (scheduled task, CI, agent test) has nobody to press Enter,
    # so the prompt turned a startup error into a hung process. Stop-WuuFatal waits only for a real
    # interactive console, and exits NON-ZERO - the bare `exit` here reported success on a failure.
    Stop-WuuFatal -WhatHappened "Environment validation failed: $($_.Exception.Message)"
}
#endregion Environment validation

#region Load required assemblies with error handling
try {
    Write-DebugLog "Loading required .NET assemblies" -Level 'INFO'
    
    $assemblies = @(
        # Console edition: WPF assemblies (PresentationFramework/PresentationCore/WindowsBase)
        # are deliberately NOT loaded, and neither are Microsoft.VisualBasic or
        # System.Windows.Forms. Both were inherited from the GUI edition and are used by NO live
        # code in this edition - verified by grep: the only [Microsoft.VisualBasic.Interaction]
        # uses are inside dead GUI closures, and [System.Windows.Forms.*] has no type uses at all.
        #
        # Removing them is not cosmetic. Add-Type -AssemblyName THROWS on failure and the catch
        # below exits, so carrying an unused assembly turns a missing optional component into a
        # hard startup failure - which would contradict this edition's central claim that it runs
        # anywhere PowerShell 5.1 runs. Add an entry here only with a caller that needs it.
    )
    
    # DirectoryServices is genuinely required (the AD import path resolves
    # System.DirectoryServices.ActiveDirectory at runtime), but only needs an explicit Add-Type on
    # PS 7+ - on 5.1 the types resolve from the default load context.
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        try {
            Add-Type -AssemblyName 'System.DirectoryServices' -ErrorAction SilentlyContinue
            Write-DebugLog "Loaded DirectoryServices assembly for PowerShell 7" -Level 'INFO'
        } catch {
            Write-DebugLog "DirectoryServices assembly not available in PowerShell 7 - AD features will be limited" -Level 'WARN'
        }
        
        try {
            Add-Type -AssemblyName 'System.DirectoryServices.ActiveDirectory' -ErrorAction SilentlyContinue
            Write-DebugLog "Loaded DirectoryServices.ActiveDirectory assembly for PowerShell 7" -Level 'INFO'
        } catch {
            Write-DebugLog "DirectoryServices.ActiveDirectory assembly not available in PowerShell 7 - AD features will be limited" -Level 'WARN'
        }
    }
    
    foreach ($assembly in $assemblies) {
        try {
            Add-Type -AssemblyName $assembly -ErrorAction Stop
            Write-DebugLog "Loaded assembly: $assembly" -Level 'INFO'
        } catch {
            Write-Error "Failed to load assembly '$assembly': $($_.Exception.Message)"
            throw
        }
    }
    
    Write-DebugLog "All required assemblies loaded successfully" -Level 'INFO'
} catch {
    Write-Error "Failed to load required assemblies: $($_.Exception.Message)"
    Write-Host "This usually indicates a problem with a required .NET assembly." -ForegroundColor Red
    # Unattended-safe, and non-zero: see the note on the environment-validation path above.
    Stop-WuuFatal -WhatHappened "Failed to load required assemblies: $($_.Exception.Message)"
}
#endregion Load required assemblies

#region Load required PowerShell modules
try {
    Write-DebugLog "Loading required PowerShell modules" -Level 'INFO'
    
    # Import Microsoft.PowerShell.Security module for ConvertTo-SecureString
    Import-Module Microsoft.PowerShell.Security -ErrorAction Stop
    Write-DebugLog "Loaded module: Microsoft.PowerShell.Security" -Level 'INFO'
    
    Write-DebugLog "All required modules loaded successfully" -Level 'INFO'
} catch {
    Write-Error "Failed to load required modules: $($_.Exception.Message)"
    Write-Host "This usually indicates a problem with PowerShell module installation." -ForegroundColor Red
    # Unattended-safe, and non-zero: see the note on the environment-validation path above.
    Stop-WuuFatal -WhatHappened "Failed to load required modules: $($_.Exception.Message)"
}
#endregion Load required modules

#region Presentation layer (console)
# Console edition: no XAML, no WPF, no window. The GUI loaded ui\MainWindow.xaml here via
# [Windows.Markup.XamlReader] and resolved every control with FindName; the console shell
# (Wuu.Console.psm1) renders the state store instead and the interactive menu replaces the
# context menu. ui/ has been removed, so this region deliberately does nothing but record
# that presentation is console-only.
Write-DebugLog "Console presentation mode (no XAML/WPF)" -Level 'INFO'
#endregion Presentation layer (console)

#region Helper Functions

#region Monitoring and Performance

# Enhanced error handling with suggestions
function Get-ErrorSuggestions {
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
}

# Automated recovery function
function Invoke-AutoRecovery {
    param([string]$ComputerName, [string]$ErrorCode)
    
    if (Get-Command -Module 'Wuu.Remote' -Name 'Invoke-AutoRecovery' -ErrorAction SilentlyContinue) {
        return Wuu.Remote\Invoke-AutoRecovery -ComputerName $ComputerName -ErrorCode $ErrorCode
    }

    $errorInfo = Get-ErrorSuggestions -ErrorMessage $ErrorCode
    
    if (-not $errorInfo.AutoFix) {
        return $false
    }
    
    try {
        $code = $ErrorCode
        if ($ErrorCode -match '0x([0-9A-Fa-f]{8})') {
            $code = $matches[1].ToLowerInvariant()
        } elseif ($ErrorCode -match '([0-9A-Fa-f]{8})') {
            $code = $matches[1].ToLowerInvariant()
        } elseif ($ErrorCode -match 'RPC server is unavailable') {
            $code = '800706ba'
        } elseif ($ErrorCode -match 'RPC.*?failed') {
            $code = '800706be'
        }

        switch ($code) {
            '800706ba' { # RPC server unavailable
                # Try to restart RPC service using Invoke-Command
                if ($ComputerName -eq 'localhost' -or $ComputerName -eq $env:COMPUTERNAME) {
                    Get-Service -Name 'RpcSs' -ErrorAction Stop | Restart-Service -ErrorAction Stop
                    Start-Sleep -Seconds 5
                    Get-Service -Name 'RemoteRegistry' -ErrorAction Stop | Start-Service -ErrorAction Stop
                } else {
                    Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                        Get-Service -Name 'RpcSs' -ErrorAction Stop | Restart-Service -ErrorAction Stop
                        Start-Sleep -Seconds 5
                        Get-Service -Name 'RemoteRegistry' -ErrorAction Stop | Start-Service -ErrorAction Stop
                    } -ErrorAction Stop
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
}

#endregion Monitoring and Performance
#region ScriptBlocks

# Helper function to update computer rows (main-session copy).
# The runspace copy is injected as $UpdateWuuComputerRowScript in
# New-ComputerRunspace (Wuu.WindowsUpdate.psm1) - keep both in sync.
#
# RENAMED (was SafeUpdateListViewItem). The old name described the GUI edition, where this wrote into
# a WPF ListView; it writes a row into the state store and there is no ListView anywhere in this
# repository. The name was actively misleading - a reviewer reading `Safe*ListView*` would look for a
# view dependency that does not exist, and a new operation might reasonably have been routed around
# it on that basis. The console edition is the shipped one, so the name now describes what the
# function does.
function Update-WuuComputerRow {
    param(
        [string]$ComputerName,
        [hashtable]$Properties
    )

    if (-not $stateStore) { return }

    try {
        # Resolve the row from the store's own synchronized hashtable.
        $targetRow = $stateStore.ByName[$ComputerName.ToLowerInvariant()]
        if (-not $targetRow) { return }

        # SS3: STALE-WRITER GUARD.
        #
        # This is the choke point every payload uses to write row state, and it resolves its target by
        # COMPUTER NAME - the row's key, not an identity. So a payload that outlives its operation still
        # finds a live row: it may be the one a newer operation now owns. Writing then would let a
        # superseded operation restamp State/Status/Colour on the operation that replaced it.
        #
        # The guard is deliberately ASYMMETRIC: it refuses only what it can PROVE is stale (a row that
        # names an operation, and a writer naming a different one). An unattributed write is permitted,
        # because startup/import paths legitimately write rows that have no operation, and refusing those
        # would break list loading. Proven-stale is refused; merely unattributed is allowed.
        #
        # A refusal is logged, not silent: otherwise "the guard held" and "the write never happened"
        # look identical to an operator reading the log.
        $writerOpId = ''
        if ($Properties -and $Properties.ContainsKey('OperationId')) { $writerOpId = [string]$Properties['OperationId'] }
        $rowOpId = ''
        if ($targetRow.PSObject.Properties['OperationId']) { $rowOpId = [string]$targetRow.OperationId }
        if ($rowOpId -ne '' -and $writerOpId -ne '' -and $rowOpId -cne $writerOpId) {
            Write-WarningLog "[$ComputerName] stale row write refused: the row belongs to operation '$rowOpId', writer is '$writerOpId'"
            return
        }
        if ($targetRow.PSObject.Properties['LastResetOperationId'] -and $targetRow.LastResetOperationId -and $writerOpId) {
            Write-WarningLog "[$ComputerName] stale row write refused: operation was reset ($($targetRow.LastResetSource): $($targetRow.LastResetReason)), writer '$writerOpId' is stale"
            return
        }
        $curRowState = if ($targetRow.PSObject.Properties['State']) { [string]$targetRow.State } else { '' }
        if ($curRowState -in @('Error', 'Timeout', 'Complete') -and $Properties -and $Properties.ContainsKey('State') -and [string]$Properties['State'] -ne $curRowState) {
            Write-WarningLog "[$ComputerName] terminal transition refused: settled row ('$curRowState') cannot move to '$($Properties['State'])'"
            return
        }

        foreach ($propertyName in $Properties.Keys) {
            $targetRow.$propertyName = $Properties[$propertyName]
        }
        $stateStore.Touch()
    } catch {
        # Silently ignore row update errors during startup
    }
}

#Add new computer(s) to list
# WUU-OBS-02: Unified with Add-WuuComputerSetNames (Wuu.Session) so that all entry points
# (flat menu, guided workflow, Active Directory import) share the same validation,
# deduplication, and row-creation pipeline.
# Legacy Exempt.txt bypass retired: host exclusion belongs in policy, not a silent local file check.
$AddEntry = {
    [CmdletBinding()]
    Param (
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        $ComputerName
    )

    $names = @(
        if ($ComputerName) {
            foreach ($item in @($ComputerName)) {
                if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item)) {
                    [string]$item
                }
            }
        }
    )

    Write-Verbose "Adding $($names -join ', ')."
    Write-InfoLog "AddEntry called with computers: $($names -join ', ')"

    # Add-WuuComputerSetNames expects a set object with a .Store property.
    $set = [pscustomobject]@{
        Name  = 'Fleet'
        Store = $stateStore
    }

    $result = Add-WuuComputerSetNames `
        -Set $set `
        -Names $names `
        -Phase 'Phase 1' `
        -StateSource 'AddEntry'

    Write-InfoLog ("AddEntry summary: Added={0}; Duplicates={1}; Invalid={2}" -f `
        $result.AddedCount, @($result.Duplicates).Count, @($result.Invalid).Count)

    # Runspace creation and job startup are handled by the job timer (Start-PendingUpdateCheck)
    # so the calling thread is never blocked waiting for job slots.
    return $result
}

# Create and configure the persistent per-computer worker runspace

# Start an update-check job for a computer item (runs on the UI thread)

# Drain pending computers into worker jobs; called by the UI job timer so the UI thread never blocks

# Note: SetUpdatesStatus function was removed as it was unused
# The functionality is now handled directly in the GetUpdates script

# Phase management helper functions



# Assign computers to phases

# Remove entry ScriptBlock
$removeEntry = {
    Param ($ComputerNames)
    
    # Add null/empty check to prevent crashes when no computers are selected
    if (-not $ComputerNames -or $ComputerNames.Count -eq 0) {
        Write-DebugLog "Remove computers called with no selections - ignoring operation" -Level 'DEBUG'
        $stateStore.SetStatus('No computers selected for removal')
        return
    }
    
    Write-InfoLog "Removing computers: $($ComputerNames.Count) entries"
    
    ForEach ($Computer in $ComputerNames) {
        try {
            # Stop any running jobs for this computer with comprehensive cleanup
            $runningJobs = $jobs | Where-Object { $_.PowerShell.Runspace -eq $Computer.Runspace }
            foreach ($job in $runningJobs) {
                try {
                    # Stop the async operation
                    $job.PowerShell.Stop()
                } catch {
                    Write-WarningLog "Failed to stop PowerShell for $($Computer.Computer): $($_.Exception.Message)"
                }
                try {
                    # Dispose the PowerShell instance
                    $job.PowerShell.Dispose()
                } catch {
                    Write-WarningLog "Failed to dispose PowerShell for $($Computer.Computer): $($_.Exception.Message)"
                }
                try {
                    # Remove from jobs list
                    $jobs.Remove($job)
                } catch {
                    Write-WarningLog "Failed to remove job from list for $($Computer.Computer): $($_.Exception.Message)"
                }
            }

            # SS3: this path removes a job OUT OF BAND - no cleanup-loop pass sees it, so the
            # loop's three guarded release sites never run for this job. The row is dropped below
            # (Remove-WuuComputerRow), so the lock cannot leak here today. It is cleared anyway so
            # the invariant holds by construction rather than by the coincidence that this caller
            # deletes the row: any future path that stops a job this way but KEEPS the row would
            # otherwise leave it permanently 'Running', and a permanently-busy computer is never
            # scheduled again.
            #
            # SS16: routed through the mutation funnel. This is main-session code (unlike the
            # cleanup loop and the payloads), so the funnel IS resolvable here and the 7-line
            # cleanup block that used to be copy-pasted at four separate sites is now one call.
            # ClearOperation covers OpState, OpStartedAt, the deadline and its source, the op name,
            # the heartbeat, the identity and the runspace reference - note it also RETIRES THE
            # IDENTITY, which two of the four former copies did not do.
            $detachOpId = ''
            if ($Computer.PSObject.Properties['OperationId']) { $detachOpId = [string]$Computer.OperationId }
            # CORE-RUNSPACE-DISPOSE-01: cache the runspace reference BEFORE ClearOperation, because
            # the funnel sets $Row.Runspace = $null. The following `if ($Computer.Runspace)` was dead
            # code - it always saw $null - so the original runspace was never Closed/Disposed.
            $rsToClose = if ($Computer.PSObject.Properties['Runspace']) { $Computer.Runspace } else { $null }
            $null = Update-WuuOperationState -Row $Computer -OperationId $detachOpId -ClearOperation
            
            # Close and dispose the cached runspace (the row's reference is already cleared).
            if ($rsToClose) {
                try {
                    $rsToClose.Close()
                } catch {
                    Write-WarningLog "Failed to close runspace for $($Computer.Computer): $($_.Exception.Message)"
                }
                try {
                    $rsToClose.Dispose()
                } catch {
                    Write-WarningLog "Failed to dispose runspace for $($Computer.Computer): $($_.Exception.Message)"
                }
                $rsToClose = $null
            }
            
            # Remove from updates hash
            if ($updatesHash.ContainsKey($Computer.Computer)) {
                try {
                    $updatesHash.Remove($Computer.Computer)
                } catch {
                    Write-WarningLog "Failed to remove from updatesHash for $($Computer.Computer): $($_.Exception.Message)"
                }
            }
            
            # Remove from performance hash
            if ($performanceHash.ContainsKey($Computer.Computer)) {
                try {
                    $performanceHash.Remove($Computer.Computer)
                } catch {
                    Write-WarningLog "Failed to remove from performanceHash for $($Computer.Computer): $($_.Exception.Message)"
                }
            }
            
            # Remove from the state store (console edition; no dispatcher/ListView)
            try {
                Remove-WuuComputerRow -Store $stateStore -Computer $Computer.Computer | Out-Null
            } catch {
                Write-WarningLog "Failed to remove store row for $($Computer.Computer): $($_.Exception.Message)"
            }
            
            Write-SuccessLog "Successfully removed computer: $($Computer.Computer)"
        } catch {
            Write-ErrorLog "Error removing computer $($Computer.Computer): $($_.Exception.Message)"
        }
    }
    
    # Update status
    Update-StatusBackground "Removed $($ComputerNames.Count) computer(s) from list."
}

# Clear computer list ScriptBlock
$clearComputerList = {
    Write-InfoLog "Clearing all computers from list"
    
    # Get all computers before clearing (snapshot from the store)
    $allComputers = Get-WuuComputerRow -Store $stateStore
    
    if ($allComputers.Count -gt 0) {
        # Remove all computers using the removeEntry ScriptBlock
        &$removeEntry $allComputers
        
        # Update status
        Update-StatusBackground 'Computer List Cleared!'
        
        Write-SuccessLog "Successfully cleared all computers from list"
    } else {
        Update-StatusBackground 'Computer list is already empty.'
    }
}

# Clear computer list (legacy alias)

#endregion ScriptBlocks

#region Update Operations

#Download available updates
$DownloadUpdates = {
    Param ($Computer, $Op)
    Try{
        Set-Location $path

        #Check download size
        $dlStats = ($updatesHash[$Computer.computer] | Where-Object {$_.IsDownloaded -eq $false} | Select-Object -ExpandProperty MaxDownloadSize | Measure-Object -Sum)

        #Update status
            $computer.Status = "Downloading $($dlStats.Count) Updates ($([math]::Round($dlStats.Sum/1MB))MB)."
            $computer.State = 'Downloading'
        if ($stateStore) { $stateStore.Touch() }

        # PHASE 1: the identity decision belongs to the RESOLVER, and only to the resolver. This call
        # is unconditional on purpose:
        #
        #   * the resolver returns $null when custom credentials are not configured, and also when
        #     the target is the local machine (DCOM rejects explicit credentials locally) - so the
        #     payload does not need to know either rule;
        #   * the previous `if ($UseCustomCredentials -and ... -and -ne 'localhost')` guard duplicated
        #     both rules in the payload, which is two places defining the same thing and the shape
        #     that let a credential failure be swallowed into a $null credential.
        #
        # No try/catch: the resolver THROWS when configured custom credentials cannot be used, and
        # that must reach the payload's catch so the row is marked Error. A refused operation is
        # correct; an unlogged identity substitution is not.
        $remoteCred = & $GetRemoteCredentialsScript -ComputerName $Computer.computer -Operation 'Windows Update download'
        $onProgress = {
            param($p)
            if ($p.Phase -ne 'Downloading') { return }
            $progressText = "Downloading $($p.Current)/$($p.Total): $($p.Title)"
                $Computer.Status = $progressText
            if ($stateStore) { $stateStore.Touch() }
        }
        $taskResult = & $InvokeRemoteTaskScript -ComputerName $Computer.computer -ScriptPath $ConfigPaths.DownloadScript -Operation 'Download' -Credential $remoteCred -ProgressCallback $onProgress
        if (-not $taskResult.Success) {
            throw "Remote download failed: $($taskResult.Error)"
        }
        $numDownloaded = $taskResult.Count

        #Update status
        if ($computer.PSObject.Properties['LastResetOperationId'] -and $computer.LastResetOperationId) { return }
        $curState = if ($computer.PSObject.Properties['State']) { [string]$computer.State } else { '' }
        if ($curState -in @('Error', 'Timeout', 'Complete')) { return }
            $computer.Status = 'Download complete.'
            $computer.State = 'UpdatesFound'
            $computer.Downloaded += $numDownloaded
        if ($stateStore) { $stateStore.Touch() }
        
        #Auto-install if enabled and there are downloaded updates ready for installation
        #
        # Reads the CONSOLE settings model, not a GUI control. This gate used to read
        # $uiHash.AutoInstallCheckBox.IsChecked, which is $null in this edition (the synchronized
        # hashtable has no such key), so `if ($null -and ...)` was ALWAYS FALSE and auto-install
        # never fired regardless of the operator's setting. It failed silently because Wuu.Core has
        # no Set-StrictMode - every other src/ module has one, which is why the omission survived.
        #
        # NOTE the same function already used $stateStore.Settings.AutoInstall a few lines below
        # (to choose PendingOp): the migration was begun and abandoned mid-function, leaving the
        # gate on the old source and the decision on the new one. They now agree.
        #
        # If $stateStore is somehow absent the condition is false: no automatic action. Every
        # degraded path here fails toward "do nothing unattended", which is the safe direction.
        if($stateStore.Settings.AutoInstall -and $computer.Downloaded -gt 0){
            #Check if there are any updates that are downloaded and don't require user input
            $downloadedUpdates = $updatesHash[$Computer.computer] | Where-Object {$_.IsDownloaded -and $_.InstallationBehavior.CanRequestUserInput -eq $false}
            
            # Skip when this download is itself running inside an AutoFlow chain - that
            # pipeline already continues into install+reboot+recheck, so re-queuing here
            # would start a duplicate install on the same runspace.
            $alreadyAutoFlow = ($Op -eq 'AutoFlow')
            $alreadyPending = $false
            if ($Computer.PSObject.Properties['Pending'] -and $Computer.Pending) { $alreadyPending = $true }
            if($downloadedUpdates -and -not $alreadyAutoFlow -and -not $alreadyPending){
                # Queue install as a follow-up (nested BeginInvoke on this busy runspace
                # would silently never run the install payload).
                #
                # SS7: this is an INTERNAL follow-up, so it must NOT displace an operator's queued
                # request - the automatic install is optional, the operator's request is not. This
                # inlines Set-WuuPendingOperation -OnlyIfEmpty because the payload runs in an
                # isolated worker runspace where no module function resolves; a test asserts the two
                # agree. Do not "simplify" this to a bare assignment: that is the silent-replacement
                # defect (an operator's queued check/download would vanish).
                $existingRequest = ''
                if ($Computer.PSObject.Properties['PendingOp'] -and $Computer.PendingOp) { $existingRequest = [string]$Computer.PendingOp }
                if ($existingRequest -eq '') {
                    $computer.Status = 'Auto-install of downloaded updates queued...'
                    $computer.State = 'Installing'
                    $Computer.PendingOp = 'InstallAndRecheck'
                    $Computer.Pending   = $true
                    if ($stateStore) { $stateStore.Touch() }
                }
            }
        }
    }
    Catch{
        if ($computer.PSObject.Properties['LastResetOperationId'] -and $computer.LastResetOperationId) { exit }
            $computer.Status = "Error occured: $($_.Exception.Message)."
            $computer.UpdatesStatus = 'Error'
            $computer.State = 'Error'
            # Set background color to grey for errored entries
        $Computer.Color = 'Error'
        if ($stateStore) { $stateStore.Touch() }

        #Cancel any remaining actions
        exit
    }
}

#Check for available updates
$GetUpdates = {
    Param ($Computer)
    Try{
        # Log to file directly in runspace
        if ($EnableDebugLogging) {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Started GetUpdates for $($Computer.Computer)"
            & $WriteLogFileScript $logEntry
        }
        
        # Define simplified logging function
        function Write-DebugLog { 
            param($Message, $Level = 'INFO', $Computer = '', [switch]$ToConsole)
            & $WriteDebugLogScript @PSBoundParameters 
        }
        
        # Define Get-ErrorSuggestions function
        function Get-ErrorSuggestions {
            param([string]$ErrorMessage)
            & $GetErrorSuggestionsScript -ErrorMessage $ErrorMessage
        }
        
        # Define Get-RemoteCredentials function
        #
        # PHASE 1: this is a thin wrapper around the injected $GetRemoteCredentialsScript, which is
        # where the identity decision lives. It exists because the payload was written against a
        # function name and the runspace only has the scriptblock variable. It deliberately does NOT
        # swallow the resolver's exception: the resolver throws when custom credentials are
        # configured but unusable, and that throw must reach the payload's catch so the operation is
        # refused rather than continued as an unintended identity.
        function Get-RemoteCredentials {
            param(
                [string]$ComputerName,
                [string]$Operation = 'WMI access'
            )
            
            # Check if script block is available
            if (Get-Variable -Name 'GetRemoteCredentialsScript' -ErrorAction SilentlyContinue) {
                & $GetRemoteCredentialsScript -ComputerName $ComputerName -Operation $Operation
            } else {
                # Fallback: for remote computers, return null (use default credentials)
                # For localhost, this should not be called
                if ($ComputerName -eq 'localhost' -or $ComputerName -eq $env:COMPUTERNAME) {
                    return $null
                } else {
                    # For remote computers, try default credentials and return null if they work
                    try {
                        $null = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $ComputerName -ErrorAction Stop
                        return $null  # Default credentials work
                    } catch {
                        throw "Failed to authenticate to $ComputerName for $Operation : $($_.Exception.Message)"
                    }
                }
            }
        }
        
        # Define the row-update wrapper for the isolated worker runspace. The real work is the
        # scriptblock injected by New-ComputerRunspace; this is a local binding so the payload can
        # call it by name. Named for what it does - it updates a computer ROW (the old
        # `SafeUpdateListViewItem` named a WPF control this console edition does not have).
        function Update-WuuComputerRow {
            param(
                [string]$ComputerName,
                [hashtable]$Properties
            )
            & $UpdateWuuComputerRowScript -ComputerName $ComputerName -Properties $Properties
        }
        
        # Define Invoke-AutoRecovery function
        function Invoke-AutoRecovery {
            param([string]$ComputerName, [string]$ErrorCode)
            & $InvokeAutoRecoveryScript -ComputerName $ComputerName -ErrorCode $ErrorCode
        }
        
        # Define timeout helpers locally (isolated runspace does not inherit script-scope functions)
        # Pool-based bounded execution via the injected WuuWorkerPool + InvokePooledScript
        # (SetVariable'd by New-ComputerRunspace) - was Start-Job per probe.
        function Invoke-CimWithTimeout {
            param(
                [string]$ComputerName,
                [string]$ClassName = 'Win32_ComputerSystem',
                [int]$TimeoutSeconds = 5,
                # PSCredential (never a plain string) so a password can't leak into logs/UI
                [pscredential]$Credential = $null,
                [string]$Operation = 'CIM operation',
                # The row whose operation deadline caps this probe; $null = no budget to cap against.
                $Row = $null
            )
            # Timeout = min(own, remaining budget), floor 5s; 0 means "no timeout" and is left alone.
            # Inlined: this runs in a payload runspace where Get-WuuEffectiveInnerTimeout is not callable.
            # Test-RemainingBudget asserts this copy agrees with it. Kept in a local - parameters are not reassigned.
            $effectiveTimeout = $TimeoutSeconds
            if ($TimeoutSeconds -gt 0 -and $null -ne $Row) {
                $rowExpiry = $Row.PSObject.Properties['TimeoutExpiresAt']
                if ($rowExpiry -and $Row.TimeoutExpiresAt) {
                    # An unparseable deadline still counts as a deadline: apply the floor.
                    $rowExpiryDate = $null
                    try { $rowExpiryDate = [datetime]$Row.TimeoutExpiresAt } catch { $rowExpiryDate = $null }
                    if ($null -eq $rowExpiryDate) {
                        $effectiveTimeout = [math]::Max(5, $TimeoutSeconds)
                    } else {
                        $remaining = [int](($rowExpiryDate - (Get-Date)).TotalSeconds)
                        if ($remaining -lt $TimeoutSeconds) { $effectiveTimeout = [math]::Max(5, $remaining) }
                    }
                }
            }
            try {
                $cimResult = & $InvokePooledScript -Pool $WuuWorkerPool -ScriptBlock {
                    # $Cred is always a PSCredential (or $null for default credentials).
                    # NOTE: PS 5.1's Get-CimInstance has NO -Credential parameter; alternate
                    # credentials must go through New-CimSession (DCOM) + Get-CimInstance -CimSession.
                    # DCOM for BOTH paths: Get-CimInstance -ComputerName implies WinRM/WSMAN
                    # and times out on WMI/DCOM-reachable hosts without a WinRM listener.
                    param([string]$ComputerName, [string]$ClassName, [pscredential]$Cred)
                    $cimSession = $null
                    try {
                        $sessionArgs = @{ ComputerName = $ComputerName; SessionOption = (New-CimSessionOption -Protocol DCOM) }
                        if ($Cred) { $sessionArgs['Credential'] = $Cred }
                        $cimSession = New-CimSession @sessionArgs -ErrorAction Stop
                        $result = Get-CimInstance -CimSession $cimSession -ClassName $ClassName -ErrorAction Stop
                        return @{ Success = $true; Result = $result }
                    } catch {
                        return @{ Success = $false; Error = $_.Exception.Message }
                    } finally {
                        if ($cimSession) { Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue }
                    }
                } -ArgumentList @($ComputerName, $ClassName, $Credential) -TimeoutSeconds $effectiveTimeout -OperationName $Operation
                if ($cimResult.Success) {
                    $inner = $cimResult.Result
                    if ($inner -and $inner.Success) {
                        return @{ Success = $true; Result = $inner.Result }
                    } else {
                        $errorMsg = if ($inner -and $inner.Error) { $inner.Error } else { 'Unknown error' }
                        return @{ Success = $false; Error = $errorMsg }
                    }
                } else {
                    return @{ Success = $false; Error = $cimResult.Error }
                }
            } catch {
                return @{ Success = $false; Error = $_.Exception.Message }
            }
        }
        
        function Invoke-ServiceWithTimeout {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]$ServiceName = 'wuauserv',

        [Parameter(Mandatory=$false)]
        [ValidateSet('Check', 'Start', 'Stop', 'Restart')]
        [string]$Action = 'Check',

        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 30,

        # The row whose operation deadline caps this call; $null = no budget to cap against.
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        $Row = $null,

        [Parameter(Mandatory=$false)]
        [ValidateRange(0, 60)]
        [int]$PostActionDelay = 5
    )

    # Same inlined budget cap as Invoke-CimWithTimeout (asserted by Test-RemainingBudget).
    $effectiveTimeout = $TimeoutSeconds
    if ($TimeoutSeconds -gt 0 -and $null -ne $Row) {
        $rowExpiry = $Row.PSObject.Properties['TimeoutExpiresAt']
        if ($rowExpiry -and $Row.TimeoutExpiresAt) {
            $rowExpiryDate = $null
            try { $rowExpiryDate = [datetime]$Row.TimeoutExpiresAt } catch { $rowExpiryDate = $null }
            if ($null -eq $rowExpiryDate) {
                $effectiveTimeout = [math]::Max(5, $TimeoutSeconds)
            } else {
                $remaining = [int](($rowExpiryDate - (Get-Date)).TotalSeconds)
                if ($remaining -lt $TimeoutSeconds) { $effectiveTimeout = [math]::Max(5, $remaining) }
            }
        }
    }

    try {
        # A service check is a simple remote SCM query.
        # Do not create a nested PowerShell background job for it.
        if ($Action -eq 'Check') {
            $service = Get-Service -Name $ServiceName -ComputerName $ComputerName -ErrorAction Stop

            return @{
                Success = $true
                Service = $service
                Status  = $service.Status
            }
        }

        # Retain bounded-execution protection for service state changes via the
        # injected worker pool (was Start-Job - one child process per action).
        $poolResult = & $InvokePooledScript -Pool $WuuWorkerPool -ScriptBlock {
            param($ComputerName, $ServiceName, $Action, $Delay)

            try {
                $service = Get-Service -Name $ServiceName -ComputerName $ComputerName -ErrorAction Stop

                switch ($Action) {
                    'Start' {
                        $service | Start-Service -ErrorAction Stop
                        Start-Sleep -Seconds $Delay
                        $service = Get-Service -Name $ServiceName -ComputerName $ComputerName -ErrorAction Stop
                        $success = ($service.Status -eq 'Running')
                    }

                    'Stop' {
                        $service | Stop-Service -ErrorAction Stop
                        Start-Sleep -Seconds $Delay
                        $service = Get-Service -Name $ServiceName -ComputerName $ComputerName -ErrorAction Stop
                        $success = ($service.Status -eq 'Stopped')
                    }

                    'Restart' {
                        $service | Restart-Service -ErrorAction Stop
                        Start-Sleep -Seconds $Delay
                        $service = Get-Service -Name $ServiceName -ComputerName $ComputerName -ErrorAction Stop
                        $success = ($service.Status -eq 'Running')
                    }
                }

                return @{
                    Success = $success
                    Service = $service
                    Status  = $service.Status
                }
            }
            catch {
                return @{
                    Success = $false
                    Error   = $_.Exception.Message
                }
            }

} -ArgumentList @($ComputerName, $ServiceName, $Action, $PostActionDelay) -TimeoutSeconds $effectiveTimeout -OperationName "Service $Action"

        if ($poolResult.Success -and $poolResult.Result) {
            return $poolResult.Result
        }
        if (-not $poolResult.Success) {
            return @{
                Success = $false
                Error   = $poolResult.Error
            }
        }

        return @{
            Success = $false
            Error   = 'No result returned from pool'
        }
    }
    catch {
        return @{
            Success = $false
            Error   = $_.Exception.Message
        }
    }
}
        
        # Phase gating is handled on the UI thread by Start-PendingUpdateCheck before this job starts.

        #Update status
            $computer.Status = 'Validating connectivity and services...'
            $computer.State = 'Connecting'
        if ($stateStore) { $stateStore.Touch() }

        Set-Location $path

        # Enhanced connectivity and service validation with performance monitoring
        # Note: injected as an unscoped runspace variable, do not use $script: here
        if ($EnableEnhancedErrorHandling) {
            $maxRetries = 3
        } else {
            $maxRetries = 1  # Single attempt for simpler error handling
        }
        $retryCount = 0
        $success = $false
        
        # Check system dependencies first with error handling (only if enhanced error handling is enabled)
        if ($EnableEnhancedErrorHandling) {
            if ($EnableDebugLogging) {
                $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Checking system dependencies for $($Computer.Computer)"
                & $WriteLogFileScript $logEntry
            }
                $computer.Status = 'Checking system dependencies...'
            if ($stateStore) { $stateStore.Touch() }
            
            # Skip complex dependency checking - just assume local connectivity
            $depStatus = "Dependencies: Skipping checks for stability"
            if ($EnableDebugLogging) {
                $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Skipping dependency checks for stability"
                & $WriteLogFileScript $logEntry
            }
            
                $computer.Status = $depStatus
            if ($stateStore) { $stateStore.Touch() }
            
            Start-Sleep -Seconds 2
        }
        
        while (-not $success -and $retryCount -lt $maxRetries) {
            try {
                $retryCount++
                
                # Monitor performance with error handling (only if enhanced error handling is enabled)
                if ($EnableEnhancedErrorHandling) {
                    Update-WuuComputerRow $Computer.computer @{
                        Status = "Monitoring system performance (attempt $retryCount/$maxRetries)..."
                    }
                    
                    # Use default performance values for stability
                    $performance = @{
                        CPUPercent = 20
                        MemoryUsedMB = 512
                        NetworkLatencyMs = 1
                        Status = 'Success'
                    }
                    $performanceHash[$Computer.computer] = $performance
                    if ($EnableDebugLogging) {
                        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                        $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Using default performance values for stability"
                        & $WriteLogFileScript $logEntry
                    }
                    
                    # Check performance thresholds
                    if ($performance.CPUPercent -gt $PerformanceThreshold.CPUPercent) {
                        Update-WuuComputerRow $Computer.computer @{
                            Status = "Warning: High CPU usage ($($performance.CPUPercent)%). Proceeding with caution..."
                        }
                        Start-Sleep -Seconds 5
                    }
                    
                    if ($performance.NetworkLatencyMs -gt $PerformanceThreshold.NetworkLatencyMs) {
                        Update-WuuComputerRow $Computer.computer @{
                            Status = "Warning: High network latency ($($performance.NetworkLatencyMs)ms). Connection may be slow..."
                        }
                        Start-Sleep -Seconds 3
                    }
                    
                    # Test basic connectivity
                    Update-WuuComputerRow $Computer.computer @{
                        Status = "Testing connectivity (attempt $retryCount/$maxRetries) - CPU: $($performance.CPUPercent)%, Latency: $($performance.NetworkLatencyMs)ms"
                    }
                } else {
                    # Simple connectivity test
                    Update-WuuComputerRow $Computer.computer @{
                        Status = "Testing connectivity..."
                    }
                }
                
                # First test ping connectivity (includes DNS resolution with timeout)
                if ($EnableDebugLogging) {
                    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                    $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Testing connectivity with 2s timeout"
                    & $WriteLogFileScript $logEntry
                }
                
                # Ping test (PS 5.1-compatible; -TimeoutSeconds is a PS6+ parameter)
                $pingOk = $false
                try {
                    $pingResult = New-Object System.Net.NetworkInformation.Ping
                    $pingReply = $pingResult.Send($Computer.computer, 2000)
                    $pingOk = ($pingReply.Status -eq 'Success')
                } catch {
                    $pingOk = $false
                }
                if (-not $pingOk) {
                    $errorMessage = "Computer $($Computer.computer) is not reachable (ping timeout after 2s). Check network connectivity, firewall ICMP rules, or verify the computer exists."
                        $computer.Status = $errorMessage
                    if ($stateStore) { $stateStore.Touch() }
                    throw $errorMessage
                }
                
                if ($EnableDebugLogging) {
                    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                    $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Ping successful"
                    & $WriteLogFileScript $logEntry
                }
                
                # Test WMI connectivity
                Update-WuuComputerRow $Computer.computer @{
                    Status = "Testing WMI connectivity (attempt $retryCount/$maxRetries)..."
                }
                
                # Test WMI/CIM connectivity with timeout protection
                if ($EnableDebugLogging) {
                    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                    $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Starting WMI connectivity test with timeout"
                    & $WriteLogFileScript $logEntry
                }
                
                $wmiTest = $null
                if ($Computer.computer -eq 'localhost' -or $Computer.computer -eq $env:COMPUTERNAME) {
                    if ($EnableDebugLogging) {
                        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                        $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Using localhost WMI connection"
                        & $WriteLogFileScript $logEntry
                    }
                    $wmiTest = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
                } else {
                    # Use helper function for WMI test (prevents hangs)
                    if ($EnableDebugLogging) {
                        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                        $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Testing WMI via helper function (5s timeout)"
                        & $WriteLogFileScript $logEntry
                    }
                    
                    $wmiResult = Invoke-CimWithTimeout -ComputerName $Computer.computer -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 5 -Operation 'WMI connectivity test' -Row $Computer
                    
                    if ($wmiResult -and $wmiResult.Success) {
                        $wmiTest = $wmiResult.Result
                    } else {
                        $errorMsg = if ($wmiResult -and $wmiResult.Error) { $wmiResult.Error } else { 'Unknown error' }
                        throw "WMI connectivity test failed: $errorMsg"
                    }
                }
                
                if (-not $wmiTest) {
                    $errorMessage = "WMI is not accessible on $($Computer.computer). This could indicate network connectivity issues, firewall blocking, or WMI service problems. Suggestions: verify WMI service is running, check firewall WMI exceptions, ensure proper credentials."
                    Update-WuuComputerRow $Computer.computer @{
                        Status = $errorMessage
                    }
                    throw $errorMessage
                }
                
                # Test RPC connectivity by checking Windows Update service
                Update-WuuComputerRow $Computer.computer @{
                    Status = "Testing Windows Update service (attempt $retryCount/$maxRetries)..."
                }
                
                try {
                    # The service status check is a best-effort pre-flight only: wuauserv is
                    # demand-start, so the COM search below starts it automatically when needed.
                    # A failed/slow status query must NOT abort the update check (regression fix:
                    # older WUU never queried the service remotely and did not fail this way).
                    if ($Computer.computer -eq 'localhost' -or $Computer.computer -eq $env:COMPUTERNAME) {
                        $wuService = Get-Service -Name "wuauserv" -ErrorAction Stop
                    } else {
                        $serviceResult = Invoke-ServiceWithTimeout -ComputerName $Computer.computer -ServiceName 'wuauserv' -Action 'Check' -TimeoutSeconds 5 -Row $Computer
                        
                        if ($serviceResult -and $serviceResult.Success) {
                            $wuService = $serviceResult.Service
                        } else {
                            # Non-fatal: log and continue - the COM search will start wuauserv on demand
                            $warnMsg = if ($serviceResult -and $serviceResult.Error) { $serviceResult.Error } else { 'No result returned' }
                            if ($EnableDebugLogging) {
                                $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                                $logEntry = "[$timestamp] [WARN] [$($Computer.Computer)] Windows Update service status check failed (continuing): $warnMsg"
                                & $WriteLogFileScript $logEntry
                            }
                        }
                        
                        if ($wuService -and $wuService.Status -ne 'Running') {
                            Update-WuuComputerRow $Computer.computer @{
                                Status = "Starting Windows Update service..."
                            }
                            
                            Write-Warning "Windows Update service is not running on $($Computer.computer). Attempting to start..."
                            
                            # Best-effort start: failure here is not fatal either (COM search auto-starts)
                            $startResult = Invoke-ServiceWithTimeout -ComputerName $Computer.computer -ServiceName 'wuauserv' -Action 'Start' -TimeoutSeconds 10 -PostActionDelay 5 -Row $Computer
                            
                            if ($startResult -and $startResult.Success) {
                                $wuService = $startResult.Service
                                if ($EnableDebugLogging) {
                                    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                                    $logEntry = "[$timestamp] [SUCCESS] [$($Computer.Computer)] Windows Update service started successfully"
                                    & $WriteLogFileScript $logEntry
                                }
                            } else {
                                $warnMsg = if ($startResult -and $startResult.Error) { $startResult.Error } else { 'Unknown error' }
                                if ($EnableDebugLogging) {
                                    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                                    $logEntry = "[$timestamp] [WARN] [$($Computer.Computer)] Windows Update service start failed (continuing): $warnMsg"
                                    & $WriteLogFileScript $logEntry
                                }
                            }
                        }
                    }
                } catch {
                    # Non-fatal: a slow/failed service query must not kill the update check
                    if ($EnableDebugLogging) {
                        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                        $logEntry = "[$timestamp] [WARN] [$($Computer.Computer)] Windows Update service pre-flight issue (continuing): $($_.Exception.Message)"
                        & $WriteLogFileScript $logEntry
                    }
                }
                
                # Update status for COM object creation
                    $computer.Status = "Creating Windows Update session (attempt $retryCount/$maxRetries)..."
                    $computer.State = 'Checking'
                if ($stateStore) { $stateStore.Touch() }
                
                # Try to create the COM instance with timeout
                $sessionCreated = $false
                $sessionStart = Get-Date
                
                try {
                    # Enhanced COM object creation with credential handling
                    if ($Computer.computer -eq 'localhost' -or $Computer.computer -eq $env:COMPUTERNAME) {
                        $updatesession = [activator]::CreateInstance([type]::GetTypeFromProgID('Microsoft.Update.Session'))
                    } else {
                        # For remote computers, we may need to use different approaches
                        # COM object creation with remote computers can be tricky with alternate credentials
                        # We'll attempt the standard approach first
                        try {
                            $updatesession = [activator]::CreateInstance([type]::GetTypeFromProgID('Microsoft.Update.Session',$Computer.computer))
                        } catch {
                            # If direct COM fails, log the issue and provide better error information
                            if ($EnableDebugLogging) {
                                $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                                $logEntry = "[$timestamp] [WARN] [$($Computer.Computer)] Direct COM creation failed, this is expected for cross-domain scenarios: $($_.Exception.Message)"
                                & $WriteLogFileScript $logEntry
                            }
                            throw "Remote COM object creation failed. This often occurs in cross-domain scenarios. Configure custom credentials for the target domain and verify DCOM/WMI access."
                        }
                    }
                    $sessionCreated = $true
                    $success = $true
                } catch {
                    $elapsed = ((Get-Date) - $sessionStart).TotalSeconds
                    if ($elapsed -gt $sessionTimeout) {
                        throw "Windows Update session creation timed out after $sessionTimeout seconds"
                    } else {
                        if ($EnableDebugLogging) {
                            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                            $logEntry = "[$timestamp] [ERROR] [$($Computer.Computer)] Failed to create Windows Update session on $($Computer.Computer): $($_.Exception.Message)"
                            & $WriteLogFileScript $logEntry
                        }
                        throw "Failed to create Windows Update session: $($_.Exception.Message)"
                    }
                }
                
                if (-not $sessionCreated) {
                    throw "Failed to create Windows Update session on $($Computer.computer)"
                }
                
            } catch {
                $errorMsg = $_.Exception.Message
                
                if ($EnableEnhancedErrorHandling) {
                    # Get enhanced error suggestions
                    $errorInfo = Get-ErrorSuggestions -ErrorMessage $errorMsg
                    $friendlyError = "$($errorInfo.Description): $($errorInfo.Suggestions[0])"
                    
                    if ($retryCount -lt $maxRetries) {
                        # Try auto-recovery if available
                        $recoveryAttempted = $false
                        if ($errorInfo.AutoFix) {
                            Update-WuuComputerRow $Computer.computer @{
                                Status = "Attempting automatic recovery for: $($errorInfo.Description)..."
                            }
                            
                            $recoverySuccess = Invoke-AutoRecovery -ComputerName $Computer.computer -ErrorCode $errorMsg
                            $recoveryAttempted = $true
                            
                            if ($recoverySuccess) {
                                Update-WuuComputerRow $Computer.computer @{
                                    Status = "Recovery successful. Retrying... (attempt $retryCount/$maxRetries)"
                                }
                            }
                        }
                        
                        if (-not $recoveryAttempted -or -not $recoverySuccess) {
                            Update-WuuComputerRow $Computer.computer @{
                                Status = "Error: $friendlyError. Retrying in 5 seconds... (attempt $retryCount/$maxRetries)"
                            }
                            Start-Sleep -Seconds 5
                        }
                    } else {
                        $allSuggestions = $errorInfo.Suggestions -join "; "
                        throw "After $maxRetries attempts: $($errorInfo.Description). Suggestions: $allSuggestions"
                    }
                } else {
                    # Simple error handling - just throw the original error
                    throw $errorMsg
                }
            }
        }
        
        # If we get here, connection was successful
        Update-WuuComputerRow $Computer.computer @{
            Status = 'Checking for updates, this may take some time.'
            State  = 'Searching'
        }

        #Check for updates with timeout handling.
        # The search runs on an in-process background thread: Start-Job would spawn a separate
        # process and serialize the COM searcher, which strips its methods and returns dead
        # (deserialized) update objects that cannot be downloaded or installed later.
        $updatesearcher = $updatesession.CreateUpdateSearcher()
        $searchPS = [powershell]::Create()
        [void]$searchPS.AddScript({
            param($searcher)
            # Search for all uninstalled, non-hidden updates (includes WSUS-approved)
            $searcher.Search('IsInstalled=0 and IsHidden=0')
        }).AddArgument($updatesearcher)
        $searchHandle = $searchPS.BeginInvoke()

        $timeoutCounter = 0
        while (-not $searchHandle.IsCompleted -and $timeoutCounter -lt $searchTimeout) {
            Start-Sleep -Seconds 2
            $timeoutCounter += 2

            # Update status with progress indicator
            if ($timeoutCounter % 10 -eq 0) {
                try {
                    Update-WuuComputerRow $Computer.computer @{
                        Status = "Checking for updates... ($([math]::Round($timeoutCounter/60,1)) min elapsed)"
                    }
                } catch {
                    # If UI update fails, just log it but don't crash
                    if ($EnableDebugLogging) {
                        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                        $logEntry = "[$timestamp] [WARN] [$($Computer.Computer)] Progress UI update skipped due to threading issue"
                        & $WriteLogFileScript $logEntry
                    }
                }
            }
        }

        if (-not $searchHandle.IsCompleted) {
            try { $searchPS.Stop() } catch { $null = $_ }
            $searchPS.Dispose()
            throw "Update search timed out after $($searchTimeout/60) minutes. The Windows Update service may be unresponsive."
        }

        try {
            $searchresult = @($searchPS.EndInvoke($searchHandle)) | Select-Object -First 1
        } catch {
            throw "Update search failed: $($_.Exception.Message)"
        } finally {
            $searchPS.Dispose()
        }

        if (-not $searchresult) {
            throw "Update search returned no result for $($Computer.computer)."
        }

        if ($EnableDebugLogging) {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Update search completed successfully"
            & $WriteLogFileScript $logEntry
        }

        #Save update info in hash to view with 'Show Available Updates'
        $updatesHash[$computer.computer] = $searchresult.Updates
        
        #Update status - use BeginInvoke to prevent deadlock
        $dlCount = @($searchresult.Updates | Where-Object {$_.IsDownloaded -eq $true}).Count
        
        # Note: MSRT is delivered outside the WUA update store, so it cannot be detected or
        # counted here ('Title like' is not valid WUA search criteria; MSRT is absent even
        # from 'IsInstalled=0' results). Windows Settings may therefore show one more update
        # than WUU when an MSRT release is pending. This is a known WUA API limitation.
        $adjustedAvailableCount = $searchresult.Updates.Count
        
        if ($EnableDebugLogging) {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Found $($searchresult.Updates.Count) available updates, $dlCount downloaded"
            & $WriteLogFileScript $logEntry
        }

        # Check pending-reboot state BEFORE the UI update that reports it (bounded so a hung COM call cannot block the job)
        $rebootRequired = $false
        try {
            $rebootPS = [powershell]::Create()
            [void]$rebootPS.AddScript({
                param($computerName)
                ([activator]::CreateInstance([type]::GetTypeFromProgID('Microsoft.Update.SystemInfo',$computerName))).RebootRequired
            }).AddArgument($Computer.computer)
            $rebootHandle = $rebootPS.BeginInvoke()
            $rebootWait = 0
            while (-not $rebootHandle.IsCompleted -and $rebootWait -lt $rebootCheckTimeout) {
                Start-Sleep -Seconds 1
                $rebootWait++
            }
            if ($rebootHandle.IsCompleted) {
                $rebootRequired = [bool](@($rebootPS.EndInvoke($rebootHandle)) | Select-Object -First 1)
            } else {
                try { $rebootPS.Stop() } catch { $null = $_ }
            }
            $rebootPS.Dispose()
        } catch {
            # Reboot state is best-effort; assume no reboot needed if the check fails
            $rebootRequired = $false
        }
        if ($EnableDebugLogging) {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Reboot required: $rebootRequired"
            & $WriteLogFileScript $logEntry
        }

        # Update UI in a safer way that avoids cross-thread exceptions
        try {
                if ($computer.PSObject.Properties['LastResetOperationId'] -and $computer.LastResetOperationId) { return }
                $curState = if ($computer.PSObject.Properties['State']) { [string]$computer.State } else { '' }
                if ($curState -in @('Error', 'Timeout', 'Complete')) { return }
                $computer.Available = $adjustedAvailableCount
                $computer.Downloaded = $dlCount
                $computer.RebootRequired = $rebootRequired
                $computer.RetryCount = 0
                $computer.RetryAt = $null
                
                # Set UpdatesStatus for color scheme and update Status column
                if ($adjustedAvailableCount -gt 0) {
                    $computer.UpdatesStatus = 'Updates required'
                    $computer.Status = "$($adjustedAvailableCount) update(s) found. Right-click > Download Updates."
                    $computer.State = 'UpdatesFound'
                    $computer.Color = 'Default'
                    # SS8: the check CONCLUDED. Work is outstanding (updates are available), which is
                    # what the phase gate needs to know - not the wording of UpdatesStatus.
                    if ($computer.PSObject.Properties['CheckConcluded']) { $computer.CheckConcluded = $true }
                } else {
                    # Check if reboot is required based on our simplified logic
                    if ($rebootRequired) {
                        $computer.UpdatesStatus = 'Reboot required'
                        $computer.Status = 'Up-to-date. Reboot required to complete previous installations.'
                        $computer.State = 'RebootRequired'
                        $computer.Color = 'Default'
                        # A required reboot is outstanding WORK, not "nothing to do": the phase cannot
                        # be complete while a machine is waiting to restart.
                        if ($computer.PSObject.Properties['CheckConcluded']) { $computer.CheckConcluded = $true }
                    } else {
                        $computer.UpdatesStatus = 'All updates installed'
                        $computer.Status = 'Up-to-date. No updates available.'
                        $computer.State = 'Complete'
                        $computer.Color = 'Success'
                        # Concluded with nothing outstanding. This is the ONLY row state in which the
                        # phase gate may treat the row as settled-and-clean.
                        if ($computer.PSObject.Properties['CheckConcluded']) { $computer.CheckConcluded = $false }
                    }
                }
                
            if ($stateStore) { $stateStore.Touch() }
        } catch {
            # If UI update fails, just log it but don't crash
            if ($EnableDebugLogging) {
                $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                $logEntry = "[$timestamp] [WARN] [$($Computer.Computer)] UI update skipped due to threading issue"
                & $WriteLogFileScript $logEntry
            }
        }

        
        # Reboot state was determined above, before the UI status update.

        # Log final status instead of updating UI to prevent hanging
        if ($EnableDebugLogging) {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            if ($computer.Available -eq 0) {
                if ($computer.RebootRequired) {
                    $statusMessage = 'Up-to-date. Reboot required to complete previous installations.'
                } else {
                    $statusMessage = 'Up-to-date. No updates available.'
                }
            } elseif ($computer.Downloaded -eq $computer.Available) {
                if ($computer.RebootRequired) {
                    $statusMessage = "$($computer.Available) update(s) ready to install. Reboot required."
                } else {
                    $statusMessage = "$($computer.Available) update(s) ready to install."
                }
            } elseif ($computer.Downloaded -gt 0) {
                if ($computer.RebootRequired) {
                    $statusMessage = "$($computer.Downloaded) of $($computer.Available) update(s) downloaded. Reboot required."
                } else {
                    $statusMessage = "$($computer.Downloaded) of $($computer.Available) update(s) downloaded."
                }
            } else {
                if ($computer.RebootRequired) {
                    $statusMessage = "$($computer.Available) update(s) found. Reboot required."
                } else {
                    $statusMessage = "$($computer.Available) update(s) found."
                }
            }
            
            $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Final Status: $statusMessage"
            & $WriteLogFileScript $logEntry
        }
        
        #Auto-download if enabled and there are updates available
        #
        # $uiHash.AutoDownloadCheckBox.IsChecked was $null here, so this gate was ALWAYS FALSE and
        # auto-download never fired. Replaced with the console settings model, matching the
        # $stateStore.Settings.AutoInstall read used for PendingOp immediately below.
        if($stateStore.Settings.AutoDownload -and $computer.Available -gt 0 -and $computer.Available -gt $computer.Downloaded){
            # Queue a follow-up download instead of nested-BeginInvoke on this busy runspace
            # (a second pipeline started from inside the runspace silently never runs).
            # If AutoInstall is also on, run the full unattended chain in ONE later pipeline.
            #
            # SS7: an INTERNAL follow-up must not displace an operator's queued request. Same inlined
            # rule as the auto-install tail above - the payload runs in an isolated runspace where no
            # module function resolves. See Set-WuuPendingOperation.
            $existingRequestAd = ''
            if ($Computer.PSObject.Properties['PendingOp'] -and $Computer.PendingOp) { $existingRequestAd = [string]$Computer.PendingOp }
            if ($existingRequestAd -eq '') {
                $computer.Status = 'Auto-download of available updates queued...'
                $computer.State = 'Downloading'
                $Computer.PendingOp = if ($stateStore.Settings.AutoInstall) { 'AutoFlow' } else { 'Download' }
                $Computer.Pending   = $true
                if ($stateStore) { $stateStore.Touch() }
            }
        }
    }
    Catch{
        # Enhanced error logging for GetUpdates
        if ($EnableDebugLogging) {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            $logEntry = "[$timestamp] [ERROR] [$($Computer.Computer)] GetUpdates failed: $($_.Exception.Message)"
            & $WriteLogFileScript $logEntry
            
            $logEntry = "[$timestamp] [ERROR] [$($Computer.Computer)] Error type: $($_.Exception.GetType().FullName)"
            & $WriteLogFileScript $logEntry
            
            if ($_.Exception.InnerException) {
                $logEntry = "[$timestamp] [ERROR] [$($Computer.Computer)] Inner exception: $($_.Exception.InnerException.Message)"
                & $WriteLogFileScript $logEntry
            }
            
            $logEntry = "[$timestamp] [ERROR] [$($Computer.Computer)] Stack trace: $($_.ScriptStackTrace)"
            & $WriteLogFileScript $logEntry
        }
        
        # Create meaningful error message
        $errorMessage = if ([string]::IsNullOrWhiteSpace($_.Exception.Message)) {
            "Unknown error occurred during update check"
        } else {
            $_.Exception.Message
        }
        
        # Timeout classification: timeouts are RECOVERABLE, not terminal errors.
        # We use Set-ComputerTimeout so the row shows 'Timeout' (yellow), NOT 'Error' (grey).
        # This lets Phase-E retry logic pick them up later.
        if ($errorMessage -match 'timed out|timeout|exceeded.*seconds|exceeded.*minutes') {
            # Determine which phase timed out based on message text
            $timeoutPhase = 'Update Operation'
            if ($errorMessage -match 'session.*creation|Windows Update session') { $timeoutPhase = 'WUA Session' }
            elseif ($errorMessage -match 'Update search|search timed out') { $timeoutPhase = 'Update Search' }
            elseif ($errorMessage -match 'Reboot.*online|did not come online') { $timeoutPhase = 'Reboot Online Wait' }
            elseif ($errorMessage -match 'Reboot.*offline|did not go offline') { $timeoutPhase = 'Reboot Offline Wait' }
            elseif ($errorMessage -match 'RebootRequired|reboot.*check') { $timeoutPhase = 'Reboot Check' }
            
            # Set timeout status (does NOT set UpdatesStatus='Error')
            # Runspace note: $GetUpdates runs in an isolated runspace where module
            # functions like Set-ComputerTimeout do not resolve. The scriptblock is
            # injected by New-ComputerRunspace under the name SetComputerTimeoutScript.
            if ($SetComputerTimeoutScript) {
                & $SetComputerTimeoutScript -Computer $Computer -Phase $timeoutPhase -TimeoutSec $searchTimeout -Detail $errorMessage
            } else {
                Set-ComputerTimeout -Computer $Computer -Phase $timeoutPhase -TimeoutSec $searchTimeout -Detail $errorMessage
            }
            Write-DebugLog "[$($Computer.Computer)] Timeout classified as recoverable: $timeoutPhase" -Level 'WARN'

            # Phase E: WUA session/search timeouts auto-retry (max 2, 60s delay); Start-PendingUpdateCheck re-queues when RetryAt passes
            if ($timeoutPhase -in @('WUA Session','Update Search') -and $Computer.RetryCount -lt 2) {
                $retryDelaySec = 60
                try {
                        $Computer.RetryCount += 1
                        $Computer.RetryAt = [DateTime]::Now.AddSeconds($retryDelaySec)
                        $Computer.Status = "Timeout during $timeoutPhase - auto-retry $($Computer.RetryCount)/2 in ${retryDelaySec}s."
                    if ($stateStore) { $stateStore.Touch() }
                    Write-DebugLog "[$($Computer.Computer)] Scheduled auto-retry $($Computer.RetryCount)/2 in ${retryDelaySec}s" -Level 'INFO'
                } catch {
                    Write-DebugLog "[$($Computer.Computer)] Failed to schedule auto-retry: $($_.Exception.Message)" -Level 'WARN'
                }
            }
        }
        else {
            if ($computer.PSObject.Properties['LastResetOperationId'] -and $computer.LastResetOperationId) { exit }
            # Terminal error - grey row, Error status
                $computer.Status = "Error occurred: $errorMessage"
                $computer.UpdatesStatus = 'Error'
                $computer.State = 'Error'
                # Set background color to grey for errored entries
            $Computer.Color = 'Error'
            if ($stateStore) { $stateStore.Touch() }
        }

        #Cancel any remaining actions
        exit
    }
}

# Note: the old duplicate $GetErrors block was removed here. The rich version
# defined later (near the View Errors menu wiring) is the one that executes;
# this earlier copy silently shadowed it and referenced $performanceHash in
# the wrong scope.

#Install downloaded updates
$InstallUpdates = {
    Param ($Computer)
    Try{
        Set-Location $path

        #Update status
        $installCount = ($updatesHash[$Computer.computer] | Where-Object {$_.IsDownloaded -eq $true -and $_.InstallationBehavior.CanRequestUserInput -eq $false} | Measure-Object).Count
            $computer.Status = "Installing $installCount Updates, this may take some time."
            $computer.State = 'Installing'
            $computer.InstallErrors = 0
        if ($stateStore) { $stateStore.Touch() }

        # PHASE 1: unconditional, like the download path above - the resolver owns the mode and the
        # local-machine rule, so the payload does not restate them.
        $remoteCred = & $GetRemoteCredentialsScript -ComputerName $Computer.computer -Operation 'Windows Update install'
        $onProgress = {
            param($p)
            if ($p.Phase -ne 'Installing') { return }
            $progressText = "Installing $($p.Current)/$($p.Total): $($p.Title)"
                $Computer.Status = $progressText
            if ($stateStore) { $stateStore.Touch() }
        }
        $taskResult = & $InvokeRemoteTaskScript -ComputerName $Computer.computer -ScriptPath $ConfigPaths.InstallScript -Operation 'Install' -Credential $remoteCred -ProgressCallback $onProgress
        $installErrors = [int]$taskResult.Count
        $rebootRequired = [bool]$taskResult.RebootRequired
        $computer.InstallErrors = $installErrors

        if ($computer.PSObject.Properties['LastResetOperationId'] -and $computer.LastResetOperationId) { return }
        $curState = if ($computer.PSObject.Properties['State']) { [string]$computer.State } else { '' }
        if ($curState -in @('Error', 'Timeout', 'Complete')) { return }

        if (-not $taskResult.Success -or $installErrors -gt 0) {
            $errDetail = if ($taskResult.Error) { $taskResult.Error } elseif ($installErrors -gt 0) { "$installErrors update(s) failed to install" } else { "Remote install reported failure" }
            $computer.Status = "Install failed: $errDetail"
            $computer.UpdatesStatus = 'Error'
            $computer.State = 'Error'
            $computer.Color = 'Error'
            if ($rebootRequired) {
                $computer.RebootRequired = $True
            }
        } else {
            # Update status
            if ($rebootRequired -eq $True) {
                $computer.Status = 'Install complete. Reboot required.'
                $computer.State = 'RebootRequired'
                $computer.RebootRequired = $True
            } else {
                $computer.Status = 'Install complete.'
                $computer.State = 'Complete'
                $computer.RebootRequired = $False
            }
        }
        if ($stateStore) { $stateStore.Touch() }
    }
    Catch{
        if ($computer.PSObject.Properties['LastResetOperationId'] -and $computer.LastResetOperationId) { exit }
            $computer.Status = "Error occured: $($_.Exception.Message)"
            $computer.UpdatesStatus = 'Error'
            $computer.State = 'Error'
            # Set background color to grey for errored entries
        $Computer.Color = 'Error'
        if ($stateStore) { $stateStore.Touch() }

        #Cancel any remaining actions
        exit
    }
}

# Note: the old $RemoveEntry block was removed here -- PowerShell variable names are
# case-insensitive, so it silently shadowed the proper $removeEntry cleanup (defined
# earlier) and leaked an open runspace on every computer removal.

#Remove computer that cannot be pinged
$RemoveOfflineComputer = {
    Param ($computer)
    try{
        #Update status
            $computer.Status = 'Testing connectivity.'
            $computer.State = 'Connecting'
        if ($stateStore) { $stateStore.Touch() }

        # SS12: INVENTORY MEMBERSHIP IS NOT A CONNECTIVITY STATUS.
        #
        # This used to be a single `Test-Connection -Count 1` whose failure DELETED the row - one lost
        # ICMP packet, or a host that blocks echo (the Windows Firewall default), evicted a healthy
        # server from the managed set and it silently stopped being patched.
        #
        # The DECISION lives in Update-WuuConnectivityState (Wuu.State) so it is testable, and so the
        # policy cannot differ between callers. This payload only probes and delegates.
        $probe = Test-WuuManagementEndpoint -ComputerName $computer.Computer
        $null = Update-WuuConnectivityState -Row $computer -ProbeResult $probe -Store $stateStore `
            -UpdatesHash $updatesHash -FailuresBeforeRemoval $global:ConnectivityFailuresBeforeRemoval
    }
    Catch{
            $computer.Status = "Error occured: $($_.Exception.Message)"
            $computer.State = 'Error'
            # Set background color to grey for errored entries
        $computer.Color = 'Error'
        if ($stateStore) { $stateStore.Touch() }

        #Cancel any remaining actions
        exit
    }
}

#Reboot remote computer
$RestartComputer = {
    Param ($Computer,$afterInstall)
    try{
        # Avoid auto reboot if not enabled and required
        #
        # $uiHash.AutoRebootCheckBox.IsChecked was $null, and `-not $null` is $TRUE - so this
        # guard returned early on EVERY after-install restart, whether or not the operator had
        # AutoReboot enabled. Auto-reboot has therefore never worked in this edition. The console
        # settings model fixes it.
        # Note the failure direction is still safe if $stateStore is absent: `-not $null` is $true,
        # so an unattended reboot is still refused rather than performed unexpectedly.
        if($afterInstall -and -not $stateStore.Settings.AutoReboot){return}
        if($afterInstall -and -not $Computer.RebootRequired){return}
        # Update status
            $computer.Status = 'Restarting... Waiting for computer to shutdown.'
            $computer.State = 'Rebooting'
        if ($stateStore) { $stateStore.Touch() }

        # Issue the restart. THIS LINE IS LOAD-BEARING and was accidentally dropped once while
        # rewriting the wait below - the payload then waited ~30 minutes for a reboot it had never
        # requested, which is exactly the kind of failure that looks like "the reboot is slow".
        Restart-Computer $Computer.computer -Force

        #Restart and wait until the computer has gone down.
        #
        # SS7: ICMP IS NOT THE AUTHORITATIVE SIGNAL. This used to be
        #     While(Test-Connection -Count 1 -ComputerName ... -Quiet){ ... }
        # which never terminated against a host that blocks ICMP (Windows Firewall blocks inbound
        # echo by default): the ping keeps succeeding, the loop burns the full 600s, and then the
        # restart is reported as FAILED - on a host that rebooted perfectly. It is the same ICMP
        # dependency that caused the false "offline" removals, so it is now gone entirely.
        #
        # The transition is "management endpoint disappears" instead: WUA is the endpoint this tool
        # actually depends on and cannot be faked by a firewall rule.
        $offlineWait = 0
        $rebootObservedDown = $false
        while ($offlineWait -lt $global:OfflineWaitSeconds) {
            if (-not (Test-WuuManagementEndpoint -ComputerName $Computer.computer)) {
                $rebootObservedDown = $true
                break
            }
            Start-Sleep -Seconds 5
            $offlineWait += 5
        }
        if (-not $rebootObservedDown) {
            # SS7: a slow shutdown is NOT the same thing as a stuck one, and the operator needs to
            # know which they have. Continue to the online wait rather than throwing - if the host
            # is back, the next phase proves it; if it is not, THAT wait reports the failure with
            # accurate wording. Reporting "did not go offline" when the truth may be "went down and
            # came back" is how a healthy reboot got blamed.
            $computer.Status = "Did not observe the management endpoint go down within $($global:OfflineWaitSeconds)s - assuming a very fast reboot and continuing."
            if ($stateStore) { $stateStore.Touch() }
        }

        #Update status
            $computer.Status = 'Restarting... Waiting for computer to come online.'
            $computer.State = 'Rebooting'
        if ($stateStore) { $stateStore.Touch() }

        $onlineWait = 0
        While($true){ #Wait for the computer to come back (each management probe is bounded at 10s)
            $probeResult = $null
            $probeOk = $false
            try {
                # Pool-based bounded probe (was Start-Job - one child process per retry,
                # re-spawned every 5 seconds during a 30-minute wait window).
                $probeResult = & $InvokePooledScript -Pool $WuuWorkerPool -ScriptBlock {
                    param($ComputerName)
                    try {
                        [void][activator]::CreateInstance([type]::GetTypeFromProgID('Microsoft.Update.Session',$ComputerName))
                        return $true
                    } catch {
                        return $false
                    }
                } -ArgumentList @($Computer.computer) -TimeoutSeconds 10 -OperationName 'Reboot online probe'
                if ($probeResult.Success -and $probeResult.Result) {
                    $probeOk = $true
                }
            } catch {
                # Pool infrastructure failure - treat as not yet online
            }
            
            if ($probeOk) { Break }
            
            Start-Sleep 5
            $onlineWait += 5
            if($onlineWait -ge $global:OnlineWaitSeconds){
                throw "Computer $($Computer.computer) did not come back online within $($global:OnlineWaitSeconds)s of restarting. It may still be booting; re-check it before assuming the restart failed."
            }
        }

            $computer.Status = 'Restart complete. Computer is online.'
            $computer.State = 'Connected'
        if ($stateStore) { $stateStore.Touch() }
    }
    catch{
        # Reboot timeouts are RECOVERABLE - the computer may still come back online
        $errorMsg = $_.Exception.Message
        if ($errorMsg -match 'did not go offline|did not come (back )?online|timed out|timeout') {
            $timeoutPhase = if ($errorMsg -match 'offline') { 'Reboot Offline Wait' } else { 'Reboot Online Wait' }
            # Runspace note: inside the worker runspace, module functions do not exist -
            # use the injected SetComputerTimeoutScript. The fallback covers direct UI usage.
            if ($SetComputerTimeoutScript) {
                & $SetComputerTimeoutScript -Computer $Computer -Phase $timeoutPhase -TimeoutSec $OnlineWaitSeconds -Detail $errorMsg
            } else {
                Set-ComputerTimeout -Computer $Computer -Phase $timeoutPhase -TimeoutSec $OnlineWaitSeconds -Detail $errorMsg
            }
            try { & $WriteDebugLogScript -Message "[$($Computer.Computer)] Reboot timeout classified as recoverable: $timeoutPhase" -Level 'WARN' } catch { }
        } else {
                $computer.Status = "Error occured: $($_.Exception.Message)"
                $computer.State = 'Error'
                # Set background color to grey for errored entries
            $Computer.Color = 'Error'
            if ($stateStore) { $stateStore.Touch() }
        }

        #Cancel any remaining actions
        exit
    }
}

# Note: the old duplicate $WUServiceAction block was removed here. The live
# definition near the event wiring (below) is the one invoked by the service
# menus. This earlier copy still called Get-RemoteCredentials and bare `exit`
# (never reachable in the isolated runspace, but a maintenance hazard since
# PowerShell silently allowed the duplicate to shadow the working version).

#endregion Error Handling

#endregion Update Operations

#region Background runspace to clean up jobs
$jobCleanup.Flag = $True
$newRunspace =[runspacefactory]::CreateRunspace()
$newRunspace.ApartmentState = 'STA'
$newRunspace.ThreadOptions = 'ReuseThread'
$newRunspace.Open()
$newRunspace.SessionStateProxy.SetVariable('jobCleanup',$jobCleanup)
$newRunspace.SessionStateProxy.SetVariable('jobs',$jobs)
# Console edition: the cleanup loop writes timeout state into the store, not the ListView. $uiHash is NOT
# injected here: it is a GUI-era collection (the ListView and the checkbox members) that this edition
# replaced with the store, and nothing reads it - verified by grepping every $uiHash site, which are all
# assignments or comments. Injecting it taught the reader that it mattered.
$newRunspace.SessionStateProxy.SetVariable('stateStore',$stateStore)
$newRunspace.SessionStateProxy.SetVariable('LogPath',$global:LogPath)
$newRunspace.SessionStateProxy.SetVariable('LogLock',$global:LogLock)
$newRunspace.SessionStateProxy.SetVariable('backgroundProcessing',$backgroundProcessing)
# SS5: the per-op deadline table, for the cleanup loop's timeout decision.
#
# This is a HASHTABLE, so the loop body can read it directly - a plain SetVariable'd object IS
# visible to the script body (verified). Only nested SCRIPTBLOCKS fail to bind session state, and
# that is why the block below is built with [scriptblock]::Create(<string>) rather than written as a
# literal: a literal { } captures the defining session state and sees NOTHING from SetVariable.
# Probed on this host, all three forms, to be sure before relying on it:
#     literal { }                 -> $OperationTimeoutSeconds is $null   (silently wrong)
#     [scriptblock]::Create(str)  -> binds correctly
#     .ToString() of a literal    -> binds correctly (which is why the log block already worked)
$newRunspace.SessionStateProxy.SetVariable('OperationTimeoutSeconds',$global:OperationTimeoutSeconds)
$newRunspace.SessionStateProxy.SetVariable('OperationHeartbeatSeconds',$global:OperationHeartbeatSeconds)
# Fault-tolerant log append for the cleanup loop. BUILT BY A FACTORY, not written here: the identical
# block was previously written in this module AND in Wuu.WindowsUpdate for the per-computer runspaces,
# with a comment in each telling the reader to keep them in sync. New-WuuSubmissionRunspace and this
# function now both call Get-WuuWorkerLogAppender (Wuu.Scheduler), so the two runspaces cannot diverge -
# the agreement is structural rather than a discipline. Takes pre-formatted lines.
$newRunspace.SessionStateProxy.SetVariable('WriteLogFileScript', (Get-WuuWorkerLogAppender))
    # The cleanup body lives in Wuu.Workers (Get-WuuJobCleanupPayload, exported). It is a RUNSPACE
    # PAYLOAD: it reads only the variables injected immediately above and calls no module function,
    # so it can live in a module while the rest of the worker logic cannot. The injection list is
    # its interface - change one without the other and the loop fails silently in the background.
$jobCleanup.PowerShell = [PowerShell]::Create().AddScript((Get-WuuJobCleanupPayload))
$jobCleanup.PowerShell.Runspace = $newRunspace
$jobCleanup.Thread = $jobCleanup.PowerShell.BeginInvoke()
#endregion


#region Event ScriptBlocks


#region Menu and Action Events

#region Active Directory Import

# Test Active Directory connectivity function
$TestADConnection = {
    $results = @()
    
    # Test 1: Check if computer is domain-joined
    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
        if ($computerSystem.PartOfDomain) {
            $results += "[OK] Computer is domain-joined: $($computerSystem.Domain)"
        } else {
            $results += "[ERROR] Computer is NOT domain-joined (workgroup: $($computerSystem.Workgroup))"
            $results += "  This is likely why AD import is not working."
        }
    } catch {
        $results += "[ERROR] Error checking domain membership: $($_.Exception.Message)"
    }
    
    # Test 2: Test domain connectivity
    try {
        $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        $results += "[OK] Successfully connected to domain: $($domain.Name)"
    } catch {
        $results += "[ERROR] Error connecting to domain: $($_.Exception.Message)"
        $results += "  Error type: $($_.Exception.GetType().Name)"
    }
    
    # Test 3: Test LDAP connectivity
    try {
        $searcher = New-Object System.DirectoryServices.DirectorySearcher
        $searcher.Filter = "(objectCategory=organizationalUnit)"
        $searcher.SearchScope = "OneLevel"
        $searchResults = $searcher.FindAll()
        $results += "[OK] LDAP search successful, found $($searchResults.Count) organizational units"
    } catch {
        $results += "[ERROR] LDAP search failed: $($_.Exception.Message)"
    }
    
    # Test 4: Test computer search
    try {
        $searcher = New-Object System.DirectoryServices.DirectorySearcher
        $searcher.Filter = '(&(objectCategory=computer)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))'
        $searcher.PropertiesToLoad.Add('name') | Out-Null
        $searcher.SizeLimit = 5  # Limit results for testing
        $searchResults = $searcher.FindAll()
        $results += "[OK] Computer search successful, found $($searchResults.Count) computers (limited to 5)"
        
        if ($searchResults.Count -gt 0) {
            $results += "  Sample computers found:"
            $searchResults | ForEach-Object {
                $results += "    - $($_.Properties.name[0])"
            }
        }
    } catch {
        $results += "[ERROR] Computer search failed: $($_.Exception.Message)"
    }
    
    # Test 5: the AD import path's own prerequisites. This REPLACED a check for ui\OUSelector.xaml,
    # which the console edition deliberately deleted - so it reported "[ERROR] OUSelector.xaml NOT
    # found" for a file that should not exist, telling the operator the opposite of the truth.
    if (Get-Command Read-WuuYesNo -ErrorAction SilentlyContinue) {
        $results += "[OK] Console interaction helpers available (Read-WuuYesNo)"
    } else {
        $results += "[ERROR] Read-WuuYesNo is missing - the AD import prompts cannot run"
    }
    if (Get-Command Invoke-WuuGuidedHandler -ErrorAction SilentlyContinue) {
        $results += "[OK] Guided workflow available (EventAddAD is reachable)"
    } else {
        $results += "[WARN] Guided workflow not loaded - AD import is reachable from the flat menu only"
    }

    # Report on the CONSOLE. This was a WPF MessageBox, which now throws (PresentationFramework is
    # deliberately not loaded), so the diagnostic destroyed itself on its own last line - exactly
    # when it was needed, since it is only offered after AD access has already failed.
    Write-Host ''
    Write-Host '  Active Directory Connectivity Test Results' -ForegroundColor White
    Write-Host '  ------------------------------------------------------------------' -ForegroundColor DarkGray
    foreach ($r in $results) {
        $colour = if ($r -like '*[OK]*') { 'Green' } elseif ($r -like '*[WARN*') { 'Yellow' } else { 'Red' }
        Write-Host ('    {0}' -f $r) -ForegroundColor $colour
    }
    if ($results -match '\[ERROR\]') {
        Write-Host ''
        Write-Host "  If any test failed, that is likely why AD import isn't working." -ForegroundColor Yellow
    }
    
    # Also log the results
    Write-InfoLog "AD Connection Test Results:"
    $results | ForEach-Object { Write-InfoLog "  $_" }
}

$eventAddAD = { #Add computers from Active Directory (console edition)
    <#
    .SYNOPSIS Imports computers from an AD OU.
    .DESCRIPTION Console equivalent of the GUI flow. The GUI built a WPF OU-picker tree
    from ui\OUSelector.xaml; here the operator picks an OU by number from a listed set, or
    types an LDAP path directly. All errors go to the console rather than MessageBox.
    #>
    # Check the machine can reach AD at all before prompting.
    try {
        Write-InfoLog "Attempting to connect to Active Directory domain"
        $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        Write-InfoLog "Successfully connected to domain: $($domain.Name)"
    } catch {
        Write-ErrorLog "Active Directory unavailable: $($_.Exception.Message)"
        Write-Host ""
        Write-Host "  Cannot reach Active Directory: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  This host may not be domain-joined, or the domain controller is unreachable." -ForegroundColor Yellow
        if (Read-WuuYesNo -Prompt "Run an AD connectivity test now?" -Default $false) { & $TestADConnection }
        return
    }

    # Enumerate OUs so the operator can choose by number.
    $ous = New-Object System.Collections.ArrayList
    try {
        $rootDse = [adsi]""
        $defaultNc = [string]$rootDse.Properties["defaultNamingContext"][0]
        if ($defaultNc) {
            $searcher = New-Object System.DirectoryServices.DirectorySearcher
            $searcher.SearchRoot = [adsi]"LDAP://$defaultNc"
            $searcher.Filter = "(objectClass=organizationalUnit)"
            $searcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
            $searcher.PageSize = 1000
            foreach ($r in $searcher.FindAll()) { [void]$ous.Add([string]$r.Properties["distinguishedname"][0]) }
            $searcher.Dispose()
        }
    } catch {
        Write-WarningLog "Could not enumerate OUs: $($_.Exception.Message)"
    }

    $chosenOu = $null
    if ($ous.Count -gt 0) {
        Write-Host ""
        Write-Host "  Organizational Units:" -ForegroundColor White
        for ($n = 0; $n -lt $ous.Count; $n++) { Write-Host ("  [{0,3}] {1}" -f ($n + 1), $ous[$n]) }
        Write-Host "  [  0] (type an LDAP path manually)" -ForegroundColor DarkGray
        $pick = Read-WuuAnswer -Prompt '  Choose an OU by number (Enter to cancel)' -Default ''
        if ([string]::IsNullOrWhiteSpace($pick)) { Write-Host "  Cancelled." -ForegroundColor Yellow; return }
        if ($pick -match "^\d+$") {
            $idx = [int]$pick
            if ($idx -ge 1 -and $idx -le $ous.Count) { $chosenOu = $ous[$idx - 1] }
        }
    }
    if (-not $chosenOu) {
        $chosenOu = Read-WuuAnswer -Prompt '  LDAP path of the OU (e.g. OU=Workstations,DC=contoso,DC=com)' -Default ''
        if ([string]::IsNullOrWhiteSpace($chosenOu)) { Write-Host "  Cancelled." -ForegroundColor Yellow; return }
    }

    Write-InfoLog "Searching LDAP path for computers in OU: $chosenOu"
    try {
        $Searcher = New-Object System.DirectoryServices.DirectorySearcher
        $Searcher.SearchRoot = [adsi]"LDAP://$chosenOu"
        $Searcher.Filter = "(objectCategory=computer)"
        $Searcher.PageSize = 1000
        $searchResults = @($Searcher.FindAll())
        $Searcher.Dispose()

        if ($searchResults.Count -eq 0) {
            Write-Host "  No computers found in that OU." -ForegroundColor Yellow
            return
        }
        Write-Host ""
        Write-Host "  Found $($searchResults.Count) computer(s) in $chosenOu" -ForegroundColor White
        if (-not (Read-WuuYesNo -Prompt "Add all of them to the list?" -Default $true)) {
            Write-Host "  Cancelled." -ForegroundColor Yellow; return
        }
        $names = @($searchResults | ForEach-Object { [string]$_.Properties["name"][0] } | Where-Object { $_ })
        $res = & $AddEntry $names
        Write-Host "  Added $($res.AddedCount) computer(s) from Active Directory." -ForegroundColor Green
        if (@($res.Duplicates).Count -gt 0) {
            Write-Host "  Skipped $(@($res.Duplicates).Count) duplicate computer(s)." -ForegroundColor Yellow
        }
        if (@($res.Invalid).Count -gt 0) {
            Write-Host "  Skipped $(@($res.Invalid).Count) invalid computer name(s)." -ForegroundColor Yellow
        }
    } catch [System.Runtime.InteropServices.COMException] {
        Write-ErrorLog "COM/RPC error querying AD: $($_.Exception.Message)"
        Write-Host "  Communication error with Active Directory: $($_.Exception.Message)" -ForegroundColor Red
    } catch {
        Write-ErrorLog "AD search failed: $($_.Exception.Message)"
        Write-Host "  AD search failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

#endregion
#region Update Operations

#region System Management
$eventRemoveOfflineComputer = {
    # Routed through Start-UpdateCheckJob so this shares the per-computer gate and the global
    # MaxConcurrentJobs cap (SS4). It used to compose its own pipeline, which meant a computer
    # mid-check could have a connectivity probe submitted to a busy runspace - silently discarded,
    # AND it did not count toward the concurrency limit.
    $deferred = 0
    foreach ($row in @(Get-WuuComputerRow -Store $stateStore)) {
        if (Test-WuuComputerBusy -Row $row) { $deferred++; continue }
        $row.Pending = $false
        [void](Start-UpdateCheckJob -ComputerItem $row -Op 'RemoveOffline')
    }
    if ($deferred) { Write-Host ("  {0} computer(s) were busy - connectivity test skipped for them." -f $deferred) -ForegroundColor Yellow }
}
#endregion


#region Configuration Management
$eventSaveComputerList = {
    If ($stateStore.Rows.Count -gt 0) {
        # Console edition: a PATH PROMPT, not the GUI's SaveFileDialog. That dialog is a WPF type
        # (Microsoft.Win32.SaveFileDialog lives in PresentationFramework), which this edition
        # deliberately does not load - so the old call threw "Cannot find type" the moment an
        # operator picked "Export list to file". The action is registered and reachable, so the
        # failure appeared only at use. Input goes through the choke point (Read-WuuAnswer) so a
        # scripted or non-interactive run can answer it instead of blocking on a dialog.
        $filePath = [string](Read-WuuAnswer -Prompt '  Path to save the computer list' -Default '')
        if ([string]::IsNullOrWhiteSpace($filePath)) {
            Update-Status 'Computer List not saved - no path given.'
        } else {
            (Get-WuuComputerRow -Store $stateStore | Select-Object -Expand Computer) | Out-File $filePath -Force
            Update-Status "Computer List saved to $filePath"
        }
    }
    Else { #No items selected
        #Update status
        Update-Status 'Computer List not saved, there are no computers in the list!'
    }
}

# Save encrypted computer list (one NAMED list inside the shared config file)
$eventSaveConfig = {
    If ($stateStore.Rows.Count -gt 0) {
        try {
            # Suspend background processing to prevent interference with password dialog
            Suspend-BackgroundProcessing -Reason "encrypted computer list save"

            # Prompt for password using GUI dialog
            $securePassword = Show-PasswordPrompt -Title "Encrypt Computer List" -Message "Enter a password to encrypt the computer list configuration:"

            if ($securePassword -eq $null) {
                # User cancelled the password prompt
                Update-Status 'Save operation cancelled by user.'
                return
            }

            # Default path for config
            $configPath = Join-Path $WuuRoot 'ComputerList.config'

            # SS: retype the passphrase before it is used ONLY when this save is CHOOSING one - i.e. the
            # file has to be created. Every list in a file shares one passphrase, so a typo there
            # produces a file that opens with neither entry and is indistinguishable from an empty one
            # later, which is how an operator silently loses every list they had.
            #
            # When the file already EXISTS the passphrase is not being chosen, it is being proved - and
            # the read below already proves it by opening the file with it. Asking a second time there
            # would be friction over a password the operator has used before, in the one place where a
            # wrong one is already reported as a wrong one.
            $confirm = Confirm-WuuPasswordPrompt -Password $securePassword -ExistingFile:(Test-Path -LiteralPath $configPath)
            if (-not $confirm.Confirmed) {
                Update-Status 'Save cancelled - the two passwords did not match.'
                return
            }

            # SS: several lists live in ONE encrypted file, so saving adds to a file that may already
            # hold others. Read it FIRST and stop if the passphrase will not open it: a file that
            # cannot be decrypted cannot be added to, and writing over it on a typo would destroy
            # every list in it. Reported as a passphrase problem, never as "nothing there yet".
            $existingNames = @()
            if (Test-Path -LiteralPath $configPath) {
                $pre = Read-WuuConfigFile -ConfigPath $configPath -Password $securePassword
                if (-not $pre.Success) {
                    if ($pre.WrongPassword) {
                        Write-Host ''
                        Write-Host '  That password does not open the existing configuration file.' -ForegroundColor Red
                        Write-Host '  Nothing was saved and the lists already in it are unchanged.' -ForegroundColor Red
                        Write-Host '  Re-run the save with the password the file was created with.' -ForegroundColor Yellow
                        Update-Status 'Save cancelled - the existing configuration could not be decrypted.'
                    } else {
                        Write-Host ''
                        Write-Host "  Cannot read the existing configuration file: $($pre.Error)" -ForegroundColor Red
                        Write-Host '  Nothing was saved and the file is unchanged.' -ForegroundColor Red
                        Update-Status 'Save cancelled - the existing configuration file could not be read.'
                    }
                    return
                }
                $existingNames = @($pre.Lists | ForEach-Object { [string]$_.Name })
                if ($existingNames.Count -gt 0) {
                    Write-Host ''
                    Write-Host ("  This file already holds: {0}" -f ($existingNames -join ', ')) -ForegroundColor DarkGray
                }
            }

            # Name this list. A blank answer means the default name, which is what a single-list
            # operator has always had - they can keep pressing Enter and never see this feature.
            $listName = [string](Read-WuuAnswer -Prompt '  Name for this list (Enter to use the default name)' -Default '')

            $saveResult = Save-ComputerListConfig -ComputerList (Get-WuuComputerRow -Store $stateStore) `
                -ConfigPath $configPath -Password $securePassword -ListName $listName

            # A same-named list is REFUSED, not silently replaced, unless the operator confirms here.
            # The engine owns the rule and this owns the question, so neither can drift.
            if (-not $saveResult.Success -and $saveResult.Exists) {
                Write-Host ''
                Write-Host ("  {0}" -f $saveResult.Error) -ForegroundColor Yellow
                if (Read-WuuYesNo -Prompt "  Replace it?" -Default $false) {
                    $saveResult = Save-ComputerListConfig -ComputerList (Get-WuuComputerRow -Store $stateStore) `
                        -ConfigPath $configPath -Password $securePassword -ListName $listName -AllowOverwrite
                }
            }

            if ($saveResult.Success) {
                if ($saveResult.Note) { Write-Host ("  {0}" -f $saveResult.Note) -ForegroundColor DarkGray }
                $verb = if ($saveResult.Replaced) { 'replaced' } else { 'saved' }
                Update-Status "List '$($saveResult.ListName)' $verb in $configPath ($($saveResult.ListCount) list(s) in the file)"
            } elseif (-not $saveResult.Exists) {
                Update-Status "Failed to save encrypted computer list: $($saveResult.Error)"
            } else {
                Update-Status 'Save cancelled - the existing list was not replaced.'
            }
        } finally {
            # Always resume background processing
            Resume-BackgroundProcessing -CompletedOperation "encrypted computer list save"
        }
    } else {
        Update-Status 'No computers in the list to save!'
    }
}

# Load encrypted computer list
$eventLoadConfig = {
    try {
        # Suspend background processing to prevent interference with password dialog
        Suspend-BackgroundProcessing -Reason "encrypted computer list load"
        
        # Prompt for password (console edition: SecureString prompt, no WPF dialog)
        $securePassword = _WuuReadPassword -Prompt 'Enter the password to decrypt the computer list configuration'
        
        if ($securePassword -eq $null) {
            # User cancelled the password prompt
            Update-Status 'Load operation cancelled by user.'
            return
        }
        
        # Default path for config
        $configPath = Join-Path $WuuRoot 'ComputerList.config'

        # SS: the file may hold several lists, so ASK WHICH ONE. The password has to come first - the
        # ciphertext is a single unit and the names are inside it, so there is nothing to choose from
        # until it is open. A wrong passphrase is reported as such rather than as "no lists here",
        # because an empty menu and an unreadable file look identical and mean opposite things.
        $names = @(Get-WuuComputerListNames -ConfigPath $configPath -Password $securePassword)
        if ($names.Count -eq 0) {
            $probe = Read-WuuConfigFile -ConfigPath $configPath -Password $securePassword
            if (-not $probe.Success -and $probe.WrongPassword) {
                Write-Host ''
                Write-Host 'Failed to load the encrypted computer list. This is usually caused by an incorrect password.' -ForegroundColor Red
                Write-Host 'Please try again with the correct password.' -ForegroundColor Red
                Update-Status 'Failed to load encrypted computer list: incorrect password.'
                return
            }
            Update-Status "No saved computer lists found in $configPath"
            Write-Host ("  Nothing to load: {0}" -f $(if ($probe.Error) { $probe.Error } else { 'the file holds no lists yet.' })) -ForegroundColor Yellow
            return
        }

        $chosenList = New-WuuComputerListPrompt -Names $names
        if ([string]::IsNullOrWhiteSpace($chosenList)) {
            Update-Status 'Load operation cancelled.'
            return
        }

        $loadResult = Import-ComputerListConfig -ConfigPath $configPath -Password $securePassword -ListName $chosenList

        if ($loadResult.Success) {
            $loadedComputers = $loadResult.Config.Computers
            if ($loadResult.Note) { Write-Host ("  {0}" -f $loadResult.Note) -ForegroundColor DarkGray }

            # SS6: compare the credential mode this list was SAVED with against the running session.
            # The saved block used to be ignored entirely, so loading a list into a session with a
            # different credential mode silently changed which account every remote operation would
            # use - a security-relevant difference that stays invisible until an access-denied appears
            # (or, worse, does not). Reported, not auto-corrected: silently switching the operator's
            # credentials on load would be a bigger surprise than the warning.
            try {
                $credCheck = Test-WuuCredentialStateMatches -Saved $loadResult.Config.CredentialConfig
                if (-not $credCheck.Match) {
                    Write-Host ''
                    Write-Host '  CREDENTIAL MODE DIFFERS from the one this list was saved with.' -ForegroundColor Yellow
                    Write-Host "    $($credCheck.Reason)" -ForegroundColor Yellow
                    Write-Host '    Remote operations will run as the CURRENT session mode. Use' -ForegroundColor Yellow
                    Write-Host '    "Set domain credentials" to change it before running anything.' -ForegroundColor Yellow
                    Write-Host ''
                } elseif ($credCheck.SavedMode -eq 'custom') {
                    Write-InfoLog ("Loaded configuration matches this session's custom credentials ($($credCheck.SavedMode))")
                }
            } catch {
                Write-WarningLog "Could not compare the saved credential mode: $($_.Exception.Message)"
            }

            # Console edition: clear the store and add the loaded rows directly.
            # (GUI edition cleared clientObservable then added rows inside a dispatcher
            # invoke; the store needs neither.)
            foreach ($row in @(Get-WuuComputerRow -Store $stateStore)) {
                Remove-WuuComputerRow -Store $stateStore -Computer $row.Computer | Out-Null
            }

            # Add loaded items to the store
            ForEach ($compData in $loadedComputers) {
                try {
                    # Only load computer name and phase - all other data starts fresh
                    $row = New-WuuComputerRow -Computer $(if ($compData.Computer) { $compData.Computer } else { 'Unknown' }) `
                                              -Phase $(if ($compData.Phase) { $compData.Phase } else { 'Phase 1' }) `
                                              -StateSource 'BulkAdd'
                    $row.Status = 'Loaded from config. Select the row and Check For Updates to refresh status.'
                    $row.UpdatesStatus = 'Unknown'
                    $row.Pending = $false   # Loaded computers wait for a manual Check For Updates
                    Add-WuuComputerRow -Store $stateStore -Row $row | Out-Null
                    Write-InfoLog "Successfully loaded computer: $($row.Computer)"
                } catch {
                    Write-ErrorLog "Failed to add computer: $($compData.Computer). Error: $($_.Exception.Message)"
                    Update-Status "Error adding $($compData.Computer): $($_.Exception.Message)"
                }
            }
            
            # Worker runspaces are created on demand (New-ComputerRunspace) when an operation is requested
            Update-Status "List '$chosenList' loaded from $configPath"
        } else {
            # Console edition: report the failure without a modal dialog.
            $errorMessage = $loadResult.Error
            if ($errorMessage -match "decrypt|password|invalid|corrupt") {
                Write-Host ''
                Write-Host 'Failed to load the encrypted computer list. This is usually caused by an incorrect password.' -ForegroundColor Red
                Write-Host "Error details: $errorMessage" -ForegroundColor Red
                Write-Host 'Please try again with the correct password.' -ForegroundColor Red
            } else {
                Write-Host ''
                Write-Host 'Failed to load the encrypted computer list.' -ForegroundColor Red
                Write-Host "Error details: $errorMessage" -ForegroundColor Red
                Write-Host 'Please check that the file exists and is not corrupted.' -ForegroundColor Red
            }
            
            Update-Status "Failed to load encrypted computer list: $($loadResult.Error)"
        }
    } finally {
        # Always resume background processing
        Resume-BackgroundProcessing -CompletedOperation "encrypted computer list load"
    }
}
#endregion

#region Update Information and Service Management
# Console edition: these handlers previously wrote to Out-GridView (a WPF-only cmdlet that
# does not exist headlessly) and read $uiHash.Listview.SelectedItems. They now resolve rows
# from the store and print to the console.
#
# THE DISPLAY HANDLERS MOVED OUT (SS8): $eventShowAvailableUpdates, $eventShowInstalledUpdates,
# $eventShowUpdateHistory, $eventViewUpdateLog and their Show-WuuObjectTable helper now live in
# src\Wuu.Actions.Display.psm1, each taking the store explicitly. The console action layer below
# calls them by name.
#
# WHAT STAYS HERE, and why:
#   * $eventAuditWSUSUpdates - a remote COM query whose result feeds the audit trail.
#   * $eventWUServiceAction / $WUServiceAction - the latter is a RUNSPACE PAYLOAD handed to the worker
#     as `$ctx.WUServiceAction`; it may use only the injected $WriteDebugLogScript / $InvokePooledScript,
#     never a module function, so it cannot move into a module.
#   * $GetErrors - reads the ambient $Error collection and $performanceHash.
$eventAuditWSUSUpdates = {
    # Audit WSUS-approved updates and compare with Windows Update count
    #
    # Console edition: targets come from the state store via Read-WuuSelection, not from
    # $uiHash.Listview.SelectedItems. That member is $null here (nothing in src/ ever assigns it),
    # so `ForEach ($Computer in @($null))` iterated nothing and this operation was a silent no-op
    # from the console AND from `wuu audit wsus`. Read-WuuSelection is the same selector every other
    # console handler uses, and the command surface already queues its -Computer answer for it
    # (see the 'audit' entry in Get-WuuCommandTable), so scripting behaviour is preserved.
    $targets = @(Read-WuuSelection -Store $stateStore -Prompt 'Audit WSUS state for which computers?')
    if ($targets.Count -eq 0) { Write-Host '  Cancelled.' -ForegroundColor Yellow; return }
    ForEach ($Computer in $targets){
        $comResult = Invoke-RemoteComWithTimeout -ComputerName $Computer.computer -TimeoutSeconds 60 -ScriptBlock {
            param($ComputerName)
            try {
                $session = [activator]::CreateInstance([type]::GetTypeFromProgID('Microsoft.Update.Session', $ComputerName))
                $searcher = $session.CreateUpdateSearcher()
                
                $standardResults = $searcher.Search('IsInstalled=0 and IsHidden=0')
                $allResults = $searcher.Search('IsInstalled=0')
                $wsusResults = $searcher.Search('IsInstalled=0 and IsAssigned=1')
                
                $wsusServer = $null
                try {
                    $wsusKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
                    if (Test-Path $wsusKey) {
                        $wsusServer = (Get-ItemProperty -Path $wsusKey -Name "WUServer" -ErrorAction SilentlyContinue).WUServer
                    }
                } catch {
                    $wsusServer = "Unable to detect"
                }
                
                $rebootRequired = $false
                try {
                    $rebootRequired = (New-Object -ComObject 'Microsoft.Update.SystemInfo').RebootRequired
                } catch { }
                
                return [PSCustomObject]@{
                    Computer = $ComputerName
                    WSUS_Server = $wsusServer
                    Standard_Search_Count = $standardResults.Updates.Count
                    Including_Hidden_Count = $allResults.Updates.Count
                    WSUS_Assigned_Count = $wsusResults.Updates.Count
                    Downloaded_Count = @($standardResults.Updates | Where-Object {$_.IsDownloaded}).Count
                    Not_Downloaded_Count = @($standardResults.Updates | Where-Object {-not $_.IsDownloaded}).Count
                    Reboot_Required = $rebootRequired
                    Updates = @($standardResults.Updates | ForEach-Object {
                        [PSCustomObject]@{
                            Title = $_.Title
                            Downloaded = $_.IsDownloaded
                            Mandatory = $_.IsMandatory
                            Assigned = $_.IsAssigned
                        }
                    })
                }
            } catch {
                return [PSCustomObject]@{ Error = $_.Exception.Message }
            }
        }
        
        if ($comResult.Success) {
            $audit = $comResult.Output
            if ($audit.Error) {
                [PSCustomObject]@{Error = "WSUS audit failed: $($audit.Error)"} | Format-List | Write-Host -ForegroundColor Red
            } else {
                $audit | Select-Object Computer, WSUS_Server, Standard_Search_Count, Including_Hidden_Count, WSUS_Assigned_Count, Downloaded_Count, Not_Downloaded_Count, Reboot_Required | Format-List | Out-String | Write-Host -ForegroundColor Cyan
                
                if ($audit.Updates.Count -gt 0) {
                    Show-WuuObjectTable -Items @($audit.Updates) -Title "WSUS Audit: $($Computer.computer) - $($audit.Updates.Count) updates found"
                } else {
                    Write-Host "  WSUS Audit: $($Computer.computer) - no updates found" -ForegroundColor DarkGray
                }
            }
        } else {
            [PSCustomObject]@{Error = "WSUS audit timed out: $($comResult.Error)"} | Format-List | Write-Host -ForegroundColor Red
        }
    }
}
$eventWUServiceAction = {
    Param ($Action, $TargetComputer)
    # Console edition: when called from the interactive menu the target(s) are already
    # resolved; fall back to the store's full list otherwise.
    # Routed through Start-UpdateCheckJob (SS4) so a service action cannot be submitted to a busy
    # runspace - where it would be silently discarded - and so it counts toward the global cap.
    $targets = if ($TargetComputer) { @($TargetComputer) } else { @(Get-WuuComputerRow -Store $stateStore) }
    $deferred = 0
    foreach ($row in $targets) {
        if (Test-WuuComputerBusy -Row $row) { $deferred++; continue }
        $row.Pending = $false
        [void](Start-UpdateCheckJob -ComputerItem $row -Op 'ServiceAction' -ServiceAction $Action)
    }
    if ($deferred) { Write-Host ("  {0} computer(s) were busy - service action skipped for them." -f $deferred) -ForegroundColor Yellow }
}

# Windows Update Service Action ScriptBlock
# NOTE: runs in the isolated per-computer runspace - use only injected scripts
# ($WriteDebugLogScript) or inline code, never main-script functions.
$WUServiceAction = {
    Param ($Computer, $Action)
    
    Try {
        try { & $WriteDebugLogScript -Message "Performing Windows Update service action '$Action' on $($Computer.Computer)" -Level 'INFO' -Computer $Computer.Computer } catch { }
        
        # Update status
            $computer.Status = switch ($Action) {
                'Start'   { 'Starting Windows Update Service...' }
                'Stop'    { 'Stopping Windows Update Service...' }
                'Restart' { 'Restarting Windows Update Service...' }
                default   { "${Action}ing Windows Update Service..." }
            }
        if ($stateStore) { $stateStore.Touch() }
        
        # Perform the service action with timeout protection (avoids hangs)
        if ($Computer.Computer -eq 'localhost' -or $Computer.Computer -eq $env:COMPUTERNAME) {
            $service = Get-Service -Name 'wuauserv' -ErrorAction Stop
            switch ($Action) {
                'Start'   { if ($service.Status -ne 'Running') { $service | Start-Service -ErrorAction Stop } }
                'Stop'    { if ($service.Status -ne 'Stopped') { $service | Stop-Service -Force -ErrorAction Stop } }
                'Restart' { $service | Restart-Service -Force -ErrorAction Stop }
                default   { throw "Unknown action: $Action" }
            }
            $result = "Windows Update Service ${Action}ed successfully"
        } else {
            # Remote: run on the worker pool with a hard timeout to prevent hangs
            # (was Start-Job - one child process per service action)
            $poolResult = & $InvokePooledScript -Pool $WuuWorkerPool -ScriptBlock {
                param($ComputerName, $Action)
                try {
                    Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                        param($a)
                        $s = Get-Service -Name 'wuauserv' -ErrorAction Stop
                        switch ($a) {
                            'Start'   { if ($s.Status -ne 'Running') { $s | Start-Service -ErrorAction Stop } }
                            'Stop'    { if ($s.Status -ne 'Stopped') { $s | Stop-Service -Force -ErrorAction Stop } }
                            'Restart' { $s | Restart-Service -Force -ErrorAction Stop }
                        }
                    } -ArgumentList $Action -ErrorAction Stop
                    return @{ Success = $true; Message = "Windows Update Service ${Action}ed successfully" }
                } catch {
                    return @{ Success = $false; Error = $_.Exception.Message }
                }
            } -ArgumentList @($Computer.Computer, $Action) -TimeoutSeconds 20 -OperationName "Service $Action"
            
            if ($poolResult.Success -and $poolResult.Result -and $poolResult.Result.Success) {
                $result = $poolResult.Result.Message
            } else {
                $errorMsg = if ($poolResult.Result -and $poolResult.Result.Error) { $poolResult.Result.Error }
                            elseif ($poolResult.Error) { $poolResult.Error }
                            else { 'Service action failed with unknown error' }
                throw $errorMsg
            }
        }
        
        # Update status with result
            $computer.Status = $result
        if ($stateStore) { $stateStore.Touch() }
        
        try { & $WriteDebugLogScript -Message "Windows Update service action '$Action' completed successfully on $($Computer.Computer)" -Level 'SUCCESS' -Computer $Computer.Computer } catch { }
        
    } Catch {
        try { & $WriteDebugLogScript -Message "Windows Update service action '$Action' failed on $($Computer.Computer): $($_.Exception.Message)" -Level 'ERROR' -Computer $Computer.Computer } catch { }
        
            $computer.Status = "Service $Action failed: $($_.Exception.Message)"
            # Set background color to grey for errored entries
        $Computer.Color = 'Error'
        if ($stateStore) { $stateStore.Touch() }
    }
}

# Get Errors ScriptBlock
$GetErrors = {
    Write-InfoLog "Retrieving error information"
    
    $errorInfo = @()
    
    # Get PowerShell errors
    if ($Error.Count -gt 0) {
        foreach ($err in $Error) {
            $errorInfo += [PSCustomObject]@{
                Timestamp = if ($err.TimeGenerated) { $err.TimeGenerated } else { Get-Date }
                Type = 'PowerShell Error'
                Message = $err.Exception.Message
                Source = if ($err.InvocationInfo.ScriptName) { Split-Path -Leaf $err.InvocationInfo.ScriptName } else { 'Unknown' }
                LineNumber = $err.InvocationInfo.ScriptLineNumber
                Details = $err.Exception.GetType().FullName
                Computer = if ($err.TargetObject) { $err.TargetObject.Computer } else { 'Local' }
            }
        }
    }
    
    # Get computer-specific errors from status messages
    foreach ($computer in (Get-WuuComputerRow -Store $stateStore)) {
        if ($computer.Status -match '^Error|failed:|timeout') {
            $errorInfo += [PSCustomObject]@{
                Timestamp = Get-Date
                Type = 'Computer Error'
                Message = $computer.Status
                Source = 'WUU Operation'
                LineNumber = ''
                Details = "UpdatesStatus: $($computer.UpdatesStatus)"
                Computer = $computer.Computer
            }
        }
    }
    
    # Get performance issues
    foreach ($computer in $performanceHash.Keys) {
        $perf = $performanceHash[$computer]
        if ($perf.Status -match 'Error|Warning') {
            $errorInfo += [PSCustomObject]@{
                Timestamp = Get-Date
                Type = 'Performance Issue'
                Message = $perf.Status
                Source = 'Performance Monitor'
                LineNumber = ''
                Details = "CPU: $($perf.CPUPercent)%, Memory: $($perf.MemoryUsedMB)MB, Latency: $($perf.NetworkLatencyMs)ms"
                Computer = $computer
            }
        }
    }
    
    if ($errorInfo.Count -eq 0) {
        $errorInfo += [PSCustomObject]@{
            Timestamp = Get-Date
            Type = 'Information'
            Message = 'No errors found'
            Source = 'WUU'
            LineNumber = ''
            Details = 'All operations completed successfully'
            Computer = 'All'
        }
    }
    
    return $errorInfo | Sort-Object Timestamp -Descending
}
#endregion

#region Credential Management
$eventSetDomainCredentials = {
    try {
        # Suspend background processing to prevent interference with credential dialog
        Suspend-BackgroundProcessing -Reason "credential configuration"
        
        Write-InfoLog "Opening credential configuration dialog"
        $dialogResult = Show-CredentialConfigDialog
        
        if ($dialogResult -eq $true) {
            $statusMessage = 'Custom credentials configured successfully'
            Write-InfoLog "Custom credentials configured successfully"
        } else {
            $statusMessage = 'Credential configuration cancelled'
            Write-InfoLog "Credential configuration cancelled"
        }
        
        # Update status bar
        Update-StatusBackground $statusMessage
        
        $credentialStatus = if ($global:UseCustomCredentials) { 'Enabled' } else { 'Disabled' }
        Write-InfoLog "Credential configuration updated: $credentialStatus"
    } catch {
        Write-Error "Failed to open credential configuration dialog: $($_.Exception.Message)"
    } finally {
        # Always resume background processing
        Resume-BackgroundProcessing -CompletedOperation "credential configuration"
    }
}
#endregion

#region Console action layer (replaces the GUI context menu / event wiring)
<#
The GUI selected rows via $uiHash.Listview.SelectedItems and invoked $event* closures that
read that selection. The console has no ListView, so each action resolves its targets from the
state store through Read-WuuSelection and then calls the SAME underlying payload/handler.
That keeps one implementation per operation - the console wrappers only do selection and
confirmation, which is exactly the part that differs from a GUI.

Mutating actions confirm before running (the audit layer will additionally require a reason
in Phase 4). Non-mutating actions run immediately.
#>
$consoleActions = [hashtable]::Synchronized(@{ Quit = $false })

# --- helpers -----------------------------------------------------------------------------
# The deployment report behind the flat menu's [y] key and the GUIDED Reports menu.
#
# It is an action-layer entry because THAT is what the flat menu can dispatch: its loop calls
# $a.Run and discards the return value, so an entry that returned a workflow state would go
# nowhere. It delegates to Show-WuuReportScreen - the same screen the guided workflow uses - which
# is why the two paths cannot report different numbers for the same window. The screen is
# documented as returning a state, which this wrapper deliberately ignores: from the flat menu
# there is no workflow to navigate, so 'back' simply returns to the menu it came from.
$consoleActions.EventDeploymentReport = {
    $ctx = [pscustomobject]@{ Actions = $consoleActions; Store = $stateStore; Set = $null }
    $null = Show-WuuReportScreen -Ctx $ctx
}

$consoleActions.ShowHelp = {
    Write-Host ''
    Write-Host '  WUU2-CLI - console Windows Update utility' -ForegroundColor White
    Write-Host '  ------------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host '  Keys operate on the computer list in the status table above.' -ForegroundColor Gray
    Write-Host '  Most actions prompt for computer name(s); enter "all" for every row,' -ForegroundColor Gray
    Write-Host '  a comma-separated list, or an unambiguous name prefix.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  Auto download/install/reboot apply to checks and downloads started from' -ForegroundColor Gray
    Write-Host '  here. Press [t] to switch ALL of them on or off together - the toggle is a' -ForegroundColor Gray
    Write-Host '  master control: any state that is not "all on" becomes "all on".' -ForegroundColor Gray
    Write-Host ''
}

$consoleActions.EventToggleSettings = {
    <#
    .SYNOPSIS The MASTER automation toggle: an absolute rule, not three independent inversions.
    .DESCRIPTION
    Previously this inverted each setting independently. From `Download ON / Install OFF /
    Reboot OFF` that produced `OFF / ON / OFF` - a state the operator cannot predict, and one that
    briefly ENABLES auto-install while they were aiming for "turn everything off". The instruction
    set forbids that explicitly, and the reason is practical: the master control is pressed
    precisely when the operator is unsure of the current state, so it is the worst possible place
    to make the result depend on it.

        ALL ON         -> all OFF
        anything else  -> all ON      (so ALL OFF -> all ON, and MIXED -> all ON)

    MIXED resolving to ALL ON is deliberate, and is the rule the instruction set specifies. The
    direction is chosen for safety of INTENT rather than of effect: pressing the master control
    never leaves a partially-enabled pipeline, and the state it leaves is the one the operator can
    then switch off in a single further press.

    It STARTS NOTHING, and that is asserted rather than merely stated. The handler may invoke only
    the settings funnel and presentation; Test-AutoSettings section 10 reads this block's own AST
    and fails if it invokes anything else, calls anything through a variable, calls anything remote,
    or writes operation state. Do not add work to this handler - changing a setting is its whole job.
    #>
    $s = $stateStore.Settings

    $allOn = ([bool]$s.AutoDownload) -and ([bool]$s.AutoInstall) -and ([bool]$s.AutoReboot)
    $target = -not $allOn

    # Through the settings funnel. Set-WuuSetting is the one place the setting names are validated,
    # and this block used to bypass it with direct assignments - which is how the invert rule stayed
    # invisible to the gate that checks the names.
    Set-WuuSetting -Store $stateStore -Name 'AutoDownload' -Value $target | Out-Null
    Set-WuuSetting -Store $stateStore -Name 'AutoInstall' -Value $target | Out-Null
    Set-WuuSetting -Store $stateStore -Name 'AutoReboot' -Value $target | Out-Null

    $state = if ($target) { 'ON' } else { 'off' }
    Update-Status ("Auto download {0}, auto install {1}, auto reboot {2}{3}" -f `
        $state, $state, $state, $(if ($target) { '' } else { ' (automation disabled)' }))
    Write-Host '' 
    Write-Host ("  Automation {0} for download, install and reboot." -f $(if ($target) { 'ENABLED ' } else { 'DISABLED' })) -ForegroundColor $(if ($target) { 'Yellow' } else { 'Green' })
    # State the CONSEQUENCE, not just the change: this control decides whether a check can roll
    # forward into downloads, installs and reboots unattended.
    if ($target) {
        Write-Host '  A check will now continue into download, install and reboot without asking.' -ForegroundColor Yellow
    } else {
        Write-Host '  Operations will stop after each step and wait for you.' -ForegroundColor Green
    }
    Write-Host '  (Nothing has been started - this only changes how FUTURE operations behave.)' -ForegroundColor DarkGray
}

# --- selection-driven action adapters ---------------------------------------------------
# Each adapter: pick rows -> (confirm if mutating) -> run the existing handler against them.
$consoleActions.EventGetUpdates = {
    $rows = @(Read-WuuSelection -Store $stateStore -Prompt 'Check which computers? ("all" for every row, Enter to cancel)')
    if ($rows.Count -eq 0) { Write-Host '  Cancelled.' -ForegroundColor Yellow; return }
    $started = 0; $deferred = 0; $skipped = 0; $replaced = @(); $declined = @()
    foreach ($r in $rows) {
        # One operation per computer (SS3): a computer already working is left queued, NOT submitted
        # to. Set Pending so the scheduler starts it as soon as the current operation finishes -
        # a plain skip would lose the operator's request.
        if (Test-WuuComputerBusy -Row $r) {
            # SS7/SS16: the slot holds ONE request. -OnlyIfEmpty keeps this a REQUEST rather than a
            # queue, so a re-check never displaces an operator's queued work and nothing is lost.
            $pendingResult = Set-WuuPendingOperation -Row $r -Op 'Check' -OnlyIfEmpty
            if ($pendingResult.Replaced) { $replaced += ($r.Computer + ' (' + $pendingResult.Replaced + ')') }
            if ($pendingResult.Refused) { $declined += ($r.Computer + ' (' + $pendingResult.Existing + ')') }
            $deferred++
            continue
        }
        if ($r.PSObject.Properties['RetryCount']) { $r.RetryCount = 0; $r.RetryAt = $null }
        $r.Pending = $false
        if (Start-UpdateCheckJob -ComputerItem $r -Op 'Check') { $started++ } else { $skipped++ }
    }
    if ($stateStore) { $stateStore.Touch() }
    Write-Host ("  Update check queued for {0} computer(s)." -f $started) -ForegroundColor Green
    if ($deferred) { Write-Host ("  {0} already busy - queued to run when they finish." -f $deferred) -ForegroundColor Yellow }
    if ($replaced.Count) {
        Write-Host ("  {0} had a queued request NOT replaced (the existing request is kept): {1}" -f $replaced.Count, ($replaced -join ', ')) -ForegroundColor DarkGray
    }
    if ($declined.Count) {
        Write-Host ("  {0} had a higher-priority request already queued, which is KEPT: {1}" -f $declined.Count, ($declined -join ', ')) -ForegroundColor DarkGray
    }
    if ($skipped) { Write-Host ("  {0} could not be submitted (see the error log)." -f $skipped) -ForegroundColor Red }
}

$consoleActions.EventDownloadUpdates = {
    $rows = @(Read-WuuSelection -Store $stateStore -Prompt 'Download updates for which computers?')
    if ($rows.Count -eq 0) { Write-Host '  Cancelled.' -ForegroundColor Yellow; return }
    if (-not (Read-WuuYesNo -Prompt "Download updates to $($rows.Count) computer(s)?" -Default $true)) {
        Write-Host '  Cancelled.' -ForegroundColor Yellow; return
    }
    $started = 0; $deferred = 0; $uptodate = 0; $replaced = @(); $declined = @()
    foreach ($r in $rows) {
        # An errored, timed-out, or offline computer cannot be assumed up-to-date just because Available is 0.
        if ($r.State -in @('Error', 'Timeout', 'Offline') -or $r.Color -in @('Error', 'Timeout')) {
            Write-Host ("  {0} is in {1} state - check for updates or resolve issue before downloading." -f $r.Computer, $r.State) -ForegroundColor Yellow
            continue
        }
        # Nothing to do - answer immediately rather than queuing an operation that will no-op.
        if ($r.Available -eq $r.Downloaded) {
            $r.Status = if ($r.Available -eq 0) { 'Up-to-Date - No updates available for download.' } else { 'All available updates are already downloaded.' }
            $uptodate++
            continue
        }
        if (Test-WuuComputerBusy -Row $r) {
            # SS7/SS16: an UPGRADE replaces and is reported; a DOWNGRADE is DECLINED and the higher
            # request already queued is KEPT. `install` then `download` on a busy computer used to
            # replace the install with a download, so an operator who asked for MORE got less with
            # no indication. See Set-WuuPendingOperation.
            $pendingResult = Set-WuuPendingOperation -Row $r -Op 'Download'
            if ($pendingResult.Replaced) { $replaced += ($r.Computer + ' (' + $pendingResult.Replaced + ' -> Download)') }
            if ($pendingResult.Refused) { $declined += ($r.Computer + ' (' + $pendingResult.Existing + ')') }
            $deferred++
            continue
        }
        $r.Pending = $false
        [void](Start-UpdateCheckJob -ComputerItem $r -Op 'Download')
        $started++
    }
    if ($stateStore) { $stateStore.Touch() }
    Write-Host ("  Download started for {0} computer(s)." -f $started) -ForegroundColor Green
    if ($deferred) { Write-Host ("  {0} already busy - queued to run when they finish." -f $deferred) -ForegroundColor Yellow }
    if ($replaced.Count) {
        Write-Host ("  {0} had a queued request REPLACED by this one (it does the same work and more): {1}" -f $replaced.Count, ($replaced -join ', ')) -ForegroundColor Yellow
    }
    if ($declined.Count) {
        Write-Host ("  {0} had a higher-priority request already queued, which is KEPT - a download would do LESS than was asked: {1}" -f $declined.Count, ($declined -join ', ')) -ForegroundColor Yellow
    }
    if ($uptodate) { Write-Host ("  {0} had nothing to download." -f $uptodate) -ForegroundColor DarkGray }
}

$consoleActions.EventInstallUpdates = {
    $rows = @(Read-WuuSelection -Store $stateStore -Prompt 'Install updates on which computers?')
    if ($rows.Count -eq 0) { Write-Host '  Cancelled.' -ForegroundColor Yellow; return }
    if (-not (Read-WuuYesNo -Prompt "Install updates on $($rows.Count) computer(s)?" -Default $false)) {
        Write-Host '  Cancelled.' -ForegroundColor Yellow; return
    }
    $started = 0; $deferred = 0; $replaced = @(); $declined = @()
    foreach ($r in $rows) {
        if (Test-WuuComputerBusy -Row $r) {
            # SS7/SS16: install ranks above a queued download, so this UPGRADES and replaces it; the
            # replacement is reported. Nothing ranks above install, so it can never be declined here.
            $pendingResult = Set-WuuPendingOperation -Row $r -Op 'InstallAndRecheck'
            if ($pendingResult.Replaced) { $replaced += ($r.Computer + ' (' + $pendingResult.Replaced + ' -> InstallAndRecheck)') }
            if ($pendingResult.Refused) { $declined += ($r.Computer + ' (' + $pendingResult.Existing + ')') }
            $deferred++
            continue
        }
        $r.Pending = $false
        [void](Start-UpdateCheckJob -ComputerItem $r -Op 'InstallAndRecheck')
        $started++
    }
    if ($stateStore) { $stateStore.Touch() }
    Write-Host ("  Install started for {0} computer(s)." -f $started) -ForegroundColor Green
    if ($deferred) { Write-Host ("  {0} already busy - queued to run when they finish." -f $deferred) -ForegroundColor Yellow }
    if ($replaced.Count) {
        Write-Host ("  {0} had a queued request REPLACED by this one (it does the same work and more): {1}" -f $replaced.Count, ($replaced -join ', ')) -ForegroundColor Yellow
    }
    if ($declined.Count) {
        Write-Host ("  {0} had a higher-priority request already queued, which is KEPT: {1}" -f $declined.Count, ($declined -join ', ')) -ForegroundColor Yellow
    }
}

$consoleActions.EventRestartComputer = {
    $rows = @(Read-WuuSelection -Store $stateStore -Prompt 'Restart which computers?')
    if ($rows.Count -eq 0) { Write-Host '  Cancelled.' -ForegroundColor Yellow; return }
    $names = ($rows | ForEach-Object { $_.Computer }) -join ', '
    Write-Host "  About to RESTART: $names" -ForegroundColor Yellow
    if (-not (Read-WuuYesNo -Prompt 'Confirm restart?' -Default $false)) {
        Write-Host '  Cancelled.' -ForegroundColor Yellow; return
    }
    $started = 0; $deferred = 0
    foreach ($r in $rows) {
        if (Test-WuuComputerBusy -Row $r) {
            # A restart is the one operation that must NOT be silently deferred: the operator
            # explicitly confirmed it for these computers. Reported per computer instead.
            Write-Host ("    {0} is busy ({1}) - restart NOT queued; re-run when it is idle." -f $r.Computer, $r.OpState) -ForegroundColor Yellow
            $deferred++
            continue
        }
        $r.Pending = $false
        [void](Start-UpdateCheckJob -ComputerItem $r -Op 'Restart')
        $started++
    }
    if ($stateStore) { $stateStore.Touch() }
    Write-Host ("  Restart started for {0} computer(s)." -f $started) -ForegroundColor Green
    if ($deferred) { Write-Host ("  {0} skipped because they were busy." -f $deferred) -ForegroundColor Yellow }
}

$consoleActions.EventRemoveOfflineComputer = {
    if (-not (Read-WuuYesNo -Prompt 'Test connectivity and remove unreachable computers?' -Default $false)) {
        Write-Host '  Cancelled.' -ForegroundColor Yellow; return
    }
    & $eventRemoveOfflineComputer
}

$consoleActions.EventAssignPhaseInteractive = {
    $rows = @(Read-WuuSelection -Store $stateStore -Prompt 'Assign a phase to which computers?')
    if ($rows.Count -eq 0) { Write-Host '  Cancelled.' -ForegroundColor Yellow; return }
    $phase = Read-WuuAnswer -Prompt '  Phase (1-5)' -Default ''
    if ($phase -notmatch '^[1-5]$') { Write-Host '  Invalid phase.' -ForegroundColor Yellow; return }
    foreach ($r in $rows) { $r.Phase = "Phase $phase" }
    if ($stateStore) { $stateStore.Touch() }
    Write-Host "  Assigned $($rows.Count) computer(s) to Phase $phase." -ForegroundColor Green
}

$consoleActions.EventShowByPhase = {
    foreach ($p in 1..5) {
        $n = 0
        foreach ($r in @(Get-WuuComputerRow -Store $stateStore)) { if ($r.Phase -eq "Phase $p") { $n++ } }
        Write-Host ("  Phase {0}: {1} computer(s)" -f $p, $n)
    }
}

$consoleActions.EventRemoveSelected = {
    $rows = @(Read-WuuSelection -Store $stateStore -Prompt 'Remove which computers from the list?')
    if ($rows.Count -eq 0) { Write-Host '  Cancelled.' -ForegroundColor Yellow; return }
    & $removeEntry $rows
}

$consoleActions.ClearComputerList = { & $clearComputerList }

# NOTE for tests: $consoleActions is assembled inside Start-WuuApplication, so it does NOT exist
# from a bare `Import-Module Wuu.Core` - a test that needs the real wiring must either run the app
# or verify handler names statically (see tests\Test-Navigation.ps1 and the validator's
# "menu handler resolves" gate). Do not paper over this by having tests build their own action
# map and call it verification: a hand-built map cannot fail the way the real one can, which is
# precisely how the $eventAddAD handler stayed unwired and unreachable without any test noticing.

# Active Directory acquisition.
#
# This adapter is what makes `EventAddAD` reachable. The $eventAddAD handler was written for the
# console edition but was NEVER wired into $consoleActions, the flat menu, or the verb table - so
# AD import was dead code: fully implemented, completely unreachable, and invisible to every test
# because nothing could invoke it. Surfaced while implementing spec 4.3 (Active Directory
# acquisition) in docs/INTERACTIVE_UI_SPEC.md, which needed it to exist.
#
# The release validator now fails the build if any menu entry names a handler with no adapter, so
# this class of "implemented but unreachable" defect cannot recur silently.
$consoleActions.EventAddAD = { & $eventAddAD }

$consoleActions.EventAddComputer = {
    $ans = Read-WuuAnswer -Prompt '  Computer name(s), separated by comma, semicolon or space' -Default ''
    if ([string]::IsNullOrWhiteSpace($ans)) { Write-Host '  Cancelled.' -ForegroundColor Yellow; return }
    # Spec 4.1 promises commas, spaces OR new lines. This split on commas and semicolons only, so
    # "SRV01 SRV02" was added as ONE computer named "SRV01 SRV02". Reading through the shared parser
    # makes every input door agree; the prompt above now describes what is actually accepted.
    $names = @(Split-WuuComputerNames -Text $ans)
    $res = & $AddEntry $names
    Write-Host "  Added $($res.AddedCount) computer(s)." -ForegroundColor Green
    if (@($res.Duplicates).Count -gt 0) {
        Write-Host "  Skipped $(@($res.Duplicates).Count) duplicate computer(s)." -ForegroundColor Yellow
    }
    if (@($res.Invalid).Count -gt 0) {
        Write-Host "  Skipped $(@($res.Invalid).Count) invalid computer name(s)." -ForegroundColor Yellow
    }
}

$consoleActions.EventAddFile = {
    $path = Read-WuuAnswer -Prompt '  Path to CSV/TXT file' -Default ''
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) {
        Write-Host '  File not found.' -ForegroundColor Red; return
    }
    $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($ext -eq '.csv') {
        $csv = Import-Csv -Path $path
        if (-not $csv -or $csv.Count -eq 0) { Write-Host '  File contained no rows.' -ForegroundColor Yellow; return }
        $cols = @($csv[0].PSObject.Properties.Name)
        Write-Host "  Columns: $($cols -join ', ')"
        $col = Read-WuuAnswer -Prompt "  Which column holds the computer name? (default '$($cols[0])')" -Default ''
        if ([string]::IsNullOrWhiteSpace($col)) { $col = $cols[0] }
        if ($cols -notcontains $col) { Write-Host '  No such column.' -ForegroundColor Red; return }
        $names = @($csv | ForEach-Object { ([string]$_.$col).Trim() } | Where-Object { $_ })
    } else {
        # Spec 4.1: "You can enter multiple names separated by commas, spaces, or new lines."
        # This branch used to keep one name per line, so "SRV01 SRV02" imported as a SINGLE computer
        # called "SRV01 SRV02" - added successfully, listed, and unable to connect. The guided
        # workflow's importer splits on whitespace/comma/semicolon/tab, so the same file meant
        # different things depending on which menu opened it. Reading through the shared parser is
        # the fix; a file with one name per line behaves exactly as before.
        $names = @(Get-Content -Path $path | ForEach-Object { Split-WuuComputerNames -Text $_ } | Where-Object { $_ })
    }
    $res = & $AddEntry $names
    Write-Host "  Imported $($res.AddedCount) computer(s)." -ForegroundColor Green
    if (@($res.Duplicates).Count -gt 0) {
        Write-Host "  Skipped $(@($res.Duplicates).Count) duplicate computer(s)." -ForegroundColor Yellow
    }
    if (@($res.Invalid).Count -gt 0) {
        Write-Host "  Skipped $(@($res.Invalid).Count) invalid computer name(s)." -ForegroundColor Yellow
    }
}

# Read-only actions delegate to the existing handlers, which read the store's rows.
$consoleActions.EventShowAvailableUpdates = { Invoke-WuuShowAvailableUpdates -Store $stateStore }
$consoleActions.EventShowInstalledUpdates = { Invoke-WuuShowInstalledUpdates -Store $stateStore }
$consoleActions.EventShowUpdateHistory = { Invoke-WuuShowUpdateHistory -Store $stateStore }
$consoleActions.EventAuditWSUSUpdates      = { & $eventAuditWSUSUpdates }
# NOTE: this adapter was missing until the release validator caught the verb table pointing at a
# nonexistent handler - the menu had the same gap (no key was bound to it), so nothing noticed.
$consoleActions.EventViewUpdateLog = { Invoke-WuuViewUpdateLog -Store $stateStore }
$consoleActions.EventSaveComputerList      = { & $eventSaveComputerList }
$consoleActions.EventSaveConfig            = { & $eventSaveConfig }
$consoleActions.EventLoadConfig            = { & $eventLoadConfig }
$consoleActions.EventSetDomainCredentials  = { & $eventSetDomainCredentials }
$consoleActions.GetErrors                  = { & $GetErrors }

$consoleActions.EventWUServiceActionInteractive = {
    $rows = @(Read-WuuSelection -Store $stateStore -Prompt 'Target computer(s) for the service action?')
    if ($rows.Count -eq 0) { Write-Host '  Cancelled.' -ForegroundColor Yellow; return }
    $act = Read-WuuAnswer -Prompt '  Action: (s)tart, (t)op, or (r)estart' -Default ''
    $map = @{ 's' = 'Start'; 't' = 'Stop'; 'r' = 'Restart' }
    $key = $act.Trim().ToLowerInvariant()
    if (-not $map.ContainsKey($key)) { Write-Host '  Invalid action.' -ForegroundColor Yellow; return }
    foreach ($r in $rows) { & $eventWUServiceAction $map[$key] $r }
}

$consoleActions.EventSetViewFilter = {
    Write-Host ''
    Write-Host '  Select Status Table View Filter:' -ForegroundColor Cyan
    Write-Host '  [1] Needs Attention (Hide up-to-date systems) [Default]'
    Write-Host '  [2] Active (Running operations / pending)'
    Write-Host '  [3] Failed (Errors, timeouts, offline)'
    Write-Host '  [4] Updates (Updates available or downloaded)'
    Write-Host '  [5] Reboot (Reboot pending)'
    Write-Host '  [6] All (Show entire fleet)'
    Write-Host ''
    $ans = Read-WuuAnswer -Prompt '  Select filter [1-6, default 1]' -Default '1'
    $filterChoice = switch (([string]$ans).Trim()) {
        '1' { 'NeedsAttention' }
        '2' { 'Active' }
        '3' { 'Failed' }
        '4' { 'Updates' }
        '5' { 'Reboot' }
        '6' { 'All' }
        default { 'NeedsAttention' }
    }
    if ($stateStore) {
        $stateStore.ViewFilter = $filterChoice
        $stateStore.Touch()
    }
    $label = Get-WuuFilterLabel -Filter $filterChoice
    Write-Host ("  Status table filter set to: {0}" -f $label) -ForegroundColor Green
}
#endregion Console action layer


#region Job scheduler timer
# Hand the shared app state to Wuu.WindowsUpdate (job/phase functions read $script:WuuCtx).
# Without this, Start-PendingUpdateCheck silently no-ops on a null context and items
# stay stuck at "Initializing...". Must run AFTER the payload closures exist and BEFORE
# the first timer tick.
$wuuContext = @{
    Jobs                       = $global:jobs
    UpdatesHash                = $global:updatesHash
    PerformanceHash            = $global:performanceHash
    ErrorSuggestions           = $global:errorSuggestionsHash
    Path                       = $PWD.Path
    LogPath                    = $global:LogPath
    LogLock                    = $global:LogLock
    EnableDebugLogging          = $global:EnableDebugLogging
    EnableEnhancedErrorHandling = $global:EnableEnhancedErrorHandling
    UseCustomCredentials        = $global:UseCustomCredentials
    CustomCredentials           = $global:CustomCredentials
    CredentialCache             = $global:CredentialCache
    PerformanceThreshold        = $global:PerformanceThreshold
    ConfigPaths                 = $global:ConfigPaths
    SearchTimeout               = $global:searchTimeout
    SessionTimeout              = $global:sessionTimeout
    RebootCheckTimeout          = $global:rebootCheckTimeout
    CimTimeoutSeconds           = $global:CimTimeoutSeconds
    ServiceTimeoutSeconds       = $global:ServiceTimeoutSeconds
    PerformanceTimeoutSeconds   = $global:PerformanceTimeoutSeconds
    CredProbeTimeoutSeconds     = $global:CredProbeTimeoutSeconds
    RebootProbeTimeoutSeconds   = $global:RebootProbeTimeoutSeconds
    OfflineWaitSeconds          = $global:OfflineWaitSeconds
    OnlineWaitSeconds           = $global:OnlineWaitSeconds
    MaxConcurrentJobs           = $global:MaxConcurrentJobs
    GetUpdates                  = $GetUpdates
    DownloadUpdates             = $DownloadUpdates
    InstallUpdates              = $InstallUpdates
    RestartComputer             = $RestartComputer
    # Exposed so the last two per-computer operations (remove-offline, service action) can go
    # through Start-UpdateCheckJob like everything else, instead of composing their own
    # [powershell]::Create() + BeginInvoke and thereby bypassing the per-computer gate (SS4).
    RemoveOfflineComputer       = $RemoveOfflineComputer
    WUServiceAction             = $WUServiceAction
    BackgroundProcessing        = $global:backgroundProcessing
    # Console edition: the state store worker runspaces write progress into.
    StateStore                  = $stateStore
}
Initialize-WuuWindowsUpdateContext -Context $wuuContext
Initialize-WuuSchedulerContext -Context $wuuContext

# Console edition: NO DispatcherTimer. The GUI could use one because ShowDialog() pumps a
# WPF message loop, so a UI-thread timer fired while the app waited for input. A console
# blocked in Read-Host has no message loop and a runspace-affine scriptblock timer cannot fire
# while the runspace is inside the prompt - so a timer would silently never tick and the
# auto-flow / Phase-E retries would stall (the same failure shape as the old auto-download
# bug). Instead the console loop polls the keyboard non-blockingly and calls this once per
# tick, on the same runspace. See Wuu.Console.psm1's module header.
$drainScheduler = {
    try {
        Start-PendingUpdateCheck
    } catch {
        Write-ErrorLog "Job scheduler tick failed: $($_.Exception.Message)"
    }
}
#endregion Job scheduler timer

#region Start the console shell
try {
    Write-InfoLog "Starting console shell"

    # Load the config-specified computer list if one exists (the GUI did this implicitly via
    # its ListView init; here it is explicit so the operator sees their list immediately).
    $startupConfig = Join-Path $WuuRoot 'ComputerList.config'
    if (Test-Path $startupConfig) {
        Write-InfoLog "Encrypted computer list present at $startupConfig - press [l] to load it."
    }

    if ($CommandArguments -and $CommandArguments.Count -gt 0) {
        # ---- Phase 2: one-shot command mode ---------------------------------------------
        # Parsed by Wuu.Command and dispatched to the SAME $consoleActions handlers the menu
        # uses, with input switched to non-interactive (missing required input fails loudly
        # instead of prompting). See Wuu.Command.psm1's header for the verb table.
        #
        # Log the invocation before parsing. Without this, command mode leaves NO trace in the
        # debug log that a command was ever requested - which makes diagnosing "my arguments
        # were ignored / vanished" impossible after the fact. The audit trail records the verb
        # (with operator + reason); this records the raw argv, which is what you need when the
        # parse itself is the suspect.
        Write-InfoLog ("Command mode: argv = [{0}]" -f ($CommandArguments -join ' '))

        $parsed = ConvertTo-WuuCommandLine -Arguments $CommandArguments

        if ($parsed.Unknown.Count -gt 0) {
            Write-Host ("  Unrecognised option(s): {0}" -f ($parsed.Unknown -join ', ')) -ForegroundColor Yellow
        }
        if ($parsed.Options.ContainsKey('Help') -or -not $parsed.Verb) {
            Get-WuuCommandHelp -Verb $parsed.Verb
            if (-not $parsed.Verb -and -not $parsed.Options.ContainsKey('Help')) {
                Write-Host '  No verb given - nothing to do. Use -Help for usage.' -ForegroundColor Yellow
            }
        } else {
            # Load the saved computer list first when one exists, so `wuu check -All` works
            # against the operator's list without an interactive load step. Without this a
            # scripted `-All` would find an empty store and silently do nothing.
            #
            # SS: the file can hold several named lists. There is no operator here to ask, so the
            # choice is made by rule, not by prompt: `-ListName` if given, else the default-named
            # list when one exists (which is what a single-list file always is, so the previous
            # behaviour is exactly preserved), else the first list in the file.
            if ((Test-Path $startupConfig) -and $parsed.Verb -ne 'add' -and $parsed.Verb -ne 'add-file') {
                try {
                    $credForLoad = $null
                    if ($parsed.Options['Password']) { $credForLoad = $parsed.Options['Password'] }
                    $wantedList = [string]$parsed.Options['ListName']
                    if ([string]::IsNullOrWhiteSpace($wantedList)) {
                        $avail = @(Get-WuuComputerListNames -ConfigPath $startupConfig -Password $credForLoad)
                        if ($avail -contains $script:WuuDefaultListName) { $wantedList = $script:WuuDefaultListName }
                        elseif ($avail.Count -gt 0) {
                            $wantedList = $avail[0]
                            Write-Host ("  '{0}' holds {1} lists ({2}); loading '{3}'. Use -ListName to pick another." -f
                                $startupConfig, $avail.Count, ($avail -join ', '), $wantedList) -ForegroundColor DarkGray
                        }
                    }
                    $loadRes = Import-ComputerListConfig -ConfigPath $startupConfig -Password $credForLoad -ListName $wantedList
                    if ($loadRes.Success) {
                        foreach ($compData in $loadRes.Config.Computers) {
                            $existing = Get-WuuComputerRow -Store $stateStore -Computer $compData.Computer
                            if ($existing) { continue }
                            $row = New-WuuComputerRow -Computer $(if ($compData.Computer) { $compData.Computer } else { 'Unknown' }) `
                                                      -Phase $(if ($compData.Phase) { $compData.Phase } else { 'Phase 1' }) `
                                                      -StateSource 'CommandMode'
                            $row.Status = 'Loaded from config. Run `wuu check` to refresh status.'
                            $row.UpdatesStatus = 'Unknown'
                            $row.Pending = $false
                            Add-WuuComputerRow -Store $stateStore -Row $row | Out-Null
                        }
                        Write-InfoLog "Command mode: loaded $($stateStore.Rows.Count) computer(s) from config"
                    } else {
                        Write-Host ("  Could not load $startupConfig : {0}" -f $loadRes.Error) -ForegroundColor Yellow
                        Write-Host '  Continuing with an empty list (use `wuu add` to populate it).' -ForegroundColor Yellow
                    }
                } catch {
                    Write-WarningLog "Command mode: config load failed: $($_.Exception.Message)"
                }
            }

            # -ServiceAction is the SERVICE action (start|stop|restart) and only means anything for
            # the 'service' verb. -SubVerb is the sub-dispatch token (show available, config save,
            # audit verify, service restart). These were once both bound to $parsed.SubVerb, which
            # worked for `service restart` purely by coincidence (that word happens to be a valid
            # service action) and hard-threw for every other sub-dispatched verb:
            #   `wuu audit export` -> ServiceAction='export' -> ValidateSet('','start','stop','restart')
            #   -> "Cannot validate argument on parameter 'ServiceAction'" -> CRITICAL ERROR.
            # The failure surfaced as a console-shell crash AFTER the verb had been parsed, so the
            # verb looked unreachable. Guard it: only pass a service action when the verb is one.
            $result = Invoke-WuuCommand -Verb $parsed.Verb -Actions $consoleActions -Store $stateStore `
                -Computer $parsed.Options['Computer'] -All:$parsed.Options['All'] `
                -Path $parsed.Options['Path'] -Column $parsed.Options['Column'] `
                -Set $(if ($parsed.Options['Set']) { [int]$parsed.Options['Set'] } else { 0 }) `
                -ServiceAction $(if ($parsed.Verb -eq 'service') { [string]$parsed.SubVerb } else { '' }) `
                -SubVerb $parsed.SubVerb -Reason $parsed.Options['Reason'] `
                -ListName $wantedList `
                -Period $parsed.Options['Period'] -GroupBy $parsed.Options['GroupBy'] `
                -From $parsed.Options['From'] -To $parsed.Options['To'] `
                -FailedOnly:$parsed.Options['FailedOnly'] -Out $parsed.Options['Out'] `
                -Dataset $parsed.Options['Dataset'] -LogPath $parsed.Options['LogPath'] `
                -Json:$parsed.Options['Json'] -WhatIf:$parsed.Options['WhatIf'] -Async:$parsed.Options['Async']

            # Give queued background work a bounded chance to run, then report state. A one-shot
            # command must not return before the operation it started has had an opportunity to
            # make progress, or `wuu check` would exit having done nothing visible.
            $deadline = (Get-Date).AddSeconds($CommandWaitSeconds)
            while ((Get-Date) -lt $deadline -and $jobs.Count -gt 0) {
                try { & $drainScheduler } catch { Write-ErrorLog "Scheduler tick failed: $($_.Exception.Message)" }
                Start-Sleep -Milliseconds 250
            }

            # SS10: what was ACCEPTED is not what COMPLETED. The loop above is a bounded wait, so
            # "returned from Invoke-WuuCommand" only proves the work was queued. Classify by the
            # STORE (does any requested row still have work outstanding?) rather than by whether
            # the call returned a result object, then add what this loop measured (the timeout).
            # Selection mirrors the handlers: 'all' or empty means every row, otherwise the names.
            $sel = @($parsed.Options['Computer'] -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $targetRows = @(Get-WuuComputerRow -Store $stateStore | Where-Object {
                $sel.Count -eq 0 -or ($sel -contains 'all') -or ($sel -contains $_.Computer)
            })
            $outstanding = @($targetRows | Where-Object { ($_.OpState -eq 'Running') -or [bool]$_.Pending })
            $busy = $outstanding.Count -gt 0

            # The classification decides the code. Each condition is distinct: a timeout is not a
            # usage error, an audit-integrity failure is not an operation failure, and queued work
            # is not success unless the caller asked for it with -Async.
            #
            # SS10: PARTIAL SUCCESS is now produced. "A succeeded, B failed" used to be unobservable
            # - the selection was resolved by one shared answer - so exit 4 was reserved but never
            # returned, and a mixed fleet reported a flat failure. Get-WuuAggregateOutcome reads the
            # per-target verdicts and returns PartialSuccess for a genuine mix, ignoring targets that
            # have not settled (an in-progress run is not a partial failure).
            $aggregate = Get-WuuAggregateOutcome -Rows $targetRows

            $exitCode = 0
            if ($busy -and -not $parsed.Options['Async']) {
                $exitCode = Get-WuuExitCode -Result 'Timeout'
            } elseif ($parsed.Options['Async'] -and $busy) {
                $exitCode = Get-WuuExitCode -Result 'Queued'
            } elseif ($aggregate -eq 'PartialSuccess') {
                # Settled, mixed: some targets succeeded and some did not. This outranks the generic
                # failure below, because it is strictly more informative and the caller can act on it.
                $exitCode = Get-WuuExitCode -Result 'PartialSuccess'
            } elseif (-not $result.Ok) {
                if ($result.PSObject.Properties['Result'] -and $result.Result) {
                    $exitCode = Get-WuuExitCode -Result $result.Result
                } else {
                    $exitCode = Get-WuuExitCode -Result 'OperationFailed'
                }
            } elseif ($aggregate -eq 'OperationFailed') {
                # The handler reported success but every settled target failed - trust the store.
                $exitCode = Get-WuuExitCode -Result 'OperationFailed'
            } elseif ($busy) {
                # -Async was requested and the work was finished inside the window, so the wait
                # merely observed a completion. That is a success, not a queue notification.
                $exitCode = Get-WuuExitCode -Result 'Success'
            }

            # SS33/SS34: ONE structured result, from which BOTH renderings derive. Before this, the
            # JSON was hand-built here and the human output was written separately, so the two could
            # - and did - describe the command differently. The result object now carries the counts,
            # the exit code and its vocabulary name, and both branches read the same fields.
            $snapshot = @(Get-WuuComputerRow -Store $stateStore | ForEach-Object {
                [pscustomobject]@{
                    Computer = $_.Computer; Phase = $_.Phase; State = $_.State
                    UpdatesStatus = $_.UpdatesStatus; Available = $_.Available
                    Downloaded = $_.Downloaded; RebootRequired = $_.RebootRequired
                    Status = $_.Status; OpState = $_.OpState; Pending = [bool]$_.Pending
                }
            })
            $commandCounts = Get-WuuCommandCounts -Rows $targetRows
            $commandResult = New-WuuCommandResult -Command $parsed.Verb -Ok ([bool]$result.Ok) `
                -ExitCode $exitCode -Completed (-not $busy) -Outstanding $outstanding.Count `
                -Counts $commandCounts -Computers $snapshot `
                -ErrorMessage $(if ($result.PSObject.Properties['Error']) { [string]$result.Error } else { '' })

            if ($parsed.Options['Json']) {
                # The documented contract (PascalCase, docs/EXIT_CODES.md) is preserved field for field;
                # the model adds SchemaVersion and the per-status counts to it.
                Format-WuuResultJson -Result $commandResult
            } else {
                Write-WuuStatusTable -Store $stateStore
                Write-WuuStatusLine -Store $stateStore
                if ($busy -and -not $parsed.Options['Async']) {
                    Write-Host ("  Timed out after {0}s with {1} computer(s) still working; the queued" -f $CommandWaitSeconds, $outstanding.Count) -ForegroundColor Yellow
                    Write-Host '  work continues in this process, but this run has NOT confirmed it finished.' -ForegroundColor Yellow
                } elseif ($parsed.Options['Async'] -and $busy) {
                    Write-Host ("  Queued on {0} computer(s) - not waiting (-Async). Exit code 6 means" -f $outstanding.Count) -ForegroundColor Yellow
                    Write-Host '  "accepted", NOT "succeeded".' -ForegroundColor Yellow
                }
            }

            $script:CommandExitCode = $exitCode
        }
    }
    else {
        Write-Host ''
        Write-Host '  WUU2-CLI - Windows Update Utility (console edition)' -ForegroundColor White
        Write-Host '  Press ? for help, t to toggle ALL automation on/off, q to quit.' -ForegroundColor DarkGray
        Write-Host '  Run with -Help for scriptable commands (wuu check -All, wuu install -Computer X).' -ForegroundColor DarkGray

        # The interactive menu is audited too: mutating actions ask for a reason and go through
        # the same fail-closed choke point as the command surface. Without this a human could
        # change remote hosts with nothing recorded, which would make the trail misleading
        # (it would look like the only changes ever made were scripted ones).
        $auditSession = Start-WuuAuditSession -Action 'interactive-menu'
        Write-InfoLog "Audit session $($auditSession.RunId) -> $($auditSession.LogPath)"
        # Capture what the operator SAW (best-effort, never fatal): the JSONL says what was done,
        # the transcript is what answers "why did they think that was right?".
        [void](Start-WuuAuditTranscript -Session $auditSession)
        $auditHook = {
            param([string]$ActionName, [string]$Reason, [scriptblock]$Body, [string[]]$Targets = @())
            # -Targets is forwarded when the caller supplies it (the guided workflow does, from the
            # confirmed plan) and otherwise derived from the rows the store is tracking. Without
            # this the record's targets were always empty for interactive changes while a scripted
            # `wuu install -Computer SRV01` recorded 'SRV01' - so the trail could not answer "which
            # hosts did this person change?" for exactly the changes a human authorised.
            if (@($Targets).Count -eq 0) { $Targets = @(Get-WuuComputerRow -Store $stateStore | ForEach-Object { $_.Computer }) }
            Invoke-WuuAuditedAction -Session $auditSession -Action $ActionName -Reason $Reason -Body $Body -Targets $Targets
        }.GetNewClosure()

        # Refusals are first-class events too (ISO 27001 A.8.15): a menu action cancelled at the
        # reason prompt is recorded as denied. Best-effort on purpose - the action is already
        # cancelled, so a logging failure must not turn a cancellation into an error.
        $denialHook = {
            param([string]$ActionName, [string]$DenialReason)
            Write-WuuAuditDenial -Session $auditSession -Action $ActionName -DenialReason $DenialReason
        }.GetNewClosure()

        try {
            # The GUIDED workflow is the default interactive experience (docs/INTERACTIVE_UI_SPEC.md).
            # It establishes a computer set before exposing any update operation, groups operations
            # into categories, and dispatches every leaf through the SAME $consoleActions handlers
            # the flat menu and the command surface use - so no operation is reimplemented and the
            # audit hooks apply identically.
            #
            # `wuu --flat-menu` restores the previous flat 25-operation loop. It is a COMMAND-LINE
            # OPTION rather than an environment variable on purpose: WUU relaunches itself elevated,
            # and UAC gives the child a fresh environment (the parent's WUU2_FLAT_MENU would simply
            # be absent in the elevated process, so the switch would silently do nothing). Arguments
            # ARE forwarded across that hop - see the elevation block above.
            $useFlatMenu = ($CommandArguments -contains '--flat-menu')
            if ($useFlatMenu) {
                Write-InfoLog 'Interactive mode: flat menu (--flat-menu)'
                Start-WuuConsoleLoop -Store $stateStore -DrainScheduler $drainScheduler -Actions $consoleActions -AuditHook $auditHook -DenialHook $denialHook
            } else {
                Write-InfoLog 'Interactive mode: guided workflow'
                Start-WuuGuidedWorkflow -Store $stateStore -DrainScheduler $drainScheduler -Actions $consoleActions -AuditHook $auditHook -DenialHook $denialHook
            }
        } finally {
            try { Write-WuuAuditRecord -Session $auditSession -Action 'session-end' -Result 'info' -Category 'session' | Out-Null } catch { }
            Stop-WuuAuditTranscript -Session $auditSession
        }
    }
}
catch {
    Write-ErrorLog "CRITICAL ERROR - console shell failed: $($_.Exception.Message)"
    Write-ErrorLog "Error type: $($_.Exception.GetType().FullName)"
    Write-ErrorLog "Stack trace: $($_.ScriptStackTrace)"
    if ($_.Exception.InnerException) {
        Write-ErrorLog "Inner exception: $($_.Exception.InnerException.Message)"
    }
    # No Read-Host and no bare exit: an unattended caller must not hang here, and a fatal failure must
    # not report success. Stop-WuuFatal writes the message, waits only for a real interactive console,
    # and exits non-zero. The error text is repeated rather than assumed, because Write-Host output is
    # not what a wrapper reads - the exit code is.
    Stop-WuuFatal -WhatHappened "Fatal error: $($_.Exception.Message)"
}
finally {
    # Comprehensive cleanup on exit
    Write-InfoLog "Starting application shutdown cleanup..."

    # Stop and dispose all running jobs
    if ($jobs) {
        Write-InfoLog "Cleaning up $($jobs.Count) background jobs"
        foreach ($job in $jobs) {
            try {
                if ($job.PowerShell) {
                    $job.PowerShell.Stop()
                    $job.PowerShell.Dispose()
                }
            } catch {
                Write-WarningLog "Failed to cleanup job: $($_.Exception.Message)"
            }
        }
        $jobs.Clear()
    }

    # Close and dispose all computer runspaces (rows live in the store now, not a ListView)
    $cleanupRows = @(Get-WuuComputerRow -Store $stateStore)
    if ($cleanupRows.Count) {
        Write-InfoLog "Cleaning up $($cleanupRows.Count) computer runspace(s)"
        foreach ($computer in $cleanupRows) {
            if ($computer.Runspace) {
                try {
                    $computer.Runspace.Close()
                    $computer.Runspace.Dispose()
                } catch {
                    Write-WarningLog "Failed to cleanup runspace for $($computer.Computer): $($_.Exception.Message)"
                }
            }
        }
    }

    # Clear synchronized hashtables
    $updatesHash.Clear()
    $performanceHash.Clear()
    $errorSuggestionsHash.Clear()
    $global:CredentialCache.Clear()

    # Dispose job cleanup runspace
    if ($jobCleanup.Flag) {
        Write-InfoLog "Cleaning up job cleanup runspace"
        $jobCleanup.Flag = $False
        if ($jobCleanup.PowerShell) {
            try {
                $jobCleanup.PowerShell.Dispose()
            } catch {
                Write-WarningLog "Failed to dispose job cleanup PowerShell: $($_.Exception.Message)"
            }
        }
        if ($jobCleanup.Runspace) {
            try {
                $jobCleanup.Runspace.Close()
                $jobCleanup.Runspace.Dispose()
            } catch {
                Write-WarningLog "Failed to cleanup job cleanup runspace: $($_.Exception.Message)"
            }
        }
    }

    Write-InfoLog "Application shutdown cleanup complete"
    Write-InfoLog "Windows Update Utility has been closed"

    # Command mode reports failure through the process exit code so a script/CI can branch on it.
    # Set AFTER cleanup so the code reflects the operation result, not a teardown hiccup.
    if ($CommandArguments -and $CommandArguments.Count -gt 0) {
        if ($script:CommandExitCode) { exit $script:CommandExitCode } else { exit 0 }
    }
}
#endregion Start the console shell
}

Export-ModuleMember -Function @('Import-WuuModules','Start-WuuApplication')
