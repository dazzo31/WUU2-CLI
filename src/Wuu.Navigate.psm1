#Requires -Version 5.1
<#
.DESCRIPTION
Guided interactive workflow for WUU2-CLI.

Spec: docs/INTERACTIVE_UI_SPEC.md (sections 2, 3, 5, 8, 9, 17-22, 28).

THE PROBLEM THIS SOLVES
-----------------------
The pre-existing interactive UI was a flat list of 25 operations. It exposed "Download updates"
before the operator had established which computers WUU2 was managing, and it required the operator
to already understand the check/download/install/restart/verify relationship. Spec section 9:
do not present a flat list of everything at the top level.

THE SHAPE
---------
A small state machine. Each screen renders and returns the ID of the next screen, so the flow is
data rather than control flow. That is what makes it testable: a screen can be driven with a
scripted answer and its next-state asserted, without a console and without blocking.

    ACQUIRE -> REVIEW -> DASHBOARD -> <category> -> ... -> DASHBOARD

WHAT THIS MODULE DOES NOT DO
----------------------------
It does not implement any update operation. Every leaf delegates to the SAME handlers the flat menu
and the command surface already call ($ctx.EventGetUpdates etc). Spec section 23: reuse the
existing action/engine layer. If you find yourself writing update logic here, it is in the wrong
file.

TESTABILITY CONTRACT (do not break this)
----------------------------------------
- Every screen reads input ONLY through Read-WuuAnswer / Read-WuuYesNo / Read-WuuSelection, which
  honour non-interactive mode. A screen that calls Read-Host directly cannot be tested and will
  hang a scripted run - the exact defect that hid the console-shell crash for two releases.
- Screens never exit the process. They return a state; the loop decides.
#>

Set-StrictMode -Version 2.0

#region Navigation tree (spec 9)

function Get-WuuNavigationTree {
    <#
    .SYNOPSIS The grouped top-level navigation.
    .DESCRIPTION
    Spec 9 requires operations be grouped into six categories plus Save and Exit, rather than a
    flat command list. Each leaf's `Handler` is the NAME of a $consoleActions key - resolved at
    dispatch time, never a captured scriptblock, so a missing handler is a diagnosable error
    instead of a silent no-op.
    #>
    @(
        @{ Id = 'UPDATES';     Key = '1'; Label = 'Update management' }
        @{ Id = 'COMPUTERS';   Key = '2'; Label = 'Computer management' }
        @{ Id = 'DEPLOYMENT';  Key = '3'; Label = 'Deployment phases' }
        @{ Id = 'CREDENTIALS'; Key = '4'; Label = 'Credentials' }
        @{ Id = 'DIAGNOSTICS'; Key = '5'; Label = 'Diagnostics' }
        @{ Id = 'REPORTS';     Key = '6'; Label = 'Reports / audit' }
        @{ Id = 'SAVE';        Key = '7'; Label = 'Save computer set' }
        @{ Id = 'ADVANCED';    Key = '9'; Label = 'Advanced (all operations)' }
        @{ Id = 'EXIT';        Key = 'q'; Label = 'Exit' }
    )
}

function Get-WuuUpdateManagementMenu {
    <#
    .SYNOPSIS The update lifecycle, in order (spec 10).
    .DESCRIPTION
    Spec 10: "Make the logical lifecycle explicit - do not make the user infer this relationship
    from separate commands." The ORDER here is the workflow:
        CHECK -> REVIEW -> DOWNLOAD -> INSTALL -> REBOOT -> VERIFY
    so it is rendered in that order rather than alphabetically.
    #>
    @(
        @{ Key = '1'; Label = 'Check for updates';        Handler = 'EventGetUpdates';                Mutating = $false }
        @{ Key = '2'; Label = 'Review available updates'; Handler = 'EventShowAvailableUpdates';      Mutating = $false }
        @{ Key = '3'; Label = 'Download updates';         Handler = 'EventDownloadUpdates';           Mutating = $true }
        @{ Key = '4'; Label = 'Install updates';          Handler = 'EventInstallUpdates';            Mutating = $true }
        @{ Key = '5'; Label = 'Restart computers';        Handler = 'EventRestartComputer';           Mutating = $true }
        @{ Key = 'b'; Label = 'Back';                     Handler = '';                               Mutating = $false }
    )
}

