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
    Spec 9 requires operations be grouped into categories rather than exposed as a flat command
    list. The taxonomy is FIVE functional categories - updates/deployment, the computer fleet,
    diagnostics, reports, and settings - plus Advanced (the retained flat list) and Exit.

    Five rather than the earlier six-plus-Save because the previous tree had grown a category per
    FEATURE (Automation, Credentials, Deployment phases), and "Deployment phases" was not a domain
    an operator thinks in - it is part of rolling out updates, so it now lives in Updates. Phase
    membership is part of managing the fleet, so it also appears in Computer fleet. Saving the set
    is persistence of the fleet, so it lives there too instead of consuming a top-level slot.

    Nothing was removed by the regroup: every operation the old tree reached is still reachable,
    and the flat list remains available under Advanced, so no capability depends on the taxonomy.

    Each leaf's `Handler` is the NAME of a $consoleActions key - resolved at dispatch time, never a
    captured scriptblock, so a missing handler is a diagnosable error instead of a silent no-op.
    #>
    @(
        @{ Id = 'UPDATES';     Key = '1'; Label = 'Updates & deployment' }
        @{ Id = 'COMPUTERS';   Key = '2'; Label = 'Computer fleet' }
        @{ Id = 'DIAGNOSTICS'; Key = '3'; Label = 'Diagnostics & health' }
        @{ Id = 'REPORTS';     Key = '4'; Label = 'Reports & audit' }
        @{ Id = 'SETTINGS';    Key = '5'; Label = 'Settings & credentials' }
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

    Each entry carries a `Workflow` (the operation id) and either a Handler (a single $consoleActions
    leaf) or a `Starts` state (an explicit multi-step sequence). Carrying the operation id as data
    is what lets one implementation of pre-flight + confirmation + results serve every entry - see
    Show-WuuOperationConfirmationScreen.
    #>
    @(
        @{ Key = '1'; Label = 'Check for updates';            Handler = 'EventGetUpdates';           Mutating = $false; Workflow = 'check' }
        @{ Key = '2'; Label = 'Download updates';             Handler = 'EventDownloadUpdates';      Mutating = $true;  Workflow = 'download' }
        @{ Key = '3'; Label = 'Install updates';              Handler = 'EventInstallUpdates';       Mutating = $true;  Workflow = 'install' }
        @{ Key = '4'; Label = 'Restart computer(s)';          Handler = 'EventRestartComputer';      Mutating = $true;  Workflow = 'restart' }
        @{ Key = '5'; Label = 'Review available updates';     Handler = 'EventShowAvailableUpdates'; Mutating = $false; Workflow = 'review' }
        # Phase status belongs to the deployment flow, so it is offered here rather than as its own
        # top-level category. The workflow id is deliberately absent: showing phases is a READ, and
        # carrying 'deploy' would make the confirmation screen state deploy prerequisites for it.
        @{ Key = '6'; Label = 'Show phase status';            Handler = 'EventShowByPhase';          Mutating = $false }
        @{ Key = '7'; Label = 'Pre-flight check';             Preflight = 'deploy';                  Mutating = $false; Workflow = 'deploy' }
        @{ Key = '8'; Label = 'Run full deployment sequence'; Starts = 'DEPLOYING';                  Mutating = $true;  Workflow = 'deploy' }
        @{ Key = 'b'; Label = 'Back';                         Handler = '';                          Mutating = $false }
    )
}

function Get-WuuComputerManagementMenu {
    <#
    .SYNOPSIS The computer fleet: membership, phase assignment and persistence.
    .DESCRIPTION
    Membership and persistence are one domain - who is in the set, and how the set is kept - so
    saving and loading live here instead of in their own top-level category. Adding manually or by
    import routes to the GUIDED screens (`Screen`), not to the flat handlers, so the operator gets
    the parse-and-review step from the fleet menu too; the flat handlers remain reachable under
    Advanced for scripted use.

    Phase assignment is a local change to the set, not a remote one, so it stays `Mutating = $false`
    like the other fleet edits - matching both the flat menu and the command table's `credentials`
    entry. The guided menu's `Mutating` flag decides whether an entry is routed through the audit
    choke point, and a local set edit does not need a remote-change reason.
    #>
    @(
        @{ Key = '1'; Label = 'Add computers manually';     Screen = 'MANUAL';                  Mutating = $false }
        @{ Key = '2'; Label = 'Import computers from file'; Screen = 'IMPORT';                  Mutating = $false }
        @{ Key = '3'; Label = 'Add from Active Directory';  Handler = 'EventAddAD';            Mutating = $false }
        @{ Key = '4'; Label = 'Assign computers to phase';  Handler = 'EventAssignPhaseInteractive'; Mutating = $false }
        @{ Key = '5'; Label = 'Remove selected computers';  Handler = 'EventRemoveSelected';   Mutating = $false }
        @{ Key = '6'; Label = 'Remove offline computers';   Handler = 'EventRemoveOfflineComputer'; Mutating = $false }
        @{ Key = '7'; Label = 'Clear computer list';        Handler = 'ClearComputerList';     Mutating = $false }
        @{ Key = '8'; Label = 'Save named computer set';    Handler = 'EventSaveConfig';       Mutating = $false }
        @{ Key = '9'; Label = 'Load named computer set';    Handler = 'EventLoadConfig';       Mutating = $false }
        @{ Key = 'e'; Label = 'Export computer names';      Handler = 'EventSaveComputerList'; Mutating = $false }
        @{ Key = 'b'; Label = 'Back';                       Handler = '';                      Mutating = $false }
    )
}

function Get-WuuDiagnosticsMenu {
    <#
    .SYNOPSIS Inspection, service control and reachability (spec 19).
    .DESCRIPTION
    Connectivity pre-flight lives here rather than in its own category: it answers "is this fleet
    reachable", which is what an operator came to Diagnostics to find out. The mutating service
    action is first because it is the one entry that changes anything, and it is the only entry
    here that is not a read.
    #>
    @(
        @{ Key = '1'; Label = 'Windows Update service actions';  Handler = 'EventWUServiceActionInteractive'; Mutating = $true }
        @{ Key = '2'; Label = 'View Windows Update log';        Handler = 'EventViewUpdateLog';           Mutating = $false }
        @{ Key = '3'; Label = 'Show installed updates';         Handler = 'EventShowInstalledUpdates';    Mutating = $false }
        @{ Key = '4'; Label = 'Audit WSUS updates vs local state'; Handler = 'EventAuditWSUSUpdates';      Mutating = $false }
        @{ Key = '5'; Label = 'View error log';                Handler = 'GetErrors';                    Mutating = $false }
        @{ Key = '6'; Label = 'Connectivity pre-flight check'; Preflight = 'check';                      Mutating = $false }
        @{ Key = 'b'; Label = 'Back';                          Handler = '';                             Mutating = $false }
    )
}

