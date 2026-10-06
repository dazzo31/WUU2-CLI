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
# 3a. AddEntry unification onto Add-WuuComputerSetNames (WUU-OBS-02 / FLEET-ADD-UNIFICATION-01)
# ---------------------------------------------------------------------------------------
# Proves that:
#   * $AddEntry in Wuu.Core.psm1 delegates directly to Add-WuuComputerSetNames.
#   * The legacy Exempt.txt silent check is retired (hosts in Exempt.txt are added, not dropped).
#   * Adding duplicate names reports them in .Duplicates and adds 0 rows.
#   * Adding invalid names reports them in .Invalid and adds 0 rows.
#   * Scalar string input, array input, empty array, and $null are all handled safely.
$coreText = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Core.psm1'))
$coreAst = [System.Management.Automation.Language.Parser]::ParseInput($coreText, [ref]$null, [ref]$null)
$addEntryNode = $coreAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text.Trim() -eq '$AddEntry'
}, $true)

if (-not $addEntryNode) {
    Fail 'could not locate $AddEntry assignment in Wuu.Core.psm1'
} else {
    $addEntryBody = $addEntryNode.Right.Extent.Text
    if ($addEntryBody -match 'Exempt\.txt') {
        Fail 'legacy Exempt.txt check still present in $AddEntry implementation'
    } else {
        Pass 'legacy Exempt.txt check is retired from $AddEntry'
    }

    if ($addEntryBody -notmatch 'Add-WuuComputerSetNames') {
        Fail '$AddEntry does not delegate to Add-WuuComputerSetNames'
    } else {
        Pass '$AddEntry delegates directly to Add-WuuComputerSetNames'
    }

    # Execute the actual extracted scriptblock with an active state store
    $testStore = New-WuuStateStore
    $addEntrySb = & ([scriptblock]::Create($addEntryBody))
    $stateStore = $testStore

    # 1. Scalar name
    $r1 = & $addEntrySb 'SRV-TEST01'
    if ($r1.AddedCount -ne 1 -or @(Get-WuuComputerRow -Store $testStore).Count -ne 1) {
        Fail "scalar name was not added (AddedCount=$($r1.AddedCount))"
    } else { Pass 'scalar string name is accepted and added' }

    # 2. Exempt.txt retirement integration: write host to Exempt.txt and ensure it is still added
    $exemptFile = Join-Path $root 'Exempt.txt'
    $prevExemptBytes = if (Test-Path -LiteralPath $exemptFile) { [System.IO.File]::ReadAllBytes($exemptFile) } else { $null }
    try {
        Set-Content -LiteralPath $exemptFile -Value 'SRV-EXEMPT01' -Encoding UTF8
        $rEx = & $addEntrySb 'SRV-EXEMPT01'
        if ($rEx.AddedCount -ne 1 -or -not $testStore.ByName.ContainsKey('srv-exempt01')) {
            Fail 'computer in Exempt.txt was skipped (legacy silent exclusion was not retired)'
        } else { Pass 'computer listed in Exempt.txt is added rather than silently skipped' }
    } finally {
        if ($null -ne $prevExemptBytes) { [System.IO.File]::WriteAllBytes($exemptFile, $prevExemptBytes) }
        else { Remove-Item -LiteralPath $exemptFile -Force -ErrorAction SilentlyContinue }
    }

    # 3. Duplicate detection
    $rDup = & $addEntrySb @('SRV-TEST01', 'srv-test01')
    if ($rDup.AddedCount -ne 0 -or @($rDup.Duplicates).Count -ne 2) {
        Fail "duplicates were not detected by `$AddEntry (Duplicates=$(@($rDup.Duplicates).Count))"
    } else { Pass 'duplicate names are detected and excluded by $AddEntry' }

    # 4. Invalid names
    $rInv = & $addEntrySb @('not a valid host!', 'another/bad')
    if ($rInv.AddedCount -ne 0 -or @($rInv.Invalid).Count -lt 1) {
        Fail "invalid names were not rejected by `$AddEntry (Invalid=$(@($rInv.Invalid).Count))"
    } else { Pass 'invalid names are rejected and reported in .Invalid by $AddEntry' }

    # 5. Null and empty array
    $rNull = & $addEntrySb $null
    $rEmpty = & $addEntrySb @()
    if ($rNull.AddedCount -ne 0 -or $rEmpty.AddedCount -ne 0) {
        Fail 'null or empty collection produced non-zero added count'
    } else { Pass 'null and empty array input handled safely with 0 added' }
}

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

foreach ($required in @('Updates & deployment', 'Computer fleet', 'Diagnostics & health', 'Reports & audit', 'Settings & credentials', 'Advanced (all operations)', 'Exit')) {
    if (-not ($tree | Where-Object { $_.Label -eq $required })) { Fail "navigation is missing category: $required" }
}
if (-not $failed) { Pass 'all spec-9 categories are present' }

# The taxonomy is a CONTRACT, pinned by Id and Label rather than by count alone, so renaming a
# category or re-adding a retired one fails here. The earlier tree had grown a category per FEATURE
# (Deployment phases, Automation, Credentials, Save); those were folded into the domains an operator
# actually thinks in, and this is what keeps them from drifting back one at a time.
$expectedTree = @(
    @{ Id = 'UPDATES';     Label = 'Updates & deployment' }
    @{ Id = 'COMPUTERS';   Label = 'Computer fleet' }
    @{ Id = 'DIAGNOSTICS'; Label = 'Diagnostics & health' }
    @{ Id = 'REPORTS';     Label = 'Reports & audit' }
    @{ Id = 'SETTINGS';    Label = 'Settings & credentials' }
    @{ Id = 'ADVANCED';    Label = 'Advanced (all operations)' }
    @{ Id = 'EXIT';        Label = 'Exit' }
)
$actualIds = @($tree | ForEach-Object { $_.Id })
$expectedIds = @($expectedTree | ForEach-Object { $_.Id })
if (($actualIds -join ',') -ne ($expectedIds -join ',')) {
    Fail "the top-level taxonomy is not the agreed one: got '$($actualIds -join ',')', want '$($expectedIds -join ',')'"
} else { Pass "the top-level taxonomy is 5 categories + Advanced + Exit ($($tree.Count) entries)" }