function Get-WuuComputerManagementMenu {
    @(
        @{ Key = '1'; Label = 'Add computers manually';        Handler = 'EventAddComputer';             Mutating = $false }
        @{ Key = '2'; Label = 'Import computers from file';    Handler = 'EventAddFile';                 Mutating = $false }
        @{ Key = '3'; Label = 'Add from Active Directory';     Handler = 'EventAddAD';                   Mutating = $false }
        @{ Key = '4'; Label = 'Remove computers';              Handler = 'EventRemoveSelected';          Mutating = $false }
        @{ Key = '5'; Label = 'Assign phase';                  Handler = 'EventAssignPhaseInteractive';  Mutating = $false }
        @{ Key = '6'; Label = 'Show computers in a phase';     Handler = 'EventShowByPhase';             Mutating = $false }
        @{ Key = '7'; Label = 'Remove offline computers';      Handler = 'EventRemoveOfflineComputer';   Mutating = $false }
        @{ Key = '8'; Label = 'Clear computer list';           Handler = 'ClearComputerList';            Mutating = $false }
        @{ Key = '9'; Label = 'Export list to file';           Handler = 'EventSaveComputerList';        Mutating = $false }
        @{ Key = 'l'; Label = 'Load saved computer set';       Handler = 'EventLoadConfig';              Mutating = $false }
        @{ Key = 's'; Label = 'Save computer set';             Handler = 'EventSaveConfig';              Mutating = $false }
        @{ Key = 'b'; Label = 'Back';                          Handler = '';                             Mutating = $false }
    )
}

function Get-WuuDeploymentMenu {
    @(
        @{ Key = '1'; Label = 'Show phase status';         Handler = 'EventShowByPhase';             Mutating = $false }
        @{ Key = '2'; Label = 'Assign computers to phase'; Handler = 'EventAssignPhaseInteractive';  Mutating = $false }
        @{ Key = 'b'; Label = 'Back';                      Handler = '';                             Mutating = $false }
    )
}

function Get-WuuDiagnosticsMenu {
    @(
        @{ Key = '1'; Label = 'Show errors';               Handler = 'GetErrors';                    Mutating = $false }
        @{ Key = '2'; Label = 'View Windows Update log';   Handler = 'EventViewUpdateLog';           Mutating = $false }
        @{ Key = '3'; Label = 'Update history';            Handler = 'EventShowUpdateHistory';       Mutating = $false }
        @{ Key = '4'; Label = 'Show installed updates';    Handler = 'EventShowInstalledUpdates';    Mutating = $false }
        @{ Key = '5'; Label = 'Audit WSUS updates';        Handler = 'EventAuditWSUSUpdates';        Mutating = $false }
        @{ Key = '6'; Label = 'Windows Update service';    Handler = 'EventWUServiceActionInteractive'; Mutating = $true }
        @{ Key = 'b'; Label = 'Back';                      Handler = '';                             Mutating = $false }
    )
}

function Get-WuuCredentialMenu {
    @(
        @{ Key = '1'; Label = 'Set domain credentials';    Handler = 'EventSetDomainCredentials';    Mutating = $false }
        @{ Key = 'b'; Label = 'Back';                      Handler = '';                             Mutating = $false }
    )
}

function Get-WuuReportsMenu {
    <#
    .SYNOPSIS Reporting / audit navigation (spec 20).
    .DESCRIPTION
    The audit entries are handled HERE rather than delegated to a $consoleActions handler, because
    `wuu audit verify|show|export` are handled by Invoke-WuuAuditCommand in the command layer - they
    are not action-layer operations. Delegating them to a non-existent handler key would be a dead
    menu entry (the exact defect that made AD import unreachable).
    #>
    @(
        @{ Key = '1'; Label = 'View audit history';        AuditSubVerb = 'show';   Mutating = $false }
        @{ Key = '2'; Label = 'Verify audit chain';        AuditSubVerb = 'verify'; Mutating = $false }
        @{ Key = '3'; Label = 'Export audit bundle';       AuditSubVerb = 'export'; Mutating = $false }
        @{ Key = '4'; Label = 'Export computer list';      Handler = 'EventSaveComputerList'; Mutating = $false }
        @{ Key = 'b'; Label = 'Back';                      Mutating = $false }
    )
}

#endregion Navigation tree

#region Screens

function Write-WuuHeader {
    param([string]$Title, [switch]$NoUnderline)
    Write-Host ''
    Write-Host "  $Title" -ForegroundColor White
    if (-not $NoUnderline) { Write-Host ('  ' + ('=' * [Math]::Min($Title.Length, 60))) -ForegroundColor DarkCyan }
}