function Get-WuuSettingsMenu {
    <#
    .SYNOPSIS Settings and credentials: what automation does, and who it authenticates as.
    .DESCRIPTION
    This replaces the separate Automation and Credentials categories. They were one decision seen
    from two angles - enabling unattended rollout is only safe if the credential the rollout uses
    is known to work - so they belong on one screen rather than two the operator must visit in the
    right order.

    The master toggle is wired by NAME to EventToggleSettings, the SAME handler the flat menu's `t`
    key uses, so the two entry points cannot implement different rules.

    Credentials are `Mutating = $true`: setting a credential is a credential change, the same way
    the command surface treats it (`wuu credentials set`). It was previously unflagged in the
    guided menu while the command table also carried `Mutating = $false`, so the asymmetry was in
    both places; flagging it here is the guided surface telling the truth about what it does.
    #>
    @(
        @{ Key = '1'; Label = 'Master automation toggle';   Handler = 'EventToggleSettings';         Mutating = $false }
        @{ Key = '2'; Label = 'Set domain credentials';     Handler = 'EventSetDomainCredentials';   Mutating = $true }
        @{ Key = '3'; Label = 'Credential pre-flight test'; Preflight = 'check';                     Mutating = $false }
        @{ Key = 'b'; Label = 'Back';                        Handler = '';                            Mutating = $false }
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

    The remote Windows Update history belongs with the other history views, so it moved here from
    Diagnostics once Diagnostics became inspection-of-this-run rather than everything that reports.
    #>
    @(
        @{ Key = '1'; Label = 'Deployment report';              Report = $true;          Mutating = $false }
        @{ Key = '2'; Label = 'View WUU audit trail';           AuditSubVerb = 'show';   Mutating = $false }
        @{ Key = '3'; Label = 'Verify audit chain integrity';   AuditSubVerb = 'verify'; Mutating = $false }
        @{ Key = '4'; Label = 'Export audit bundle';            AuditSubVerb = 'export'; Mutating = $false }
        @{ Key = '5'; Label = 'Windows Update history on targets'; Handler = 'EventShowUpdateHistory'; Mutating = $false }
        @{ Key = 'b'; Label = 'Back';                           Mutating = $false }
    )
}

#endregion Navigation tree

#region Workflow specs (spec 10 / 11)

function Get-WuuWorkflowSpec {
    <#
    .SYNOPSIS The explicit step sequence for a multi-step operation (spec 10 / 11).
    .DESCRIPTION
    Spec 10 requires the update lifecycle be made explicit rather than inferred from separate
    commands, and spec 11 requires full deployment to be the whole sequence:

        CHECK -> DOWNLOAD -> INSTALL -> REBOOT -> RE-CHECK -> VERIFY

    This table is the ONE place that sequence is written down. The renderer prints it, the executor
    walks it, and the confirmation screen shows it - so the three can never drift apart.

    Each step names the operation id it maps to, which is what makes the run loop a plain data
    driver rather than control flow: `PreflightOp` is what pre-flight and the confirmation gate are
    evaluated against for that step, while `Op` may be a lighter action ('restart' inside a
    deployment is only performed where a reboot is actually pending).
    #>
    param([string]$Name = '')
    switch ($Name.ToLowerInvariant()) {
        'check-chain' {
            @(
                @{ Label = 'Check for updates';  Op = 'check' ; PreflightOp = 'check' ; Mutating = $false }
                @{ Label = 'Review available';   Op = 'review'; PreflightOp = 'review'; Mutating = $false }
            )
        }
        'deploy' {
            @(
                @{ Label = 'Check for updates';      Op = 'check'    ; PreflightOp = 'check'    ; Mutating = $false }
                @{ Label = 'Download updates';       Op = 'download' ; PreflightOp = 'download' ; Mutating = $true }
                @{ Label = 'Install updates';        Op = 'install'  ; PreflightOp = 'install'  ; Mutating = $true }
                @{ Label = 'Restart where required'; Op = 'restart'  ; PreflightOp = 'restart'  ; Mutating = $true }
                @{ Label = 'Re-check';               Op = 'check'    ; PreflightOp = 'check'    ; Mutating = $false }
                @{ Label = 'Verify';                 Op = 'verify'   ; PreflightOp = 'review'   ; Mutating = $false }
            )
        }
        default { @() }
    }
}

#endregion Workflow specs

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

    # Automation state, shown HERE rather than only inside the Automation submenu. A setting an
    # operator has to navigate to discover is one they forget, and this one decides whether a check
    # silently rolls forward into downloads, installs and reboots. It is read from the store, which
    # is the single source of truth - the same values the worker gates read.
    $settings = $Ctx.Set.Store.Settings
    $dlOn = [bool]$settings.AutoDownload
    $ilOn = [bool]$settings.AutoInstall
    $rbOn = [bool]$settings.AutoReboot
    $allOn = $dlOn -and $ilOn -and $rbOn
    $anyOn = $dlOn -or $ilOn -or $rbOn
    if ($allOn) {
        Write-Host '  Automation: ALL ON - a check continues into download, install and reboot' -ForegroundColor Yellow
    } elseif ($anyOn) {
        # Mixed is stated as its parts, because "MIXED" alone tells the operator nothing actionable.
        Write-Host ("  Automation: PARTIAL - download {0}, install {1}, reboot {2}" -f `
            $(if ($dlOn) { 'ON' } else { 'off' }), $(if ($ilOn) { 'ON' } else { 'off' }), $(if ($rbOn) { 'ON' } else { 'off' })) -ForegroundColor Yellow
    } else {
        Write-Host '  Automation: all off - operations stop after each step' -ForegroundColor DarkGray
    }

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
            # The deployment report is a reporting ENGINE operation (Wuu.Reporting), not an
            # action-layer handler, so it hands off to its own screen where the window can be
            # chosen - the same reason audit subverbs are dispatched here rather than by Handler.
            if ($item.ContainsKey('Report')) { return 'REPORT' }
            # Audit subverbs are command-layer operations, not action-layer handlers (spec 20).
            if ($item.ContainsKey('AuditSubVerb')) {
                Invoke-WuuAuditSubVerb -Ctx $Ctx -SubVerb $item.AuditSubVerb
                return $State
            }
            # Contextual pre-flight (spec 18): credentials and connectivity are reachable from the
            # category they belong to, with a real result, rather than only after an operation fails.
            if ($item.ContainsKey('Preflight')) {
                $Ctx | Add-Member -NotePropertyName PreflightOperation -NotePropertyValue ([string]$item.Preflight) -Force
                return 'PREFLIGHT'
            }
            # A multi-step operation (spec 10 / 11) hands off to its own state instead of
            # dispatching one leaf here - the sequence lives in Get-WuuWorkflowSpec.
            if ($item.ContainsKey('Starts')) {
                $Ctx | Add-Member -NotePropertyName PendingOperation -NotePropertyValue ([string]$item.Workflow) -Force
                $Ctx | Add-Member -NotePropertyName PreflightOperation -NotePropertyValue ([string]$item.Workflow) -Force
                return [string]$item.Starts
            }
            # A GUIDED SCREEN, not a handler. "Add computers manually" and "Import computers from
            # file" used to be reachable only from the acquisition path, so the fleet menu offered
            # the FLAT handlers instead - which parse a file or a line with different rules and
            # validate nothing. Routing to the screen keeps one parse-and-review behaviour no matter
            # which door the operator came through; the flat handlers stay reachable under Advanced.
            if ($item.ContainsKey('Screen')) { return [string]$item.Screen }
            if ($item.Handler) {
                # The operation id travels with the dispatch so the confirmation screen can state
                # which prerequisites apply to it (spec 7 / 12).
                $op = if ($item.ContainsKey('Workflow')) { [string]$item.Workflow } else { '' }
                Invoke-WuuGuidedHandler -Ctx $Ctx -Handler $item.Handler -Mutating ([bool]$item.Mutating) -Operation $op
            }
            return $State
        }
    }
    Write-Host "  Unknown selection '$choice'." -ForegroundColor Yellow
    return $State
}

function Show-WuuReportScreen {
    <#
    .SYNOPSIS Spec 20: the deployment report, with its window chosen interactively.
    .DESCRIPTION
    CALLS THE SAME ENGINE as `wuu report`. Spec 23/24 require the guided UI and the command surface
    to invoke the same operations, and this is the stronger form of that rule: not merely a shared
    action, but the same FUNCTIONS (Get-WuuAuditHistory / Get-WuuDeploymentReport /
    Format-WuuReportTable / Export-WuuDeploymentReport). If the two entry points could diverge, a
    number quoted from the menu could disagree with the number quoted from the CLI for the same
    window, which is exactly the kind of discrepancy that makes a report untrustworthy.

    Every prompt goes through Read-WuuAnswer, so this screen is drivable from a test and cannot
    block an unattended run.
    #>
    param([Parameter(Mandatory)]$Ctx)

    Write-WuuHeader 'DEPLOYMENT REPORT'

    # Window presets rather than a free-text period: the operator picking "last 7 days" from a menu
    # should not have to remember the '<n>d' grammar, and the CLI still offers it for scripts.
    Write-Host '  1. Last 24 hours'
    Write-Host '  2. Last 7 days'
    Write-Host '  3. Last 30 days'
    Write-Host '  4. Everything recorded'
    Write-Host '  b. Back'
    $periodChoice = [string](Read-WuuAnswer -Prompt '  Period' -Default '2')
    $period = switch ($periodChoice.Trim().ToLowerInvariant()) {
        '1' { '24h' }
        '2' { '7d' }
        '3' { '30d' }
        '4' { 'all' }
        'b' { 'BACK' }
        default { 'BACK' }
    }
    if ($period -eq 'BACK') { return 'REPORTS' }

    # Ask which audit source BEFORE reading, so a missing store is a clear message rather than an
    # empty table the operator has to interpret.
    $dir = Get-WuuAuditDirectory
    $files = @(Get-ChildItem -LiteralPath $dir -Filter 'audit-*.jsonl' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        Write-Host ''
        Write-Host '  No audit trail found - nothing has been recorded on this machine yet.' -ForegroundColor Yellow
        Write-Host ("  Reporting reads {0}" -f $dir) -ForegroundColor DarkGray
        $null = Read-WuuAnswer -Prompt '  Press Enter to continue' -Default ''
        return 'REPORTS'
    }

    $history = Get-WuuAuditHistory -Period $period
    if (-not $history.Ok) {
        Write-Host ("  Could not read the audit trail: {0}" -f $history.Error) -ForegroundColor Red
        $null = Read-WuuAnswer -Prompt '  Press Enter to continue' -Default ''
        return 'REPORTS'
    }

    $report = Get-WuuDeploymentReport -Records $history.Records -GroupBy Day
    Format-WuuReportTable -Report $report -Window $history -Top 5

    Write-Host '  Next actions:'
    Write-Host '    1. Wider window'
    Write-Host '    2. Export these runs to CSV'
    Write-Host '    3. Export failing targets to CSV'
    Write-Host '    4. Verify the audit chain'
    Write-Host '    5. Back to Reports'
    $next = [string](Read-WuuAnswer -Prompt '  Selection' -Default '5')
    switch ($next.Trim().ToLowerInvariant()) {
        '1' { return 'REPORT' }
        '2' { return (Invoke-WuuReportExportScreen -Report $report -Dataset 'Runs') }
        '3' { return (Invoke-WuuReportExportScreen -Report $report -Dataset 'Targets') }
        '4' { Invoke-WuuAuditSubVerb -Ctx $Ctx -SubVerb 'verify'; return 'REPORTS' }
        default { return 'REPORTS' }
    }
}

function Invoke-WuuReportExportScreen {
    # Writes a report dataset to a path the operator supplies. Kept as its own function so both
    # export choices share one prompt-and-report path, and so a failure names the DATASET as well
    # as the error - "could not write" without saying what is a message the operator cannot act on.
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$Dataset
    )

    $target = [string](Read-WuuAnswer -Prompt ("  Path for the {0} CSV" -f $Dataset.ToLowerInvariant()) -Default '')
    if ([string]::IsNullOrWhiteSpace($target)) {
        Write-Host '  Cancelled - nothing was written.' -ForegroundColor Yellow
        return 'REPORTS'
    }

    $export = Export-WuuDeploymentReport -Report $Report -Path $target.Trim() -Dataset $Dataset
    Write-Host ''
    if ($export.Success) {
        Write-Host ("  Wrote {0} row(s) of '{1}' to {2}" -f $export.Rows, $Dataset, $target.Trim()) -ForegroundColor Green
        if ($export.Rows -eq 0) {
            # Say WHY it is empty. A header-only file is correct but looks like a bug otherwise.
            Write-Host '  (No rows matched - the file holds only its header.)' -ForegroundColor DarkGray
        }
    } else {
        Write-Host ("  Could not write '{0}': {1}" -f $target.Trim(), $export.Error) -ForegroundColor Red
    }
    $null = Read-WuuAnswer -Prompt '  Press Enter to continue' -Default ''
    return 'REPORTS'
}

function Invoke-WuuAuditSubVerb {    # Runs `audit verify|show|export` via the same path the command surface uses. Export is handed
    # the set's STORE because the operator is working in a computer set (spec 6) - the command-layer
    # default would export the saved config file instead of the set they are looking at.
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$SubVerb)
    try {
        if ($SubVerb -eq 'export' -and $Ctx.Store) {
            $null = Invoke-WuuAuditCommand -SubVerb $SubVerb -Store $Ctx.Store
        } else {
            $null = Invoke-WuuAuditCommand -SubVerb $SubVerb
        }
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
        [bool]$Mutating = $false,
        [string]$Operation = '',
        [AllowEmptyCollection()][string[]]$Targets = @()
    )

    if (-not $Ctx.Actions.ContainsKey($Handler)) {
        Write-Host ("  DEFECT: no handler named '{0}'. This menu entry is wired to nothing." -f $Handler) -ForegroundColor Red
        return
    }

    # The selection normally lives in the store and the handler prompts for it. An explicit
    # -Targets list is how the GUIDED WORKFLOW narrows an operation to a set it has already
    # confirmed - most importantly the retry-failed path (spec 15), which must not re-prompt for a
    # set the operator just authorised. $null means "no guided decision": the handler prompts.
    # NOTE it must NOT be set to an empty array here: Read-WuuSelection treats an empty guided list
    # as "target nothing", so defaulting it would turn every guided operation into a no-op.
    $guidedTargetsSet = $false
    if (@($Targets).Count -gt 0) {
        $global:WuuGuidedTargets = @($Targets)
        $guidedTargetsSet = $true
    }

    if ($Mutating) {
        # The reason was already collected by the confirmation screen (spec 12) when the operation
        # was confirmed, so asking again here would be a duplicate prompt with nothing to add.
        # It is deliberately CONSUMED (cleared) below: each mutating step of a deployment must
        # collect its own reason rather than silently inheriting the previous step's.
        $reason = if ($Ctx.PSObject.Properties['Reason']) { [string]$Ctx.Reason } else { '' }
        if ([string]::IsNullOrWhiteSpace($reason) -and -not $Ctx.AuditHook) {
            Write-Host '  WARNING: auditing is not active, so this change will not be recorded.' -ForegroundColor Yellow
            # OUT-NULL IS LOAD-BEARING, not tidiness. A handler's OUTPUT goes to the pipeline, and the
            # screens that call this function return a workflow state - so an unpiped call makes the
            # caller's return value an ARRAY of ('<whatever the handler printed>', '<the state>').
            # A switch over that array runs EVERY matching arm, and the state the loop receives is the
            # whole object, which it reports as "unknown workflow state". See the note on the
            # Out-Null below for the full failure this caused.
            & $Ctx.Actions[$Handler] | Out-Null
            if ($guidedTargetsSet) { $global:WuuGuidedTargets = $null }
            return
        }
        if ([string]::IsNullOrWhiteSpace($reason)) {
            # Reached only when a mutating action is invoked WITHOUT the confirmation screen
            # (the Advanced flat menu). Asking here keeps that path auditable.
            $reason = [string](Read-WuuAnswer -Prompt '  Reason for this change (recorded in the audit trail)' -Default '')
        }
        if ([string]::IsNullOrWhiteSpace($reason)) {
            Write-Host '  A reason is required for audited changes - operation cancelled.' -ForegroundColor Yellow
            if ($Ctx.DenialHook) {
                try { & $Ctx.DenialHook $Handler 'reason not supplied (cancelled at prompt)' | Out-Null } catch { }
            }
            if ($guidedTargetsSet) { $global:WuuGuidedTargets = $null }
            return
        }
        $Ctx | Add-Member -NotePropertyName Reason -NotePropertyValue '' -Force
        try {
            & $Ctx.AuditHook $Handler $reason $Ctx.Actions[$Handler] -Targets @($Targets) | Out-Null
        } catch {
            # Fall back to the hook's two-argument shape so a caller-supplied hook still works
            # (e.g. in a test), rather than losing the audit record entirely.
            & $Ctx.AuditHook $Handler $reason $Ctx.Actions[$Handler] | Out-Null
        }
        if ($guidedTargetsSet) { $global:WuuGuidedTargets = $null }
        return
    }

    # OUT-NULL IS NOT COSMETIC. This function is called from screens that RETURN A WORKFLOW STATE, and
    # a handler's output goes to the pipeline: without the pipe, the screen's return value becomes an
    # ARRAY of (handler output..., state) instead of the state. That produced two symptoms which looked
    # like unrelated bugs and cost real time to trace:
    #   * the loop received a PSCustomObject (a $GetErrors error row, complete with its Timestamp - the
    #     '2. View errors' path on the results screen) and reported it as an unknown workflow state;
    #   * worse, a switch over a 2-element array runs BOTH matching arms, so the arm that reassigns
    #     $state ran as well as 'default' - and 'default' printed $state AFTER the reassignment, naming
    #     a perfectly valid state ('DASHBOARD') as unknown.
    # 11 call sites depend on this function not leaking; the audit branch above has always piped.
    & $Ctx.Actions[$Handler] | Out-Null
    if ($guidedTargetsSet) { $global:WuuGuidedTargets = $null }
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
            # Out-Null is load-bearing: leaking dispatch output turns the return
            # value into an array and corrupts workflow state (instructions SS8 / bug 3e346ad).
            if ($a.Mutating) { Invoke-WuuGuidedHandler -Ctx $Ctx -Handler $a.Handler -Mutating $true | Out-Null }
            else { & $a.Run $Ctx.Actions | Out-Null }
            return 'ADVANCED'
        }
    }
    Write-Host "  Unknown selection '$choice'." -ForegroundColor Yellow
    return 'ADVANCED'
}

#endregion Screens

#region Pre-flight, confirmation, execution and results (spec 7 / 12 / 14 / 15)

function New-WuuPreflightContext {
    <#
    .SYNOPSIS The LIVE probe set pre-flight uses, assembled in one place.
    .DESCRIPTION
    Every probe is built from primitives the engine already uses, and none of them is reimplemented:

      Ping        - the same Test-Connection check $RemoveOfflineComputer performs
      Credentials - Invoke-CimWithTimeout, the codebase's bounded DCOM probe
      Service     - Invoke-ServiceWithTimeout -Action Check
      OS / Reboot - Win32_OperatingSystem, and the Microsoft.Update.SystemInfo query the update
                    engine already uses to decide whether a reboot is pending

    WHY THE SCRIPTBLOCKS USE -ArgumentList RATHER THAN CLOSING OVER ANYTHING. An earlier shape
    wrote `[scriptblock]{ param($n) ... & $probe $n ... }` to wrap each injected probe, which
    captures the surrounding scope - and the release validator (correctly) rejects any use of the
    injection anti-pattern in this module, because a bound scriptblock handed to another runspace
    resolves its variables in the WRONG session and comes back empty. Calling each probe directly
    with -ArgumentList keeps every call site free of that pattern.

    Returned as data on the context rather than called in place, so a test can substitute probes
    that answer instantly - which is the difference between asserting "offline hosts are excluded
    from the available count" in milliseconds versus waiting on a real ping timeout per host.
    #>
    [pscustomobject]@{
        Ping = { param($Name)
            [bool](Test-Connection -Count 1 -ComputerName $Name -Quiet -ErrorAction SilentlyContinue)
        }
        Credentials = { param($Name)
            $r = Invoke-CimWithTimeout -ComputerName $Name -ClassName 'Win32_ComputerSystem' `
                -TimeoutSeconds $global:CimTimeoutSeconds -Operation 'pre-flight credential probe'
            if ($r -and $r.Success) { 'valid' } else { 'failed' }
        }
        Service = { param($Name)
            $s = Invoke-ServiceWithTimeout -ComputerName $Name -ServiceName 'wuauserv' -Action Check `
                -TimeoutSeconds $global:ServiceTimeoutSeconds
            if ($s -and $s.Success -and $s.Status) { [string]$s.Status } else { 'unknown' }
        }
        OS = { param($Name)
            $r = Invoke-CimWithTimeout -ComputerName $Name -ClassName 'Win32_OperatingSystem' `
                -TimeoutSeconds $global:CimTimeoutSeconds -Operation 'pre-flight OS probe'
            if ($r -and $r.Success -and $r.Result) {
                $os = @($r.Result)[0]
                '{0} (build {1})' -f $os.Caption, $os.BuildNumber
            } else { '' }
        }
        Reboot = { param($Name)
            $r = Invoke-WithPoolTimeout -ScriptBlock {
                param($c)
                try { [bool]([activator]::CreateInstance([type]::GetTypeFromProgID('Microsoft.Update.SystemInfo', $c))).RebootRequired }
                catch { $false }
            } -ArgumentList $Name -TimeoutSeconds $global:RebootProbeTimeoutSeconds -OperationName 'pre-flight reboot probe'
            if ($r -and $r.Success) { [bool]$r.Result } else { $false }
        }
    }
}

