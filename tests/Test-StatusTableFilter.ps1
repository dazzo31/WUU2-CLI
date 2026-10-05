#Requires -Version 5.1
<#
.SYNOPSIS Status table view filter and State=Error / Status=Up-to-Date consistency tests (CLI-FILTER-01).
.DESCRIPTION
Validates:
  1. Test-WuuRowFilter correctly filters rows by category:
     - 'NeedsAttention' (Primary: hides clean settled up-to-date systems)
     - 'Active' (currently running operations)
     - 'Failed' (errors, timeouts, offline)
     - 'Updates' (available or downloaded updates > 0)
     - 'Reboot' (reboot required)
     - 'All' (unfiltered fleet view)
  2. An errored system (State='Error' or Color='Error') is NEVER hidden by NeedsAttention
  3. Get-WuuFilteredRows returns exact matching subsets
  4. EventDownloadUpdates does not falsely stamp 'Up-to-Date' on errored or offline hosts
  5. Successful scan conclusion clears stale Error color to Success
  6. Menu wiring for key 'f' in flat and guided menus

Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-StatusTableFilter.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$fail = $false
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail = $true }
function Pass($m) { Write-Host "PASS: $m" -ForegroundColor Green }

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

$global:EnableDebugLogging = $false

# ---------------------------------------------------------------------------------------
# 1. Test-WuuRowFilter - Primary Filter: NeedsAttention (Hide Up-to-Date)
# ---------------------------------------------------------------------------------------
# A clean settled host must be HIDDEN (evaluates to $false for NeedsAttention)
$cleanRow = New-WuuComputerRow -Computer 'CLEAN01' -Phase 'Phase 1'
$cleanRow.State = 'Complete'
$cleanRow.Color = 'Success'
$cleanRow.Available = 0
$cleanRow.Downloaded = 0
$cleanRow.RebootRequired = $false
$cleanRow.InstallErrors = 0
$cleanRow.OpState = 'Idle'
$cleanRow.Pending = $false
$cleanRow.Status = 'Up-to-date. No updates available.'

if (Test-WuuRowFilter -Row $cleanRow -Filter 'NeedsAttention') {
    Fail "clean settled host was NOT hidden by NeedsAttention filter"
} else {
    Pass "clean settled host is hidden by NeedsAttention filter ($false)"
}

# A host with available updates must be SHOWN
$withUpdatesRow = New-WuuComputerRow -Computer 'UPD01' -Phase 'Phase 1'
$withUpdatesRow.Available = 3
if (-not (Test-WuuRowFilter -Row $withUpdatesRow -Filter 'NeedsAttention')) {
    Fail "host with available updates was hidden by NeedsAttention filter"
} else {
    Pass "host with available updates is shown by NeedsAttention filter"
}

# A host requiring reboot must be SHOWN
$rebootRow = New-WuuComputerRow -Computer 'RBT01' -Phase 'Phase 1'
$rebootRow.State = 'Complete'
$rebootRow.RebootRequired = $true
if (-not (Test-WuuRowFilter -Row $rebootRow -Filter 'NeedsAttention')) {
    Fail "host requiring reboot was hidden by NeedsAttention filter"
} else {
    Pass "host requiring reboot is shown by NeedsAttention filter"
}

# An errored host (Available=0) must NEVER be hidden by NeedsAttention
$errorRow = New-WuuComputerRow -Computer 'ERR01' -Phase 'Phase 1'
$errorRow.State = 'Error'
$errorRow.Color = 'Error'
$errorRow.Available = 0
$errorRow.Downloaded = 0
$errorRow.Status = 'Error occurred: RPC server unavailable.'
if (-not (Test-WuuRowFilter -Row $errorRow -Filter 'NeedsAttention')) {
    Fail "errored host was falsely hidden by NeedsAttention filter (contradiction escape)"
} else {
    Pass "errored host is retained by NeedsAttention filter"
}

# A running host must be SHOWN
$runningRow = New-WuuComputerRow -Computer 'RUN01' -Phase 'Phase 1'
$runningRow.OpState = 'Running'
if (-not (Test-WuuRowFilter -Row $runningRow -Filter 'NeedsAttention')) {
    Fail "running host was hidden by NeedsAttention filter"
} else {
    Pass "running host is shown by NeedsAttention filter"
}

# ---------------------------------------------------------------------------------------
# 2. Status-based filters: Active, Failed, Updates, Reboot, All
# ---------------------------------------------------------------------------------------
# Active filter
if (-not (Test-WuuRowFilter -Row $runningRow -Filter 'Active')) { Fail "running host not matched by Active filter" }
else { Pass "Active filter matches running host" }

if (Test-WuuRowFilter -Row $cleanRow -Filter 'Active') { Fail "idle host matched by Active filter" }
else { Pass "Active filter rejects idle host" }

# Failed filter
if (-not (Test-WuuRowFilter -Row $errorRow -Filter 'Failed')) { Fail "errored host not matched by Failed filter" }
else { Pass "Failed filter matches errored host" }

$timeoutRow = New-WuuComputerRow -Computer 'TIME01' -Phase 'Phase 1'
$timeoutRow.State = 'Timeout'
$timeoutRow.Color = 'Timeout'
if (-not (Test-WuuRowFilter -Row $timeoutRow -Filter 'Failed')) { Fail "timeout host not matched by Failed filter" }
else { Pass "Failed filter matches timeout host" }

if (Test-WuuRowFilter -Row $cleanRow -Filter 'Failed') { Fail "clean host matched by Failed filter" }
else { Pass "Failed filter rejects clean host" }

# Updates filter
if (-not (Test-WuuRowFilter -Row $withUpdatesRow -Filter 'Updates')) { Fail "host with updates not matched by Updates filter" }
else { Pass "Updates filter matches host with available updates" }