function Show-WuuAcquisitionScreen {
    <#
    .SYNOPSIS Spec 3: the startup screen when no computer set exists.
    .DESCRIPTION
    Returns the next state. Deliberately offers NO update operations - spec 3: "the application must
    not expose update/deployment operations until a computer set exists."
    #>
    param([Parameter(Mandatory)]$Ctx)

    Write-WuuHeader 'WUU2 - Windows Update Utility'
    $count = Get-WuuComputerSetCount -Set $Ctx.Set
    if ($count -gt 0) {
        Write-Host "  Computer set: $count computer(s) loaded." -ForegroundColor Green
        Write-Host ''
        Write-Host '  What would you like to do?' -ForegroundColor White
        Write-Host '    1. Add computers manually'
        Write-Host '    2. Import computer list'
        Write-Host '    3. Add computers from Active Directory'
        Write-Host '    4. Load saved computer set'
        Write-Host '    5. Continue to dashboard'
        Write-Host '    6. Exit'
    } else {
        Write-Host '  No computer set is loaded.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  What would you like to do?' -ForegroundColor White
        Write-Host '    1. Add computers manually'
        Write-Host '    2. Import computer list'
        Write-Host '    3. Add computers from Active Directory'
        Write-Host '    4. Load saved computer set'
        Write-Host '    5. Exit'
    }

    $hasSet = ($count -gt 0)
    $choice = [string](Read-WuuAnswer -Prompt '  Selection' -Default '')

    switch ($choice.Trim().ToLowerInvariant()) {
        '1' { return 'MANUAL' }
        '2' { return 'IMPORT' }
        '3' { Invoke-WuuGuidedHandler -Ctx $Ctx -Handler 'EventAddAD'; return 'ACQUIRE' }
        '4' { Invoke-WuuGuidedHandler -Ctx $Ctx -Handler 'EventLoadConfig'; return 'ACQUIRE' }
        '5' { if ($hasSet) { return 'REVIEW' } else { return 'EXIT' } }
        '6' { return 'EXIT' }
        'q' { return 'EXIT' }
        default {
            Write-Host "  Unknown selection '$choice'." -ForegroundColor Yellow
            return 'ACQUIRE'
        }
    }
}

function Show-WuuManualEntryScreen {
    <#
    .SYNOPSIS Spec 4.1: manual entry, with review before committing.
    .DESCRIPTION
    Parses what was pasted, SHOWS the parse result, and only then offers add / edit / cancel - the
    spec's "the user must be able to review before committing".
    #>
    param([Parameter(Mandatory)]$Ctx)

    Write-WuuHeader 'ADD COMPUTERS MANUALLY'
    Write-Host '  Enter computer names.'
    Write-Host ''
    Write-Host '  You can enter multiple names separated by commas, spaces, or new lines.' -ForegroundColor DarkGray

    $text = [string](Read-WuuAnswer -Prompt '  Computer names' -Default '')
    # @() is load-bearing: without it, entering ONE name yields a String, and `.Count` then throws
    # "The property 'Count' cannot be found on this object".
    $names = @(Split-WuuComputerNames -Text $text)
    if ($names.Count -eq 0) {
        Write-Host '  Nothing entered.' -ForegroundColor Yellow
        return 'ACQUIRE'
    }

    Write-Host ''
    Write-Host '  Computers found:' -ForegroundColor White
    foreach ($n in $names) {
        $ok = Test-WuuComputerName -Name $n
        if ($ok) { Write-Host "    $n" }
        else { Write-Host "    $n  (invalid name)" -ForegroundColor Red }
    }
    $validCount = @($names | Where-Object { Test-WuuComputerName -Name $_ }).Count
    Write-Host ''
    Write-Host "  $validCount computer(s) entered." -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '    1. Add these computers'
    Write-Host '    2. Edit list'
    Write-Host '    3. Cancel'

    $choice = [string](Read-WuuAnswer -Prompt '  Selection' -Default '')
    switch ($choice.Trim().ToLowerInvariant()) {
        '1' {
            $res = Add-WuuComputerSetNames -Set $Ctx.Set -Names $names
            Write-Host ''
            Write-Host ("  Added:      {0}" -f $res.AddedCount) -ForegroundColor Green
            if (@($res.Duplicates).Count) { Write-Host ("  Duplicates: {0}  ({1})" -f @($res.Duplicates).Count, (@($res.Duplicates) -join ', ')) -ForegroundColor Yellow }
            if (@($res.Invalid).Count)    { Write-Host ("  Invalid:    {0}  ({1})" -f @($res.Invalid).Count, (@($res.Invalid) -join ', ')) -ForegroundColor Red }
            return 'REVIEW'
        }
        '2' { return 'MANUAL' }
        default { return 'ACQUIRE' }
    }
}

