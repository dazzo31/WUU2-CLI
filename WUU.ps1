#Requires -Version 5.1
<#
.SYNOPSIS
Windows Update Utility (WUU2) - application entry point (console edition).

.DESCRIPTION
Two modes:

  WUU.ps1                       interactive menu
  WUU.ps1 <verb> [options]      run one operation and exit  (Phase 2 command mode)

  Examples:
    WUU.ps1 check -All
    WUU.ps1 show available -Computer SRV01 -Json
    WUU.ps1 install -Computer SRV01 -WhatIf
    WUU.ps1 -Help

Run `WUU.ps1 -Help` for the full verb list. All logic lives in src\*.psm1: the presentation
layer is src\Wuu.Console.psm1 and the verb layer is src\Wuu.Command.psm1 (neither is imported
here - Start-WuuApplication handles module loading).

.NOTES
Requires an elevated PowerShell host:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WUU.ps1 check -All
(-STA is retained for compatibility with the update COM APIs and the per-computer runspaces.)

Exit codes: 0 = success, 1 = the command failed (command mode only).

TIP - create a `wuu.cmd` shim on PATH to avoid typing the host:
    @echo off
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0WUU.ps1" %*
#>
[CmdletBinding()]
param(
    # Everything after the script name is forwarded to command mode. ValueFromRemainingArguments
    # keeps options like -Computer from being bound by THIS param block.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments = @()
)

$ErrorActionPreference = 'Stop'

# WUU must run from its own folder (Scripts\, src\ are relative to here)
$wuuRoot = Split-Path $MyInvocation.MyCommand.Path
Set-Location $wuuRoot

try {
    Import-Module (Join-Path $wuuRoot 'src\Wuu.Core.psm1') -ErrorAction Stop
    Start-WuuApplication -WuuRoot $wuuRoot -CommandArguments $Arguments
} catch {
    Write-Error "Failed to start WUU: $($_.Exception.Message)"
    Read-Host 'Press Enter to exit'
    exit 1
}
