#Requires -Version 5.1
<#
.SYNOPSIS
Windows Update Utility (WUU2) - application entry point.

.DESCRIPTION
Thin launcher: validates the host, imports the src/ modules, and hands control to
Start-WuuApplication. All logic lives in src\*.psm1; the presentation layer is
src\Wuu.Console.psm1 (console edition - no XAML, no WPF).

.NOTES
Requires an elevated PowerShell host:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WUU.ps1
(-STA is retained for compatibility with the update COM APIs and the per-computer runspaces.)
#>
param()

$ErrorActionPreference = 'Stop'

# WUU must run from its own folder (Scripts\, src\ are relative to here)
$wuuRoot = Split-Path $MyInvocation.MyCommand.Path
Set-Location $wuuRoot

try {
    Import-Module (Join-Path $wuuRoot 'src\Wuu.Core.psm1') -ErrorAction Stop
    Start-WuuApplication -WuuRoot $wuuRoot
} catch {
    Write-Error "Failed to start WUU: $($_.Exception.Message)"
    Read-Host 'Press Enter to exit'
    exit 1
}