function Select-WuuImportColumn {
    <#
    .SYNOPSIS Detects CSV columns and resolves which one holds the computer name.
    .DESCRIPTION
    Spec 4.2: "Detect available columns. Identify the computer-name column. Allow the user to
    confirm the selected column."

    Detection picks an obvious header first (Computer/Name/Hostname/Server/CN), else falls back to
    the FIRST column - but the fallback is CONFIRMED with the operator rather than assumed, because
    guessing wrong on a 200-row CSV silently imports the wrong field as host names.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Header,
        [string]$Preferred
    )

    if ($Preferred) {
        $idx = [array]::IndexOf($Header, $Preferred)
        if ($idx -ge 0) { return $idx }
    }
    $candidates = @('computer', 'computername', 'name', 'hostname', 'host', 'server', 'cn', 'device')
    for ($i = 0; $i -lt $Header.Count; $i++) {
        if ($candidates -contains $Header[$i].Trim().ToLowerInvariant()) { return $i }
    }
    return 0
}

function Show-WuuImportScreen {
    <#
    .SYNOPSIS Spec 4.2: file import with explicit valid / duplicate / invalid reporting.
    .DESCRIPTION
    Supports TXT (one name per line, or comma/space separated), CSV (with column selection), and the
    saved WUU2 configuration (which delegates to the existing loader rather than being reimplemented).
    #>
    param([Parameter(Mandatory)]$Ctx)

    Write-WuuHeader 'IMPORT COMPUTERS'
    Write-Host '    1. TXT'
    Write-Host '    2. CSV'
    Write-Host '    3. Saved WUU2 configuration'
    Write-Host '    4. Cancel'

    $kind = [string](Read-WuuAnswer -Prompt '  Selection' -Default '')
    switch ($kind.Trim().ToLowerInvariant()) {
        '3' { Invoke-WuuGuidedHandler -Ctx $Ctx -Handler 'EventLoadConfig'; return 'ACQUIRE' }
        '4' { return 'ACQUIRE' }
        '1' { }
        '2' { }
        default { Write-Host '  Unknown selection.' -ForegroundColor Yellow; return 'ACQUIRE' }
    }

    $path = [string](Read-WuuAnswer -Prompt '  Path to file' -Default '')
    if ([string]::IsNullOrWhiteSpace($path)) { Write-Host '  No path given.' -ForegroundColor Yellow; return 'ACQUIRE' }
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host ("  File not found: {0}" -f $path) -ForegroundColor Red
        return 'ACQUIRE'
    }

    $lines = @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) { Write-Host '  File is empty.' -ForegroundColor Yellow; return 'ACQUIRE' }

    $names = @()
    if ($kind.Trim() -eq '2') {
        # ---- CSV: split the header, resolve the name column, then read that column ----------
        $header = @($lines[0] -split '[,;\t]' | ForEach-Object { $_.Trim().Trim('"') })
        $idx = Select-WuuImportColumn -Header $header
        Write-Host ''
        Write-Host ("  Detected {0} column(s): {1}" -f $header.Count, ($header -join ' | ')) -ForegroundColor DarkGray
        Write-Host ("  Computer-name column: [{0}] {1}" -f $idx, $header[$idx]) -ForegroundColor Cyan

        $confirm = [string](Read-WuuAnswer -Prompt '  Use this column? [Y/n]' -Default 'y' -HasDefault)
        if ($confirm.Trim().ToLowerInvariant() -match '^n') {
            $pick = [string](Read-WuuAnswer -Prompt '  Enter column number' -Default '0')
            $parsed = 0
            if ([int]::TryParse($pick.Trim(), [ref]$parsed) -and $parsed -ge 0 -and $parsed -lt $header.Count) { $idx = $parsed }
            else { Write-Host '  Invalid column - cancelled.' -ForegroundColor Yellow; return 'ACQUIRE' }
        }
        foreach ($line in ($lines | Select-Object -Skip 1)) {
            $cells = @($line -split '[,;\t]')
            if ($idx -lt $cells.Count) { $names += $cells[$idx].Trim().Trim('"') }
        }
    } else {
        # ---- TXT: one per line, but tolerate comma/space separated lines --------------------
        foreach ($line in $lines) { $names += @(Split-WuuComputerNames -Text $line) }
    }

    $res = Add-WuuComputerSetNames -Set $Ctx.Set -Names $names -StateSource 'Import'

    Write-Host ''
    Write-Host ("  Imported {0} entr(ies)." -f $names.Count) -ForegroundColor White
    Write-Host ("    Valid:      {0}" -f $res.AddedCount) -ForegroundColor Green
    Write-Host ("    Duplicates: {0}" -f @($res.Duplicates).Count) -ForegroundColor Yellow
    Write-Host ("    Invalid:    {0}" -f @($res.Invalid).Count) -ForegroundColor Red

    # Spec 4.2: "Never silently discard invalid or duplicate entries" - so list them.
    if (@($res.Duplicates).Count) { Write-Host ("      duplicates: {0}" -f (@($res.Duplicates) | Select-Object -First 10 -join ', ')) -ForegroundColor DarkYellow }
    if (@($res.Invalid).Count)    { Write-Host ("      invalid:    {0}" -f (@($res.Invalid) | Select-Object -First 10 -join ', ')) -ForegroundColor DarkRed }

    Write-Host ''
    Write-Host '    1. Review computer set'
    Write-Host '    2. Continue adding'
    Write-Host '    3. Cancel'
    $choice = [string](Read-WuuAnswer -Prompt '  Selection' -Default '1')
    switch ($choice.Trim().ToLowerInvariant()) {
        '2' { return 'IMPORT' }
        '3' { return 'ACQUIRE' }
        default { return 'REVIEW' }
    }
}