function Invoke-WuuPreflightCheck {
    <#
    .SYNOPSIS Runs pre-flight and records the result on the context.
    .DESCRIPTION
    Exists so pre-flight is triggered from ONE place. The confirmation screen calls it when the
    operator has not run it yet, and the category menus call it directly (spec 18: credentials are
    "surfaced contextually in pre-flight ... do not make credential configuration something users
    only find after an operation fails").
    #>
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$Operation
    )

    $ctxPf = if ($Ctx.PSObject.Properties['PreflightContext']) { $Ctx.PreflightContext } else { $null }
    if (-not $ctxPf) { $ctxPf = New-WuuPreflightContext }

    Write-Host ''
    Write-Host ("  Pre-flight: {0}" -f (Get-WuuOperationLabel -Operation $Operation)) -ForegroundColor White
    Write-Host '  Probing reachability, credentials, Windows Update service, OS and reboot state...' -ForegroundColor DarkGray

    $tick = if ($Ctx.PSObject.Properties['Tick']) { $Ctx.Tick } else { $null }

    $report = Get-WuuPreflightReport -Set $Ctx.Set -Operation $Operation `
        -PingProbe $ctxPf.Ping -CredentialProbe $ctxPf.Credentials `
        -ServiceProbe $ctxPf.Service -OsProbe $ctxPf.OS -RebootProbe $ctxPf.Reboot `
        -Tick $tick

    $Ctx | Add-Member -NotePropertyName Preflight -NotePropertyValue $report -Force
    $Ctx | Add-Member -NotePropertyName PreflightOperation -NotePropertyValue $Operation -Force
    Write-InfoLog ("Pre-flight ({0}): {1} computer(s), {2} reachable, {3} available, {4} blocking, {5} warning(s)" -f `
        $Operation, $report.Computers, $report.Reachable, $report.Available, $report.Blocking, $report.Warnings)
    return $report
}

