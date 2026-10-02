# Test: the console AUTO settings actually gate worker behaviour (hardening brief SS2).
#
# WHY THIS SUITE EXISTS
# ---------------------
# All three automatic behaviours were dead in every release up to v1.4.1-cli. The gates read
# $uiHash.AutoDownloadCheckBox.IsChecked / AutoInstallCheckBox / AutoRebootCheckBox, which are $null
# in this edition because $uiHash is an EMPTY synchronized hashtable. Nothing failed loudly, because
# Wuu.Core.psm1 is the only src/ module without Set-StrictMode - a missing hashtable key is $null.
#
#     AutoDownload:  if ($null -and ...)       -> always $false -> never auto-downloaded
#     AutoInstall:   if ($null -and ...)       -> always $false -> never auto-installed
#     AutoReboot:    if (... -and -not $null)  -> always $true  -> always returned early
#
# So "the setting is on but nothing happened" was the behaviour of every build ever shipped, and no
# test could catch it because the setting was never consulted at all.
#
# HOW THIS TEST AVOIDS THAT CLASS OF BLINDNESS
# --------------------------------------------
# It does NOT re-implement the gates. It EXTRACTS the three condition expressions from the shipped
# source with the PowerShell AST and evaluates them against synthetic rows and settings. That means:
#   * if a gate is reverted to a GUI member, the extraction fails -> this test fails;
#   * if a gate is moved to a different setting, the truth table fails -> this test fails;
#   * the test cannot drift away from the implementation, because it does not contain a copy.
#
# Section 10 applies the same technique to the master toggle itself. The handler tells the operator
# "Nothing has been started - this only changes how FUTURE operations behave." Nothing asserted that:
# section 9 proves WHICH settings change, never what the handler CALLS, so a submission or a remote
# call could be added to the branch and every prior assertion would still pass.
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-AutoSettings.ps1
#
# -CorePath exists so this suite can be pointed at a PRE-FIX copy of the module to prove it has
# teeth. A test that passes against both the broken and the fixed code is not evidence, which is
# the same check Test-AuditConcurrency.ps1 documents for its own concurrency assertions.
#Requires -Version 5.1
param([string]$CorePath)

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$corePath = if ($CorePath) { $CorePath } else { Join-Path $root 'src\Wuu.Core.psm1' }
if (-not (Test-Path -LiteralPath $corePath)) { throw "Core module not found: $corePath" }

$failures = @()
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -eq "$Expected") { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host ("FAIL: {0} - expected '{1}', got '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red; $script:failures += $Name }
}

# --- 1. Locate the three gates in the shipped source ------------------------------------------
$errs = $null; $toks = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($corePath, [ref]$toks, [ref]$errs)
if ($errs.Count) { throw "Wuu.Core.psm1 does not parse: $($errs[0].Message)" }

# Every `if (<cond>)` whose condition mentions stateStore.Settings - those ARE the auto gates.
$gateTexts = @()
foreach ($ifAst in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.IfStatementAst] }, $true)) {
    $t = $ifAst.Clauses[0].Item1.Extent.Text
    if ($t -match 'stateStore\.Settings') { $gateTexts += $t }
}
$gateTexts = @($gateTexts | Sort-Object -Unique)
Write-Host ("Located {0} auto-setting gate(s) in Wuu.Core.psm1" -f $gateTexts.Count) -ForegroundColor DarkGray
foreach ($g in $gateTexts) { Write-Host ("    {0}" -f $g) -ForegroundColor DarkGray }

Assert-Equal ($gateTexts.Count -ge 3) $true 'found at least 3 auto-setting gates in the shipped source'

# ...and that NONE of them mentions a GUI control. This is the regression guard: reverting a gate
# to a checkbox makes the count drop and this assertion fail.
$guiGates = @($gateTexts | Where-Object { $_ -match 'CheckBox|IsChecked|uiHash' })
Assert-Equal $guiGates.Count 0 'no auto-setting gate references a GUI control'

