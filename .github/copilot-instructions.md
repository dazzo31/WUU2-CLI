# WUU2-CLI — Copilot instructions

**Windows Update Utility, console edition.** Remote Windows Update check/download/install/reboot
across a fleet, with a hash-chained ISO 27001 A.8.15 audit trail. Pure PowerShell 5.1 — no build
system, no package manager, no Pester. This is a **separate git repository** from the GUI edition
(`..\WUU2`); do not mix them, and do not copy its XAML/WPF rules here.

## Layout boundaries
- `WUU.ps1` is the entry point only. All logic lives in `src\*.psm1` — add code to a module.
- Modules load via `Import-WuuModules` (all `-Global`); the order is mostly for readability.
  `Wuu.Navigate` (guided workflow) and `Wuu.Session` (ComputerSet) sit *above* the engine: they
  delegate to the `$consoleActions` handlers in `Wuu.Core.psm1` and must never call the update
  engine directly.
- `dist\` (including `dist\staging\`) is packaged output — never edit it or search it.
- `Wuu.Core.psm1` retains legacy closures (`$eventGetUpdates`, `$eventInstallUpdates`,
  `$eventCopyComputers`, `$eventActionMenu`, …) that read `$uiHash.Listview.SelectedItems` — a
  WPF path the console shell never populates. Console behaviour lives in the `$consoleActions.*`
  adapters; extend those, not the `$event*` closures, and add no new WPF/`System.Windows.*` use.

## Commands (elevated; `-STA` is required)
- Release gate: `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Validate-Release.ps1`
- Suites: `tests\Test-*.ps1`, excluding `Test-ColumnResize.ps1` and `Test-DragResize.ps1`
  (GUI leftovers; the latter hangs on a blocking dispatcher pump).

## Constraints that have broken this project before
- PowerShell 5.1 is the floor: no `ForEach-Object -Parallel`, no 3-argument `Join-Path`.
- Shipped files containing non-ASCII must keep a UTF-8 BOM — `files.encoding` is `utf8` for this
  reason. A BOM-less file is read as ANSI by 5.1 and a multi-byte character eats a quote.
- Interactive input goes through `Read-WuuAnswer` / `Read-WuuYesNo` / `Read-WuuSelection` only.
  A screen that calls `Read-Host` cannot be tested and hangs scripted runs.
- Mutating operations carry `Mutating = $true` and run through the audit choke point, which
  requires a reason. Keep those flags accurate — a wrong flag silently skips the audit rule.
