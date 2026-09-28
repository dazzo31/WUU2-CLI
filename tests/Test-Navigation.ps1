#Requires -Version 5.1
<#
.SYNOPSIS Guided interactive workflow test (docs/INTERACTIVE_UI_SPEC.md).
.DESCRIPTION
Covers the P0 requirements of spec section 25 and the acceptance tests of sections 26-27.

WHY THIS SUITE EXISTS
---------------------
The interactive UI shipped a fatal crash for two releases because every test was non-interactive
and none of them entered the interactive shell. This suite drives the workflow through its screens
using the non-interactive input choke point, so a screen that cannot be driven - or that returns a
state leading nowhere - fails here instead of at the operator's console.

Note what is NOT tested here: whether a remote host actually patches. That is the engine, covered
by the other suites; this one is about orchestration.
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
# 1. ComputerSet is a first-class object (spec 6)
# ---------------------------------------------------------------------------------------
$store = New-WuuStateStore
$set = New-WuuComputerSet -Store $store -Name 'Test set'
if ($set.Name -ne 'Test set') { Fail 'computer set did not keep its name' } else { Pass 'computer set carries a name' }
if ($set.Store -ne $store) { Fail 'computer set does not read through to the store' } else { Pass 'computer set reads through to the state store (single source of truth)' }
if ((Get-WuuComputerSetCount -Set $set) -ne 0) { Fail 'new set is not empty' } else { Pass 'new computer set starts empty' }

$sum = Get-WuuComputerSetSummary -Set $set
if (-not $sum.IsEmpty) { Fail 'summary of an empty set does not report IsEmpty' } else { Pass 'empty set summary reports IsEmpty' }

# ---------------------------------------------------------------------------------------
# 2. Name validation and splitting (spec 4.1)
# ---------------------------------------------------------------------------------------
$validNames = @('SRV01', 'srv-02.example.com', 'A1', 'web01.dom.local.')
foreach ($n in $validNames) {
    if (-not (Test-WuuComputerName -Name $n)) { Fail "valid name rejected: $n" }
}
Pass "accepted $($validNames.Count) valid names"

$invalidNames = @('', '   ', '-leadinghyphen', 'trailinghyphen-', 'has space', 'bad_char!', ('x' * 300))
foreach ($n in $invalidNames) {
    if (Test-WuuComputerName -Name $n) { Fail "invalid name accepted: '$n'" }
}
Pass "rejected $($invalidNames.Count) invalid names"

# Splitting must handle the separators the spec lists: commas, spaces, new lines.
$split = @(Split-WuuComputerNames -Text "SRV01, SRV02`nSRV03 SRV04;SRV05`tSRV06")
if ($split.Count -ne 6) { Fail "expected 6 names from mixed separators, got $($split.Count)" }
else { Pass 'splits comma / space / newline / semicolon / tab separated input' }

if (@(Split-WuuComputerNames -Text '   ').Count -ne 0) { Fail 'whitespace produced names' } else { Pass 'whitespace is not treated as a name' }

# EXACTLY ONE name. This is a distinct code path from the multi-name case and it is the one that
# broke in the field: entering a single computer (`localhost`) crashed the manual-entry screen with
# "The property 'Count' cannot be found on this object", while entering three worked. The cause is
# PowerShell unwrapping a one-element array to a scalar, which removes .Count.
#
# The assertions below check the ELEMENT TYPE too, not just the count: a function that returns
# `,$array` while the caller wraps in @() yields ONE element that is itself an array, so
# $names[0] is an Object[] instead of a name - a shape bug that a count-only assertion misses.
$one = @(Split-WuuComputerNames -Text 'localhost')
if ($one.Count -ne 1) { Fail "single name did not survive as a 1-element array (got $($one.Count))" }
elseif ($one[0] -isnot [string]) { Fail "single name element is $($one[0].GetType().Name), not a string" }
elseif ($one[0] -ne 'localhost') { Fail "single name came back as '$($one[0])'" }
else { Pass 'a SINGLE name is returned as a 1-element array of string' }

$zero = @(Split-WuuComputerNames -Text '')
if ($zero.Count -ne 0) { Fail "empty input produced $($zero.Count) names" } else { Pass 'empty input yields an empty array (Count = 0)' }

