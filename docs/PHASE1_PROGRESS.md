# Phase 1 — Presentation Abstraction: Progress Log

**Started:** 2026-09-27
**Goal:** Remove the WPF dependency from worker payloads by replacing
`$uiHash.<Control>.Dispatcher.Invoke(...)` + `EditItem/CommitEdit/Refresh` +
`ContainerFromItem(...).Background` with a thread-safe state store.
**Full plan:** [CLI_AUDIT_PLAN.md](CLI_AUDIT_PLAN.md) §6 Phase 1

---

## Status: IN PROGRESS

| Deliverable | State |
|---|---|
| `src/Wuu.State.psm1` (store + row factory + settings + operator context) | **DONE** |
| `tests/Test-StateStore.ps1` (headless + isolated-worker proof) | **DONE, 19/19 PASS** |
| `Wuu.WindowsUpdate.psm1` dispatcher actions → store | **DONE** |
| `stateStore` injected into worker + jobCleanup runspaces + context | **DONE** |
| `Wuu.Core.psm1` payloads (89 remaining `Dispatcher` refs) → store | NOT STARTED |
| Headless payload harness (`Start-WuuApplication` stub) | NOT STARTED |
| Delete `ui/` + XAML load path | NOT STARTED |

**Remaining `Dispatcher` references: 89** (measured in `Wuu.Core.psm1`). These are the
payload/event-handler sites (`$GetUpdates`, `$DownloadUpdates`, `$InstallUpdates`,
`$RestartComputer`, `$AddEntry`, `$removeEntry`, …) plus GUI-only chrome that gets deleted
with `ui/`. `Wuu.WindowsUpdate.psm1` is fully rewired.

## New in the second increment

- **`Settings` on the store** replaces the three `$uiHash.Auto*CheckBox.IsChecked` reads.
  Enumerated the *entire* `$uiHash` surface used by payloads to size this properly: the three
  checkboxes are the only behavioural members; everything else is menu wiring
  (`AddADMenu`, `ExitMenu`, …), ListView chrome (`Listview`, `clientObservable`, `GridView`)
  or `Window`. Verified by regex over both modules — do not guess this again.
- **`SetStatus` store method** replaces `$uiHash.StatusTextBox.Text = $x`.
- **`Set-WuuSetting`** validated setter (console-shell side).
- **Rewired `Wuu.WindowsUpdate.psm1`**: `SafeUpdateListViewItemScript`,
  `SetComputerTimeoutScript`, `SetComputerStateScript` write to the store + `Touch()`.
  Timeout colour `[Brushes]::LightYellow` → `$Computer.Color = 'Timeout'`.
- **Rewired the jobCleanup 10-minute-timeout handler** in `Wuu.Core.psm1` (was a
  `Dispatcher.Invoke` + `foreach` lookup; now a direct `$stateStore.ByName[...]` write).
- **`stateStore` injected** into `New-ComputerRunspace`, the jobCleanup runspace, and the
  WindowsUpdate context (`StateStore` key).
- **`docs/SUGGESTIONS_FOR_GUI.md`** — 7 structural improvements for the WPF edition with risk
  ratings and adoption order (requested by the user).

---

## What was discovered (this shaped the approach)

Before writing anything, the actual coupling was measured rather than assumed:

1. **Worker payloads already mutate row objects directly.** Across `Wuu.Core.psm1` the
   dominant pattern is `$computer.Status = '...'` / `$computer.State = '...'` — plain
   property assignment on a `PSObject`. That already works headlessly; it is why so much
   of the engine needs no change.

2. **Only three things are genuinely WPF-bound:**
   - `$uiHash.Listview.Items.EditItem($row)` + `CommitEdit()` + `Refresh()` → **redraw**
   - `$uiHash.ListView.Dispatcher.Invoke('Background', [action]{...})` → **thread marshalling**
   - `ContainerFromItem($row).Background = [Brushes]::LightGray|LightYellow` → **colour**

3. **Colour is only ever two values in practice:** `LightGray` (error) and `LightYellow`
   (timeout). Verified by grep of every `Brushes` usage. So colour reduces to a *name*
   on the row — no brush, no visual tree walk, no `ItemContainerGenerator`.

This means the abstraction is small: a synchronized row collection plus a revision
counter (redraw signal) plus a colour name. **No WPF type needs to be modelled.**

## Design decisions (and why)

### D1 — Workers talk to the store by property mutation + `Touch()`, not by calling module functions
Isolated runspaces created by `New-ComputerRunspace` **cannot see module functions**
(established in the GUI edition: modules imported without `-Global` are invisible to
sibling modules/runspaces). So `Wuu.State` functions are for the *console shell* only.

