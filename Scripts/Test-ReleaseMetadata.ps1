# Release validation, RELEASE METADATA group: elevation relaunch, -STA, single-sourced version, packager contents, help text, parameter reassignment. Extracted from Validate-Release.ps1 (instructions SS39).
#
# DOT-SOURCED FRAGMENT - not a standalone script. Validate-Release.ps1 dot-sources it into its own
# scope, which is what gives this file $root, the verdict helpers (Pass/Fail/Warn/Skip/Not-Implemented)
# and any variable the gate computed above the dot-source line. It is dot-sourced AT ITS ORIGINAL
# POSITION because the order of the verdict list is part of what CI reads.

# (a) The elevation relaunch must forward the REAL arguments. The original used `if ($args)`,
#     which is ALWAYS empty inside a param() function, so `WUU.ps1 install -Computer X` relaunched
#     into the interactive menu with the operator's arguments silently discarded.
if ($coreRaw -match '(?m)^\s*if\s*\(\$args\)\s*\{') {
    Fail "elevation/STA relaunch tests `$args, which is always empty inside a param() function - forwarded arguments would be silently dropped"
} else { Pass 'no relaunch relies on $args (arguments would not be silently dropped)' }

# (b) Both relaunches must pass -STA. A relaunch without it trips the STA validation and relaunches
#     a SECOND time, losing the arguments again (the bug that made this a two-hop problem).
#     Match the argument-array construction lines, identified by the '-NoProfile' string literal.
#     (Matching on 'powershell.exe' instead also hits `$processStartInfo.FileName = 'powershell.exe'`,
#     which is a false positive - the gate was probed against the real file before being trusted.)
$relaunchLines = @($coreRaw -split "`n" | Where-Object { $_ -match "'-NoProfile'" })
$missingSta = @($relaunchLines | Where-Object { $_ -notmatch "'-STA'" })
if ($relaunchLines.Count -lt 2) {
    Fail "expected 2 relaunch argument lists (elevation + STA), found $($relaunchLines.Count)"
} elseif ($missingSta.Count -gt 0) {
    Fail "a relaunch does not pass -STA (would trigger a second relaunch and lose arguments): $($missingSta[0].Trim())"
} else { Pass 'both relaunch paths pass -STA' }

# (c) The elevation relaunch must forward $CommandArguments (the real parameter).
if ($coreRaw -notmatch '\$forwardArgs') {
    Fail 'elevation relaunch does not build a forwarded-argument list'
} else { Pass 'elevation relaunch forwards the real command arguments' }

# (d) A declined UAC prompt must NOT block on input - Read-Host after a cancellation hangs any
#     unattended/CI invocation forever.
$elevBlock = [regex]::Match($coreRaw, '(?s)Requesting elevation.*?#endregion Administrator Privilege Check').Value
if ($elevBlock -match 'Read-Host') {
    Fail 'elevation failure path calls Read-Host (hangs non-interactive invocations on a declined UAC prompt)'
} else { Pass 'declined elevation exits without blocking on input' }

# (e) A sub-dispatch token must never be passed to a ValidateSet parameter meant for something
#     else. Binding $parsed.SubVerb to -ServiceAction hard-threw for every sub-dispatched verb
#     except `service restart` (whose subverb happens to be a valid service action):
#       `audit export` -> "Cannot validate argument on parameter 'ServiceAction'" -> CRITICAL ERROR,
#     which made audit verify/show/export look permanently unreachable.
if ($coreRaw -match '(?m)^\s*-ServiceAction\s+\$parsed\.SubVerb\s*$') {
    Fail "-ServiceAction is bound directly to `$parsed.SubVerb - every non-service subverb crashes on the ValidateSet"
} else { Pass '-ServiceAction is guarded by verb (subverbs cannot crash the ValidateSet)' }

# (f) Command mode must log the raw argv. Without it, command mode leaves NO trace that a command
#     was requested, making "my arguments were ignored" impossible to diagnose after the fact.
if ($coreRaw -notmatch 'Command mode: argv') {
    Fail 'command mode does not log its argv (argument-loss failures are undiagnosable)'
} else { Pass 'command mode logs its argv' }