$retired = @($tree | Where-Object { $_.Id -in @('DEPLOYMENT', 'AUTOMATION', 'CREDENTIALS', 'SAVE') })
if ($retired.Count) { Fail "retired top-level categor(ies) present: $((@($retired | ForEach-Object { $_.Id })) -join ', ')" }
else { Pass 'no retired feature-per-category entry survives at the top level' }

# ...and nothing was LOST in the regroup. Every operation the flat menu reaches must also be
# reachable by navigating the taxonomy; Advanced is what makes that guarantee hold, and this is the
# assertion that would catch a regroup that quietly dropped an operation instead of relocating it.
#
# Compared on CAPABILITIES, not on handler names alone: the grouped menus also reach things through
# an entry KIND rather than a Handler - the deployment report is a `Report` entry (its own screen,
# not an action-layer handler) and the audit subverbs are `AuditSubVerb` entries. A handler-name-only
# comparison would report those as stranded when they are in fact reachable.
#
# `ShowHelp` is excluded deliberately: it renders help, it is not an operation, and the flat `?` key
# is its only home. Listing it here would force a meaningless menu entry into the taxonomy.
$flatHandlersForCoverage = @((Get-WuuMenuActions) |
        Where-Object { $_.Handler -and $_.Handler -ne 'ShowHelp' } |
        ForEach-Object { $_.Handler } | Sort-Object -Unique)
$guidedHandlersForCoverage = @()
foreach ($menuFnForCoverage in @('Get-WuuUpdateManagementMenu', 'Get-WuuComputerManagementMenu', 'Get-WuuDiagnosticsMenu', 'Get-WuuReportsMenu', 'Get-WuuSettingsMenu')) {
    $guidedHandlersForCoverage += @((& $menuFnForCoverage) | Where-Object { $_.ContainsKey('Handler') -and $_.Handler } | ForEach-Object { $_.Handler })
}
$guidedHandlersForCoverage += @('EventAddComputer', 'EventAddFile')        # reachable via a Screen entry
$guidedHandlersForCoverage += @('EventDeploymentReport')                   # reachable via the Report entry
$guidedHandlersForCoverage += @('Invoke-WuuAuditCommand', 'Invoke-WuuAuditSubVerb')  # via AuditSubVerb entries
$guidedHandlersForCoverage = @($guidedHandlersForCoverage | Sort-Object -Unique)
$unreachableOps = @($flatHandlersForCoverage | Where-Object { $guidedHandlersForCoverage -notcontains $_ })
if ($unreachableOps.Count) { Fail "operation(s) reachable only from the flat menu, so the regroup strands them if Advanced is ever removed: $($unreachableOps -join ', ')" }
else { Pass "every flat operation is also reachable by navigating the grouped taxonomy ($($flatHandlersForCoverage.Count) handlers)" }

# Navigating must not expose a mutating operation at the top level.
$mutatingTopLevel = @($tree | Where-Object { $_.ContainsKey('Mutating') -and $_.Mutating })
if ($mutatingTopLevel.Count) { Fail 'top-level navigation exposes a mutating operation' } else { Pass 'no mutating operation at the top level' }

# ---------------------------------------------------------------------------------------
# 5a. Automation must remain reachable from the guided workflow, and its state VISIBLE.
#
# Before this, automation settings existed and the flat menu could toggle them, but the guided
# workflow - the DEFAULT entry path - had no way to set or even see them. An operator using the
# guided UI could neither enable nor discover the automatic behaviours, and the instruction set
# requires the operator always be able to determine what automation is enabled. The settings
# engine was fine; the interface did not reach it.
#
# The AUTOMATION category has since been merged into Settings & credentials. The REQUIREMENT is
# therefore asserted against wherever the control now lives rather than against the retired id:
# what must hold is that the master control is reachable from a top-level category and that the
# dashboard states what automation is enabled.
$settingsCategory = $tree | Where-Object { $_.Id -eq 'SETTINGS' }
if (-not $settingsCategory) {
    Fail 'the guided navigation has no SETTINGS category - automatic behaviour cannot be reached or seen from the default interface'
} else { Pass 'the guided navigation exposes a SETTINGS category' }

$settingsItems = @(Get-WuuSettingsMenu)
if ($settingsItems.Count -eq 0) { Fail 'the settings menu is empty' }
else { Pass "the settings menu lists $($settingsItems.Count) entry(ies)" }

# The master control must be reachable, wired by name to the SAME handler the flat menu uses.
if (-not ($settingsItems | Where-Object { $_.Handler -eq 'EventToggleSettings' })) {
    Fail 'the settings menu does not offer the master toggle (EventToggleSettings)'
} else { Pass 'the settings menu offers the master automation toggle' }

# Every settings entry needs a dispatch key, like every other category.
$settingsUndispatched = @($settingsItems | Where-Object {
        -not $_.ContainsKey('Handler') -and -not $_.ContainsKey('Preflight') -and
        -not $_.ContainsKey('Starts') -and $_.Key -ne 'b'
    })
if ($settingsUndispatched.Count -gt 0) { Fail "$($settingsUndispatched.Count) settings entry(ies) dispatch to nothing" }
else { Pass 'every settings menu entry dispatches to something' }

# The workflow loop must actually dispatch the state, or the category is unreachable.
$navRawAuto = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Navigate.psm1') -Raw
if ($navRawAuto -notmatch "'SETTINGS'\s*\{\s*\`$state = Show-WuuCategoryScreen") {
    Fail "the workflow loop has no dispatch for the 'SETTINGS' state - the category would be a dead menu entry"
} else { Pass "the workflow loop dispatches the 'SETTINGS' state" }

# ...and the DASHBOARD must SHOW the automation state, so the operator can determine it without
# navigating. A setting that is only visible inside a submenu is one an operator forgets.
$dashboardBody = [regex]::Match($navRawAuto, '(?s)function Show-WuuDashboardScreen.*?(?=\nfunction )').Value
if ($dashboardBody -notmatch 'AutoDownload') {
    Fail 'the dashboard does not show the automation state - the operator cannot tell what automation is enabled without navigating into a submenu'
} else { Pass 'the dashboard reports the automation state' }

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
    @{ Name = 'update management';  Items = @(Get-WuuUpdateManagementMenu) }
    @{ Name = 'computer management'; Items = @(Get-WuuComputerManagementMenu) }
    @{ Name = 'diagnostics';        Items = @(Get-WuuDiagnosticsMenu) }
    @{ Name = 'reports';            Items = @(Get-WuuReportsMenu) }
    @{ Name = 'settings';           Items = @(Get-WuuSettingsMenu) }
)

