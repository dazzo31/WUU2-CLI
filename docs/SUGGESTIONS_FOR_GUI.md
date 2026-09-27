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

## Not suggested

- **Don't** try to unify the GUI and CLI shells behind one abstraction. The two editions share
  the *engine* (Remote/Workers/Network/Models/Logging/Scripts — all already presentation-free);
  the shells are legitimately different and a shared shell layer would cost more than it saves.
- **Don't** remove the `Language constructs only` comments even after S1 — they encode a real
  past deadlock, and the rule still applies to any callback reached while another thread waits.

---

## Suggested adoption order

1. **S2 + S5** — small, zero-risk, immediately reduce future breakage and improve diagnosability.
2. **S4 + S6** — small, consolidates duplicated error/timeout handling.
3. **S1** — the big one; do it module-by-module with `Test-StateStore.ps1`-style proof at each
   step. Highest value (removes the deadlock class and the virtualized-row colour bug).
4. **S3** — cleanup pass after S2 lands.
5. **S7** — opportunistic.