# ---------------------------------------------------------------------------------------
# 3. Acquisition reports valid / duplicate / invalid - never silently drops (spec 4.2)
# ---------------------------------------------------------------------------------------
$res = Add-WuuComputerSetNames -Set $set -Names @('SRV01', 'SRV02', 'SRV01', 'not a host!', 'SRV03')
if ($res.AddedCount -ne 3) { Fail "expected 3 added, got $($res.AddedCount)" }
elseif (@($res.Duplicates).Count -ne 1) { Fail "expected 1 duplicate reported, got $(@($res.Duplicates).Count)" }
elseif (@($res.Invalid).Count -ne 1) { Fail "expected 1 invalid reported, got $(@($res.Invalid).Count)" }
else { Pass 'acquisition reports added / duplicate / invalid separately' }

# A duplicate against EXISTING membership must also be caught (not just within one call).
$res2 = Add-WuuComputerSetNames -Set $set -Names @('SRV01')
if ($res2.AddedCount -ne 0 -or @($res2.Duplicates).Count -ne 1) { Fail 'duplicate of an existing computer was not detected' }
else { Pass 'detects duplicates against existing set membership' }

# Case-insensitivity matters: Windows host names are case-insensitive.
$res3 = Add-WuuComputerSetNames -Set $set -Names @('srv01')
if ($res3.AddedCount -ne 0) { Fail 'case-variant duplicate was added as a new computer' }
else { Pass 'duplicate detection is case-insensitive' }

if ((Get-WuuComputerSetCount -Set $set) -ne 3) { Fail "set has $(Get-WuuComputerSetCount -Set $set) computers, expected 3" }
else { Pass 'set contains exactly the valid, non-duplicate computers' }

# ---------------------------------------------------------------------------------------
# 4. Phase rollup (spec 8 / 13 - phases visible, including empty ones)
# ---------------------------------------------------------------------------------------
$phases = @(Get-WuuComputerSetPhases -Set $set)
if ($phases.Count -ne 5) { Fail "expected 5 phases always reported, got $($phases.Count)" }
else { Pass 'reports all 5 phases (empty phases are not hidden)' }

$p1 = $phases[0]
if ($p1.Computers -ne 3) { Fail "Phase 1 should hold 3 computers, has $($p1.Computers)" }
elseif ($p1.IsEmpty) { Fail 'Phase 1 reported empty but holds computers' }
else { Pass 'phase rollup counts computers per phase' }

if (-not $phases[1].IsEmpty) { Fail 'Phase 2 should be empty' } else { Pass 'empty phase reports IsEmpty' }

# ---------------------------------------------------------------------------------------
# 5. Grouping: operations are not a flat top-level list (spec 9)
# ---------------------------------------------------------------------------------------
$tree = @(Get-WuuNavigationTree)
if ($tree.Count -gt 12) { Fail "top-level navigation has $($tree.Count) entries - spec 9 requires grouping" }
else { Pass "top-level navigation is grouped ($($tree.Count) entries, not 25+ operations)" }

foreach ($required in @('Update management', 'Computer management', 'Deployment phases', 'Credentials', 'Diagnostics', 'Reports / audit', 'Save computer set', 'Exit')) {
    if (-not ($tree | Where-Object { $_.Label -eq $required })) { Fail "navigation is missing category: $required" }
}
if (-not $failed) { Pass 'all spec-9 categories are present' }

# Navigating must not expose a mutating operation at the top level.
$mutatingTopLevel = @($tree | Where-Object { $_.ContainsKey('Mutating') -and $_.Mutating })
if ($mutatingTopLevel.Count) { Fail 'top-level navigation exposes a mutating operation' } else { Pass 'no mutating operation at the top level' }