# The list above is written BY HAND, and it silently omitted `automation` - so the menu added most
# recently was the one menu whose entries were never swept. Nothing failed, because a shorter list
# catches fewer defects rather than reporting that it is shorter. Cross-check it against the tree:
# every category the top-level navigation ROUTES to a category screen must appear in the list above,
# so adding a menu without sweeping it is a FAILURE instead of a quiet loss of coverage.
# Compared data-to-data (the list above against this map), not by re-parsing the list's own text,
# which would be a test that reads its own source and can drift from what it actually sweeps.
$categoryMenu = [ordered]@{
    UPDATES     = @{ Fn = 'Get-WuuUpdateManagementMenu';   SweptAs = 'update management' }
    COMPUTERS   = @{ Fn = 'Get-WuuComputerManagementMenu'; SweptAs = 'computer management' }
    DIAGNOSTICS = @{ Fn = 'Get-WuuDiagnosticsMenu';        SweptAs = 'diagnostics' }
    REPORTS     = @{ Fn = 'Get-WuuReportsMenu';            SweptAs = 'reports' }
    SETTINGS    = @{ Fn = 'Get-WuuSettingsMenu';           SweptAs = 'settings' }
}
$navSourceForSweep = [string](Get-Content (Join-Path $root 'src\Wuu.Navigate.psm1') -Raw)
$unswept = @()
foreach ($state in $categoryMenu.Keys) {
    $fn = $categoryMenu[$state].Fn
    # (a) the category must actually be routed to a category screen by the workflow loop
    if ($navSourceForSweep -notmatch ("'" + $state + "'\s*\{\s*\`$state = Show-WuuCategoryScreen")) { continue }
    # (b) ...and its menu function must be one of the menus swept above
    $swept = @($allLeafMenus | Where-Object { (& $fn).Count -gt 0 -and $categoryMenu[$state].SweptAs -eq $_.Name })
    if (-not $swept.Count) { $unswept += "$state ($fn is routed but is not in the wiring sweep list)" }
}
if ($unswept.Count) { Fail "categor(ies) reachable from the top-level navigation are NOT swept for wiring, so their entries could point at nothing undetected: $($unswept -join '; ')" }
else { Pass "every navigation category is covered by the wiring sweep ($($allLeafMenus.Count) menus)" }

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

# ---------------------------------------------------------------------------------------
# 13. Pre-flight: prerequisites, verdicts and the available count (spec 7 / 25 P0)
# ---------------------------------------------------------------------------------------
# Verdicts are three-valued on purpose. A boolean would collapse "nothing downloaded yet" (a
# warning the operator may accept) into the same answer as "this cannot proceed", which is how a
# pre-flight report becomes noise an operator learns to skip.
$prRow = New-WuuComputerRow -Computer 'PR01'
# A freshly created row is Pending=$true (a check is already queued for it), so the 'check'
# verdict is legitimately a WARNING. Clearing it models a row that has been checked and settled.
$prRow.Pending = $false
$vCheck = Test-WuuPrerequisite -Row $prRow -Op 'check'
if ($vCheck.State -ne 'Ok') { Fail "check should be Ok on a settled row, got $($vCheck.State)" }
else { Pass 'prerequisite: check is Ok on a settled row' }

# ...and while a check is already queued for the same row it is a Warning, not Ok.
$prRow.Pending = $true
if ((Test-WuuPrerequisite -Row $prRow -Op 'check').State -ne 'Warning') { Fail 'check on a row with a queued check should be a Warning' }
else { Pass 'prerequisite: check already queued is a Warning' }
$prRow.Pending = $false

# install with nothing downloaded is BLOCKING: there is genuinely nothing to install.
$vInstall = Test-WuuPrerequisite -Row $prRow -Op 'install'
if ($vInstall.State -ne 'Blocking') { Fail "install with nothing downloaded should be Blocking, got $($vInstall.State)" }
else { Pass 'prerequisite: install with nothing downloaded is Blocking' }

# ...but download with nothing available is only a WARNING - the operator may still proceed.
$vDownload = Test-WuuPrerequisite -Row $prRow -Op 'download'
if ($vDownload.State -ne 'Warning') { Fail "download with nothing available should be Warning, got $($vDownload.State)" }
else { Pass 'prerequisite: download with nothing available is a Warning, not Blocking' }

$prRow.Available = 3; $prRow.Downloaded = 3
$vDl2 = Test-WuuPrerequisite -Row $prRow -Op 'download'
if ($vDl2.State -ne 'Warning') { Fail "download when everything is already downloaded should be Warning, got $($vDl2.State)" }
else { Pass 'prerequisite: download when already downloaded is a Warning' }
$vIn2 = Test-WuuPrerequisite -Row $prRow -Op 'install'
if ($vIn2.State -ne 'Ok') { Fail "install with 3 downloaded should be Ok, got $($vIn2.State)" }
else { Pass 'prerequisite: install with downloads present is Ok' }

# restart is only Ok when a reboot is actually pending - this is what stops a deployment's
# "reboot where required" step from restarting a fleet that does not need it.
$vRestart = Test-WuuPrerequisite -Row $prRow -Op 'restart'
if ($vRestart.State -ne 'Warning') { Fail "restart with no pending reboot should be Warning, got $($vRestart.State)" }
else { Pass 'prerequisite: restart with no pending reboot is a Warning' }
$prRow.RebootRequired = $true
if ((Test-WuuPrerequisite -Row $prRow -Op 'restart').State -ne 'Ok') { Fail 'restart with a pending reboot should be Ok' }
else { Pass 'prerequisite: restart with a pending reboot is Ok' }

# An OFFLINE row fails every operation, whatever the operation says.
$prRow.State = 'Offline'
$vOff = Test-WuuPrerequisite -Row $prRow -Op 'check'
if ($vOff.State -ne 'Blocking') { Fail "an offline row should block every operation, got $($vOff.State)" }
else { Pass 'prerequisite: an offline row blocks every operation' }

# An UNKNOWN operation must block, not pass. Defaulting to Ok would let a typo'd operation name
# sail through pre-flight with its prerequisites unchecked - the exact failure pre-flight exists
# to prevent.
$prRow.State = 'Queued'
if ((Test-WuuPrerequisite -Row $prRow -Op 'no-such-op').State -ne 'Blocking') { Fail 'an unknown operation should be Blocking' }
else { Pass 'prerequisite: an unknown operation is Blocking (not silently Ok)' }