function Show-WuuComputerSetReviewScreen {
    <#
    .SYNOPSIS Spec 5: review the set before beginning update operations.
    #>
    param([Parameter(Mandatory)]$Ctx)

    $computers = @(Get-WuuComputerSetComputers -Set $Ctx.Set)
    Write-WuuHeader 'COMPUTER SET REVIEW'
    Write-Host ("  Computers: {0}" -f $computers.Count) -ForegroundColor White
    Write-Host ''

    if ($computers.Count -eq 0) {
        Write-Host '  (no computers)' -ForegroundColor DarkGray
    } else {
        $fmt = "  {0,4} {1,-24} {2}"
        Write-Host ($fmt -f '#', 'COMPUTER', 'PHASE') -ForegroundColor DarkCyan
        $i = 0
        foreach ($c in $computers) {
            $i++
            Write-Host ($fmt -f $i, $c.Computer, $c.Phase)
        }
    }

    Write-Host ''
    Write-Host '  Actions:'
    Write-Host '    1. Add computers           6. Show computers in a phase'
    Write-Host '    2. Remove computers        7. Save computer set'
    Write-Host '    3. Assign phase            8. Continue'
    Write-Host '    4. Configure credentials   9. Cancel'
    Write-Host '    5. Add from Active Directory'

    $choice = [string](Read-WuuAnswer -Prompt '  Selection' -Default '8')
    switch ($choice.Trim().ToLowerInvariant()) {
        '1' { return 'MANUAL' }
        '2' { Invoke-WuuGuidedHandler -Ctx $Ctx -Handler 'EventRemoveSelected'; return 'REVIEW' }
        '3' { Invoke-WuuGuidedHandler -Ctx $Ctx -Handler 'EventAssignPhaseInteractive'; return 'REVIEW' }
        '4' { Invoke-WuuGuidedHandler -Ctx $Ctx -Handler 'EventSetDomainCredentials'; return 'REVIEW' }
        '5' { Invoke-WuuGuidedHandler -Ctx $Ctx -Handler 'EventAddAD'; return 'REVIEW' }
        '6' { Invoke-WuuGuidedHandler -Ctx $Ctx -Handler 'EventShowByPhase'; return 'REVIEW' }
        '7' { Invoke-WuuGuidedHandler -Ctx $Ctx -Handler 'EventSaveConfig'; $Ctx.Set.IsSaved = $true; return 'REVIEW' }
        '8' { if ($computers.Count -eq 0) { Write-Host '  No computers - add some first.' -ForegroundColor Yellow; return 'REVIEW' } else { return 'DASHBOARD' } }
        default { return 'ACQUIRE' }
    }
}