function Get-WuuRowOperationState {
    <#
    .SYNOPSIS Maps a row onto the lifecycle state the execution screen displays (spec 14).
    .DESCRIPTION
    Spec 14 requires the execution screen to distinguish Waiting, Checking, Downloading,
    Installing, Rebooting, Verifying, Complete, Failed and Offline. The row's own State value
    already IS that vocabulary (see the ValidateSet on the state setter in Wuu.Core), so this
    translates rather than invents - and returns a display name plus the colour to use.
    #>
    param([Parameter(Mandatory)]$Row)

    switch ([string]$Row.State) {
        'Queued'         { @{ Name = 'Waiting';     Color = 'DarkGray' } }
        'Connecting'     { @{ Name = 'Connecting';  Color = 'DarkGray' } }
        'Connected'      { @{ Name = 'Connected';   Color = 'DarkGray' } }
        'Checking'       { @{ Name = 'Checking';    Color = 'Cyan' } }
        'Searching'      { @{ Name = 'Checking';    Color = 'Cyan' } }
        'UpdatesFound'   { @{ Name = 'Available';   Color = 'Yellow' } }
        'Downloading'    { @{ Name = 'Downloading'; Color = 'Cyan' } }
        'Installing'     { @{ Name = 'Installing';  Color = 'Cyan' } }
        'RebootRequired' { @{ Name = 'Reboot needed'; Color = 'Yellow' } }
        'Rebooting'      { @{ Name = 'Rebooting';   Color = 'Yellow' } }
        'Verifying'      { @{ Name = 'Verifying';   Color = 'Cyan' } }
        'Complete'       { @{ Name = 'Complete';    Color = 'Green' } }
        'Timeout'        { @{ Name = 'Timed out';   Color = 'Yellow' } }
        'Error'          { @{ Name = 'Failed';      Color = 'Red' } }
        'Offline'        { @{ Name = 'Offline';     Color = 'DarkGray' } }
        default          { @{ Name = [string]$Row.State; Color = 'Gray' } }
    }
}