# The mutating set must agree with the audit rule everywhere else: download/install/restart/service.
foreach ($mutOp in @('download', 'install', 'restart', 'service', 'deploy')) {
    if (-not (Test-WuuOperationRequiresReason -Operation $mutOp)) { Fail "operation '$mutOp' should require a reason" }
}
foreach ($readOp in @('check', 'review')) {
    if (Test-WuuOperationRequiresReason -Operation $readOp) { Fail "operation '$readOp' should not require a reason" }
}
if (-not $failed) { Pass 'reason requirement matches the mutating set (download/install/restart/service/deploy)' }

# Pre-flight composition, with injected probes so the assertions are instant and deterministic
# (a real ping timeout per host would dominate the suite's runtime). The operation is 'check':
# 'install' would be BLOCKING for every fresh row (nothing is downloaded yet), which would make
# the availability assertions pass for the wrong reason.
$pfStore = New-WuuStateStore
$pfSet = New-WuuComputerSet -Store $pfStore
$null = Add-WuuComputerSetNames -Set $pfSet -Names @('ON1', 'ON2', 'OFF1')

$pfReport = Get-WuuPreflightReport -Set $pfSet -Operation 'check' `
    -PingProbe { param($n) $n -ne 'OFF1' } `
    -CredentialProbe { 'valid' } `
    -ServiceProbe { 'Running' } `
    -OsProbe { 'Windows Server 2022 (build 20348)' } `
    -RebootProbe { $false }

if ($pfReport.Computers -ne 3) { Fail "pre-flight should report 3 targets, got $($pfReport.Computers)" }
elseif ($pfReport.Reachable -ne 2) { Fail "pre-flight should report 2 reachable, got $($pfReport.Reachable)" }
elseif ($pfReport.Offline -ne 1) { Fail "pre-flight should report 1 offline, got $($pfReport.Offline)" }
else { Pass 'pre-flight reports targets / reachable / offline' }

if ($pfReport.ProbedOffline) { Fail 'pre-flight did not use the supplied probes' }
else { Pass 'pre-flight uses the supplied probe set' }

# The availability count is the number spec 7 offers to "continue with" - and an OFFLINE computer
# must NOT be in it, or the operator is told to continue with hosts pre-flight just proved
# unusable. (The offline host is made offline by the PING PROBE, which is the real signal.)
if ($pfReport.Available -ne 2) { Fail "pre-flight should report 2 available, got $($pfReport.Available)" }
else { Pass 'pre-flight availability excludes offline computers (spec 7 "continue with N")' }

if ($pfReport.Blocking -lt 1) { Fail "pre-flight should count the blocking computer, got $($pfReport.Blocking)" }
elseif (@($pfReport.Problems).Count -lt 1) { Fail 'pre-flight reported no problem text for the blocked computer' }
else { Pass 'pre-flight reports blocking problems with their reason' }

# An offline computer must not be probed for credentials/services: on a real estate that is a
# guaranteed multi-second timeout per host, making pre-flight cost scale with the number of
# machines that are down.
$offResult = @($pfReport.Results | Where-Object { $_.Computer -eq 'OFF1' })[0]
if ($offResult.Credentials -ne 'not tested (offline)') { Fail "offline computer was probed for credentials ('$($offResult.Credentials)')" }
elseif ($offResult.ProbeState -ne 'skipped (offline)') { Fail "offline computer probe state is '$($offResult.ProbeState)'" }
else { Pass 'pre-flight does not probe credentials/services on offline computers' }

$onResult = @($pfReport.Results | Where-Object { $_.Computer -eq 'ON1' })[0]
if ($onResult.Credentials -ne 'valid' -or $onResult.WuService -ne 'Running') { Fail 'a reachable computer was not probed' }
else { Pass 'pre-flight probes credentials and the WU service on reachable computers' }

# "Credentials valid N / M" is spec 18's contextual result, so M must be the PROBED count.
if ($pfReport.CredentialsValid -ne 2) { Fail "credentials-valid count should be 2 (of the 2 probed), got $($pfReport.CredentialsValid)" }
else { Pass 'pre-flight credential result is out of the probed computers only' }

# The OS string must actually be carried through - spec 7 requires OS compatibility be evaluated.
if ($onResult.OS -notmatch '20348') { Fail "pre-flight did not carry the OS through ('$($onResult.OS)')" }
else { Pass 'pre-flight reports the OS of reachable computers' }

# ...and the whole thing still composes to a usable report with NO probes. The "cannot tell" case
# must NOT be reported as a fleet of dead machines: an unconditional (total - reachable) would
# have said 3 offline here, which is what a pre-flight report must never do.
$pfNo = Get-WuuPreflightReport -Set $pfSet -Operation 'check'
if (-not $pfNo.ProbedOffline) { Fail 'pre-flight without probes should report ProbedOffline' }
elseif ($pfNo.Offline -ne 0) { Fail "with no ping probe, Offline must be 0 ("cannot tell"), got $($pfNo.Offline)" }
elseif ($pfNo.Available -ne 3) { Fail "with no probes every computer should be available, got $($pfNo.Available)" }
else { Pass 'pre-flight with no probes reports "cannot tell" rather than offline' }

# ---------------------------------------------------------------------------------------
# 13b. Pre-flight live probes: credential resolution & safe OS unwrapping (C4)
# ---------------------------------------------------------------------------------------
$liveProbes = New-WuuPreflightContext

# 1. Credentials probe with default identity on localhost reports 'valid'
$resDefCred = & $liveProbes.Credentials 'localhost'
if ($resDefCred -ne 'valid') { Fail "pre-flight live Credentials probe on localhost should be 'valid', got '$resDefCred'" }
else { Pass 'pre-flight live Credentials probe reports valid for working default identity' }

# 2. Credentials probe when custom credentials fail verification must report 'failed' (no silent success or fallback)
$global:UseCustomCredentials = $true
$badSec = ConvertTo-SecureString 'invalid-pw-nav-test' -AsPlainText -Force
$global:CustomCredentials = New-Object System.Management.Automation.PSCredential('CONTOSO\nonexistent-nav-user', $badSec)
$global:CredentialCache = @{}

$resCustomFail = & $liveProbes.Credentials 'localhost'
if ($resCustomFail -ne 'failed') { Fail "pre-flight live Credentials probe should report 'failed' on unusable custom credentials, got '$resCustomFail'" }
else { Pass 'pre-flight live Credentials probe reports failed when configured custom credentials cannot authenticate' }

# 3. OS probe when custom credentials fail verification must return '' without throwing or emitting " (build )"
$resOsFail = & $liveProbes.OS 'localhost'
if ($resOsFail -ne '') { Fail "pre-flight live OS probe should return '' on unusable custom credentials, got '$resOsFail'" }
else { Pass 'pre-flight live OS probe returns empty string on credential failure (no " (build )")' }

# Reset custom credentials
$global:UseCustomCredentials = $false
$global:CustomCredentials = $null
$global:CredentialCache = @{}

# 4. OS probe on localhost with valid credentials returns real OS data with build
$resLiveOs = & $liveProbes.OS 'localhost'
if ($resLiveOs -notmatch 'build \d+') { Fail "pre-flight live OS probe on localhost should include build number, got '$resLiveOs'" }
else { Pass "pre-flight live OS probe formats valid OS data: '$resLiveOs'" }
try { Close-WuuWorkerPool } catch { }

# ---------------------------------------------------------------------------------------
# 14. Operation plan (spec 12): the plan must state the lifecycle, not imply it
# ---------------------------------------------------------------------------------------
$planSet = New-WuuComputerSet -Store (New-WuuStateStore)
$null = Add-WuuComputerSetNames -Set $planSet -Names @('P1', 'P2')
$p2 = Get-WuuComputerRow -Store $planSet.Store -Computer 'P2'
$p2.Available = 4; $p2.Downloaded = 2; $p2.RebootRequired = $true; $p2.Phase = 'Phase 2'

$plan = New-WuuOperationPlan -Set $planSet -Operation 'download'
if ($plan.TargetCount -ne 2) { Fail "plan should target the whole set by default, got $($plan.TargetCount)" }
else { Pass 'plan targets the whole computer set without the user re-specifying it (spec 6)' }

if ($plan.UpdatesToDownload -ne 2) { Fail "plan should count 2 updates to download, got $($plan.UpdatesToDownload)" }
else { Pass 'plan counts updates still to download' }

if ($plan.ExpectedReboots -ne 1) { Fail "plan should report 1 expected reboot, got $($plan.ExpectedReboots)" }
else { Pass 'plan reports expected reboots' }

if (@($plan.PerPhase).Count -ne 2) { Fail "plan should break down by phase, got $(@($plan.PerPhase).Count) phase(s)" }
else { Pass 'plan reports the per-phase breakdown (spec 13 phases visible in deployment)' }

if (-not $plan.RequiresReason) { Fail 'a download plan should require a reason' }
else { Pass 'plan states whether a change reason is required' }

# The lifecycle is stated explicitly (spec 10) - 'deploy' must be the full sequence, not one step.
$deployPlan = New-WuuOperationPlan -Set $planSet -Operation 'deploy'
if (@($deployPlan.Lifecycle).Count -lt 5) { Fail "deploy lifecycle should list the full sequence, got $(@($deployPlan.Lifecycle) -join ' -> ')" }
else { Pass "deploy plan states the full lifecycle ($(@($deployPlan.Lifecycle) -join ' -> '))" }

# A narrowed plan is how retry-failed targets exactly the failures (spec 15).
$narrow = New-WuuOperationPlan -Set $planSet -Operation 'install' -Targets @('P2')
if ($narrow.TargetCount -ne 1 -or $narrow.Targets[0] -ne 'P2') { Fail "narrowed plan targeted $($narrow.Targets -join ',')" }
else { Pass 'plan can be narrowed to specific computers (retry-failed)' }

# ---------------------------------------------------------------------------------------
# 15. Confirmation gate (spec 12): nothing mutating runs without an explicit reason
# ---------------------------------------------------------------------------------------
$confStore = New-WuuStateStore
$confSet = New-WuuComputerSet -Store $confStore
$null = Add-WuuComputerSetNames -Set $confSet -Names @('C1')

$confCalls = New-Object System.Collections.ArrayList
$confCtx = [pscustomobject]@{
    Set = $confSet; Store = $confStore
    Actions = @{ EventDownloadUpdates = { $null = $confCalls.Add('ran') } }
    AuditHook = { param($n, $r, $b, [string[]]$Targets = @()) $null = $confCalls.Add(('audited:{0}:{1}' -f $n, $r)) }
    DenialHook = $null; LastOperation = ''; Preflight = $null
}

# (a) Explicit refusal must NOT run the action.
Initialize-WuuInputMode -NonInteractive -Answers @('2')
$d1 = Confirm-WuuMutation -Ctx $confCtx -Operation 'download'
if ($d1.Proceed) { Fail 'confirmation proceeded after the operator chose Cancel' }
elseif ($confCalls.Count -ne 0) { Fail 'the action ran despite being declined' }
else { Pass 'spec 12: declining the confirmation does not run the action' }

# (b) A blank reason must be REFUSED, not defaulted - a defaulted reason makes every guided change
# look identical in the audit trail.
Initialize-WuuInputMode -NonInteractive -Answers @('1', '')
$d2 = Confirm-WuuMutation -Ctx $confCtx -Operation 'download'
if ($d2.Proceed) { Fail 'confirmation proceeded with a blank reason' }
elseif (-not $d2.ReasonBlank) { Fail 'the refusal was not reported as a blank-reason refusal' }
else { Pass 'spec 12: a blank change reason is refused, not defaulted' }

# (c) A supplied reason proceeds and is recorded on the context for the audit choke point.
Initialize-WuuInputMode -NonInteractive -Answers @('1', 'CHG-2026-0929 monthly patching')
$d3 = Confirm-WuuMutation -Ctx $confCtx -Operation 'download'
if (-not $d3.Proceed) { Fail "confirmation did not proceed with a reason ($($d3.Message))" }
elseif ($confCtx.Reason -ne 'CHG-2026-0929 monthly patching') { Fail "the reason was not placed on the context ('$($confCtx.Reason)')" }
else { Pass 'spec 12: the change reason is captured for the audit trail' }

# (d) A READ operation needs no reason but still needs confirmation.
Initialize-WuuInputMode -NonInteractive -Answers @('1')
$d4 = Confirm-WuuMutation -Ctx $confCtx -Operation 'check'
if (-not $d4.Proceed) { Fail 'a read-only operation should not require a reason' }
else { Pass 'spec 12: read-only operations need no reason' }

# (e) The blank reason must be RECORDED AS A DENIAL (ISO 27001 A.8.15: refusals are events too).
$denials = New-Object System.Collections.ArrayList
$confCtx | Add-Member -NotePropertyName DenialHook -NotePropertyValue { param($n, $r) $null = $denials.Add(('{0}|{1}' -f $n, $r)) } -Force
Initialize-WuuInputMode -NonInteractive -Answers @('1', '')
$null = Confirm-WuuMutation -Ctx $confCtx -Operation 'download'
if ($denials.Count -eq 0) { Fail 'a blank reason did not produce a denial record' }
else { Pass 'a refused confirmation is recorded as a denial (A.8.15)' }

# ---------------------------------------------------------------------------------------
# 16. The guided target override (spec 6 / 15): retry-failed must not re-prompt
# ---------------------------------------------------------------------------------------
# The handlers read the selection themselves, so the narrowing is delivered through the guided
# target override that Read-WuuSelection honours. An EMPTY list must mean "target nothing" -
# if it fell through to prompting, a retry with no failures would become an all-computers run.
$selStore = New-WuuStateStore
$null = Add-WuuComputerSetNames -Set (New-WuuComputerSet -Store $selStore) -Names @('S1', 'S2', 'S3')

$global:WuuGuidedTargets = @('S1', 'S3')
$picked = @(Read-WuuSelection -Store $selStore)
if ($picked.Count -ne 2) { Fail "guided override returned $($picked.Count) rows, expected 2" }
elseif (($picked.Computer -join ',') -ne 'S1,S3') { Fail "guided override returned '$($picked.Computer -join ',')'" }
else { Pass 'guided target override narrows a selection without prompting' }

if ($null -ne $global:WuuGuidedTargets) { Fail 'the guided override was not cleared after use' }
else { Pass 'the guided override is consumed (cannot leak into the next operation)' }

# An empty guided list targets nothing and must NOT prompt (no answers queued - a prompt would throw).
Initialize-WuuInputMode -NonInteractive -Answers @()
$global:WuuGuidedTargets = @()
$none = @(Read-WuuSelection -Store $selStore)
if ($none.Count -ne 0) { Fail "an empty guided target list returned $($none.Count) rows" }
else { Pass 'an empty guided target list targets nothing (does not fall through to prompting)' }
$global:WuuGuidedTargets = $null

# A NAME that no longer exists must be dropped, not turned into a prompt or an error - rows can be
# removed between the confirmation and the retry.
$global:WuuGuidedTargets = @('S1', 'GONE')
$partial = @(Read-WuuSelection -Store $selStore)
if ($partial.Count -ne 1) { Fail "an unknown guided target should be dropped, got $($partial.Count) rows" }
else { Pass 'an unknown guided target is dropped rather than erroring' }
$global:WuuGuidedTargets = $null

# ---------------------------------------------------------------------------------------
# 17. The audit record carries the confirmed targets (guided != less informed than scripted)
# ---------------------------------------------------------------------------------------
$auditArgs = New-Object System.Collections.ArrayList
$targetCtx = [pscustomobject]@{
    Set = $selStore; Store = $selStore
    Actions = @{ EventInstallUpdates = { } }
    AuditHook = { param($n, $r, $b, [string[]]$Targets = @()) $null = $auditArgs.Add("$n|$r|$($Targets -join '+')") }
    DenialHook = $null; LastOperation = ''; Reason = 'CHG-1'
}
Initialize-WuuInputMode -NonInteractive -Answers @()
Invoke-WuuGuidedHandler -Ctx $targetCtx -Handler 'EventInstallUpdates' -Mutating $true -Operation 'install' -Targets @('S1', 'S2')
if ($auditArgs.Count -ne 1) { Fail "expected one audit call, got $($auditArgs.Count)" }
elseif ($auditArgs[0] -ne 'EventInstallUpdates|CHG-1|S1+S2') { Fail "audit targets not forwarded ('$($auditArgs[0])')" }
else { Pass 'the confirmed target list reaches the audit record' }

# The reason is CONSUMED, so a second mutating step cannot silently inherit the first one's.
if ($targetCtx.Reason -ne '') { Fail "the reason was not consumed ('$($targetCtx.Reason)')" }
else { Pass 'the change reason is consumed after use (each change records its own)' }

# ---------------------------------------------------------------------------------------
# 18. Results screen (spec 15): outcomes and actionable next steps, never just "complete"
# ---------------------------------------------------------------------------------------
$resStore = New-WuuStateStore
$resSet = New-WuuComputerSet -Store $resStore
$null = Add-WuuComputerSetNames -Set $resSet -Names @('OK1', 'BAD1', 'RBT1')
(Get-WuuComputerRow -Store $resStore -Computer 'OK1').State = 'Complete'
$badRow = Get-WuuComputerRow -Store $resStore -Computer 'BAD1'
$badRow.State = 'Error'; $badRow.Status = 'WMI is not accessible'
(Get-WuuComputerRow -Store $resStore -Computer 'RBT1').RebootRequired = $true

$resCtx = [pscustomobject]@{
    Set = $resSet; Store = $resStore; Actions = @{}; AuditHook = $null; DenialHook = $null
    LastOperation = ''; ExecutionOperation = 'install'
}
Initialize-WuuInputMode -NonInteractive -Answers @('5')
$resOut = (Show-WuuResultsScreen -Ctx $resCtx 6>&1 | Out-String)
if ($resOut -notmatch 'Successful:\s+1') { Fail 'results screen did not report the successful count' }
elseif ($resOut -notmatch 'Failed:\s+1') { Fail 'results screen did not report the failed count' }
elseif ($resOut -notmatch 'WMI is not accessible') { Fail 'results screen did not list the failure cause' }
elseif ($resOut -notmatch 'Reboot required:\s*1') { Fail 'results screen did not report pending reboots' }
else { Pass 'spec 15: results report successful / failed / reboot with the failure cause' }

# The retry action must NARROW to the failures - that is the whole point of "retry failed".
Initialize-WuuInputMode -NonInteractive -Answers @('1')
$next = Show-WuuResultsScreen -Ctx $resCtx
if ($next -ne 'CONFIRM') { Fail "retry returned '$next', expected CONFIRM" }
elseif (@($resCtx.RetryTargets).Count -ne 1 -or $resCtx.RetryTargets[0] -ne 'BAD1') {
    Fail "retry targeted '$($resCtx.RetryTargets -join ',')', expected only BAD1"
} else { Pass 'spec 15: retry-failed narrows the operation to the failures' }

# ...and it must force a FRESH pre-flight: the whole premise of a retry is that something changed,
# so inheriting the pre-flight that ran before the failure would be actively misleading.
if ($null -ne $resCtx.Preflight) { Fail 'retry did not clear the stale pre-flight report' }
else { Pass 'retry clears the stale pre-flight (a retry must re-verify)' }

# The results screen must offer a way out, not only a way back to the dashboard.
#
# Driven by NUMBER, and the number moved from 6 to 7 when the deployment report was added as
# option 5. That is a genuine UI change rather than a test being adjusted to pass: the assertion's
# subject is "the screen offers a way out", and Exit is still offered - it is now the last entry,
# after the report and Back. What must NOT change is that 7 leaves the workflow; if a future edit
# silently repointed that key at another screen, this still fails.
Initialize-WuuInputMode -NonInteractive -Answers @('7')
if ((Show-WuuResultsScreen -Ctx $resCtx) -ne 'EXIT') { Fail 'results screen has no working Exit' }
else { Pass 'spec 15: results screen offers exit' }

# ---------------------------------------------------------------------------------------
# 19. Every workflow step maps to a real handler with real mutating flags (spec 10 / 11)
# ---------------------------------------------------------------------------------------
$deploySpec = @(Get-WuuWorkflowSpec -Name 'deploy')
if ($deploySpec.Count -lt 6) { Fail "the deploy workflow should have the full sequence, got $($deploySpec.Count) step(s)" }
else { Pass "deploy workflow is the full lifecycle ($($deploySpec.Count) steps)" }

# 'restart where required' is only performed where a reboot is pending - so it is a step whose
# prerequisite ('restart' -> Warning when nothing is pending) is what makes it conditional. If any
# step's PreflightOp is unknown, Test-WuuPrerequisite returns Blocking and the step silently dies.
$stepProblems = @()
foreach ($s in $deploySpec) {
    $verdict = Test-WuuPrerequisite -Row (New-WuuComputerRow -Computer 'X') -Op ([string]$s.PreflightOp)
    if ($verdict.State -eq 'Blocking' -and [string]$s.PreflightOp -notin @('install', 'restart')) {
        $stepProblems += "$($s.Label) -> $($s.PreflightOp) is Blocking on a fresh row"
    }
}
if ($stepProblems.Count) { Fail "workflow step(s) cannot run: $($stepProblems -join '; ')" }
else { Pass 'every deployment step has a recognised precondition' }

# The mutating flags in the workflow must match the audit rule, or a step would skip the reason.
$specMismatch = @()
foreach ($s in $deploySpec) {
    if ([bool]$s.Mutating -ne (Test-WuuOperationRequiresReason -Operation ([string]$s.PreflightOp))) {
        $specMismatch += "$($s.Label): Mutating=$($s.Mutating) but rule says $(Test-WuuOperationRequiresReason -Operation ([string]$s.PreflightOp))"
    }
}
if ($specMismatch.Count) { Fail "workflow mutating flags disagree with the audit rule: $($specMismatch -join '; ')" }
else { Pass 'workflow mutating flags agree with the audit reason rule' }

# ---------------------------------------------------------------------------------------
# 20. The pre-flight and confirmation screens are wired into the menu and the loop (spec 7 / 12)
# ---------------------------------------------------------------------------------------
$updItems = @(Get-WuuUpdateManagementMenu)
if (-not ($updItems | Where-Object { $_.ContainsKey('Preflight') })) { Fail 'update management has no pre-flight entry' }
elseif (-not ($updItems | Where-Object { $_.ContainsKey('Starts') })) { Fail 'update management has no full-deployment entry' }
else { Pass 'update management exposes pre-flight and full deployment' }

# The credentials pre-flight lives in Settings now that Credentials is a category no longer; the
# spec-18 requirement (credentials are testable from their own area, not only after a failure) is
# asserted against where they actually are.
$credItems = @(Get-WuuSettingsMenu)
if (-not ($credItems | Where-Object { $_.ContainsKey('Preflight') })) { Fail 'settings has no credential pre-flight test (spec 18)' }
elseif (-not ($credItems | Where-Object { $_.Handler -eq 'EventSetDomainCredentials' })) { Fail 'settings cannot set credentials' }
else { Pass 'spec 18: credentials are settable and testable from Settings, not only after a failure' }

# A deployment can still be started from the taxonomy (it moved from its own category into Updates).
$deployItems = @(Get-WuuUpdateManagementMenu)
if (-not ($deployItems | Where-Object { $_.ContainsKey('Starts') })) { Fail 'deployment cannot be started from the grouped taxonomy' }
else { Pass 'spec 13: a deployment can be started from Updates & deployment' }

# The guided screens the fleet menu routes to must actually be dispatched. Three separate things
# have to line up, and a check of only the first two is vacuous - it passes while the entry is dead:
#   1. the menu entry names a Screen;
#   2. the workflow loop dispatches that state;
#   3. the CATEGORY SCREEN acts on the Screen key (without this, the entry falls through to
#      `return $State` and silently does nothing - the dead-entry class all over again).
#
# (3) is checked on the AST, not on the source text. This assertion was first written as a regex and
# was VACUOUS: commenting the dispatch out still left the words `ContainsKey('Screen')` in the file,
# so the pattern matched the comment that replaced the code. A comment cannot be an IfStatementAst.
$fleetItems = @(Get-WuuComputerManagementMenu)
$navAstForScreen = [System.Management.Automation.Language.Parser]::ParseInput($navRawAuto, [ref]$null, [ref]$null)
$categoryFnAst = @($navAstForScreen.FindAll({
            param($x) ($x -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($x.Name -eq 'Show-WuuCategoryScreen')
        }, $true))
if ($categoryFnAst.Count -ne 1) {
    Fail "expected exactly 1 Show-WuuCategoryScreen definition, found $($categoryFnAst.Count)"
} else {
    $screenDispatch = @($categoryFnAst[0].FindAll({
                param($x) ($x -is [System.Management.Automation.Language.IfStatementAst]) -and
                ($x.Clauses[0].Item1.Extent.Text -match "ContainsKey\('Screen'\)") -and
                ($x.Clauses[0].Item2.Extent.Text -match '\$item\.Screen')
            }, $true))
    if (-not $screenDispatch.Count) {
        Fail "Show-WuuCategoryScreen does not dispatch on a 'Screen' key, so any entry that routes to a screen falls through to 'return `$State' and silently does nothing"
    } else { Pass 'the category screen dispatches entries that name a Screen (checked on the AST, so a comment cannot satisfy it)' }
}
foreach ($needScreen in @('MANUAL', 'IMPORT')) {
    if (-not ($fleetItems | Where-Object { $_.ContainsKey('Screen') -and $_.Screen -eq $needScreen })) {
        Fail "the fleet menu does not route to the '$needScreen' screen"
    } elseif ($navRawAuto -notmatch ("'" + $needScreen + "'\s*\{\s*\`$state = Show-")) {
        Fail "the workflow loop has no dispatch for the '$needScreen' screen, so the fleet menu entry is dead"
    }
}
if (-not $failed) { Pass 'the fleet menu routes add/import to the guided screens, and both the loop and the category screen dispatch them' }

