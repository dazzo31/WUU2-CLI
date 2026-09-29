---
applyTo: "**/*.ps1, **/*.psm1, **/*.psd1"
---

# PowerShell standards for WUU2-CLI

Windows PowerShell 5.1 is the floor (7.x must also work). Keep PS7 compatibility: `Get-CimInstance`
not `Get-WmiObject`, `Invoke-Command` not `-ComputerName` remoting parameters, 2-argument
`Join-Path` not the 3-argument form, no `ForEach-Object -Parallel`.

## Naming and correctness
- Variable names are case-insensitive: never declare two that differ only by case, and never use
  `$host`, `$pid`, `$error`, `$matches`, or another automatic variable as a local.
- PascalCase approved Verb-Noun for functions; only real, documented cmdlets and parameters.
- Single-quoted strings unless interpolating; here-strings for multi-line text; no stray backticks.

## Module and state boundaries
- Modules are imported with `-Global` (see `Import-WuuModules`). A module imported without it is
  invisible to the isolated worker runspaces, which is why cross-module helpers read `$global:*`.
- Interactive input must go through `Read-WuuAnswer` / `Read-WuuYesNo` / `Read-WuuSelection`: they
  honour non-interactive mode. A `Read-Host` call inside a screen cannot be driven by a test.
- Presentation code (`Wuu.Navigate`, `Wuu.Session`) delegates to the action layer. Reaching into
  the update engine from a screen forks the engine and bypasses the audit reason rule.

## Runspaces, threading, and the update engine
- Windows Update Agent COM objects are apartment-affine and cannot cross a process or runspace
  boundary: never `Start-Job` for them (serialization strips the COM interfaces) and never route
  them through the worker pool. WUA work stays in `New-ComputerRunspace`; the pool in
  `Wuu.Workers.psm1` is for bounded WMI/CIM/service/ping/network probes only.
- Bound remote work with `Invoke-CimWithTimeout` / `Invoke-ServiceWithTimeout` /
  `Invoke-WithPoolTimeout` rather than hand-rolled waits.
- Scriptblocks injected into a runspace via `SessionStateProxy.SetVariable` must be unbound:
  `[scriptblock]::Create($sb.ToString())`. A literal `{...}` stays bound to the creating runspace.
- `PowerShell.Dispose()` does not close an explicitly assigned runspace — call `Runspace.Close()`
  and then `Dispose()`, or it leaks.
- Snapshot a synchronized collection before enumerating it (`@($jobs)`), and write to the store
  by mutating row properties plus `$stateStore.Touch()`.

## Output and loops
- Prefer pipeline cmdlets (`Where-Object`, `Select-Object`, `ForEach-Object`) to manual loops, and
  never grow an array with `+=` inside a loop — use `[System.Collections.ArrayList]`.
- **Exception:** on any path that can execute while a caller is blocked on the console renderer,
  use language constructs only (`foreach`/`if`). Pipeline cmdlets there have deadlocked this app.
- Return collections plainly and wrap call sites in `@()`. Do not use `return ,$x` or
  `Write-Output -NoEnumerate` — combined with a wrapping caller that yields a nested array.
- Output objects, not formatted text; never parse `Format-*` output. `Write-Host` only for
  operator-facing status.

## Errors, diagnostics, secrets
- `try`/`catch` only where handled or rethrown, referencing `$_.Exception.Message`; check
  `$LASTEXITCODE` after external tools; use `Write-Verbose` for diagnostics.
- No hard-coded secrets. Use `Get-Credential`, a parameter, or the existing encrypted
  computer-list config / credential cache; expose paths and environment values as parameters.
- Logging is fault-tolerant by design: a failure to log must not abort the operation — except on
  mutating audit paths, which are deliberately fail-closed.