# (g) The released version must be single-sourced. The banner and the audit records each hardcoded
#     their own string, so a release could ship with the log claiming one version and the audit
#     trail (an ISO 27001 field) recording another.
if ($coreRaw -notmatch '\$global:WuuVersion\s*=') {
    Fail 'no $global:WuuVersion constant - the version is not single-sourced'
} elseif ($auditRaw -match "wuuVersion\s*=\s*'v") {
    Fail 'Wuu.Audit hardcodes wuuVersion instead of reading $global:WuuVersion'
} else { Pass 'version is single-sourced ($global:WuuVersion)' }

# (h) The packager must ship docs\ (recursively). A non-recursive top-level *.md copy shipped a
#     release with NO compliance documentation at all.
if ($pkgRaw -notmatch "docsSrc") {
    Fail 'packager does not include docs\ - a release would ship without the ISO/retention docs'
} else { Pass 'packager includes docs\ (compliance documentation ships)' }

# (i) The packager must not ship GUI-edition documents into a console release.
if ($pkgRaw -notmatch 'guiOnlyDocs') {
    Fail 'packager does not exclude GUI-only docs (would misdirect a console-edition tester)'
} else { Pass 'packager excludes GUI-only docs from the console package' }

# (j) The command help must document -LogPath, since -Path means different things per subverb
#     (an inspected log for verify/show, an output destination for export).
if ($cmdRaw -notmatch "'-logpath'") {
    Fail "-LogPath is not registered as a known option (audit export cannot name its input log)"
} else { Pass '-LogPath is a registered option' }

# (k) NO FUNCTION MAY REASSIGN ITS OWN PARAMETER.
#     PowerShell variable names are CASE-INSENSITIVE, so a local named `$actions` IS the
#     `$Actions` parameter - and since a parameter's declared type is enforced on every
#     assignment, `$actions = Get-WuuMenuActions` (an Object[]) tried to coerce into the
#     [hashtable]$Actions parameter and threw
#         Cannot convert the "System.Object[]" value of type "System.Object[]" to
#         type "System.Collections.Hashtable"
#     That killed the console shell the instant the menu was drawn, making the interactive
#     edition completely unusable - while every non-interactive test suite stayed green, because
#     none of them draw the menu. This class has now bitten this project three times ($host,
#     $pid, and this), so it is gated.
$reassign = @()
foreach ($modFile in @(Get-ChildItem -Path (Join-Path $root 'src') -Filter '*.psm1' -File)) {
    $modErrs = $null
    $modAst = [System.Management.Automation.Language.Parser]::ParseFile($modFile.FullName, [ref]$null, [ref]$modErrs)
    if (-not $modAst) { continue }
    foreach ($fn in $modAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if (-not $fn.Body.ParamBlock) { continue }
        $paramNames = @($fn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        if ($paramNames.Count -eq 0) { continue }
        $assigned = @($fn.Body.FindAll({
            $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $args[0].Left -is [System.Management.Automation.Language.VariableExpressionAst]
        }, $true) | ForEach-Object { $_.Left.VariablePath.UserPath })
        # NOTE: compared with -contains on UserPath, which is already case-insensitive for the
        # comparison operators used here. Matching on the AST (not raw text) means comments
        # cannot produce false positives - the same lesson as the RAW-vs-tokenised rule.
        foreach ($a in $assigned) {
            if ($paramNames -contains $a) { $reassign += "$($modFile.Name)::$($fn.Name) reassigns `$$a" }
        }
    }
}
$reassign = @($reassign | Sort-Object -Unique)
if ($reassign.Count -gt 0) {
    Fail "function(s) reassign their own parameter (case-insensitive collision - type coercion can throw): $($reassign -join '; ')"
} else { Pass 'no function reassigns its own parameter (no case-insensitive collisions)' }

# --- 12. Interactive workflow invariants (docs/INTERACTIVE_UI_SPEC.md) ----------------------
#     Encodes the spec's P0 requirements (section 25) as STRUCTURAL facts, so a future change
#     cannot quietly undo the redesign.

$navRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Navigate.psm1') -Raw
$conRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Console.psm1') -Raw
$coreRaw2 = $coreRaw
