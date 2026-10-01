# Wuu.Core history (moved out of the module header, 2026-09-30)

This material was the module header of `src/Wuu.Core.psm1`. It is preserved verbatim for provenance; it
is **not** a description of the current file and should not be read as one.

## Why it was moved

It described the file as a GUI application, carried the author and date of the legacy GUI edition, and
listed the feature changelog of that edition's enhanced build. `Wuu.Core.psm1` is the headless CLI engine:
the release gate asserts that the shipped tree contains no WPF, no XAML and no `ui` references at all, and
a header claiming otherwise is read as current fact by the next person to open the file. A long header is
a cost; a **wrong** header is a defect.

The CLI edition's real identity, version, and release notes live at:

- `docs/RELEASE_NOTES_v1.5.0-beta.3-cli.md` - what this edition is
- `docs/HARDENING_COMPLETION_REPORT.md` - enforcement status per invariant
- `docs/ARCHITECTURE.md`, `docs/STATE-MACHINE.md` - how the engine is put together

See `docs/CODE_COMMENT_POLICY.md` for why the rest of the inline commentary was deliberately left in place.

## Original header (verbatim)

```
.SYNOPSIS
This script provides a GUI for remotely managing Windows Updates.

.DESCRIPTION
This script provides a GUI for remotely managing Windows Updates. You can check for, download, and install updates remotely. There is also an option to automatically reboot the computer after installing updates if required.

.EXAMPLE
.\WUU.ps1

This example open the Windows Update Utility.

.NOTES
Author: Tyler Siegrist
Date: 12/14/2016

This script needs to be run as an administrator with the credentials of an administrator on the remote computers.

Microsoft restricts remote download/install of Windows Updates, so those steps run the patch scripts locally on the remote machine as SYSTEM through a temporary scheduled task (managed over WMI/DCOM), which reports progress back through the registry.

.CHANGELOG
Enhanced Version - 2025-07-08
- Added enhanced error handling with retry logic and connectivity validation
- Improved error messages with specific suggestions for common issues (RPC, WMI, access denied)
- Added performance monitoring (CPU usage, memory, network latency) with threshold warnings
- Implemented automated recovery for common issues (RPC service restart, Remote Registry service)
- Added dependency checking (RPC, WMI, Windows Update service) before operations
- Implemented job throttling for scalability (max concurrent operations configurable)
- Added grey background coloring for errored entries in the UI
- Enhanced status messages to include "Reboot required" when applicable
- Added three automation levels:
  * Auto Reboot: Automatically reboots after installation if required
  * Auto Install: Automatically installs updates once downloaded
  * Full Automation: Complete workflow (download -> install -> reboot -> re-check)
- Added tooltips to UI elements for better user guidance
- Improved error handling with auto-recovery attempts and detailed suggestions
- Enhanced connectivity validation with multiple retry attempts
- Added performance thresholds to prevent operations on overloaded systems
- Implemented comprehensive logging of system performance metrics
- Fixed PowerShell Core 7.x compatibility issues:
  * Replaced Get-Service -ComputerName with Invoke-Command for remote service management
  * Replaced Get-WmiObject with Get-CimInstance for WMI operations
  * Added local vs remote computer detection for proper cmdlet usage
- Added debug logging toggle variable ($EnableDebugLogging) set to $false by default
  * Reduces console output and log file generation for cleaner operation
  * Can be enabled by setting $global:EnableDebugLogging = $true at the top of the script
- Fixed PSScriptAnalyzer warning by removing unused $dependencies variable
- Added configurable credential management for remote WMI/CIM queries
  * Custom credential configuration dialog for username, domain, and password
  * Securely stores credentials with encrypted computer list configurations
  * Falls back to prompting for alternate credentials if configured credentials fail
  * Caches working credentials per computer to avoid repeated prompts
  * Right-click context menu option to configure custom credentials
  * Greatly improves connectivity to domain computers with authentication requirements
```

## Note on the GUI edition

The header's UI items ("grey background coloring for errored entries in the UI", "tooltips to UI elements",
the custom-credential *dialog*, the right-click *context menu*) belong to the GUI edition, which is not
shipped here. Their console equivalents - row colour names, the credential store, the `:config` command -
are documented in `docs/ARCHITECTURE.md`. The one item that is a genuine platform constraint rather than a
feature is the paragraph about Microsoft restricting remote download/install, which is retained inline in
the module.