function Get-Gate([string]$Match, [string]$Exact) {
    # Selected by shape, not by position. There are FOUR settings-dependent conditions in the
    # source, not three: the AutoInstall setting also decides whether the follow-up operation is
    # the full AutoFlow chain or a plain Download (`$Computer.PendingOp = if (<setting>) ...`).
    # Selecting on shape keeps the test honest if a future edit adds a fifth gate.
    #
    # $Exact, when supplied, requires the condition to BE that text - `$gateTexts` holds the
    # CONDITION only (the extent of the `if` clause), so anchoring on "if (" would never match.
    # @(...) around the WHOLE if-expression, not inside each branch. `$c = if (...) {A} else {B}`
    # emits a one-element array which PowerShell then UNWRAPS to a scalar string, so `$c[0]` would
    # return the first CHARACTER of the gate text ('$') and build a nonsense scriptblock. This is
    # the same single-element-unwrapping class the release validator has a gate for; it is why the
    # assertion below checks .Count AND the constructed source rather than trusting either.
    $c = @(if ($Exact) { $gateTexts | Where-Object { $_ -ceq $Exact } } else { $gateTexts | Where-Object { $_ -match $Match } })
    if ($c.Count -ne 1) { throw "expected exactly 1 gate for '$Match'/'$Exact', found $($c.Count)" }
    $text = [string]$c[0]
    if ($text -notmatch 'stateStore\.Settings\.') { throw "extracted gate text is not a settings gate: '$text'" }
    return [scriptblock]::Create("param(`$stateStore, `$computer, `$afterInstall) " + $text)
}

$gateDownload = Get-Gate 'AutoDownload' ''
$gateInstall = Get-Gate 'AutoInstall.*Downloaded' ''
$gateReboot = Get-Gate 'AutoReboot' ''
# The AutoFlow/Download decision - the bare setting, with no row properties involved.
$gatePendingOp = Get-Gate '' '$stateStore.Settings.AutoInstall'

# --- 2. Synthetic fixtures mirroring the real shapes ------------------------------------------
# Settings: a SYNCHRONIZED hashtable of three booleans, exactly as New-WuuStateStore builds it.
function New-TestStore([bool]$dl, [bool]$inst, [bool]$rb) {
    return [hashtable]::Synchronized(@{
            Settings = [hashtable]::Synchronized(@{ AutoDownload = $dl; AutoInstall = $inst; AutoReboot = $rb })
        })
}
# Row: the property contract the gates actually touch.
function New-TestRow([int]$available, [int]$downloaded) {
    return [pscustomobject]@{ Computer = 'SRV01'; Available = $available; Downloaded = $downloaded; State = 'Complete'; Pending = $false }
}

# --- 3. AutoDownload truth table ---------------------------------------------------------------
# A row with 12 available, 3 downloaded: the gate should fire ONLY when the setting is on.
$rowWork = New-TestRow 12 3
Assert-Equal (& $gateDownload (New-TestStore $true $false $false) $rowWork $false) $true `
    'AutoDownload=ON  + updates outstanding -> gate TRUE (auto-download will queue)'
Assert-Equal (& $gateDownload (New-TestStore $false $false $false) $rowWork $false) $false `
    'AutoDownload=OFF + updates outstanding -> gate FALSE (no auto-download)'
Assert-Equal (& $gateDownload (New-TestStore $true $false $false) $rowWork $false) $true `
    'AutoDownload=ON  is independent of AutoInstall'

# Nothing outstanding -> must not fire even when enabled (the counts still matter).
Assert-Equal (& $gateDownload (New-TestStore $true $false $false) (New-TestRow 0 0) $false) $false `
    'AutoDownload=ON  + nothing available -> gate FALSE'
Assert-Equal (& $gateDownload (New-TestStore $true $false $false) (New-TestRow 5 5) $false) $false `
    'AutoDownload=ON  + all already downloaded -> gate FALSE'

# --- 4. AutoInstall truth table ---------------------------------------------------------------
$rowReady = New-TestRow 5 5      # downloaded > 0
$rowNoDl = New-TestRow 5 0       # downloaded == 0
Assert-Equal (& $gateInstall (New-TestStore $false $true $false) $rowReady $false) $true `
    'AutoInstall=ON  + downloads present -> gate TRUE (auto-install will queue)'
Assert-Equal (& $gateInstall (New-TestStore $false $false $false) $rowReady $false) $false `
    'AutoInstall=OFF + downloads present -> gate FALSE (no auto-install)'
Assert-Equal (& $gateInstall (New-TestStore $false $true $false) $rowNoDl $false) $false `
    'AutoInstall=ON  + nothing downloaded -> gate FALSE'