function Show-WuuDashboardScreen {
    <#
    .SYNOPSIS Spec 8: the main dashboard.
    .DESCRIPTION
    Must answer: what am I managing, what state is it in, what updates are pending, what is running,
    and what should I do next. The phase summary is spec 13's "phases visible as part of deployment
    rather than hidden configuration".
    #>
    param([Parameter(Mandatory)]$Ctx)

    $summary = Get-WuuComputerSetSummary -Set $Ctx.Set

    Write-WuuHeader 'WUU2'
    Write-Host ("  COMPUTER SET: {0}{1}" -f $summary.Name, $(if ($Ctx.Set.IsSaved) { '' } else { '  (unsaved)' })) -ForegroundColor White
    Write-Host ("  Computers: {0}" -f $summary.Total)
    if ($Ctx.LastOperation) { Write-Host ("  Last operation: {0}" -f $Ctx.LastOperation) -ForegroundColor DarkGray }

    # The live table (existing renderer - reused, not reimplemented).
    Write-WuuStatusTable -Store $Ctx.Set.Store

    # Phase visibility (spec 13).
    $phases = @(Get-WuuComputerSetPhases -Set $Ctx.Set | Where-Object { -not $_.IsEmpty })
    if ($phases.Count -gt 0) {
        Write-Host '  PHASES' -ForegroundColor DarkCyan
        foreach ($p in $phases) {
            $status = if ($p.IsComplete) { 'Complete' } else { "$($p.Complete)/$($p.Computers) complete" }
            Write-Host ("    Phase {0}: {1} computer(s)  {2}" -f $p.Phase, $p.Computers, $status)
        }
        Write-Host ''
    }

    if ($summary.IsEmpty) {
        Write-Host '  No computers in the set.' -ForegroundColor Yellow
    } elseif ($summary.Error -gt 0 -or $summary.Timeout -gt 0) {
        Write-Host ("  Attention: {0} errored, {1} timed out." -f $summary.Error, $summary.Timeout) -ForegroundColor Yellow
    } elseif ($summary.WithUpdates -gt 0) {
        Write-Host ("  {0} computer(s) have updates available." -f $summary.WithUpdates) -ForegroundColor Yellow
    } else {
        Write-Host '  No updates currently outstanding.' -ForegroundColor Green
    }

    $tree = Get-WuuNavigationTree
    $fmt = "    [{0}] {1}"
    Write-Host ''
    foreach ($node in $tree) { Write-Host ($fmt -f $node.Key, $node.Label) }

    $choice = [string](Read-WuuAnswer -Prompt '  Selection' -Default '')
    $sel = $choice.Trim().ToLowerInvariant()
    foreach ($node in $tree) {
        if ($node.Key -eq $sel) { return $node.Id }
    }
    Write-Host "  Unknown selection '$choice'." -ForegroundColor Yellow
    return 'DASHBOARD'
}

function Show-WuuCategoryScreen {
    <#
    .SYNOPSIS Renders a grouped submenu and dispatches the chosen handler.
    .DESCRIPTION
    Shared by every category so grouping logic exists once. Handlers are resolved by NAME against
    $Ctx.Actions at dispatch time; a name with no handler is reported as a defect rather than
    silently doing nothing.

    Returns the state to return to - always the category itself (so the operator can run several
    operations without re-navigating), except Back which returns to the dashboard. Deriving the
    return state from the TITLE was a bug: 'UPDATE MANAGEMENT' does not equal the state id
    'UPDATES', so every dispatch fell into the unknown-state branch.
    #>
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][string]$State
    )

    Write-WuuHeader $Title
    foreach ($item in $Items) {
        $mark = if ($item.Mutating) { '*' } else { ' ' }
        Write-Host ("    [{0}] {1} {2}" -f $item.Key.PadLeft(2), $mark, $item.Label)
    }
    Write-Host '    (* = changes remote state)' -ForegroundColor DarkGray

    $choice = [string](Read-WuuAnswer -Prompt '  Selection' -Default '')
    $sel = $choice.Trim().ToLowerInvariant()
    foreach ($item in $Items) {
        if ($item.Key -eq $sel) {
            if ($sel -eq 'b' -or $sel -eq 'q') { return 'DASHBOARD' }
            # Audit subverbs are command-layer operations, not action-layer handlers (spec 20).
            if ($item.ContainsKey('AuditSubVerb')) {
                Invoke-WuuAuditSubVerb -Ctx $Ctx -SubVerb $item.AuditSubVerb
                return $State
            }
            if ($item.Handler) {
                Invoke-WuuGuidedHandler -Ctx $Ctx -Handler $item.Handler -Mutating ([bool]$item.Mutating)
            }
            return $State
        }
    }
    Write-Host "  Unknown selection '$choice'." -ForegroundColor Yellow
    return $State
}