# The pre-flight screen must be reachable and must not explode on an EMPTY set.
$emptyCtx = [pscustomobject]@{
    Set = (New-WuuComputerSet -Store (New-WuuStateStore)); Store = (New-WuuStateStore)
    Actions = @{}; AuditHook = $null; DenialHook = $null; LastOperation = ''
}
Initialize-WuuInputMode -NonInteractive -Answers @()
$pfNext = Show-WuuPreflightScreen -Ctx $emptyCtx
if ($pfNext -ne 'DASHBOARD') { Fail "pre-flight on an empty set returned '$pfNext'" }
else { Pass 'pre-flight on an empty set returns to the dashboard cleanly' }

# ---------------------------------------------------------------------------------------
# A GUIDED HANDLER'S OUTPUT MUST NOT REACH THE PIPELINE.
#
# Every screen that calls Invoke-WuuGuidedHandler RETURNS A WORKFLOW STATE, and a handler's output
# goes to the pipeline - so an unpiped call makes the screen return an ARRAY of (handler output,
# state) instead of the state. Two field symptoms came from exactly that, and neither named the
# cause:
#
#   * the loop received a PSCustomObject (a $GetErrors error row, complete with its Timestamp -
#     the results screen's "2. View errors" path) and reported it as an unknown workflow state;
#   * and because a switch over a 2-element array runs EVERY matching arm, the arm that reassigns
#     $state ran alongside `default`, which then printed $state AFTER the reassignment - naming a
#     perfectly valid state ('DASHBOARD') as unknown.
#
# The assertion is on the TYPE and COUNT of what comes back, not on the value: a handler that
# returns nothing must not turn the state into an array even when the state itself is correct.
$leakActions = [hashtable]::Synchronized(@{})
$leakActions['ReturningHandler'] = {
    # Two objects with a Timestamp, mirroring $GetErrors' real shape.
    [PSCustomObject]@{ Timestamp = Get-Date; Type = 'PowerShell Error'; Message = 'first' }
    [PSCustomObject]@{ Timestamp = Get-Date; Type = 'PowerShell Error'; Message = 'second' }
}
$leakCtx = [pscustomobject]@{ Set = $null; Store = (New-WuuStateStore); Actions = $leakActions; AuditHook = $null; DenialHook = $null }