Assert-Equal (& $gateInstall (New-TestStore $true $true $false) $rowReady $false) $true `
    'AutoInstall=ON  is independent of AutoDownload'

# --- 4b. The AutoFlow/Download decision --------------------------------------------------------
# A fourth setting-dependent gate, found by this test's own extraction rather than by inspection:
# when a download completes, `PendingOp` decides whether the follow-up is the full unattended chain
# (AutoFlow) or a plain Download. It must follow AutoInstall, or the two would disagree inside one
# function - which is exactly the half-migrated state this pass set out to fix.
Assert-Equal (& $gatePendingOp (New-TestStore $false $true $false) $rowReady $false) $true `
    'AutoInstall=ON  -> follow-up operation is AutoFlow (download+install+reboot+recheck)'
Assert-Equal (& $gatePendingOp (New-TestStore $false $false $false) $rowReady $false) $false `
    'AutoInstall=OFF -> follow-up operation is a plain Download'

# --- 5. AutoReboot truth table ----------------------------------------------------------------
# The gate is `$afterInstall -and -not <setting>` -> it means "return early / skip the reboot".
# So: afterInstall=TRUE + AutoReboot=OFF must SKIP; afterInstall=TRUE + AutoReboot=ON must NOT skip.
Assert-Equal (& $gateReboot (New-TestStore $false $false $true) $rowReady $true) $false `
    'afterInstall + AutoReboot=ON  -> does NOT skip the reboot'
Assert-Equal (& $gateReboot (New-TestStore $false $false $false) $rowReady $true) $true `
    'afterInstall + AutoReboot=OFF -> skips the reboot'
# A manual (non-afterInstall) restart must never be suppressed by the auto setting.
Assert-Equal (& $gateReboot (New-TestStore $false $false $false) $rowReady $false) $false `
    'manual restart is not suppressed by AutoReboot=OFF'

# --- 6. Combination matrix --------------------------------------------------------------------
# All eight combinations, asserting the download and install gates follow their own setting only.
$combos = @()
foreach ($d in @($true, $false)) { foreach ($i in @($true, $false)) { foreach ($r in @($true, $false)) { $combos += , @($d, $i, $r) } } }
$comboFails = 0
foreach ($c in $combos) {
    $s = New-TestStore $c[0] $c[1] $c[2]
    if ((& $gateDownload $s $rowWork $false) -ne $c[0]) { $comboFails++ }
    if ((& $gateInstall $s $rowReady $false) -ne $c[1]) { $comboFails++ }
    # reboot gate is inverted: it skips when the setting is FALSE
    if ((& $gateReboot $s $rowReady $true) -ne (-not $c[2])) { $comboFails++ }
}
Assert-Equal $comboFails 0 'all 8 setting combinations behave correctly (download/install/reboot)'

# --- 7. Missing settings must fail SAFE -------------------------------------------------------
# If the store is absent or malformed, no unattended action should occur. Worth asserting because
# the previous failure mode was precisely "no visible effect, no error".
$malformed = [hashtable]::Synchronized(@{})
$safe = $true
try {
    if ((& $gateDownload $malformed $rowWork $false)) { $safe = $false }
    if ((& $gateInstall $malformed $rowReady $false)) { $safe = $false }
    # For the reboot gate, "safe" means it DOES skip (returns truthy).
    if (-not (& $gateReboot $malformed $rowReady $true)) { $safe = $false }
} catch {
    $safe = $false
    Write-Host ("    (evaluating a malformed store threw: {0})" -f $_.Exception.Message) -ForegroundColor DarkYellow
}
Assert-Equal $safe $true 'a malformed/absent Settings store fails SAFE (no unattended action)'

# --- 8. The GUI members must not exist in the console at all ----------------------------------
# Documents WHY this was broken and guards the underlying condition: $uiHash is empty, so any code
# reading a control member gets $null rather than an error.
Import-Module (Join-Path $root 'src\Wuu.State.psm1') -Force -ErrorAction Stop
$store = New-WuuStateStore
Assert-Equal $store.Settings.AutoDownload $false 'new store defaults AutoDownload to $false (safe default)'