function Invoke-WuuAuditSubVerb {
    <# Runs `audit verify|show|export` via the same path the command surface uses. #>
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$SubVerb)
    try {
        $null = Invoke-WuuAuditCommand -SubVerb $SubVerb
    } catch {
        Write-Host ("  audit {0} failed: {1}" -f $SubVerb, $_.Exception.Message) -ForegroundColor Red
    }
}

function Invoke-WuuGuidedHandler {
    <#
    .SYNOPSIS Dispatches one leaf operation through the existing action layer.
    .DESCRIPTION
    Spec 23/24: the guided UI and the command surface must invoke the SAME operations. This resolves
    the handler by name out of $Ctx.Actions - the identical object the flat menu and the command
    table dispatch to. No operation is implemented here.

    A missing handler is a DEFECT, not a no-op: the AD-import handler existed for months but was
    never wired into any menu, so the feature was unreachable while appearing implemented. That is
    why this reports loudly instead of returning quietly.

    Mutating operations are routed through the audit choke point ($Ctx.AuditHook), so a change made
    from the guided UI is recorded exactly like one made from the command line.
    #>
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$Handler,
        [bool]$Mutating = $false
    )

    if (-not $Ctx.Actions.ContainsKey($Handler)) {
        Write-Host ("  DEFECT: no handler named '{0}'. This menu entry is wired to nothing." -f $Handler) -ForegroundColor Red
        return
    }

    if ($Mutating) {
        if (-not $Ctx.AuditHook) {
            Write-Host '  WARNING: auditing is not active, so this change will not be recorded.' -ForegroundColor Yellow
            & $Ctx.Actions[$Handler]
            return
        }
        $reason = [string](Read-WuuAnswer -Prompt '  Reason for this change (recorded in the audit trail)' -Default '')
        if ([string]::IsNullOrWhiteSpace($reason)) {
            Write-Host '  A reason is required for audited changes - operation cancelled.' -ForegroundColor Yellow
            if ($Ctx.DenialHook) {
                try { & $Ctx.DenialHook $Handler 'reason not supplied (cancelled at prompt)' | Out-Null } catch { }
            }
            return
        }
        & $Ctx.AuditHook $Handler $reason $Ctx.Actions[$Handler] | Out-Null
        return
    }

    & $Ctx.Actions[$Handler]
}

function Show-WuuAdvancedScreen {
    <#
    .SYNOPSIS The pre-existing flat 25-operation menu, one level down.
    .DESCRIPTION
    Spec 9 forbids the flat list at the TOP level, which grouping satisfies. But the flat list is
    genuinely useful to an operator who already knows WUU2, and removing it would reduce capability
    (against the spirit of spec 27). So it is retained here, explicitly labelled, rather than
    deleted.
    #>
    param([Parameter(Mandatory)]$Ctx)

    Write-WuuHeader 'ADVANCED - ALL OPERATIONS'
    Write-Host '  The full flat operation list, for operators who already know WUU2.' -ForegroundColor DarkGray
    Write-WuuMenu -Store $Ctx.Set.Store

    $choice = [string](Read-WuuAnswer -Prompt '  Selection' -Default '')
    $sel = $choice.Trim().ToLowerInvariant()
    if ($sel -eq 'q') { return 'EXIT' }
    if ($sel -eq 'b') { return 'DASHBOARD' }

    foreach ($a in (Get-WuuMenuActions)) {
        if ($a.Key -eq $sel) {
            if ($a.Mutating) { Invoke-WuuGuidedHandler -Ctx $Ctx -Handler $a.Handler -Mutating $true }
            else { & $a.Run $Ctx.Actions }
            return 'ADVANCED'
        }
    }
    Write-Host "  Unknown selection '$choice'." -ForegroundColor Yellow
    return 'ADVANCED'
}

#endregion Screens

#region Workflow loop

