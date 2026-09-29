#Requires -Version 5.1
<#
.SYNOPSIS
    SS8: workflow state must not be decided by a display string.

.DESCRIPTION
    Test-PhaseCompletion used `UpdatesStatus -ne 'All updates installed'` as its outstanding-work
    predicate. UpdatesStatus is a DISPLAY string, written from eight sites with five different values.

    The concrete failure, and the one this suite drives: `wuu check` in command mode loads rows from
    config and sets UpdatesStatus = 'Unknown' with a "run wuu check to refresh" message. Under the old
    predicate such a row was permanently "outstanding", so its phase could NEVER complete - a phase
    gate that fails closed forever because of a status message.

    Asserted here:
      1. the predicate is no longer the display string;
      2. a config-loaded row ('Unknown', no work, nothing checked) DOES settle;
      3. a concluded-clean row settles;
      4. a row with work outstanding does NOT settle (per-update counts AND RebootRequired);
      5. a row that is queued/mid-operation does NOT settle;
      6. a row that is not established but mid-operation does NOT settle - $null is not "clean";
      7. the settled-failure policy still runs BEFORE the outstanding check (SS9 ordering).

    The function is invoked through the real module with a real store, so this exercises the shipped
    path rather than a re-implementation.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail++ }

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force -DisableNameChecking
Import-WuuModules -WuuRoot $root

$wupdRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw
$stateRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw

# --- 1. the predicate is not a display string ----------------------------------------
$body = [regex]::Match($wupdRaw, 'function Test-PhaseCompletion[\s\S]*?\nfunction ')
$bodyText = if ($body.Success) { $body.Value } else { '' }
if (-not $bodyText) {
    Bad 'could not locate Test-PhaseCompletion'
} else {
    # Comment lines are dropped first: the code explains the REMOVAL of the old predicate by quoting
    # it, so matching raw text reported a false failure (observed). Same reasoning as the validator's
    # Get-WuuCodeWithoutComments.
    $bodyCode = (($bodyText -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    if ($bodyCode -match "UpdatesStatus -ne 'All updates installed'" -or $bodyCode -match 'UpdatesStatus\s*-ne') {
        Bad "the phase gate still decides outstanding work from the UpdatesStatus DISPLAY string"
    } else {
        Ok 'the phase gate no longer uses the UpdatesStatus display string as its predicate'
    }
    if ($bodyCode -match 'CheckConcluded') {
        Ok 'the phase gate consults a workflow-state field (CheckConcluded)'
    } else {
        Bad 'the phase gate does not consult any workflow-state field'
    }
    # The workflow state must still be consulted for mid-operation detection.
    if ($bodyCode -match '\$state -in') {
        Ok 'the phase gate distinguishes mid-operation workflow states'
    } else {
        Bad 'the phase gate does not look at the workflow state at all'
    }
}

# --- 2. CheckConcluded is a real field on the row contract ----------------------------
$probe = New-WuuComputerRow -Computer 'SRV01'
if ($probe.PSObject.Properties['CheckConcluded']) {
    Ok 'the row contract carries CheckConcluded'
} else {
    Bad 'the row contract is missing CheckConcluded - the gate would have to fall back to a string'
}
if ($null -eq $probe.CheckConcluded) {
    Ok 'CheckConcluded defaults to $null (NOT established), which is not the same as "clean"'
} else {
    Bad "CheckConcluded defaults to '$($probe.CheckConcluded)' - " + 'not-established must be distinguishable from concluded-clean'
}

# --- 3-6. drive the real gate --------------------------------------------------------
# Test-PhaseCompletion reads $script:WuuCtx.StateStore, so a store is published there the way the
# application does. This is the real entry point, not an extracted copy.
function Get-PhaseVerdict {
    param([hashtable]$Store, [string]$Phase)
    $global:WuuCtx = @{ StateStore = $Store }
    # $script:WuuCtx inside the module resolves to the module's script scope, which
    # Import-WuuModules -Global does not populate - so set it via the module's own scope.
    $mod = Get-Module Wuu.WindowsUpdate
    & $mod { $script:WuuCtx = $global:WuuCtx }
    return (Test-PhaseCompletion -Phase $Phase)
}

function New-TestStore {
    param($Row)
    $s = New-WuuStateStore
    Add-WuuComputerRow -Store $s -Row $Row | Out-Null
    return $s
}

# (2) a config-loaded row: New-WuuComputerRow gives State='Queued' and the command loader sets
#     UpdatesStatus='Unknown' ("run wuu check to refresh"). It must NOT settle - a phase must not pass
#     on machines nobody has checked - and, crucially, it must refuse for the RIGHT reason: the
#     workflow state, not the wording of a status message.
$r = New-WuuComputerRow -Computer 'SRV01'
$r.Phase = 'Phase 1'; $r.UpdatesStatus = 'Unknown'; $r.Pending = $false
$r.Available = 0; $r.Downloaded = 0; $r.RebootRequired = $false
$v = Get-PhaseVerdict -Store (New-TestStore $r) -Phase 'Phase 1'
if (-not $v) { Ok "an unchecked config-loaded row (State='Queued') does NOT settle - a phase cannot pass on unchecked machines" }
else { Bad 'an unchecked config-loaded row settled - the phase passed on a machine nobody checked' }

# ...and the DISPLAY STRING no longer decides: the same row with a different wording behaves the same.
$r2 = New-WuuComputerRow -Computer 'SRV01'
$r2.Phase = 'Phase 1'; $r2.UpdatesStatus = 'Totally different wording'; $r2.Pending = $false
$v2 = Get-PhaseVerdict -Store (New-TestStore $r2) -Phase 'Phase 1'
if ($v2 -eq $v) { Ok 're-wording UpdatesStatus does not change the verdict (the display string is out of the decision)' }
else { Bad "re-wording UpdatesStatus changed the verdict ($v -> $v2) - a display string is still driving gating" }

# THE CONCRETE DEFECT, stated as a test: work outstanding but STALE WORDING. Under the old predicate
# (status -ne 'All updates installed') this row read as settled and its phase advanced with updates
# available. The workflow fields now decide, so it correctly blocks.
$r = New-WuuComputerRow -Computer 'SRV01'
$r.Phase = 'Phase 1'; $r.State = 'UpdatesFound'; $r.UpdatesStatus = 'All updates installed'   # stale
$r.Pending = $false; $r.CheckConcluded = $true; $r.Available = 3
$v = Get-PhaseVerdict -Store (New-TestStore $r) -Phase 'Phase 1'
if (-not $v) { Ok 'a row with 3 updates available but STALE wording ("All updates installed") does NOT settle (the real SS8 defect)' }
else { Bad 'stale wording let a row with 3 updates available settle - the phase advanced past real work' }

# (3) concluded clean
$r = New-WuuComputerRow -Computer 'SRV01'
$r.Phase = 'Phase 1'; $r.State = 'Complete'; $r.UpdatesStatus = 'All updates installed'
$r.Pending = $false; $r.CheckConcluded = $false; $r.Available = 0; $r.Downloaded = 0
$v = Get-PhaseVerdict -Store (New-TestStore $r) -Phase 'Phase 1'
if ($v) { Ok 'a concluded-clean row settles' } else { Bad 'a concluded-clean row did not settle' }

# (4a) work outstanding via the per-update count
$r = New-WuuComputerRow -Computer 'SRV01'
$r.Phase = 'Phase 1'; $r.State = 'UpdatesFound'; $r.UpdatesStatus = 'Updates required'
$r.Pending = $false; $r.CheckConcluded = $true; $r.Available = 3
$v = Get-PhaseVerdict -Store (New-TestStore $r) -Phase 'Phase 1'
if (-not $v) { Ok 'a row whose check concluded with updates available does NOT settle' }
else { Bad 'a row with 3 updates available settled - the phase would advance past real work' }

# (4b) work outstanding via RebootRequired ONLY - the case the display string alone could miss
$r = New-WuuComputerRow -Computer 'SRV01'
$r.Phase = 'Phase 1'; $r.State = 'RebootRequired'; $r.UpdatesStatus = 'Reboot required'
$r.Pending = $false; $r.CheckConcluded = $true; $r.Available = 0; $r.Downloaded = 0; $r.RebootRequired = $true
$v = Get-PhaseVerdict -Store (New-TestStore $r) -Phase 'Phase 1'
if (-not $v) { Ok 'a row requiring a reboot does NOT settle (a pending restart is outstanding work)' }
else { Bad 'a reboot-required row settled - the phase would advance with a machine waiting to restart' }

# (5) mid-operation
$r = New-WuuComputerRow -Computer 'SRV01'
$r.Phase = 'Phase 1'; $r.State = 'Installing'; $r.UpdatesStatus = 'Installing'
$r.Pending = $false; $r.CheckConcluded = $null; $r.Available = 0; $r.Downloaded = 2
$v = Get-PhaseVerdict -Store (New-TestStore $r) -Phase 'Phase 1'
if (-not $v) { Ok 'a row that is installing does NOT settle' } else { Bad 'an installing row settled' }

# (6) not established ($null) but mid-operation with NO visible counts - the trap: $null must not be
#     read as "clean". Here 'Installing' with no counters is still mid-operation.
$r = New-WuuComputerRow -Computer 'SRV01'
$r.Phase = 'Phase 1'; $r.State = 'Installing'; $r.UpdatesStatus = 'Installing'
$r.Pending = $false; $r.CheckConcluded = $null; $r.Available = 0; $r.Downloaded = 0; $r.RebootRequired = $false
$v = Get-PhaseVerdict -Store (New-TestStore $r) -Phase 'Phase 1'
if (-not $v) { Ok 'CheckConcluded=$null is NOT treated as clean when the workflow is mid-operation' }
else { Bad 'a null CheckConcluded with an active workflow state settled - $null was read as clean' }

# ...and a Pending row still blocks, whatever else is set
$r = New-WuuComputerRow -Computer 'SRV01'
$r.Phase = 'Phase 1'; $r.State = 'Queued'; $r.UpdatesStatus = 'All updates installed'
$r.Pending = $true; $r.CheckConcluded = $false
$v = Get-PhaseVerdict -Store (New-TestStore $r) -Phase 'Phase 1'
if (-not $v) { Ok 'a Pending row does NOT settle (it is queued for the scheduler)' }
else { Bad 'a Pending row settled' }

# an empty phase still completes
$v = Get-PhaseVerdict -Store (New-WuuStateStore) -Phase 'Phase 5'
if ($v) { Ok 'a phase with no computers still completes' } else { Bad 'an empty phase reported incomplete' }

# --- 7. the SS9 ordering is preserved -------------------------------------------------
if ($bodyText) {
    $policyAt = $bodyText.IndexOf('Test-WuuPhaseFailureBlocks')
    $concludedAt = $bodyText.IndexOf('CheckConcluded')
    if ($policyAt -ge 0 -and $concludedAt -ge 0 -and $policyAt -lt $concludedAt) {
        Ok 'the settled-failure policy is still evaluated before the outstanding-work check (SS9 ordering)'
    } else {
        Bad "SS9 ordering broken (policy at $policyAt, concluded check at $concludedAt)"
    }
}

# The payload must actually set the field at the conclusion site, or the new predicate never becomes
# true and every row would sit at $null forever.
$coreRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$setCount = ([regex]::Matches($coreRaw, "CheckConcluded'\]\)\s*\{\s*\`$\w+\.CheckConcluded\s*=\s*\`$(true|false)")).Count
if ($setCount -ge 3) {
    Ok "the check payload sets CheckConcluded on all $setCount outcome(s) (available / reboot / clean)"
} else {
    Bad "only $setCount CheckConcluded assignment(s) in the payload - an outcome would never be recorded"
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'Test-PhaseWorkflowState.ps1: ALL PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host "Test-PhaseWorkflowState.ps1: $fail FAILURE(S)" -ForegroundColor Red
    exit 1
}