Workers instead:
```powershell
$r = $store.ByName['srv01']      # synchronized hashtable read
$r.Status = 'Downloading...'      # plain property write
$store.Touch()                    # METHOD on the store object -> resolves in workers
```
`Touch` is a `ScriptMethod` added to the store instance, so it resolves from an isolated
runspace where cmdlets would not. **This is verified by the test, not assumed.**

### D2 — `Color` as a name, not a Brush
`Set-WuuComputerRowColor -Row $r -Color 'Error'` replaces the `Brushes::LightGray`
assignment. Mapping preserved exactly: `Error` → grey row, `Timeout` → yellow row.
The console renderer maps these names to console colours; the store stays WPF-free.

### D3 — Row factory centralises the property contract
Row PSObjects **throw on assigning an undefined property**. The GUI edition added
properties at 3 separate creation sites (`AddEntry` direct/dispatched + config load).
`New-WuuComputerRow` now defines all 20 properties in one place, including the two new
ones (`Color`, `Revision`). Every creation site must go through it.

### D4 — `Revision` counter replaces `Refresh()`
Renderers poll `$store.Revision` (a single int, cheap and atomic-ish under a synchronized
hashtable) and redraw only when it changes. This is the console equivalent of
`Items.CommitEdit()/Refresh()` and avoids redrawing on every tick.

### D5 — `New-WuuOperatorContext` is groundwork for Phase 4
Captures user/machine/elevation/runId once per run so every audit record can be stamped
without re-resolving. Placed here because it is identity state, not audit I/O.

---

## Test evidence (14/14 PASS)

`tests/Test-StateStore.ps1` — run: `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-StateStore.ps1`

```
PASS: Wuu.State imports with no WPF assembly loaded
PASS: store created (empty, Rows/ByName present)
PASS: row created with full property contract
PASS: row has all 20 contract properties
PASS: row added
PASS: case-insensitive lookup works
PASS: duplicate add replaces existing row
PASS: colour set by name (no WPF Brush)
PASS: ISOLATED worker runspace mutated the row (module functions NOT needed)
PASS: worker property writes landed on the live row
PASS: Touch() bumped Revision (3 -> 4) - renderer redraw signal works
PASS: remove works
PASS: remove of missing row returns false
PASS: operator context: <user>@<machine> elevated=<bool>
```

The decisive assertions are #1 (no WPF assembly loaded after import) and #9/#10 (a real
isolated runspace — same topology as `New-ComputerRunspace` — mutated the live row without
module-function access). The keystone risk of Phase 1 is therefore retired.

### Test gotchas recorded
- An **empty `ArrayList`/`hashtable` is falsy** in PowerShell — assert on `$null` or
  `.Count`, never truthiness. (Cost one false FAIL.)

---

## Next actions (in order)

1. **Rewire `Wuu.Core.psm1` payloads** (89 `Dispatcher` refs, mechanical). Each
   `EditItem(x); ...; CommitEdit(); Refresh()` block becomes direct property writes on the
   already-in-scope `$Computer` row plus one `$stateStore.Touch()`. Each
   `ContainerFromItem(...).Background = Brushes::X` becomes `$row.Color = 'Error'|'Timeout'`.
   Each `$uiHash.Auto*CheckBox.IsChecked` read becomes `$stateStore.Settings.Auto*`.
   Each `$uiHash.StatusTextBox.Text = $x` becomes `$stateStore.SetStatus($x)`.
   Delete GUI-only chrome (`$eventWindowInit`, `$eventKeyDown`, column resize, all the
   `$uiHash.*Menu.Add_Click` wiring) when `ui/` goes.
2. **Headless harness test**: import the modules and run a payload against the store with
   **no WPF assembly loadable** — proves payloads are truly decoupled.
3. **Delete `ui/`** and the `XamlReader` load path once nothing references it.

## Constraints to carry forward (do not lose these)

- Worker runspaces: **no module functions, no pipeline cmdlets on callback paths** — language
  constructs only. (`Where-Object`/`Select-Object` in a dispatcher-bound action caused a
  permanent two-thread deadlock in the GUI edition. The dispatcher is gone, but the rule is
  kept because the same paths can still be reached while another thread waits on us.)
- Row objects: **all properties must exist at creation** (`New-WuuComputerRow`).
- `Touch()` / `SetStatus()` are store *methods* (resolve in workers); `Wuu.State` *functions*
  are console-shell-only.
- An **empty ArrayList/hashtable is falsy** in PowerShell — assert on `$null`/`.Count`.