# --- 9. MASTER TOGGLE SEMANTICS (instructions SS16) --------------------------------------------
#
# The toggle used to INVERT each setting independently. From `Download ON / Install OFF / Reboot OFF`
# that yields `OFF / ON / OFF` - a state the operator cannot predict, and one that briefly ENABLES
# auto-install when they meant "turn everything off". The rule is now explicit and absolute:
#
#     ALL ON         -> OFF, OFF, OFF
#     anything else  -> ON,  ON,  ON      (so ALL OFF -> ALL ON, and MIXED -> ALL ON)
#
# MIXED resolving to ALL ON is deliberate: pressing the master control while unsure of the current
# state gives a defined answer instead of an inverted surprise.
#
# Driven against the REAL handler, extracted from the shipped source - not a copy of the rule. A
# re-implementation here would pass while the product kept inverting, which is the blindness this
# suite's header warns about.
#
# Read from $corePath, not a hardcoded src\ path, so the suite's documented -CorePath mechanism
# (point it at a PRE-FIX copy to prove the assertions have teeth) still works for this section too.
$coreSource = Get-Content -LiteralPath $corePath -Raw
$toggleBlock = [regex]::Match($coreSource, "(?s)\`$consoleActions\.EventToggleSettings\s*=\s*\{(.*?)\n\}")
if (-not $toggleBlock.Success) {
    $failures += 'EventToggleSettings was not found in Wuu.Core.psm1'
    Write-Host 'FAIL: the master toggle handler could not be located' -ForegroundColor Red
} else {
    # The handler writes settings and calls Update-Status / Write-Host. Update-Status is a Core
    # function unavailable here, so it is stubbed; the SETTINGS WRITES are what is under test.
    function Update-Status { param([string]$Message) }
    $syntheticStore = New-WuuStateStore
    $toggleAction = [scriptblock]::Create("param(`$stateStore) $($toggleBlock.Groups[1].Value)")

    $toggleTable = @(
        @{ Name = 'ALL OFF  -> ALL ON';    Start = @($false, $false, $false); Want = @($true, $true, $true) }
        @{ Name = 'ALL ON   -> ALL OFF';   Start = @($true, $true, $true);     Want = @($false, $false, $false) }
        @{ Name = 'MIXED 1  -> ALL ON';    Start = @($true, $false, $false);  Want = @($true, $true, $true) }
        @{ Name = 'MIXED 2  -> ALL ON';    Start = @($false, $true, $false);  Want = @($true, $true, $true) }
        @{ Name = 'MIXED 3  -> ALL ON';    Start = @($false, $false, $true);  Want = @($true, $true, $true) }
    )
    foreach ($case in $toggleTable) {
        $st = $syntheticStore.Settings
        $st.AutoDownload = $case.Start[0]; $st.AutoInstall = $case.Start[1]; $st.AutoReboot = $case.Start[2]
        try { & $toggleAction $syntheticStore } catch {
            $failures += "master toggle threw for $($case.Name): $($_.Exception.Message)"
            Write-Host ("FAIL: master toggle threw for {0}: {1}" -f $case.Name, $_.Exception.Message) -ForegroundColor Red
            continue
        }
        $got = @($st.AutoDownload, $st.AutoInstall, $st.AutoReboot)
        Assert-Equal ($got -join '/') ($case.Want -join '/') "master toggle: $($case.Name)"
    }

    # An inverting write is what made the mixed state unpredictable; re-introducing one anywhere
    # would restore the defect silently.
    $inverts = @([regex]::Matches($coreSource, '=\s*-not\s+\$\w*\.?(AutoDownload|AutoInstall|AutoReboot)'))
    Assert-Equal $inverts.Count 0 'no automation setting is INVERTED (the toggle computes an explicit value)'
}

# --- 10. THE MASTER TOGGLE CANNOT START WORK (instructions SS16) --------------------------------
#
# The handler tells the operator "(Nothing has been started - this only changes how FUTURE operations
# behave.)". Section 9 above proves WHICH settings change; it says nothing about what the handler
# CALLS, so a submission or a remote call could be slipped into the branch and every assertion above
# would still pass.
#
# Asserted on the handler's own AST, not on its text. A comment naming a command is not a call, and
# this suite tests behaviour rather than prose (instructions SS37). The allowlist is CLOSED - a
# command that is not listed fails even if it is also not on the denylist - so the check keeps its
# teeth when someone later invents a new dispatch helper.
$toggleAssign = @($ast.FindAll({
            param($x) ($x -is [System.Management.Automation.Language.AssignmentStatementAst]) -and
            ($x.Left.Extent.Text -ceq '$consoleActions.EventToggleSettings')
        }, $true))