# 1. The handler call itself must leak nothing.
$leak = Invoke-WuuGuidedHandler -Ctx $leakCtx -Handler 'ReturningHandler'
if ($null -ne $leak) {
    Fail "Invoke-WuuGuidedHandler leaked the handler's output ($($leak.GetType().Name)) into the pipeline"
} else { Pass 'a guided handler''s output does not reach the pipeline' }

# 2. ...and the call-then-return shape must still yield exactly one string.
function Get-ProbeScreenState {
    Invoke-WuuGuidedHandler -Ctx $leakCtx -Handler 'ReturningHandler'
    return 'RESULTS'
}
$probeState = Get-ProbeScreenState
if (@($probeState).Count -ne 1) {
    Fail "a screen that returns a state after a guided handler returned $((@($probeState) | ForEach-Object { $_.GetType().Name }) -join ' + ') instead of one string"
} elseif ($probeState -isnot [string]) {
    Fail "the screen state came back as $($probeState.GetType().Name), not a string"
} elseif ($probeState -ne 'RESULTS') {
    Fail "the screen state came back as '$probeState', not 'RESULTS'"
} else { Pass 'a screen returns exactly the state string after a guided handler runs' }

# 3. The workflow loop must refuse a non-string hand-off instead of reporting it as an unknown state.
$navSource = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Navigate.psm1') -Raw
if ($navSource -notmatch '\$state -isnot \[string\]') {
    Fail 'the workflow loop does not validate the state type - a screen returning an object would be reported as an unknown state, naming the symptom and hiding the cause'
} else { Pass 'the workflow loop validates that a screen handed it a state name' }