function Wait-WuuRowsSettled {
    <#
    .SYNOPSIS Waits (bounded) for the targeted rows to stop running, draining the scheduler.
    .DESCRIPTION
    A deployment step is queued asynchronously - the action handlers return as soon as the
    per-computer runspace is started. Without a wait, "Full deployment" would queue a download while
    the search that discovers what to download is still running, and the download would see nothing.

    Bounded on purpose: an update run can legitimately take a long time, and an unbounded wait would
    turn an unresponsive host into a hung application. On timeout the caller is told, so the results
    screen can say "still running" rather than claiming success.
    #>
    param(
        [Parameter(Mandatory)]$Ctx,
        [AllowEmptyCollection()][string[]]$Targets = @(),
        [int]$TimeoutSeconds = 1800
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($Ctx.PSObject.Properties['Tick']) { try { & $Ctx.Tick } catch { } }
        $busy = 0
        foreach ($r in @(Get-WuuComputerSetComputers -Set $Ctx.Set)) {
            if (@($Targets).Count -gt 0 -and $Targets -notcontains $r.Computer) { continue }
            if ($r.Pending) { $busy++; continue }
            switch ([string]$r.State) {
                'Queued'      { $busy++ }
                'Connecting'  { $busy++ }
                'Connected'   { $busy++ }
                'Checking'    { $busy++ }
                'Searching'   { $busy++ }
                'Downloading' { $busy++ }
                'Installing'  { $busy++ }
                'Rebooting'   { $busy++ }
                'Verifying'   { $busy++ }
            }
        }
        if ($busy -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Confirm-WuuMutation {
    <#
    .SYNOPSIS Builds the plan and requires explicit confirmation before a mutating operation.
    .DESCRIPTION
    Spec 12. Returns a decision object rather than a boolean so the caller can distinguish the
    three outcomes that matter - "run it", "the operator said no", and "there is nothing to
    confirm" - and act on them differently. `Proceed` is deliberately the ONLY value that permits
    a mutation.

    A blank reason is REFUSED rather than defaulted. The audit trail records the reason, and a
    defaulted reason would make every guided change look identical in the trail; the flat menu and
    the command surface both refuse a blank reason for the same reason.
    #>
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$Operation,
        [AllowEmptyCollection()][string[]]$Targets = @(),
        # -Yes is how a test (or a scripted caller) supplies the confirmation and the reason
        # without a prompt - the same shape the command surface uses for its Answers queue.
        [switch]$Yes,
        [string]$Reason = ''
    )

    $plan = New-WuuOperationPlan -Set $Ctx.Set -Operation $Operation -Targets $Targets -Preflight $Ctx.Preflight

    Write-WuuHeader ("CONFIRM: {0}" -f $plan.Label.ToUpperInvariant())
    Write-Host ("  Computers:  {0} of {1}" -f $plan.AvailableCount, $plan.TargetCount) -ForegroundColor White
    if ($plan.AvailableCount -ne $plan.TargetCount) {
        Write-Host ("  ({0} will be skipped - see pre-flight)" -f ($plan.TargetCount - $plan.AvailableCount)) -ForegroundColor Yellow
    }
    Write-Host ("  Updates to download: {0}   to install: {1}" -f $plan.UpdatesToDownload, $plan.UpdatesToInstall)
    Write-Host ("  Expected reboots:    {0}" -f $plan.ExpectedReboots)
    Write-Host ''
    Write-Host ("  Sequence: {0}" -f ($plan.Lifecycle -join ' -> ')) -ForegroundColor DarkCyan

    if (@($plan.PerPhase).Count -gt 0) {
        Write-Host ''
        Write-Host '  By phase:' -ForegroundColor DarkCyan
        foreach ($p in $plan.PerPhase) {
            Write-Host ("    {0}: {1} computer(s)" -f $p.Phase, $p.Computers)
        }
    }

    if (-not $Ctx.Preflight) {
        Write-Host ''
        Write-Host '  Pre-flight has not been run for this operation.' -ForegroundColor Yellow
    }

    if ($plan.TargetCount -eq 0) {
        Write-Host ''
        Write-Host '  Nothing to do - no computers selected.' -ForegroundColor Yellow
        return @{ Proceed = $false; Reason = ''; ReasonBlank = $false; Plan = $plan; Message = 'no targets' }
    }

    Write-Host ''
    Write-Host '    1. Confirm and run'
    Write-Host '    2. Cancel'
    $choice = if ($Yes) { '1' } else { [string](Read-WuuAnswer -Prompt '  Selection' -Default '2') }

    if ($choice.Trim().ToLowerInvariant() -ne '1') {
        Write-Host '  Cancelled.' -ForegroundColor Yellow
        return @{ Proceed = $false; Reason = ''; ReasonBlank = $false; Plan = $plan; Message = 'cancelled' }
    }

    $reasonValue = $Reason
    if ($plan.RequiresReason) {
        if (-not $reasonValue) { $reasonValue = [string](Read-WuuAnswer -Prompt '  Change reason (recorded in the audit trail)' -Default '') }
        if ([string]::IsNullOrWhiteSpace($reasonValue)) {
            Write-Host '  A change reason is required - operation cancelled.' -ForegroundColor Yellow
            # The refusal is recorded HERE rather than by the caller, because this is the function
            # that actually knows a refusal happened. Leaving it to the screen meant any other
            # caller of the confirmation gate (a test, a future workflow) produced an unrecorded
            # refusal - and an unrecorded refusal is exactly what ISO 27001 A.8.15 is about.
            if ($Ctx.DenialHook) {
                try { & $Ctx.DenialHook $Operation 'reason not supplied (cancelled at confirmation)' | Out-Null } catch { }
            }
            return @{ Proceed = $false; Reason = ''; ReasonBlank = $true; Plan = $plan; Message = 'reason required' }
        }
    }

    $Ctx | Add-Member -NotePropertyName Reason -NotePropertyValue $reasonValue -Force
    $Ctx | Add-Member -NotePropertyName Pending -NotePropertyValue ([pscustomobject]@{
        Operation = $Operation
        Plan      = $plan
        Targets   = $plan.Targets
        Reason    = $reasonValue
    }) -Force

    return @{ Proceed = $true; Reason = $reasonValue; ReasonBlank = $false; Plan = $plan; Message = 'confirmed' }
}

function Show-WuuPreflightScreen {
    <#
    .SYNOPSIS Spec 7 pre-flight: report, then a real choice about what to do next.
    .DESCRIPTION
    The report is the P0 requirement ("The user must not discover these problems halfway through
    a deployment"). The four actions are spec 7's own list, and the first states the real number -
    "Continue with N available computers", not "Continue".
    #>
    param([Parameter(Mandatory)]$Ctx)

    $computerCount = Get-WuuComputerSetCount -Set $Ctx.Set
    if ($computerCount -eq 0) {
        Write-WuuHeader 'PRE-FLIGHT'
        Write-Host '  No computers in the set - nothing to check.' -ForegroundColor Yellow
        return 'DASHBOARD'
    }

    $op = if ($Ctx.PSObject.Properties['PreflightOperation']) { [string]$Ctx.PreflightOperation } else { 'check' }
    if ([string]::IsNullOrWhiteSpace($op)) { $op = 'check' }

    $report = Invoke-WuuPreflightCheck -Ctx $Ctx -Operation $op

    Write-Host ''
    Write-Host '  PRE-FLIGHT RESULT' -ForegroundColor White
    $fmt = '    {0,-24} {1}'
    Write-Host ($fmt -f 'Targets', $report.Computers)
    if ($report.ProbedOffline) {
        # Reachability was not probed, so neither a reachable NOR an offline figure is meaningful.
        # Printing "Offline: 3" because the ping count happened to be zero is how a pre-flight
        # report teaches an operator to distrust it.
        Write-Host '    Reachability, credentials, WU service, OS and reboot state: not probed' -ForegroundColor DarkGray
    } else {
        Write-Host ($fmt -f 'Reachable', $report.Reachable)
        Write-Host ($fmt -f 'Offline', $report.Offline)
        Write-Host ($fmt -f 'Credentials valid', ("{0} / {1}" -f $report.CredentialsValid, $report.Reachable))
        Write-Host ($fmt -f 'WU service running', ("{0} / {1}" -f $report.ServiceOk, $report.Reachable))
        Write-Host ($fmt -f 'Pending reboot', $report.RebootPending)
    }
    Write-Host ($fmt -f 'Prerequisites', ("{0} blocking, {1} warning" -f $report.Blocking, $report.Warnings))

    if (@($report.Problems).Count -gt 0) {
        Write-Host ''
        Write-Host '  Potential problems' -ForegroundColor Yellow
        foreach ($p in @($report.Problems | Select-Object -First 20)) { Write-Host ("    - {0}" -f $p) -ForegroundColor DarkYellow }
        if (@($report.Problems).Count -gt 20) { Write-Host ("    ... and {0} more" -f (@($report.Problems).Count - 20)) -ForegroundColor DarkYellow }
    } else {
        Write-Host ''
        Write-Host '  No potential problems found.' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host ("    1. Continue with {0} available computer(s)" -f $report.Available)
    Write-Host '    2. Remove offline computers'
    Write-Host '    3. Review problems'
    Write-Host '    4. Cancel'

    $choice = [string](Read-WuuAnswer -Prompt '  Selection' -Default '4')
    switch ($choice.Trim().ToLowerInvariant()) {
        '1' {
            if ($report.Available -eq 0) {
                Write-Host '  No available computers - nothing to continue with.' -ForegroundColor Yellow
                return 'DASHBOARD'
            }
            return 'DASHBOARD'
        }
        '2' {
            # Deliberately NOT re-probing straight after. The handler queues the checks, so the
            # rows are still present at this instant; re-probing here would report the same
            # offline hosts again and look like the removal had failed.
            if ($report.Offline -eq 0) { Write-Host '  No offline computers to remove.' -ForegroundColor DarkGray; return 'PREFLIGHT' }
            Write-Host ('  Queued connectivity test for {0} computer(s); unreachable rows are removed as it completes.' -f $report.Computers) -ForegroundColor Cyan
            Invoke-WuuGuidedHandler -Ctx $Ctx -Handler 'EventRemoveOfflineComputer'
            return 'DASHBOARD'
        }
        '3' {
            Write-Host ''
            foreach ($r in @($report.Results)) {
                Write-Host ("    {0,-24} reach={1,-5} creds={2,-18} wu={3,-18} reboot={4}" -f `
                    $r.Computer, $r.Reachable, $r.Credentials, $r.WuService, $r.PendingReboot)
                if ($r.Problem) { Write-Host ("      -> {0}" -f $r.Problem) -ForegroundColor DarkYellow }
            }
            Write-Host ''
            $null = Read-WuuAnswer -Prompt '  Press Enter to continue' -Default ''
            return 'PREFLIGHT'
        }
        default { return 'DASHBOARD' }
    }
}

function Show-WuuOperationConfirmationScreen {
    <#
    .SYNOPSIS Spec 12: run pre-flight if needed, show the plan, then obtain explicit confirmation.
    .DESCRIPTION
    Pre-flight is offered rather than assumed. Spec 7 requires it before disruptive operations,
    but re-probing a large estate on every keystroke would make the workflow unusable, so an
    operator who has ALREADY seen a fresh report (the context holds one for this same operation)
    is not asked again - they are told the decision is theirs.

    On confirmation the mutating step is dispatched through Invoke-WuuGuidedHandler, so the reason
    collected here is what the audit choke point records (spec 12: "If a change reason is required
    by the existing audit system, collect it naturally at this stage").
    #>
    param([Parameter(Mandatory)]$Ctx)

    $op = if ($Ctx.PSObject.Properties['PreflightOperation']) { [string]$Ctx.PreflightOperation } else { 'check' }
    if ([string]::IsNullOrWhiteSpace($op)) { $op = 'check' }

    $targets = if ($Ctx.PSObject.Properties['RetryTargets']) { @($Ctx.RetryTargets) } else { @() }

    # A fresh report for this operation means the operator has already reviewed the problems.
    $needsPreflight = $true
    if ($Ctx.Preflight) {
        if ([string]$Ctx.Preflight.Operation -eq $op) { $needsPreflight = $false }
    }
    if ($needsPreflight -and (Get-WuuComputerSetCount -Set $Ctx.Set) -gt 0) {
        Write-Host ''
        Write-Host '  Running pre-flight before this operation (spec 7) - this can take a moment.' -ForegroundColor DarkGray
        $report = Invoke-WuuPreflightCheck -Ctx $Ctx -Operation $op
        if ($report.Blocking -gt 0) {
            Write-Host ''
            Write-Host ("  {0} computer(s) have blocking problems; see 'Pre-flight check' to review." -f $report.Blocking) -ForegroundColor Yellow
        }
    }

    $decision = Confirm-WuuMutation -Ctx $Ctx -Operation $op -Targets $targets
    if (-not $decision.Proceed) {
        # No denial is recorded here: Confirm-WuuMutation records the refusal itself, and doing it
        # in both places would put two 'denied' records in the trail for one cancel.
        # Back to the category that offered the operation, so a refused confirmation is not a dead
        # end. The category id is derived from the state that pushed this screen.
        return (Get-WuuCategoryStateForOperation -Operation $op)
    }

    # 'deploy' is a sequence, not a leaf (spec 11) - hand it to the deployment runner.
    if ($op.ToLowerInvariant() -eq 'deploy') {
        $Ctx | Add-Member -NotePropertyName DeploymentStep -NotePropertyValue 0 -Force
        return 'EXECUTING'
    }

    $handler = Get-WuuOperationHandler -Operation $op
    if (-not $handler) {
        Write-Host ("  DEFECT: no handler for operation '{0}'." -f $op) -ForegroundColor Red
        return 'DASHBOARD'
    }

    Write-Host ''
    Write-Host ("  Running: {0}" -f (Get-WuuOperationLabel -Operation $op)) -ForegroundColor White
    Invoke-WuuGuidedHandler -Ctx $Ctx -Handler $handler -Mutating (Test-WuuOperationRequiresReason -Operation $op) -Operation $op -Targets $targets
    Write-InfoLog ("Guided operation '{0}' dispatched for {1} computer(s), reason: {2}" -f $op, @($targets).Count, $decision.Reason)

    $Ctx | Add-Member -NotePropertyName ExecutionOperation -NotePropertyValue $op -Force
    return 'EXECUTING'
}

function Get-WuuOperationHandler {
    <# The single $consoleActions handler responsible for an operation id. #>
    param([Parameter(Mandatory)][string]$Operation)
    switch ($Operation.ToLowerInvariant()) {
        'check'    { 'EventGetUpdates' }
        'review'   { 'EventShowAvailableUpdates' }
        'download' { 'EventDownloadUpdates' }
        'install'  { 'EventInstallUpdates' }
        'restart'  { 'EventRestartComputer' }
        'service'  { 'EventWUServiceActionInteractive' }
        'deploy'   { '' }
        default    { '' }
    }
}

function Get-WuuCategoryStateForOperation {
    <# Which category screen offered this operation - so cancelling returns somewhere sensible. #>
    param([Parameter(Mandatory)][string]$Operation)
    switch ($Operation.ToLowerInvariant()) {
        # Deployment is offered by the Updates category now; the DEPLOYMENT category no longer
        # exists, so a refused deploy confirmation must return somewhere that does.
        'deploy' { 'UPDATES' }
        default  { 'UPDATES' }
    }
}

function Show-WuuExecutionScreen {
    <#
    .SYNOPSIS Spec 14: live per-computer progress for the running operation.
    .DESCRIPTION
    Spec 14 wants the lifecycle states distinguished; Get-WuuRowOperationState maps the row's own
    vocabulary onto them. For a single-step operation this waits for the step to settle and then
    moves to the results screen, which is spec 15's requirement that a run never just ends with
    "Operation complete."

    Full deployment is driven step-by-step from Get-WuuWorkflowSpec (spec 11) - each step is
    confirmed separately, because a change reason is required per change, and the operator should
    be able to stop between steps.
    #>
    param([Parameter(Mandatory)]$Ctx)

    $op = if ($Ctx.PSObject.Properties['ExecutionOperation']) { [string]$Ctx.ExecutionOperation } else { 'check' }
    if ([string]::IsNullOrWhiteSpace($op)) { $op = 'check' }

    $targets = if ($Ctx.PSObject.Properties['RetryTargets']) { @($Ctx.RetryTargets) } else { @() }

    $spec = @(Get-WuuWorkflowSpec -Name (Get-WuuWorkflowNameForOperation -Operation $op))

    Write-WuuHeader ("EXECUTING: {0}" -f (Get-WuuOperationLabel -Operation $op).ToUpperInvariant())

    if ($spec.Count -gt 0) {
        # Multi-step: run the sequence, showing progress after each step. The AUTHORISATION for the
        # whole sequence was taken once, by the confirmation screen, so the loop collects a reason
        # per mutating step from the context rather than interrupting each one with its own
        # Confirm/Cancel prompt - and it deliberately does NOT re-probe. Re-running the full probe
        # set before every step would multiply pre-flight cost by the number of steps while telling
        # the operator nothing new within a single deployment run.
        $stepIndex = 0
        if ($Ctx.PSObject.Properties['DeploymentStep']) { $stepIndex = [int]$Ctx.DeploymentStep }
        while ($stepIndex -lt $spec.Count) {
            $step = $spec[$stepIndex]
            Write-Host ''
            Write-Host ("  [{0}/{1}] {2}" -f ($stepIndex + 1), $spec.Count, $step.Label) -ForegroundColor White

            if ($step.Mutating -and -not [string]$Ctx.Reason) {
                # Each mutating step is its own audited change, so it needs its own reason. This is
                # collected here (not inherited) because the trail must be able to explain step 4
                # without reference to step 2.
                $stepReason = [string](Read-WuuAnswer -Prompt ("  Change reason for '{0}'" -f $step.Label) -Default '')
                if ([string]::IsNullOrWhiteSpace($stepReason)) {
                    Write-Host '  A change reason is required - deployment stopped.' -ForegroundColor Yellow
                    if ($Ctx.DenialHook) {
                        try { & $Ctx.DenialHook ([string]$step.Op) 'reason not supplied (deployment step cancelled)' | Out-Null } catch { }
                    }
                    $Ctx | Add-Member -NotePropertyName DeploymentStep -NotePropertyValue 0 -Force
                    return 'RESULTS'
                }
                $Ctx | Add-Member -NotePropertyName Reason -NotePropertyValue $stepReason -Force
            }

            $handler = Get-WuuOperationHandler -Operation ([string]$step.Op)
            if ($handler) {
                Invoke-WuuGuidedHandler -Ctx $Ctx -Handler $handler -Mutating ([bool]$step.Mutating) -Operation ([string]$step.Op) -Targets $targets
            } else {
                Write-Host ("  DEFECT: workflow step '{0}' has no handler." -f $step.Op) -ForegroundColor Red
            }

            $settled = Wait-WuuRowsSettled -Ctx $Ctx -Targets $targets
            if (-not $settled) {
                Write-Host '  Some computers are still running; moving on with the last known state.' -ForegroundColor Yellow
            }

            Write-WuuExecutionTable -Ctx $Ctx -Targets $targets
            $stepIndex++
            $Ctx | Add-Member -NotePropertyName DeploymentStep -NotePropertyValue $stepIndex -Force
        }
        $Ctx | Add-Member -NotePropertyName DeploymentStep -NotePropertyValue 0 -Force
        return 'RESULTS'
    }

    # Single step: wait for it, showing the table as it goes.
    Write-Host ''
    Write-Host '  Waiting for the operation to complete...' -ForegroundColor DarkGray
    $settled = Wait-WuuRowsSettled -Ctx $Ctx -Targets $targets
    if (-not $settled) {
        Write-Host '  Bounded wait elapsed - reporting the state as it stands.' -ForegroundColor Yellow
    }
    Write-WuuExecutionTable -Ctx $Ctx -Targets $targets
    return 'RESULTS'
}

function Get-WuuWorkflowNameForOperation {
    <# Maps an operation id onto the workflow spec that drives it, if any. #>
    param([Parameter(Mandatory)][string]$Operation)
    switch ($Operation.ToLowerInvariant()) {
        'deploy' { 'deploy' }
        default  { '' }
    }
}

function Write-WuuExecutionTable {
    <# Spec 14's per-computer progress view. #>
    param(
        [Parameter(Mandatory)]$Ctx,
        [AllowEmptyCollection()][string[]]$Targets = @()
    )

    Write-Host ''
    $fmt = '    {0,-22} {1,-16} {2}'
    Write-Host ($fmt -f 'COMPUTER', 'STATE', 'DETAIL') -ForegroundColor DarkCyan
    foreach ($r in @(Get-WuuComputerSetComputers -Set $Ctx.Set)) {
        if (@($Targets).Count -gt 0 -and $Targets -notcontains $r.Computer) { continue }
        $s = Get-WuuRowOperationState -Row $r
        Write-Host ($fmt -f $r.Computer, $s.Name, ([string]$r.Status)) -ForegroundColor $s.Color
    }
}

function Show-WuuResultsScreen {
    <#
    .SYNOPSIS Spec 15: never finish with only "Operation complete."
    .DESCRIPTION
    Reports Successful / Failed / Offline / Reboot required, lists failures WITH their cause, and
    offers actionable next steps - retry failed, view errors, history, export, dashboard. The
    retry path narrows the set via $Ctx.RetryTargets so the next operation targets exactly the
    computers that failed, rather than making the operator re-select them (spec 6).
    #>
    param([Parameter(Mandatory)]$Ctx)

    $op = if ($Ctx.PSObject.Properties['ExecutionOperation']) { [string]$Ctx.ExecutionOperation } else { 'check' }
    if ([string]::IsNullOrWhiteSpace($op)) { $op = 'check' }

    $summary = Get-WuuComputerSetSummary -Set $Ctx.Set
    $computers = @(Get-WuuComputerSetComputers -Set $Ctx.Set)

    $failed = @($computers | Where-Object { [string]$_.State -eq 'Error' })
    $timedOut = @($computers | Where-Object { [string]$_.State -eq 'Timeout' })
    $rebootPending = @($computers | Where-Object { $_.RebootRequired })
    $successful = @($computers | Where-Object { [string]$_.State -eq 'Complete' })

    Write-WuuHeader 'RESULTS'
    Write-Host ("  Operation:      {0}" -f (Get-WuuOperationLabel -Operation $op)) -ForegroundColor White
    Write-Host ("  Successful:     {0}" -f $successful.Count) -ForegroundColor Green
    Write-Host ("  Failed:         {0}" -f ($failed.Count + $timedOut.Count)) -ForegroundColor $(if (($failed.Count + $timedOut.Count) -gt 0) { 'Red' } else { 'Gray' })
    Write-Host ("  Offline:        {0}" -f $summary.Offline) -ForegroundColor $(if ($summary.Offline -gt 0) { 'Yellow' } else { 'Gray' })
    Write-Host ("  Reboot required:{0}" -f $rebootPending.Count) -ForegroundColor $(if ($rebootPending.Count -gt 0) { 'Yellow' } else { 'Gray' })

    # Failures with their cause (spec 15). The row's Status is where the engine records why.
    if (($failed.Count + $timedOut.Count) -gt 0) {
        Write-Host ''
        Write-Host '  FAILURES' -ForegroundColor Red
        foreach ($f in ($failed + $timedOut)) {
            Write-Host ("    {0}" -f $f.Computer) -ForegroundColor Red
            Write-Host ("      {0}" -f ([string]$f.Status)) -ForegroundColor DarkRed
        }
    }

    if ($rebootPending.Count -gt 0) {
        Write-Host ''
        Write-Host '  REBOOT PENDING' -ForegroundColor Yellow
        foreach ($r in $rebootPending) { Write-Host ("    {0}" -f $r.Computer) -ForegroundColor Yellow }
    }

    Write-Host ''
    Write-Host '  Next actions:'
    Write-Host '    1. Retry failed computers'
    Write-Host '    2. View errors'
    Write-Host '    3. Update history'
    Write-Host '    4. Export audit bundle'
    Write-Host '    5. Deployment report (fleet history)'
    Write-Host '    6. Back to dashboard'
    Write-Host '    7. Exit'

    # Default moved to 6 because the new report entry took slot 5 and Enter must still mean
    # "carry on" - landing on the report would turn a reflexive Enter into a slow audit scan.
    $choice = [string](Read-WuuAnswer -Prompt '  Selection' -Default '6')
    switch ($choice.Trim().ToLowerInvariant()) {
        '1' {
            $targets = @(($failed + $timedOut) | ForEach-Object { $_.Computer })
            if ($targets.Count -eq 0) {
                Write-Host '  Nothing failed - nothing to retry.' -ForegroundColor DarkGray
                return 'RESULTS'
            }
            Write-Host ("  Retrying {0} computer(s): {1}" -f $targets.Count, ($targets -join ', ')) -ForegroundColor Cyan
            $Ctx | Add-Member -NotePropertyName RetryTargets -NotePropertyValue $targets -Force
            $Ctx | Add-Member -NotePropertyName PreflightOperation -NotePropertyValue $op -Force
            # Force a fresh pre-flight: the retry must not inherit the pre-flight that ran BEFORE
            # the failures, because the whole point of retrying is that something has changed.
            $Ctx | Add-Member -NotePropertyName Preflight -NotePropertyValue $null -Force
            return 'CONFIRM'
        }
        '2' { Invoke-WuuGuidedHandler -Ctx $Ctx -Handler 'GetErrors'; return 'RESULTS' }
        '3' { Invoke-WuuGuidedHandler -Ctx $Ctx -Handler 'EventShowUpdateHistory'; return 'RESULTS' }
        '4' { Invoke-WuuAuditSubVerb -Ctx $Ctx -SubVerb 'export'; return 'RESULTS' }
        '5' { return 'REPORT' }
        '7' { return 'EXIT' }
        default { return 'DASHBOARD' }
    }
}

function Start-WuuDeploymentSequence {
    <#
    .SYNOPSIS Spec 11: full deployment as an explicit, confirmable sequence.
    .DESCRIPTION
    Named for spec 13, which requires phases to be visible as part of deployment rather than
    hidden configuration: the confirmation step of the sequence reports the per-phase plan, so the
    operator sees which phase each computer belongs to at the moment they authorise the change.

    The screen itself is Show-WuuExecutionScreen, driven by the 'deploy' workflow spec - this
    function exists so a menu entry can name a state ('DEPLOYING') without that state having to
    know the workflow table.
    #>
    param([Parameter(Mandatory)]$Ctx)

    if ((Get-WuuComputerSetCount -Set $Ctx.Set) -eq 0) {
        Write-WuuHeader 'FULL DEPLOYMENT'
        Write-Host '  No computers in the set - nothing to deploy.' -ForegroundColor Yellow
        return 'DASHBOARD'
    }

    if ($Ctx.PSObject.Properties['RetryTargets']) {
        $Ctx | Add-Member -NotePropertyName RetryTargets -NotePropertyValue @() -Force
    }
    $Ctx | Add-Member -NotePropertyName ExecutionOperation -NotePropertyValue 'deploy' -Force
    $Ctx | Add-Member -NotePropertyName DeploymentStep -NotePropertyValue 0 -Force
    # A deployment starts a NEW sequence, so any pre-flight from an earlier operation must not be
    # treated as covering its first step.
    $Ctx | Add-Member -NotePropertyName Preflight -NotePropertyValue $null -Force
    $Ctx | Add-Member -NotePropertyName PreflightOperation -NotePropertyValue '' -Force

    Write-InfoLog 'Guided full deployment started (spec 11 sequence)'
    return Show-WuuExecutionScreen -Ctx $Ctx
}

#endregion Pre-flight, confirmation, execution and results

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
        # Set by Show-WuuPreflightScreen; read by the confirmation screen. Null means "pre-flight
        # has not run for the pending operation", which the confirmation screen treats as a reason
        # to offer running it rather than to assume the targets are fine.
        Preflight     = $null
        # The operation awaiting confirmation. Null means no operation is pending.
        Pending       = $null
        # Injectable probes so the workflow is drivable without a network. See
        # New-WuuPreflightContext for why they are injected rather than called directly.
        PreflightContext = (New-WuuPreflightContext)
        Quit          = $false
    }

    # Spec 3: never assume a computer set exists. Start at acquisition when empty.
    $state = if ((Get-WuuComputerSetCount -Set $set) -gt 0) { 'DASHBOARD' } else { 'ACQUIRE' }

    while ($state -ne 'EXIT') {
        # Drain queued work each tick - same reason as the flat menu: a console blocked in a prompt
        # has no message loop, so the scheduler must be polled by this loop.
        try { & $DrainScheduler } catch { Write-Warning "Scheduler tick failed: $($_.Exception.Message)" }

        # Screens below run synchronous, potentially slow work (pre-flight probes, then the update
        # steps themselves). The loop is not ticking while a screen is on the stack, so the drain
        # is passed down as ctx.Tick and the pre-flight/deployment loops poll it per computer.
        $ctx | Add-Member -NotePropertyName Tick -NotePropertyValue $DrainScheduler -Force

        # Validate the hand-off BEFORE dispatching. A screen that returns something other than a state
        # name (see the Out-Null note in Invoke-WuuGuidedHandler) makes the switch below meaningless, and
        # the old `default` arm then reported it as an "unknown workflow state" - which names the symptom
        # and hides the cause. Naming the real problem where it happens is the difference between a
        # five-minute fix and the two confusing messages that this check exists to replace.
        if ($state -isnot [string] -or [string]::IsNullOrWhiteSpace($state)) {
            # $null is the most likely value here, and $null.GetType() throws - so the type name is
            # derived defensively. A diagnostic that crashes while reporting a defect is worse than
            # the defect.
            $stateType = if ($null -eq $state) { 'null' } else { $state.GetType().Name }
            Write-Host ''
            Write-Host '  DEFECT: a workflow screen returned something that is not a state name, so the' -ForegroundColor Red
            Write-Host '          workflow cannot continue from it. Returning to the dashboard.' -ForegroundColor Red
            Write-Host ("          Received: {0} of type {1}" -f ($state | Out-String -Width 200).Trim(), $stateType) -ForegroundColor DarkRed
            $state = 'DASHBOARD'
            continue
        }

        switch ($state) {
            'ACQUIRE'      { $state = Show-WuuAcquisitionScreen -Ctx $ctx }
            'MANUAL'       { $state = Show-WuuManualEntryScreen -Ctx $ctx }
            'IMPORT'       { $state = Show-WuuImportScreen -Ctx $ctx }
            'REVIEW'       { $state = Show-WuuComputerSetReviewScreen -Ctx $ctx }
            'DASHBOARD'    { $state = Show-WuuDashboardScreen -Ctx $ctx }
            'UPDATES'      { $state = Show-WuuCategoryScreen -Ctx $ctx -Title 'UPDATES & DEPLOYMENT' -Items @(Get-WuuUpdateManagementMenu) -State 'UPDATES' }
            'COMPUTERS'    { $state = Show-WuuCategoryScreen -Ctx $ctx -Title 'COMPUTER FLEET' -Items @(Get-WuuComputerManagementMenu) -State 'COMPUTERS' }
            'DIAGNOSTICS'  { $state = Show-WuuCategoryScreen -Ctx $ctx -Title 'DIAGNOSTICS & HEALTH' -Items @(Get-WuuDiagnosticsMenu) -State 'DIAGNOSTICS' }
            'REPORTS'      { $state = Show-WuuCategoryScreen -Ctx $ctx -Title 'REPORTS & AUDIT' -Items @(Get-WuuReportsMenu) -State 'REPORTS' }
            'SETTINGS'     { $state = Show-WuuCategoryScreen -Ctx $ctx -Title 'SETTINGS & CREDENTIALS' -Items @(Get-WuuSettingsMenu) -State 'SETTINGS' }
            'REPORT'       { $state = Show-WuuReportScreen -Ctx $ctx }
            'ADVANCED'     { $state = Show-WuuAdvancedScreen -Ctx $ctx }
            'PREFLIGHT'    { $state = Show-WuuPreflightScreen -Ctx $ctx }
            'CONFIRM'      { $state = Show-WuuOperationConfirmationScreen -Ctx $ctx }
            'EXECUTING'    { $state = Show-WuuExecutionScreen -Ctx $ctx }
            'RESULTS'      { $state = Show-WuuResultsScreen -Ctx $ctx }
            'DEPLOYING'    { $state = Start-WuuDeploymentSequence -Ctx $ctx }
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
    'Get-WuuDiagnosticsMenu'
    'Get-WuuSettingsMenu'
    'Get-WuuReportsMenu'
    'Get-WuuWorkflowSpec'
    'Select-WuuImportColumn'
    'Show-WuuAcquisitionScreen'
    'Show-WuuManualEntryScreen'
    'Show-WuuImportScreen'
    'Show-WuuComputerSetReviewScreen'
    'Show-WuuDashboardScreen'
    'Show-WuuCategoryScreen'
    'Show-WuuReportScreen'
    'Invoke-WuuReportExportScreen'
    'Show-WuuAdvancedScreen'
    'Show-WuuPreflightScreen'
    'Show-WuuOperationConfirmationScreen'
    'Show-WuuExecutionScreen'
    'Show-WuuResultsScreen'
    'Start-WuuDeploymentSequence'
    'New-WuuPreflightContext'
    'Invoke-WuuPreflightCheck'
    'Confirm-WuuMutation'
    'Get-WuuRowOperationState'
    'Invoke-WuuGuidedHandler'
    'Invoke-WuuAuditSubVerb'
    'Start-WuuGuidedWorkflow'
)
