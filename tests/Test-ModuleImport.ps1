#Requires -Version 5.1
<#
.SYNOPSIS Import smoke test for the split WUU2 modules.
.DESCRIPTION Imports each src module in dependency order and reports exported commands.
Run from repo root:  powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-ModuleImport.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

# This suite MUST be able to fail. It previously printed `MISSING <cmd>` in red and then exited 0, so
# every scripted runner - and the documented CI loop - recorded it as a PASS even when a command the
# entry point depends on had disappeared. A test that cannot fail is worse than no test, because it is
# counted as protection. The exit code is now derived from the missing list.
$missing = @()

try {
    Get-ChildItem (Join-Path $root 'src\*.psm1') | Sort-Object Name | ForEach-Object {
        Import-Module $_.FullName -ErrorAction Stop
        Write-Host ("IMPORTED  {0}  ({1} exports)" -f $_.BaseName, (Get-Module $_.BaseName).ExportedCommands.Keys.Count)
    }
    Write-Host 'ALL MODULES IMPORT OK' -ForegroundColor Green

    # Verify the key commands the entry point depends on
    $required = @('Start-WuuApplication','New-WuuErrorSuggestions','Write-DebugLog','Invoke-CimWithTimeout','Show-CredentialConfigDialog','New-ComputerRunspace')
    foreach ($c in $required) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { Write-Host ("PASS: required command available: {0} ({1})" -f $c, $cmd.ModuleName) -ForegroundColor Green }
        else {
            # Reported as a FAIL line so the aggregate runner counts it, and collected for the exit code.
            Write-Host ("FAIL: MISSING required command: {0} - the entry point depends on it" -f $c) -ForegroundColor Red
            $missing += $c
        }
    }
} catch {
    Write-Host ("FAIL: IMPORT FAILED: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

if ($missing.Count) {
    Write-Host ("FAIL: {0} required command(s) missing: {1}" -f $missing.Count, ($missing -join ', ')) -ForegroundColor Red
    exit 1
}
Write-Host ("RESULT: all {0} modules imported and every required command resolved" -f (Get-ChildItem (Join-Path $root 'src\*.psm1')).Count) -ForegroundColor Green
exit 0