# 4. Show-WuuAdvancedScreen must not leak non-mutating action output into its return value.
# A handler that emits objects (e.g. $GetErrors returning error objects) must not turn
# the screen's return value into an array, which would corrupt the workflow loop.
$advActions = [hashtable]::Synchronized(@{})
$advActions['GetErrors'] = {
    [PSCustomObject]@{ Timestamp = Get-Date; Type = 'Error'; Message = 'sample error' }
}
$advCtx = [pscustomobject]@{ Set = (New-WuuComputerSet -Store (New-WuuStateStore)); Store = (New-WuuStateStore); Actions = $advActions; AuditHook = $null; DenialHook = $null }
Initialize-WuuInputMode -NonInteractive -Answers @('e')
$advState = Show-WuuAdvancedScreen -Ctx $advCtx
if (@($advState).Count -ne 1) {
    Fail "Show-WuuAdvancedScreen leaked action output and returned $((@($advState) | ForEach-Object { $_.GetType().Name }) -join ' + ') instead of one string"
} elseif ($advState -isnot [string]) {
    Fail "Show-WuuAdvancedScreen returned $($advState.GetType().Name), not a string"
} elseif ($advState -ne 'ADVANCED') {
    Fail "Show-WuuAdvancedScreen returned '$advState', not 'ADVANCED'"
} else { Pass 'Show-WuuAdvancedScreen discards action output and returns strictly [string]''ADVANCED''' }

if ($fail) { Write-Host 'SOME CHECKS FAILED' -ForegroundColor Red; exit 1 }
else { Write-Host 'ALL PASS' -ForegroundColor Cyan }

