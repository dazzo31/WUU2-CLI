# WUU2-CLI v1.4.1-cli

**Fixes a fatal crash that made the interactive edition completely unusable.** If you tried
v1.4.0-cli and saw this immediately after the menu was drawn:

```
Fatal error: Cannot convert the "System.Object[]" value of type "System.Object[]"
to type "System.Collections.Hashtable".
```

…that is this bug, and it is fixed. **v1.4.0-cli should not be used.**

---

## The bug

`Start-WuuConsoleLoop` takes its action layer as a parameter:

```powershell
param(
    ...
    [Parameter(Mandatory)][hashtable]$Actions,
    ...
)
```

and then, at the top of the loop, asked for the menu list:

```powershell
$actions = Get-WuuMenuActions     # <-- returns an ARRAY
```

**PowerShell variable names are case-insensitive**, so `$actions` *is* the `$Actions` parameter —
not a new variable. And a parameter's declared type is enforced on **every** assignment, not just
at binding, so storing an `Object[]` into a `[hashtable]` threw before any input was read. The
shell died on the line after the menu was drawn, which is exactly what the screenshot showed.

The same function then read the wrong value too (`foreach ($a in $actions)`), so even without the
type coercion the loop would have iterated the action *hashtable* instead of the menu.

Fixed by renaming the local to `$menuActions` and updating its one consumer.

## Why it shipped

Every existing test suite is **non-interactive** — they call the action layer directly and never
draw the menu. All of them stayed green, and the validator's 37 structural checks passed, while
the interactive edition was 100% broken. **A green suite that never exercises the surface the user
touches is not evidence about that surface.**

This is the third occurrence of this bug class in this project:

| Variable | Collided with | Effect |
| --- | --- | --- |
| `$host` | read-only automatic `$Host` | write error |
| `$pid` | read-only automatic `$PID` | write error |
| `$actions` | `[hashtable]$Actions` parameter | **fatal crash at startup** |

## Fixes in v1.4.1-cli

1. **The crash** — `$actions` renamed to `$menuActions` in `Start-WuuConsoleLoop`.
2. **The same pattern elsewhere.** A new validator gate scans every function in `src\` via the
   PowerShell AST and fails the build if *any* function reassigns one of its own parameters. It
   found two more instances:
   - `Invoke-WuuAuditCommand` — `$logPath = $LogPath` assigned its own `[string]$LogPath`
     parameter. Harmless only because both sides are `[string]`; renamed to `$resolvedLog`.
   - `Write-WuuLogEntry` — `$LogLock = New-Object System.Object` assigned its own `[object]$LogLock`
     parameter. Harmless only because the type is `[object]`; renamed to `$effectiveLock`.
   Both are now provably safe rather than coincidentally safe.
3. **The menu blocked automated testing.** The menu keypress was read with
   `[Console]::ReadKey`, the *only* menu input that bypassed the Phase 2 input choke point
   (`Read-WuuAnswer`). Anything driving the menu programmatically, or a redirected stdin, would
   hang forever on a terminal nobody was typing into — so the loop was **unreachable from a test**,
   which is why the crash could not be caught. The loop now honours non-interactive mode and pulls
   selections through the same choke point, so it can be driven deterministically.
4. **New test suite: `tests\Test-ConsoleLoop.ps1`** (13 checks) covering the presentation path:
   menu shape and uniqueness, mutating-entry set, rendering with an **empty** list (the operator's
   exact state) and with a computer present, plus entering and leaving the loop itself.
   **The test was verified to have teeth**: the bug was reintroduced and the suite failed with the
   original error message before being restored.

## Verification

- `Scripts\Validate-Release.ps1` — **38/38** (new gate: no function reassigns its own parameter).
- **12 test suites green** under PS 5.1, including the new console-loop suite.
- The new suite was proved to detect the original defect, not merely to pass.

## Still worth knowing

- **`README.md` still documents the GUI edition** (right-click the grid, ListView, columns). It
  will misdirect anyone reading it. Not addressed in this release.
- **The audit trail is tamper-evident, not tamper-proof.** A host administrator can delete a
  day's file and the remainder still verifies. See `docs/ISO_27001_A815_MAPPING.md` §8.
- `tests\Test-ColumnResize.ps1` and `Test-DragResize.ps1` still hang (they load
  `PresentationFramework` — GUI-era leftovers). They are not part of the suite.

---

## Upgrading from v1.4.0-cli

Replace the folder. No config migration, no audit-format change — the record schema is unchanged
from v1.4.0-cli, so existing audit logs still verify.
