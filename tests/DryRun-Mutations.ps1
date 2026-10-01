# Dry run: check each mutation pattern matches the shipped source EXACTLY ONCE, without editing anything.
# A pattern that matches 0 times would edit nothing, and the harness would then report "CAUGHT" against a
# healthy tree - a proof that never ran.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$core = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Core.psm1'))
$state = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.State.psm1'))
$audit = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Audit.psm1'))

$patterns = @(
    @{ Id = 'M1'; File = 'Core';  Text = $core;  Pattern = "Invoke-CimWithTimeout -ComputerName `$Computer.computer -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 5 -Operation 'WMI connectivity test' -Row `$Computer" },
    @{ Id = 'M2'; File = 'State'; Text = $state; Pattern = "`$result = @{ Known = `$false; Remaining = `$null; Op = ''; ExpiresAt = `$null }" },
    @{ Id = 'M3'; File = 'Core';  Text = $core;  Pattern = "-ArgumentList @(`$ComputerName, `$ClassName, `$Credential) -TimeoutSeconds `$effectiveTimeout -OperationName `$Operation" },
    @{ Id = 'M4'; File = 'Audit'; Text = $audit; Pattern = '$result.Reason = "anchor refused: the anchor directory is the log''s own directory (''$logDir''), so it offers no separation from the log it anchors"' },
    @{ Id = 'M5'; File = 'Core';  Text = $core;  Pattern = "`$effectiveTimeout = `$TimeoutSeconds`r`n            if (`$TimeoutSeconds -gt 0 -and `$null -ne `$Row) {" }
)

$bad = 0
foreach ($p in $patterns) {
    $n = ([regex]::Matches($p.Text, [regex]::Escape($p.Pattern))).Count
    $ok = ($n -eq 1)
    if (-not $ok) { $bad++ }
    Write-Host ("  {0} [{1,-5}] matched {2} time(s)  {3}" -f $p.Id, $p.File, $n, $(if ($ok) { 'OK' } else { 'PROBLEM - must be exactly 1' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
    if (-not $ok) { Write-Host ("      pattern: {0}" -f ($p.Pattern -replace "`r?`n", '\n')) -ForegroundColor DarkGray }
}

# The detection needles must appear in a file the gate actually RUNS, or "the gate failed with this
# message" could never be satisfied by the mutation under test.
#
# THE CORPUS IS THE GATE PLUS ITS FRAGMENTS. Validate-Release.ps1 was decomposed (instructions SS39)
# into Scripts\Test-*.ps1 dot-sourced fragments, and these needles moved with their blocks - so
# searching only the gate now reports "needle missing" for a message that is present and live. Reading
# the CONCATENATION is what keeps this a check on the emitted text rather than on the file layout.
$gateFiles = @((Join-Path $root 'Scripts\Validate-Release.ps1')) +
    @(Get-ChildItem -Path (Join-Path $root 'Scripts') -Filter 'Test-*.ps1' -File | ForEach-Object { $_.FullName })
$gate = ($gateFiles | ForEach-Object { [System.IO.File]::ReadAllText($_) }) -join "`n"
Write-Host ("  (needle corpus: {0} file(s) = the gate + its fragments)" -f $gateFiles.Count) -ForegroundColor DarkGray
Write-Host ''
Write-Host '  detection needles in the gate:'
foreach ($n in 'omit -Row', 'no recorded deadline had its inner timeout changed', 'does not PASS it to the pool', 'CALLS a module function', 'offers no separation') {
    $c = ([regex]::Matches($gate, [regex]::Escape($n))).Count
    Write-Host ("    {0,-58} {1}" -f $n, $c) -ForegroundColor $(if ($c -ge 1) { 'Green' } else { 'Red' })
    if ($c -lt 1) { $bad++ }
}

Write-Host ''
if ($bad -eq 0) { Write-Host 'DRY RUN OK' -ForegroundColor Green; exit 0 }
else { Write-Host "DRY RUN FAILED ($bad problem(s))" -ForegroundColor Red; exit 1 }
