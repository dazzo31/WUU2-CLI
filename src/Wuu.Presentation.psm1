#Requires -Version 5.1
<#
.DESCRIPTION
Presentation and status helpers for the console edition, extracted from Wuu.Core.psm1 (instructions SS8:
Core should become a bootstrap/orchestration layer, and SS7: presentation belongs to the console module).

WHY THIS MODULE AND NOT Wuu.Core. These seven helpers are the console edition's answer to the GUI's
dialog and status-window calls: status text, a password prompt, error/warning dialogs, and the
background-processing pause. They own no engine logic. Wuu.Console is the presentation layer, so that is
where they belong, next to the renderers and the input choke point they already depend on.

THE STATE STORE IS PASSED IN, NOT CAPTURED. In Wuu.Core these were closures over Start-WuuApplication's
`$stateStore`. A module cannot close over another scope, so the store arrives through
Initialize-WuuPresentation - the same shape as Initialize-WuuInputMode immediately below it, and the same
approach Wuu.Scheduler and Wuu.WindowsUpdate already use for their runspaces ("explicit context, never a
module global"). Initialize-WuuInputMode is called first so the presentation initializer does not have to
know about it, and both are called from Start-WuuApplication's startup path.
#>

# The store the status writers update. Module-scope, set once by Initialize-WuuPresentation, because
# Update-Status is called from 17 sites that have no reason to thread a store through their signatures.
$script:WuuPresentationStore = $null

function Initialize-WuuPresentation {
    <#
    .SYNOPSIS Hands the presentation helpers the state store they write status into.
    .DESCRIPTION Called once during startup, before any helper can run. Idempotent: a second call with
    $null is refused rather than silently detaching the store the status writers need.
    #>
    param([Parameter(Mandatory)][object]$StateStore)
    $script:WuuPresentationStore = $StateStore
}

# Function to update status text box
function Update-Status {
    param([string]$Message)
    try {
        # Console edition: store-held status text (renderer draws it); no dispatcher.
        if ($script:WuuPresentationStore) { $script:WuuPresentationStore.SetStatus($Message) }
    } catch {
        # Silently handle errors during shutdown
    }
}

# Function to update status text box with background priority
function Update-StatusBackground {
    param([string]$Message)
    try {
        # Console edition: same path as Update-Status - there is no UI-thread priority
        # distinction once the status is just a value in the store.
        if ($script:WuuPresentationStore) { $script:WuuPresentationStore.SetStatus($Message) }
    } catch {
        # Silently handle errors during shutdown
    }
}

# Console password prompt (replaces the WPF Show-PasswordPrompt dialog).
# Returns a SecureString, or $null if the operator cancelled (empty password).
#
# ROUTED THROUGH Read-WuuAnswer (the single input choke point) rather than calling Read-Host here.
# The project rule is that all input goes through the choke point because a screen calling Read-Host
# directly cannot be driven in non-interactive mode; the choke point's -Secure path is also the one
# that supplies a queued test answer, so a scripted run can exercise this prompt. A bare Read-Host
# here would block a command-mode run at the unlock prompt with no way to answer it.
function _WuuReadPassword {
    param([string]$Prompt = 'Password')
    $sec = $null
    try {
        $sec = Read-WuuAnswer -Prompt $Prompt -Secure
    } catch {
        # The choke point throws when a REQUIRED input is missing in non-interactive mode. That is the
        # correct outcome (fail the command rather than hang), so it is reported and turned into $null
        # for this caller's existing contract - never into a silent empty password.
        Write-ErrorLog "Secure password prompt failed: $($_.Exception.Message)"
        return $null
    }
    if ($null -eq $sec) { return $null }
    # -AsSecureString returns a SecureString; a queued non-interactive answer arrives as a plain
    # string. Convert so the caller always receives the type it expects (it calls Protect-Credential).
    if ($sec -is [System.Security.SecureString]) { return $sec }
    try {
        return (ConvertTo-SecureString -String ([string]$sec) -AsPlainText -Force)
    } catch {
        Write-ErrorLog "Could not convert the supplied password to a SecureString: $($_.Exception.Message)"
        return $null
    }
}

# Function to show message box and log error
function Show-ErrorDialog {
    # Console edition: the GUI's MessageBox is gone, and so is the WPF assembly it needed. A modal
    # dialog would be fatal in a HEADLESS tool - an unattended run would block forever with nobody
    # to click OK. The message is logged and printed instead. Kept rather than deleted: it is the
    # obvious thing for a future error path to call, and a caller that silently vanished would be
    # worse than one that prints.
    param(
        [string]$Message,
        [string]$Title = 'Error',
        [string]$LogMessage = '',
        [string]$Computer = ''
    )

    if ($LogMessage) {
        Write-ErrorLog $LogMessage -Computer $Computer
    } else {
        Write-ErrorLog $Message -Computer $Computer
    }

    Write-Host ''
    Write-Host ("  {0}: {1}" -f $Title, $Message) -ForegroundColor Red
}

# Function to show warning dialog and log
function Show-WarningDialog {
    # See the note on Show-ErrorDialog: console output, never a modal dialog.
    param(
        [string]$Message,
        [string]$Title = 'Warning',
        [string]$LogMessage = '',
        [string]$Computer = ''
    )

    if ($LogMessage) {
        Write-WarningLog $LogMessage -Computer $Computer
    } else {
        Write-WarningLog $Message -Computer $Computer
    }

    Write-Host ''
    Write-Host ("  {0}: {1}" -f $Title, $Message) -ForegroundColor Yellow
}

# Background processing control functions.
# The paused flag is the SHARED synchronized hashtable created by Wuu.Configuration, passed in at
# initialization rather than captured: the job-cleanup runspace reads the same object, so pausing has
# to flip one instance rather than set a copy.
$script:WuuBackgroundProcessing = $null

function Initialize-WuuBackgroundProcessing {
    <#
    .SYNOPSIS Hands the pause helpers the shared synchronized flag they set.
    .DESCRIPTION Separate from Initialize-WuuPresentation because it is a different object with a
    different lifecycle: the flag is created by Wuu.Configuration and shared with a runspace.
    #>
    param([Parameter(Mandatory)][object]$BackgroundProcessing)
    $script:WuuBackgroundProcessing = $BackgroundProcessing
}

function Suspend-BackgroundProcessing {
    param(
        [string]$Reason = 'User operation'
    )

    Write-InfoLog "Suspending background processing: $Reason"

    # Temporarily pause the job cleanup routine
    if ($script:WuuBackgroundProcessing) { $script:WuuBackgroundProcessing.Suspended = $true }

    # Update status to show background processing is paused
    Update-Status "â¸ï¸ Background processing paused for $Reason..."

    # Give a moment for any current operations to complete
    Start-Sleep -Milliseconds 500
}

function Resume-BackgroundProcessing {
    param(
        [string]$CompletedOperation = 'User operation'
    )

    Write-InfoLog "Resuming background processing after: $CompletedOperation"

    # Resume the job cleanup routine
    if ($script:WuuBackgroundProcessing) { $script:WuuBackgroundProcessing.Suspended = $false }

    # Update status to show background processing is resumed
    Update-Status "âœ… Background processing resumed after $CompletedOperation"
}

Export-ModuleMember -Function @(
    'Initialize-WuuPresentation'
    'Initialize-WuuBackgroundProcessing'
    'Update-Status'
    'Update-StatusBackground'
    '_WuuReadPassword'
    'Show-ErrorDialog'
    'Show-WarningDialog'
    'Suspend-BackgroundProcessing'
    'Resume-BackgroundProcessing'
)
