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
| `Wuu.Core.psm1` payloads → store | **DONE - no payload path touches WPF** |
| Headless payload harness (`Test-HeadlessEngine.ps1`) | **DONE, 11/11 PASS** |
| Delete `ui/` + XAML load path | NOT STARTED (removes the remaining GUI-chrome refs) |

## Increment 4 - the decisive gate: the engine runs with NO WPF

`tests/Test-HeadlessEngine.ps1` - **11/11 PASS**. This is the Phase 1 acceptance test, and it
tests the *shipping code* rather than a copy: it extracts the real injected helper
scriptblocks out of `New-ComputerRunspace`'s source, parse-checks them, and executes them in a
real isolated runspace while asserting a WPF assembly is never loaded.

```
PASS: baseline: no WPF assembly loaded in a fresh -NoProfile process
PASS: Import-WuuModules loads the engine with NO WPF assembly
PASS: Wuu.State exports the store factory
PASS: extracted real injected helpers from source via tokenizer (9 total)
PASS: no injected helper references Dispatcher/Brushes/ListView (comments excluded)
PASS: all 3 real injected helpers executed in an isolated runspace
PASS: SetComputerTimeoutScript set Color='Timeout' (was [Brushes]::LightYellow)
PASS: timeout state applied to the live row
PASS: timeout status text correct
PASS: helpers bumped Revision to 4 (redraw signal works)
PASS: NO WPF assembly loaded after running the full helper set
```

**Scope note:** this covers the *engine and payload layer* - what worker runspaces execute.
The GUI *shell* (`Start-WuuApplication`) still loads XAML; that goes when `ui/` is deleted.

Also in this increment: the encrypted-config-load path (the **third** row-creation site from
SUGGESTIONS S2) now uses `New-WuuComputerRow`; the `clientObservable` clear/`ItemsSource`
setup is gone; `Show-PasswordPrompt` -> `_WuuReadPassword` (`Read-Host -AsSecureString`);
`MessageBox` error dialogs -> console output.

### Four test-authoring bugs - all produced FALSE failures that looked like product bugs

Worth recording because each sent me chasing a non-existent defect in the module:

1. **Extracting a scriptblock by counting braces with a hand-rolled quote tracker breaks on an
   apostrophe inside a COMMENT** ("the store's own table") - it opens a phantom string and then
   swallows the real closing brace, yielding a 19 KB "scriptblock" that does not parse.
   **Use `[PSParser]::Tokenize`** - it already understands comments and strings.
2. **Hashtable literals tokenise as `GroupStart '@{'`, not `'{'`.** Counting only `'{'` makes
   `@{...}` look unbalanced and ends the block early. Count both forms.
3. **`ScriptBlock.ToString()` returns the BODY WITHOUT the outer braces.** Production calls
   `[scriptblock]::Create({...}.ToString())`; feeding the braces into `Create` produces a
   scriptblock whose body is a *nested* scriptblock literal, so `& $helper` merely **prints the
   helper's source** instead of running it - a silent no-op indistinguishable from a broken
   helper. Extract the inner text.
4. **Asserting "no WPF references" against raw scriptblock text flags explanatory comments**
   (`# Was: ... [Brushes]::LightYellow`). Strip comments before matching.

**Remaining `Dispatcher` refs: 12**, all GUI-only chrome in `Wuu.Core.psm1` that is deleted
with `ui/`: the `JobTimer` (`DispatcherTimer`), `$eventWindowInit` column-resize /
visual-tree grip wiring (3 `BeginInvoke`), the pre-`ShowDialog` dispatcher diagnostics, and
`$eventActionMenu` menu enable/disable. **No payload path references WPF any more.**

---

## Increment 3 - the payload pass (the bulk of Phase 1)

- **`$AddEntry`**: the ~120-line dual-branch (pre-dispatch diagnostics + direct vs dispatched
  `clientObservable`/ListView path) collapsed to ~15 lines via `New-WuuComputerRow` +
  `Add-WuuComputerRow`. Duplicate detection now `$stateStore.ByName.ContainsKey(...)`.
- **`$removeEntry`** / **`$clearComputerList`**: `Remove-WuuComputerRow` / `Get-WuuComputerRow`.
- **`$DownloadUpdates` / `$GetUpdates` / `$InstallUpdates` / `$RestartComputer` /
  `$RemoveOfflineComputer` / `$WUServiceAction`** and the event handlers: 32 blocks
  transformed mechanically, 7 handled by hand (single-line invokes, multiline status blocks,
  and blocks the shape-matcher refused).
- **`SafeUpdateListViewItem`, `Set-ComputerState`, `Set-ComputerTimeout`, `Update-Status`,
  `Update-StatusBackground`**: rewritten to store writes (increment 3a).
- Copy-cell status colours (`Foreground = 'Green'|'Orange'|'Red'`) dropped - the store
  carries status *text*; colour is a renderer concern.

### The mechanical transformer - and the bugs it taught us

`Scripts\_transform-dispatchers.ps1` (excluded from release zips) rewrites only blocks whose
opening line closes its own argument list, whose closing line is exactly `})`, and whose body
contains an `EditItem` call. 32 matched; everything else is **reported, not guessed**.

A first, greedy version corrupted the file two ways - **both reverted, fixed, and documented
in the script header:**

1. The appended redraw line was built with a **double-quoted** format string, so `$stateStore`
   interpolated to empty *inside the transformer's own scope* and emitted
   `if ( ) { $stateStore.Touch() }` into the module (20 parse errors).
   **Lesson: any generator that emits PowerShell must build emitted code from SINGLE-quoted
   strings, or the generator's own variables get substituted into the output.**
2. Single-line `[action]{...})` blocks matched the open-regex and **swallowed the following
   statement** (a `return` disappeared).
   **Lesson: match on an opening line that ENDS with `{`, never a whole block on one line.**

Both were caught by a PS 5.1 parse check plus reading `git diff` - which is why the
transformation was reverted twice rather than committed blind. Integrity greps on the final
pass: `0` empty-`if` matches, `0` `Brushes]::` left, `36` `Touch()` calls.

---


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
