# Suggestions for the GUI edition (WUU2)

**From:** WUU2-CLI Phase 1 refactor (2026-09-27)
**For:** `dazzo31/WUU2` (the WPF edition)

Structural improvements noticed while building the console edition. Each one is
something the CLI refactor proved out, so the GUI version can adopt it with known-good
evidence rather than guesswork. Ordered by value-to-risk. **None of these are required**
for WUU2 to keep working — they are maintainability/robustness wins.

---

## S1 — Extract the state store; stop writing UI state through the ListView ⭐ highest value

**Problem.** Payloads currently report progress by reaching into WPF:
`$uiHash.Listview.Items.EditItem($row)` … `CommitEdit()` … `Refresh()`, wrapped in
`$uiHash.ListView.Dispatcher.Invoke('Background',[action]{...})`, with colour applied via
`$uiHash.Listview.ItemContainerGenerator.ContainerFromItem($row).Background = [Brushes]::X`.

**Why it's a problem, not just ugly:**
- It forces every payload to carry WPF knowledge, so payloads cannot be tested or run
  headlessly.
- The `Dispatcher.Invoke` pattern is the documented cause of the two historical deadlocks
  (dispatcher actions bound to a busy worker's session state; `Where-Object` inside such an
  action). The mitigation today is a comment saying "language constructs only" — a rule that
  a future edit can silently break.
- `ContainerFromItem` is a **visual-tree lookup**: it returns `$null` for rows that are
  virtualized/scrolled out of view, so the colour silently doesn't apply. (In practice only
  two colours are ever used — `LightGray` for error, `LightYellow` for timeout — so this
  lookup buys almost nothing.)

**Suggestion.** Introduce a `Wuu.State.psm1` store (exactly as the CLI edition now has —
`src/Wuu.State.psm1`, 19/19 tests green) and have payloads write to it; keep the ListView as
a *renderer* that polls `$store.Revision` on the existing 1s `JobTimer` and redraws only when
it changed. Colour becomes a name on the row (`Error`/`Timeout`), which the GUI maps to
`LightGray`/`LightYellow` at render time — no visual-tree walk, so virtualized rows colour
correctly.

**Evidence it works.** `tests/Test-StateStore.ps1` proves a real isolated runspace (same
topology as `New-ComputerRunspace`) can mutate a row and signal a redraw **without module
function access**. The contract is: workers read `$stateStore.ByName[name]`, set properties,
call `$stateStore.Touch()` — `Touch` is a `ScriptMethod` on the store object, so it resolves
where cmdlets would not.

**Risk if adopted:** medium (touches ~200 call sites) but mechanical and testable, and it
removes a whole class of latent hangs. Could be done incrementally, module by module.

---

## S2 — Centralise row creation (`New-WuuComputerRow`)

**Problem.** Row PSObjects are created in **three** places (`AddEntry` direct branch,
`AddEntry` dispatched branch, and encrypted-config load), each with its own
`New-Object PSObject -Property @{...}` literal. Row objects **throw on assigning an undefined
property**, so every new field must be added to all three or you get a runtime failure only on
the path that lacks it. This has already bitten: the timeout work had to add
`TimeoutExpiresAt`/`TimeoutSource`/`RetryCount`/`RetryAt` at all three sites, and
`PendingOp` had to be treated defensively with `PSObject.Properties[...]` checks.

**Suggestion.** One `New-WuuComputerRow -Computer <name>` factory that defines every field
(incl. `Color`/`Revision` if S1 is adopted). All three sites call it. Adding a field then
happens once.

**Risk if adopted:** very low. Pure refactor; no behaviour change.

---

## S3 — Replace the `PSObject.Properties[...]` defensive checks with guaranteed fields

**Problem.** Because fields can be missing (see S2), the codebase has scattered guards like
`if ($item.PSObject.Properties['PendingOp'] -and $item.PendingOp)`. These hide bugs (a field
that should always exist silently reads as absent) and add noise.

**Suggestion.** After S2, every field is guaranteed — drop the guards. Where a value is
genuinely optional, use `$null` as its default rather than an absent property.

**Risk if adopted:** low, but only safe *after* S2. Doing it before would turn latent
missing-field bugs into hard failures — which is arguably better, but should be deliberate.

---

## S4 — One choke point for "mark this computer as errored/timeout"

