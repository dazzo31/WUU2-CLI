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

Exit codes (command mode; see `WUU.ps1 -Help` and src\Wuu.Command.psm1 Get-WuuExitCode):
    0 success - the operation COMPLETED     4 partial success (reserved)
    1 operation failed                      5 audit failure (chain broken / unwritable)
    2 usage error                           6 queued (-Async: accepted, NOT completed)
    3 timeout - still working               7 refused (e.g. a mutating verb without -Reason)

Note 6: `-Async` means "queue it and give me my prompt back". Without -Async, a command that
returns while work is still running exits 3, never 0 - a script must not read "accepted" as
"done".

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
