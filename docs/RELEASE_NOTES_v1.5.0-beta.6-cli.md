# WUU2-CLI v1.5.0-beta.6-cli

**A structure-and-safety release: two live defects fixed, and the internals decomposed.**

Same commands, same options, same engine behaviour as beta.5 for every documented workflow. This release
is mostly *structural* — Core and the release validator were broken up — but it also fixes two defects
that only showed themselves when the code was moved and read closely.

> **This is a PRERELEASE.** The version is stamped on every audit record, so a trail is self-identifying:
> `wuuVersion: v1.5.0-beta.6-cli` tells an auditor the evidence came from pre-release software.

---

## Read this first — two defects that shipped in earlier betas

Both were reachable and neither was caught by a test, because no test exercised the action.

### 1. `wuu config save` could hang in an unattended run

`Show-PasswordPrompt` (Wuu.Credentials) called `Read-Host` **directly** instead of going through the input
choke point. In command mode — `wuu config save`, or any scripted/scheduled run — nobody can answer a
bare `Read-Host`, so the run **waited at the prompt instead of failing**.

The release gate has asserted this exact contract for a while, but it only checked `Wuu.Core`, and the
bypass was in another module. It surfaced when the choke-point-routed prompt was extracted and the check
was re-pointed at its new home.

**Fixed:** `Show-PasswordPrompt` now routes through `_WuuReadPassword`. The gate check also gained a
negative assertion, so it fails loudly if the prompt ever leaves the file it is expected in, rather than
passing on absent text.

### 2. "Export list to file" threw every time it was used

`$eventSaveComputerList` — menu key `x`, the guided UI, and the `EventSaveComputerList` action behind
`wuu export` — built a `Microsoft.Win32.SaveFileDialog`. That type lives in **PresentationFramework**,
which this edition deliberately does not load, so the call threw *"Cannot find type"* on use.

The action was registered and reachable, which is what made it a live defect rather than dead GUI debris.
The gate missed it because its GUI-only pattern named `Microsoft.Win32.OpenFileDialog` but **not
`SaveFileDialog`** — the same family, in the same assembly.

**Fixed:** the action takes its destination from the input choke point (`Read-WuuAnswer`), and the `export`
verb supplies the path (its answer builder previously supplied nothing, because the *dialog* produced the
path rather than a prompt). The gate pattern now covers the family, and a new contract assertion drives
both halves.

---

## Also closed

### A queued follow-up could sit on a settled row

`Set-WuuPendingOperation` had no settled-row check, and `Set-ComputerState -ClearOperation` skips the
transition guard, so a row could be settled **and** advertise queued work — the row counted as finished
while its next operation was still in the queue.

The setter now refuses a settled row **with a reason**, and the funnel resolves a row that still holds a
queued follow-up back to `Queued`. The follow-up is not lost: it survives and the scheduler still drains
it. Verified by driving the real functions.

### The release gate is now reproducible

The remaining-budget verdict varied between runs — *"caps the 30s probe to 19s"* or *"to 20s"* — because
the check set a deadline and the driven function then sampled the clock again. No two runs produced the
same report, which made the gate impossible to diff in CI.

The check now pins the clock to the deadline's own base. That makes the remainder exact, so the assertion
could be **tightened** from a range to an exact value — and mutation testing confirms the tightening added
real detection power.

---

## Structural work (no behaviour change)

`Wuu.Core.psm1` was one 4,100-line function. It is now a bootstrap/orchestration layer plus focused
modules. Every extraction was verified against a fixed verdict/behaviour baseline.

| Moved | To |
| --- | --- |
| Application configuration (version, timeouts, credentials, paths) | `Wuu.Configuration.psm1` |
| Status text, dialogs, password prompt, background-pause | `Wuu.Presentation.psm1` |
| Console display actions (show updates / history / log) | `Wuu.Actions.Display.psm1` |
| The background job-cleanup payload | `Wuu.Workers.psm1` |

The job-cleanup payload is worth a note: it runs in an isolated runspace where no module function is
callable. It could move only because it reads **nothing** except injected variables and calls only built-in
cmdlets — measured by AST analysis rather than assumed, and the verification is that the moved 317 lines
are byte-identical to the originals.

`Scripts\Validate-Release.ps1` went from 3,312 to 1,774 lines, split into focused `Test-*.ps1` files
(`Test-SourceStructure`, `Test-AuditContract`, `Test-Contracts`, `Test-Architecture`,
`Test-MutationContract`, `Test-ReleaseMetadata`, `Test-Encoding`, `Test-BudgetAndAnchoring`). The
top-level validator still runs every check and still emits the same verdict list, in the same order.

---

## Verification

| Check | Result |
| --- | --- |
| Release gate | pass — 170 verdicts, 0 FAIL, **identical across runs**; the version guard resolves against this tag |
| Test suites | 43 run, 42 pass, 1 skip, 0 fail — **1,192 assertions** |
| Mutation proofs | P3 close-out 5/5 caught; pool-cap 4/4 caught; sources restored byte-identically |

**Both totals above are from the TAGGED tree, not from a pre-tag run.** That distinction matters here: the
SS18 version guard only evaluates once a tag exists, so an off-tag run reports a SKIP where the released
tree reports a PASS. (This release also fixed a test that asserted that SKIP — see the note under
"Known limitations".)

---

## Known limitations (unchanged from beta.5)

- **41 direct operation-state writes** remain outside `Wuu.State`. Many are inside payload runspaces where
  the funnel is not callable. The gate now *ratchets* this: it fails if the count rises, and warns when it
  falls, so the ceiling can be lowered.
- **§33 command result model** and **§34 versioned JSON** are not implemented.
- **The scheduler-serialization test** flakes roughly 1 in 16 (a fleet job that produces no payload output).
  It is instrumented to report runspace state and `HadErrors` when it next fires; it is **not** fixed,
  because guessing at a race that cannot yet be observed is worse than gathering evidence.
- **The audit anchor is local.** A privileged administrator can still delete an entire audit-day file. An
  external anchor is the proper fix and is not in this release.

### One more test fix, found by releasing

`Test-PoolDiagnostics` asserted that the gate report contains at least one `SKIP`. The gate's only skip is
the version guard, which fires **only when HEAD is not on a tag** — so the suite passed on every
development run and failed the moment the release was tagged. It asserted the opposite of what it meant.

It now checks the property that actually holds in both states: every verdict carries one of the five
kinds, so "not evaluated" is never read as "evaluated clean", and the SKIP kind is reachable either as a
count or — on a tag — because the version guard legitimately passes instead.