**Problem.** The error path is duplicated ~8 times, each copy repeating the same six steps:
set `Status`, set `UpdatesStatus = 'Error'`, set `State = 'Error'`, look up the ListView item,
set `Background = LightGray`, `CommitEdit`, `Refresh`. The timeout path is duplicated too.
Divergence is inevitable (already: some copies set `InstallErrors`, some don't).

**Suggestion.** `Set-ComputerError -Row $row -Message $msg` and
`Set-ComputerTimeout -Row $row -Phase $p -TimeoutSec $n -Detail $d` as the single helpers,
with colour handled by the store (S1). Note `Set-ComputerTimeout` already exists in
`Wuu.Core.psm1` **and** as an injected worker copy — the CLI edition keeps that split (workers
can't see module functions) but both bodies are now 5 lines instead of 20.

**Risk if adopted:** low. Behaviour-preserving if the helpers match the current majority
behaviour.

---

## S5 — Make the auto-download/install tail log its decision

**Problem.** The auto tails in `$GetUpdates`/`$DownloadUpdates` are silent when they *don't*
fire. If the ticked checkboxes don't produce action, there is no log line saying whether the
gate was false, the counts were wrong, or the dispatch was skipped. Diagnosing this on a
remote domain host required reasoning about the code rather than reading the log.

**Suggestion.** One `Write-DebugLog` line inside the gate recording the decision inputs:
checkbox states, `Available`, `Downloaded`, and the chosen `PendingOp`. Cheap, and makes the
next report self-diagnosing.

**Risk if adopted:** none.

---

## S6 — `PendingOp` as an explicit enum rather than a magic string

**Problem.** `PendingOp` carries `'Download'`/`'AutoFlow'`/`'InstallAndRecheck'` as raw
strings, matched in `Start-PendingUpdateCheck` and used to suppress a duplicate auto-install in
`$DownloadUpdates`. A typo produces a silent fallback to the default (plain check) — no error.

**Suggestion.** `[ValidateSet(...)]` on the setter, or named constants. The CLI edition
already validates the *consuming* parameter (`Start-UpdateCheckJob -Op` has a `ValidateSet`);
the *producing* side (assignment in the tails) is still a bare string.

**Risk if adopted:** very low.

---

## S7 — `ui/` and credential dialogs: consider `Get-Credential`

**Problem.** `Wuu.Credentials.psm1` (689 lines) is largely bespoke XAML dialog plumbing
(`XamlReader.Load`, `Add_Click` wiring, `ShowDialog`). It also duplicates validation that the
CLI edition expresses in a few lines.

**Suggestion.** Not a refactor to rush — the custom dialog is genuine UX (domain/user fields,
test button, "remember" behaviour). But the **validation** rules and the "test credentials"
probe are duplicated between the dialog and the config path; extracting those into plain
functions would shrink the module and make them unit-testable without WPF.

**Risk if adopted:** low if only validation/probe logic is extracted; leave the XAML alone.

---

## S8 — Replace row-existence lookups on `ListView.Items` with a keyed lookup

**Problem.** Duplicate detection in `AddEntry` is
`($uiHash.Listview.Items | Select-Object -Expand Computer) -contains $computer` — an O(n)
pipeline enumeration of the **UI collection**, executed on whatever thread calls AddEntry.
Several other places search `ListView.Items` with a `foreach` for the same reason (the
`SafeUpdateListViewItem` helper, the timeout handler, `$removeEntry`). Every one of these is
a UI-thread-affinity and cost issue that only exists because the ListView is doubling as the
data model.

**Suggestion.** Keep a `Computer -> row` hashtable alongside the collection (the CLI edition's
`$store.ByName` — case-insensitive) and use `ContainsKey` for existence and direct indexing
for lookup. Duplicate detection becomes O(1) with no UI enumeration and no thread affinity.
This is a small, self-contained change that can be made *without* adopting S1 wholesale:
add the hashtable next to `clientObservable`, populate it in `AddEntry`, remove in
`$removeEntry`.

**Risk if adopted:** low. Behaviour must match the existing case handling (the CLI store is
case-insensitive via `ToLowerInvariant()`; the GUI's `-contains` is case-insensitive by
default for strings, so they agree).

---

## S9 — Status-bar colour is mixed into the status write

**Problem.** Copy-cell handlers set both the text **and** the colour in the same dispatcher
action (`$uiHash.StatusTextBox.Foreground = 'Green'|'Orange'|'Red'`), and the two
`Update-Status` / `Update-StatusBackground` helpers differ *only* by DispatcherPriority.
Status is therefore modelled as a UI mutation rather than a value.

**Suggestion.** Treat status as `{ Text; Level }` where Level is
`Info`/`Success`/`Warning`/`Error`, set once, and let the renderer map Level to a brush/colour.
That removes the Foreground writes, makes the two helpers one, and means a status can be
logged, asserted on in tests, or rendered in a non-GUI surface without change.

**Risk if adopted:** very low; mechanical.

---

## S10 — The config-load path is a third copy of the row contract (highest-value S2 instance)

**Problem.** `$eventLoadConfig` does not just create a row — it also clears
`clientObservable` and re-creates it (`ItemsSource` re-assignment) inside a dispatcher invoke,
then creates each row with its **own** `New-Object PSObject -Property @{...}` literal carrying
a *different* default set from `AddEntry` (`Status = 'Loaded from config...'`,
`UpdatesStatus = 'Unknown'`, `Pending = $false`). So the three row-creation sites (S2) differ
not only in mechanism but in **initial values**, and the load path additionally depends on
`clientObservable` existing *and* being re-bindable.

**Suggestion.** `New-WuuComputerRow -Computer X -StateSource BulkAdd` then set the two or
three differing fields explicitly. The "loaded from config" differences are *policy*, not
schema, so they belong as visible overrides rather than buried in a duplicate literal.
Dropping the `clientObservable` re-creation also removes a real hazard: an
`ObservableCollection` swap while the ListView is bound can lose selection/scroll state.

**Value note.** This is the concrete site where S2 pays off most, because it is the one that
has drifted furthest from the others. Adopting S2 with just `AddEntry` + this path would
already eliminate the divergence.

---

## S11 — Status messages are set as `TextBox.Text`, so they cannot be logged or asserted on

**Problem.** `Update-Status`/`Update-StatusBackground` write directly to
`$uiHash.StatusTextBox.Text` inside a dispatcher invoke. Status is therefore only observable
in the GUI: it cannot be logged with the message, asserted in a test, or surfaced in any
non-GUI host. Several error paths also set the status *instead of* logging.

**Suggestion.** Make the status a value in a small state object (`{ Text; Level; Timestamp }`)
and have the renderer display it. Then every status change can also be written to the debug
log (one line), which is exactly what made the CLI edition's auto-download investigation
possible to diagnose from a log file rather than from the code.

**Risk if adopted:** low, but touches many call sites. Pairs naturally with S1.

---

## S12 — Password prompting is a GUI-only function on the load path

**Problem.** `$eventLoadConfig` calls `Show-PasswordPrompt`, a bespoke XAML dialog. Because the
whole path is written around it, the load operation cannot run in a console, a scheduled task,
or a test without that dialog. (The CLI edition replaced it with a five-line
`Read-Host -AsSecureString` wrapper.)

**Suggestion.** Split "obtain a password" from "do the load": the load path should accept a
`SecureString` parameter, with the dialog as one *caller* rather than a dependency. That also
makes the decrypt path unit-testable with a synthetic password (and is the only way to test
the wrong-password branch, which today can only be exercised by a human typing).

**Risk if adopted:** low-medium: mostly a signature change plus moving the prompt to the caller.

---

## Not suggested

- **Don't** try to unify the GUI and CLI shells behind one abstraction. The two editions share
  the *engine* (Remote/Workers/Network/Models/Logging/Scripts — all already presentation-free);
  the shells are legitimately different and a shared shell layer would cost more than it saves.
- **Don't** remove the `Language constructs only` comments even after S1 — they encode a real
  past deadlock, and the rule still applies to any callback reached while another thread waits.

---

## Suggested adoption order

1. **S2 + S10 + S5** — row factory applied to all three creation sites (S10 is the one that
   has drifted furthest), plus the auto-tail decision log. Small, zero-risk.
2. **S8 + S9 + S11** — small, self-contained: keyed lookups, status colour as a level, status
   as a loggable value.
3. **S4 + S6** — small, consolidates duplicated error/timeout handling.
4. **S12** — split password acquisition from the load path; unlocks testing the wrong-password
   branch.
5. **S1** — the big one; do it module-by-module with `Test-StateStore.ps1`-style proof at each
   step. Highest value (removes the deadlock class and the virtualized-row colour bug).
6. **S3** — cleanup pass after S2 lands.
7. **S7** — opportunistic.

## Verification recipe for a mechanical pass (proven on the CLI edition)

The CLI edition's ~200-site payload pass used generated edits, not hand-editing. What actually
caught the mistakes was this combination — each step found a different bug class:

1. **PS 5.1 parser pass** on every touched file (`[Language.Parser]::ParseFile`) — catches
   structural damage. Found 20 errors from a bad generator.
2. **Targeted corruption greps**, not just "does it parse": `if (\s*\)` (empty conditions),
   orphaned braces, and a **count of expected new calls** (e.g. `$stateStore.Touch()` should
   equal the number of transformed blocks). Parsing can succeed while semantics are wrong.
3. **Read the `git diff`** — this is what caught a *deleted `return`* that parsed fine.
4. **Diff size sanity** — a pass that should be roughly line-neutral showing −600 lines means
   something was swallowed.

Corollary: **commit before a mechanical pass** so a revert is one command. The CLI pass was
reverted twice before it was safe; that is the expected cost, not a sign of failure.


## Process note (from actually doing this refactor)

The CLI edition's payload pass was done with a **conservative, report-the-rest** generator
rather than hand-editing ~200 sites or a greedy regex. Two bugs still slipped through and
both are worth avoiding if the GUI edition does a similar mechanical pass:

1. **Never build emitted PowerShell from a double-quoted string in a generator.** `"if ($store.Touch())"`
   in generator source substitutes the *generator's* `$store` (empty) into the output. Use
   single quotes / `-f` with single-quoted templates.
2. **Never match a whole statement block on one line.** A regex that accepts
   `... Invoke(...){ ... }` on a single line will match and then consume the *next* statement
   (in our case a `return`) as part of the block.

Verify mechanically after any such pass: a PS 5.1 parse check **plus** greps for the specific
corruption shapes (empty `if (`, orphaned braces) **plus** reading the diff. The CLI pass was
reverted twice before it was safe to commit — that is the expected cost, not a failure.