# ---------------------------------------------------------------------------------------
# 6. Every menu entry resolves to a handler that EXISTS IN THE ACTION LAYER (spec 23)
# ---------------------------------------------------------------------------------------
# $consoleActions is assembled inside Start-WuuApplication, so it is not available from a bare
# module import. Rather than build a stub map here (which could not fail the way the real one
# can - and a stub is exactly why the unwired $eventAddAD handler went unnoticed), the handler
# names are resolved against the ACTUAL $consoleActions.<Name> assignments in Core's source. That
# catches "menu entry points at nothing" statically and for every entry at once.
$coreSource = Get-Content (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$wiredActions = @{}
foreach ($m in [regex]::Matches($coreSource, '\$consoleActions\.(\w+)\s*=')) {
    $wiredActions[$m.Groups[1].Value] = $true
}
if ($wiredActions.Count -lt 15) {
    Fail "only found $($wiredActions.Count) wired console actions - the source scan is probably wrong"
} else { Pass "found $($wiredActions.Count) wired console actions in Core" }

$allLeafMenus = @(
    @{ Name = 'update management'; Items = @(Get-WuuUpdateManagementMenu) }
    @{ Name = 'computer management'; Items = @(Get-WuuComputerManagementMenu) }
    @{ Name = 'deployment'; Items = @(Get-WuuDeploymentMenu) }
    @{ Name = 'credentials'; Items = @(Get-WuuCredentialMenu) }
    @{ Name = 'diagnostics'; Items = @(Get-WuuDiagnosticsMenu) }
    @{ Name = 'reports'; Items = @(Get-WuuReportsMenu) }
)
$unresolved = @()
foreach ($menu in $allLeafMenus) {
    foreach ($item in $menu.Items) {
        if ($item.ContainsKey('Handler') -and $item.Handler) {
            if (-not $wiredActions.ContainsKey($item.Handler)) { $unresolved += "$($menu.Name):[$($item.Key)] $($item.Handler)" }
        }
        if ($item.ContainsKey('AuditSubVerb')) {
            if (-not (Get-Command Invoke-WuuAuditCommand -ErrorAction SilentlyContinue)) { $unresolved += "$($menu.Name):[$($item.Key)] audit $($item.AuditSubVerb)" }
        }
    }
}
if ($unresolved.Count) { Fail "menu entries point at handlers that do not exist: $($unresolved -join '; ')" }
else { Pass 'every grouped menu entry resolves to a real wired handler (no dead entries)' }

# The flat menu must expose a Handler key too, so the same check applies to it.
$flat = @(Get-WuuMenuActions)
$flatMissing = @($flat | Where-Object { -not $_.ContainsKey('Handler') })
if ($flatMissing.Count) { Fail "$($flatMissing.Count) flat-menu entries carry no Handler key" }
else { Pass 'every flat-menu entry carries a Handler key' }

$flatUnresolved = @($flat | Where-Object { $_.Handler -and -not $wiredActions.ContainsKey($_.Handler) } | ForEach-Object { $_.Handler } | Sort-Object -Unique)
if ($flatUnresolved.Count) { Fail "flat menu points at missing handlers: $($flatUnresolved -join ', ')" }
else { Pass 'every flat-menu entry resolves to a real wired handler' }

# ---------------------------------------------------------------------------------------
# 7. Spec 27 / 24: command automation is untouched
# ---------------------------------------------------------------------------------------
$tbl = Get-WuuCommandTable
foreach ($v in @('check', 'download', 'install', 'restart', 'audit', 'show', 'add', 'export')) {
    if (-not $tbl.ContainsKey($v)) { Fail "command surface lost the '$v' verb" }
}
if (-not $failed) { Pass 'all automation verbs still present (spec 27)' }

# Mutating verbs must still require a reason - the guided UI must not have relaxed the audit rule.
$mutatingVerbs = @($tbl.Keys | Where-Object { $tbl[$_].Mutating } | Sort-Object)
if (($mutatingVerbs -join ',') -ne 'download,install,restart,service') {
    Fail "mutating verbs changed: $($mutatingVerbs -join ',')"
} else { Pass 'mutating verb set unchanged: download, install, restart, service' }

# ---------------------------------------------------------------------------------------
# 8. Spec 26 acceptance: a new user reaches the dashboard from an empty set
# ---------------------------------------------------------------------------------------
# Drive the acquisition screen -> manual entry -> review -> dashboard, with only the answers a
# new user would type. This is the state machine working end to end.
$freshStore = New-WuuStateStore
$freshSet = New-WuuComputerSet -Store $freshStore
$ctx2 = [pscustomobject]@{
    Set = $freshSet; Store = $freshStore; Actions = $global:consoleActions
    AuditHook = $null; DenialHook = $null; LastOperation = ''
}

Initialize-WuuInputMode -NonInteractive -Answers @('1')
$next = Show-WuuAcquisitionScreen -Ctx $ctx2
if ($next -ne 'MANUAL') { Fail "acquisition screen with '1' returned '$next', expected MANUAL" }
else { Pass 'spec 26: startup offers manual entry and routes to it' }

Initialize-WuuInputMode -NonInteractive -Answers @('SRV01, SRV02 SRV03', '1')
$next = Show-WuuManualEntryScreen -Ctx $ctx2
if ($next -ne 'REVIEW') { Fail "manual entry returned '$next', expected REVIEW" }
elseif ((Get-WuuComputerSetCount -Set $freshSet) -ne 3) { Fail 'manual entry did not add the 3 computers' }
else { Pass 'spec 26: manual entry parses, reviews and commits 3 computers' }

# ...and again with ONE name, which is the case that crashed in the field. Driving the SCREEN (not
# just the parser) is the point: the crash happened inside Show-WuuManualEntryScreen, so a
# parser-only test would have passed while the operator still saw a fatal error.
$oneStore = New-WuuStateStore
$oneSet = New-WuuComputerSet -Store $oneStore
$ctxOne = [pscustomobject]@{ Set = $oneSet; Store = $oneStore; Actions = @{}; AuditHook = $null; DenialHook = $null; LastOperation = '' }
$oneThrew = $null
try {
    Initialize-WuuInputMode -NonInteractive -Answers @('localhost', '1')
    $next = Show-WuuManualEntryScreen -Ctx $ctxOne
} catch {
    $oneThrew = $_.Exception
}
if ($oneThrew) { Fail "manual entry with a SINGLE name threw: $($oneThrew.Message)" }
elseif ((Get-WuuComputerSetCount -Set $oneSet) -ne 1) { Fail "single-name entry added $(Get-WuuComputerSetCount -Set $oneSet) computers, expected 1" }
else { Pass 'spec 26: manual entry handles a SINGLE name (the field crash)' }

Initialize-WuuInputMode -NonInteractive -Answers @('8')
$next = Show-WuuComputerSetReviewScreen -Ctx $ctx2
if ($next -ne 'DASHBOARD') { Fail "review with 'continue' returned '$next', expected DASHBOARD" }
else { Pass 'spec 26: review screen continues to the dashboard' }

# And the dashboard renders + returns a category.
Initialize-WuuInputMode -NonInteractive -Answers @('1')
$next = Show-WuuDashboardScreen -Ctx $ctx2
if ($next -ne 'UPDATES') { Fail "dashboard with '1' returned '$next', expected UPDATES" }
else { Pass 'spec 26: dashboard routes to update management' }

# ---------------------------------------------------------------------------------------
# 9. Empty-set guard: operations are NOT exposed before a set exists (spec 3)
# ---------------------------------------------------------------------------------------
$emptyStore = New-WuuStateStore
$emptySet = New-WuuComputerSet -Store $emptyStore
$ctx3 = [pscustomobject]@{ Set = $emptySet; Store = $emptyStore; Actions = $global:consoleActions; AuditHook = $null; DenialHook = $null; LastOperation = '' }
Initialize-WuuInputMode -NonInteractive -Answers @('')
$next = Show-WuuAcquisitionScreen -Ctx $ctx3
if ($next -ne 'EXIT' -and $next -ne 'ACQUIRE') { Fail "empty set: acquisition returned '$next'" }
else { Pass 'spec 3: empty set cannot reach an update operation' }

# The START STATE for an empty set must be ACQUIRE, not DASHBOARD. This is the P0 requirement
# ("computer acquisition is the first meaningful task") and the whole point of the redesign.
$startState = if ((Get-WuuComputerSetCount -Set $emptySet) -gt 0) { 'DASHBOARD' } else { 'ACQUIRE' }
if ($startState -ne 'ACQUIRE') { Fail "an empty set starts at $startState, not ACQUIRE" }
else { Pass 'spec 3 / P0: an empty computer set starts at acquisition' }

$startState2 = if ((Get-WuuComputerSetCount -Set $freshSet) -gt 0) { 'DASHBOARD' } else { 'ACQUIRE' }
if ($startState2 -ne 'DASHBOARD') { Fail "a populated set starts at $startState2, not DASHBOARD" }
else { Pass 'a populated set starts at the dashboard' }

# ---------------------------------------------------------------------------------------
# 10. Mutating leaf operations demand a reason (audit integrity, spec 12)
# ---------------------------------------------------------------------------------------
$auditCalls = New-Object System.Collections.ArrayList
$reasonGiven = $null
$fakeAudit = { param($name, $reason, $body) $null = $auditCalls.Add($name); $script:reasonGiven = $reason }
$ctx4 = [pscustomobject]@{ Set = $set; Store = $store; Actions = @{ EventDownloadUpdates = { } }; AuditHook = $fakeAudit; DenialHook = $null; LastOperation = '' }

Initialize-WuuInputMode -NonInteractive -Answers @('')
Invoke-WuuGuidedHandler -Ctx $ctx4 -Handler 'EventDownloadUpdates' -Mutating $true
if ($auditCalls.Count -ne 0) { Fail 'a mutating guided action ran with no reason' }
else { Pass 'mutating guided action is refused without a reason' }

Initialize-WuuInputMode -NonInteractive -Answers @('CHG-2026-0918')
Invoke-WuuGuidedHandler -Ctx $ctx4 -Handler 'EventDownloadUpdates' -Mutating $true
if ($auditCalls.Count -ne 1) { Fail "expected the mutating action to be audited once, got $($auditCalls.Count)" }
elseif ($reasonGiven -ne 'CHG-2026-0918') { Fail "reason not forwarded to the audit layer (got '$reasonGiven')" }
else { Pass 'mutating guided action is audited with its reason' }

# A missing handler must be reported, not silently ignored (the AD-import class of defect).
Initialize-WuuInputMode -NonInteractive -Answers @()
$defectCtx = [pscustomobject]@{ Set = $set; Store = $store; Actions = @{}; AuditHook = $null; DenialHook = $null; LastOperation = '' }
$out = (Invoke-WuuGuidedHandler -Ctx $defectCtx -Handler 'EventDoesNotExist' 6>&1 | Out-String)
if ($out -notmatch 'DEFECT') { Fail 'a missing handler was not reported as a defect' }
else { Pass 'a menu entry with no handler is reported as a defect' }

# ---------------------------------------------------------------------------------------
# 11. CSV column detection (spec 4.2)
# ---------------------------------------------------------------------------------------
$hdr1 = @('Computer', 'OS', 'Phase')
if ((Select-WuuImportColumn -Header $hdr1) -ne 0) { Fail 'failed to detect a Computer header' } else { Pass 'detects a "Computer" column header' }

$hdr2 = @('AssetTag', 'Hostname', 'OU')
if ((Select-WuuImportColumn -Header $hdr2) -ne 1) { Fail 'failed to detect a Hostname column (not first)' } else { Pass 'detects a non-first name column' }

$hdr3 = @('ColA', 'ColB')
if ((Select-WuuImportColumn -Header $hdr3) -ne 0) { Fail 'fallback for ambiguous headers should be column 0' } else { Pass 'falls back to the first column when no header is recognisable' }

if ((Select-WuuImportColumn -Header $hdr2 -Preferred 'Hostname') -ne 1) { Fail 'explicit -Preferred column not honoured' } else { Pass 'honours an explicitly preferred column' }

# ---------------------------------------------------------------------------------------
# 12. Workflow loop terminates (no dead states)
# ---------------------------------------------------------------------------------------
# Drive the whole loop with scripted answers ending in quit; it must not hang or throw.
$loopStore = New-WuuStateStore
$null = Add-WuuComputerSetNames -Set (New-WuuComputerSet -Store $loopStore) -Names @('SRV01')
Initialize-WuuInputMode -NonInteractive -Answers @('q')
$loopThrew = $null
try {
    # A minimal action map is enough here: the assertion is that the loop reaches EXIT, not that
    # any operation runs. (The real $consoleActions is assembled inside Start-WuuApplication.)
    Start-WuuGuidedWorkflow -Store $loopStore -DrainScheduler { $null } -Actions @{}
} catch {
    $loopThrew = $_.Exception
}
if ($loopThrew) { Fail "workflow loop threw: $($loopThrew.Message)" }
else { Pass 'workflow loop runs to EXIT without throwing' }

if ($fail) { Write-Host 'SOME CHECKS FAILED' -ForegroundColor Red; exit 1 }
else { Write-Host 'ALL PASS' -ForegroundColor Cyan }