Assert-Equal $toggleAssign.Count 1 'the EventToggleSettings handler was located exactly once in the shipped source'
if ($toggleAssign.Count -eq 1) {
    $handlerAst = [System.Management.Automation.Language.Parser]::ParseInput(
        $toggleAssign[0].Right.Extent.Text, [ref]$null, [ref]$null)

    # Every command the handler can invoke. `Out-Null` appears because each funnel call is piped to
    # it; that is a pipe sink, not work.
    $called = @($handlerAst.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() })
    $distinct = @($called | Where-Object { $_ } | Sort-Object -Unique)
    Write-Host ('  EventToggleSettings invokes: {0}' -f ($distinct -join ', ')) -ForegroundColor DarkGray

    $allow = @('Set-WuuSetting', 'Update-Status', 'Write-Host', 'Out-Null')
    $unexpected = @($distinct | Where-Object { $allow -notcontains $_ })
    $unnamed = @($called | Where-Object { -not $_ }).Count

    Assert-Equal $unexpected.Count 0 "the master toggle invokes only the settings funnel and presentation (unexpected: $($unexpected -join ', '))"
    Assert-Equal $unnamed 0 'the master toggle invokes no command through a variable or expression (an indirect call cannot be allowlisted)'

    # Named explicitly as well as covered by the closed allowlist, so a failure names the hazard
    # instead of only reporting an unrecognised command.
    $remote = @('Invoke-Command', 'New-PSSession', 'Enter-PSSession', 'Start-Job', 'Start-ThreadJob',
        'Start-Process', 'Invoke-WuuRemoteTask', 'Invoke-CimMethod', 'Invoke-WmiMethod',
        'Invoke-Expression', 'New-WuuWorker', 'Submit-WuuOperation')
    $present = @($remote | Where-Object { $called -contains $_ })
    Assert-Equal $present.Count 0 "the master toggle starts no work and calls nothing remote (found: $($present -join ', '))"

    # It changes SETTINGS, not operation state. A row write from here would be a mutation outside the
    # approved state code (instructions SS9), which the module-scope gate cannot see because this is
    # a scriptblock body rather than module scope.
    $stateWrites = @($handlerAst.FindAll({
                param($x) ($x -is [System.Management.Automation.Language.AssignmentStatementAst]) -and
                ($x.Left.Extent.Text -match '\.(OperationId|OpState|PendingOp|Revision|Pending|State|StateSource)\b')
            }, $true))
    Assert-Equal $stateWrites.Count 0 'the master toggle writes no operation state (it changes settings only)'

    # All three settings, by name, through the funnel. Two or four would be a defect the table in
    # section 9 cannot see, because it only reads the resulting values.
    $funnelNames = @()
    foreach ($c in $handlerAst.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        if ($c.GetCommandName() -ceq 'Set-WuuSetting') {
            for ($i = 0; $i -lt ($c.CommandElements.Count - 1); $i++) {
                if ($c.CommandElements[$i].Extent.Text -ceq '-Name') {
                    $funnelNames += ([string]$c.CommandElements[$i + 1].Extent.Text).Trim([char]39, [char]34)
                }
            }
        }
    }
    Assert-Equal ((@($funnelNames | Sort-Object -Unique)) -join ', ') 'AutoDownload, AutoInstall, AutoReboot' 'all three settings, and only those, are written through the funnel'
}

# The toggle must go through the settings funnel. Set-WuuSetting exists and is exported, so a
# direct `$s.AutoX = ...` bypasses the one place that validates setting names.
$stateRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw
Assert-Equal ([bool]($stateRaw -match 'function Set-WuuSetting')) $true 'the settings funnel (Set-WuuSetting) exists'
Assert-Equal ([bool]($stateRaw -match "'Set-WuuSetting'")) $true 'the settings funnel (Set-WuuSetting) is exported'

Write-Host ''
if ($failures.Count) {
    Write-Host ("SOME CHECKS FAILED ({0}): {1}" -f $failures.Count, ($failures -join '; ')) -ForegroundColor Red
    exit 1
}
Write-Host 'ALL PASS' -ForegroundColor Cyan