if (Test-WuuRowFilter -Row $cleanRow -Filter 'Updates') { Fail "clean host matched by Updates filter" }
else { Pass "Updates filter rejects host with 0 updates" }

# Reboot filter
if (-not (Test-WuuRowFilter -Row $rebootRow -Filter 'Reboot')) { Fail "reboot host not matched by Reboot filter" }
else { Pass "Reboot filter matches reboot-pending host" }

if (Test-WuuRowFilter -Row $cleanRow -Filter 'Reboot') { Fail "clean host matched by Reboot filter" }
else { Pass "Reboot filter rejects clean host" }

# All filter
if (-not (Test-WuuRowFilter -Row $cleanRow -Filter 'All') -or -not (Test-WuuRowFilter -Row $errorRow -Filter 'All')) {
    Fail "All filter failed to match all rows"
} else {
    Pass "All filter matches all rows"
}

# ---------------------------------------------------------------------------------------
# 3. Get-WuuFilteredRows Fleet Projection
# ---------------------------------------------------------------------------------------
$fleet = @($cleanRow, $withUpdatesRow, $rebootRow, $errorRow, $runningRow, $timeoutRow)
$attentionOnly = @(Get-WuuFilteredRows -Rows $fleet -Filter 'NeedsAttention')
if ($attentionOnly.Count -ne 5) {
    Fail "expected 5 rows needing attention (1 clean hidden), got $($attentionOnly.Count)"
} else {
    Pass "NeedsAttention correctly hid exactly 1 clean host from a 6-node fleet"
}

$failedOnly = @(Get-WuuFilteredRows -Rows $fleet -Filter 'Failed')
if ($failedOnly.Count -ne 2) {
    Fail "expected 2 failed rows (ERR01, TIME01), got $($failedOnly.Count)"
} else {
    Pass "Failed filter correctly selected exactly 2 failed hosts"
}

# ---------------------------------------------------------------------------------------
# 4. State=Error / Status=Up-to-Date Bug Fix Verification
# ---------------------------------------------------------------------------------------
$coreRaw = [string](Get-Content (Join-Path $root 'src\Wuu.Core.psm1') -Raw)
$cmdRaw = [string](Get-Content (Join-Path $root 'src\Wuu.Command.psm1') -Raw)

# EventDownloadUpdates guards no-op check so errored hosts are not stamped 'Up-to-Date'
$dlBody = [regex]::Match($coreRaw, '\$consoleActions\.EventDownloadUpdates\s*=\s*\{[\s\S]*?\n\}').Value
if ($dlBody -match "State\s+-in\s+@\('Error',\s*'Timeout',\s*'Offline'\)") {
    Pass "EventDownloadUpdates guards no-op check against Error/Timeout/Offline states"
} else {
    Fail "EventDownloadUpdates does NOT guard no-op check against Error/Timeout/Offline states"
}

# Scan recovery clears Error color to Success
$checkSuccessMatch = ($coreRaw -match "UpdatesStatus\s*=\s*'All updates installed'[\s\S]*?State\s*=\s*'Complete'[\s\S]*?Color\s*=\s*'Success'")
if ($checkSuccessMatch) {
    Pass "GetUpdates clean completion explicitly clears row Color to 'Success'"
} else {
    Fail "GetUpdates clean completion does NOT reset Color to 'Success'"
}

# Command mode dry-run guards errored hosts against no-op
$cmdDlMatch = ($cmdRaw -match "in error/offline state \(\`$\(\`$r\.State\)\) - check required before downloading")
if ($cmdDlMatch) {
    Pass "ConvertTo-WuuCommandLine rejects no-op resolution for errored hosts"
} else {
    Fail "ConvertTo-WuuCommandLine does not reject no-op resolution for errored hosts"
}

# ---------------------------------------------------------------------------------------
# 5. Menu Wiring Verification for Key 'f'
# ---------------------------------------------------------------------------------------
$menu = @(Get-WuuMenuActions)
$fAction = $menu | Where-Object { $_.Key -eq 'f' }
if (-not $fAction) {
    Fail "Get-WuuMenuActions does not contain key 'f'"
} elseif ($fAction.Handler -ne 'EventSetViewFilter') {
    Fail "key 'f' is not wired to EventSetViewFilter ($($fAction.Handler))"
} else {
    Pass "key 'f' is wired to EventSetViewFilter in flat menu actions"
}

$fleetMenu = @(Get-WuuComputerManagementMenu)
$fFleet = $fleetMenu | Where-Object { $_.Key -eq 'f' }
if (-not $fFleet) {
    Fail "Get-WuuComputerManagementMenu does not contain key 'f'"
} elseif ($fFleet.Handler -ne 'EventSetViewFilter') {
    Fail "fleet menu key 'f' is not wired to EventSetViewFilter ($($fFleet.Handler))"
} else {
    Pass "key 'f' is wired to EventSetViewFilter in guided computer menu"
}

$filterHandlerMatch = ($coreRaw -match '\$consoleActions\.EventSetViewFilter\s*=')
if (-not $filterHandlerMatch) {
    Fail "consoleActions does not contain EventSetViewFilter handler in Wuu.Core.psm1"
} else {
    Pass "consoleActions.EventSetViewFilter handler is registered in Wuu.Core.psm1"
}

# ---------------------------------------------------------------------------------------
# Final Verdict
# ---------------------------------------------------------------------------------------
if ($script:fail) {
    Write-Host "`nTest-StatusTableFilter: FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nTest-StatusTableFilter: ALL ASSERTIONS PASSED" -ForegroundColor Green
    exit 0
}