function Start-WuuGuidedWorkflow {
    <#
    .SYNOPSIS Runs the guided interactive workflow (spec 2 state machine).
    .DESCRIPTION
    The loop is trivial by design: each screen returns the next state, so the flow is data rather
    than nested control flow. That is what makes it drivable from a test.

    Screens are dispatched from a hashtable so a missing state is reported rather than hanging.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Store,
        [Parameter(Mandatory)][scriptblock]$DrainScheduler,
        [Parameter(Mandatory)][hashtable]$Actions,
        [scriptblock]$AuditHook,
        [scriptblock]$DenialHook,
        [string]$ComputerSetName = 'Unsaved computer set'
    )

    $set = New-WuuComputerSet -Store $Store -Name $ComputerSetName
    $ctx = [pscustomobject]@{
        Set           = $set
        Store         = $Store
        Actions       = $Actions
        AuditHook     = $AuditHook
        DenialHook    = $DenialHook
        LastOperation = ''
        Quit          = $false
    }

    # Spec 3: never assume a computer set exists. Start at acquisition when empty.
    $state = if ((Get-WuuComputerSetCount -Set $set) -gt 0) { 'DASHBOARD' } else { 'ACQUIRE' }

    while ($state -ne 'EXIT') {
        # Drain queued work each tick - same reason as the flat menu: a console blocked in a prompt
        # has no message loop, so the scheduler must be polled by this loop.
        try { & $DrainScheduler } catch { Write-Warning "Scheduler tick failed: $($_.Exception.Message)" }

        switch ($state) {
            'ACQUIRE'      { $state = Show-WuuAcquisitionScreen -Ctx $ctx }
            'MANUAL'       { $state = Show-WuuManualEntryScreen -Ctx $ctx }
            'IMPORT'       { $state = Show-WuuImportScreen -Ctx $ctx }
            'REVIEW'       { $state = Show-WuuComputerSetReviewScreen -Ctx $ctx }
            'DASHBOARD'    { $state = Show-WuuDashboardScreen -Ctx $ctx }
            'UPDATES'      { $state = Show-WuuCategoryScreen -Ctx $ctx -Title 'UPDATE MANAGEMENT' -Items @(Get-WuuUpdateManagementMenu) -State 'UPDATES' }
            'COMPUTERS'    { $state = Show-WuuCategoryScreen -Ctx $ctx -Title 'COMPUTER MANAGEMENT' -Items @(Get-WuuComputerManagementMenu) -State 'COMPUTERS' }
            'DEPLOYMENT'   { $state = Show-WuuCategoryScreen -Ctx $ctx -Title 'DEPLOYMENT PHASES' -Items @(Get-WuuDeploymentMenu) -State 'DEPLOYMENT' }
            'CREDENTIALS'  { $state = Show-WuuCategoryScreen -Ctx $ctx -Title 'CREDENTIALS' -Items @(Get-WuuCredentialMenu) -State 'CREDENTIALS' }
            'DIAGNOSTICS'  { $state = Show-WuuCategoryScreen -Ctx $ctx -Title 'DIAGNOSTICS' -Items @(Get-WuuDiagnosticsMenu) -State 'DIAGNOSTICS' }
            'REPORTS'      { $state = Show-WuuCategoryScreen -Ctx $ctx -Title 'REPORTS / AUDIT' -Items @(Get-WuuReportsMenu) -State 'REPORTS' }
            'ADVANCED'     { $state = Show-WuuAdvancedScreen -Ctx $ctx }
            'SAVE'         { Invoke-WuuGuidedHandler -Ctx $ctx -Handler 'EventSaveConfig'; $ctx.Set.IsSaved = $true; $state = 'DASHBOARD' }
            default {
                Write-Host ("  DEFECT: unknown workflow state '{0}' - returning to dashboard." -f $state) -ForegroundColor Red
                $state = 'DASHBOARD'
            }
        }
    }

    Write-Host ''
    Write-Host '  Shutting down...' -ForegroundColor DarkGray
}

#endregion Workflow loop

Export-ModuleMember -Function @(
    'Get-WuuNavigationTree'
    'Get-WuuUpdateManagementMenu'
    'Get-WuuComputerManagementMenu'
    'Get-WuuDeploymentMenu'
    'Get-WuuDiagnosticsMenu'
    'Get-WuuCredentialMenu'
    'Get-WuuReportsMenu'
    'Select-WuuImportColumn'
    'Show-WuuAcquisitionScreen'
    'Show-WuuManualEntryScreen'
    'Show-WuuImportScreen'
    'Show-WuuComputerSetReviewScreen'
    'Show-WuuDashboardScreen'
    'Show-WuuCategoryScreen'
    'Show-WuuAdvancedScreen'
    'Invoke-WuuGuidedHandler'
    'Invoke-WuuAuditSubVerb'
    'Start-WuuGuidedWorkflow'
)
