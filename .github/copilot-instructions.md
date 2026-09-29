# WUU2-CLI — Copilot Instructions

## 1. Project identity

WUU2-CLI is the console edition of WUU2 (Windows Update Utility).

It is a **Windows PowerShell 5.1** application used to inspect, download, install, and reboot Windows Update targets across a fleet of remote Windows computers.

The CLI maintains an audit trail with hash chaining for ISO 27001 A.8.15-style auditability.

This repository is separate from the WUU2 GUI repository.

The primary architectural goal is **predictable, testable, safe remote execution**. Do not optimize for cleverness or minimal code at the expense of correctness.

Read these documents when the task touches the relevant area:

* `docs/ARCHITECTURE.md`
* `docs/STATE-MACHINE.md`
* `docs/DEVELOPMENT.md`
* `docs/TESTING.md`

### How to read those documents, and this one

They describe **both** what exists and what is intended, and the difference matters more than
anything else in this file.

| Term | Meaning |
| --- | --- |
| **CURRENT** | Implemented and observable in `src\`. The source is authoritative. |
| **TARGET** | Specified but **not implemented**. Do not assume it exists. |
| **ENFORCED** | CURRENT **and** a `Scripts\Validate-Release.ps1` gate fails if it regresses. |

Rules for reading and writing them:

1. **The source code is authoritative.** Where a document and the code disagree, the code is
   current behaviour and the document is wrong or aspirational.
2. **A passing test is evidence, not proof.** A test proves only what it actually exercises. A test
   whose name mentions an invariant it does not drive asserts nothing — check what it runs, not what
   it is called.
3. **Do not describe a TARGET invariant as current behaviour** — not in a commit message, not in a
   doc, not in a summary to the user. If you implement one, say so and cite the test.
4. If a document contradicts the code and you cannot tell which is intended, **stop and report the
   conflict rather than guessing**.

The authoritative status of each core invariant is the table in §8.

---

## 2. Repository boundaries

This repository is the CLI application.

Do not mix it with the GUI repository.

The GUI repository is separate and must not be treated as a source of truth for CLI behaviour.

Do not:

* copy XAML/WPF implementation into the CLI
* introduce WPF dependencies
* assume GUI state exists in the CLI
* make CLI behaviour depend on GUI controls
* perform unrelated GUI cleanup while modifying CLI functionality

### `dist/`

`dist/` is packaged/distribution output.

**Never edit files under `dist/`.**

**Never use files under `dist/` as the source of truth for implementation.**

This includes:

* `dist\`
* `dist\staging\`

Make source changes under the normal source/test directories and regenerate packaging output when appropriate.

---

## 3. Entry point and module structure

`WUU.ps1` is the application entry point.

Keep application logic out of `WUU.ps1` unless the task specifically concerns startup/argument handling.

Application logic belongs in `src\*.psm1`.

Modules are loaded through `Import-WuuModules`, using `-Global`.

The important layering is:

```text
Wuu.Navigate
    ↓
Wuu.Session / ComputerSet
    ↓
$consoleActions adapters
    ↓
Wuu.Core
    ↓
Windows Update / remote execution engine
```

`Wuu.Navigate` and `Wuu.Session` sit above the engine.

They must not bypass the normal `$consoleActions` handlers and call the update engine directly.

Remote operations must ultimately pass through the scheduler/operation execution architecture described in `docs/ARCHITECTURE.md`.

---

## 4. Legacy GUI-origin code

`Wuu.Core.psm1` defines **12** closures named `$event*`:

```text
$eventAddAD              $eventRemoveOfflineComputer   $eventShowInstalledUpdates
$eventAuditWSUSUpdates   $eventSaveComputerList        $eventShowUpdateHistory
$eventLoadConfig         $eventSaveConfig              $eventViewUpdateLog
$eventSetDomainCredentials  $eventShowAvailableUpdates  $eventWUServiceAction
```

They originated in the GUI edition, where the interface was a WPF ListView.

**Note:** `$eventInstallUpdates` is *mentioned* in comments but is **not defined** anywhere. Do not
treat it as an existing closure, and do not cite it.

Current reality, which is more nuanced than "legacy code to avoid":

* **They are still live.** The menu dispatches through them, and the `$consoleActions.*` adapters
  frequently delegate to them. They are not dead code.
* **The GUI state they depended on is gone.** The WPF members are referenced **only inside comments**
  — there are **zero code references** to `SelectedItems`, `IsChecked`, `CheckBox`, `Dispatcher` or
  `System.Windows.*` anywhere in `src\`. Verified by tokenizing every module and blanking comment
  text in place: every hit is a `#` or `<# #>` line explaining what was removed.
* Those members would be `$null` here, and `Wuu.Core.psm1` has no `Set-StrictMode`, so a read would
  fail **silently** rather than throwing. That is why the comments exist — they are the record of a
  class of silent failure, not decoration.
* **`uiHash` still exists and is passed to runspaces**, but it is created as an empty synchronized
  hashtable and **no member holding a control is ever assigned**. Do not repopulate it.
* The name `SafeUpdateListViewItem` survives as a **naming leftover** — it is defined twice
  (`Wuu.Core.psm1` L835 and L1200) and invoked once, via a runspace-injected scriptblock. It is a
  Phase 11 rename candidate, not a GUI dependency.

Therefore:

> **Do not copy an existing `$event*` closure's structure into new work, and do not "repair" one by
> restoring GUI-era behaviour.** Route new console behaviour through the `$consoleActions.*`
> adapters — see `docs/ARCHITECTURE.md` for the intended layering.

Do not introduce new:

```text
System.Windows.*
```

or other WPF dependencies.

Do not rename or delete an existing `$event*` closure as part of unrelated work — that is Phase 11
territory, and it is listed in `docs/DEVELOPMENT.md` as a deliberate follow-on, not a side effect.

Therefore:

> **Do not copy an existing `$event*` closure's structure into new work, and do not "repair" one by
> restoring GUI-era behaviour.** Route new console behaviour through the `$consoleActions.*`
> adapters — see `docs/ARCHITECTURE.md` for the intended layering.

Do not introduce new:

```text
System.Windows.*
```

or other WPF dependencies.

Do not rename or delete an existing `$event*` closure as part of unrelated work — that is Phase 11
territory, and it is listed in `docs/DEVELOPMENT.md` as a deliberate follow-on, not a side effect.

---

## 5. Windows PowerShell 5.1

The application must remain compatible with **Windows PowerShell 5.1**.

Do not use features introduced after PowerShell 5.1.

Examples of prohibited assumptions include:

* `ForEach-Object -Parallel`
* PowerShell 7-only syntax/features
* APIs unavailable on the supported Windows PowerShell runtime
* three-argument `Join-Path`

If uncertain whether a construct works on Windows PowerShell 5.1, verify it before using it.

Do not silently convert the project to PowerShell 7.

---

## 6. File encoding

Some shipped files contain non-ASCII characters.

These files must retain their **UTF-8 BOM**.

The repository intentionally uses:

```text
files.encoding = utf8
```

because Windows PowerShell 5.1 can interpret BOM-less UTF-8 as ANSI.

A BOM-less rewrite can cause multi-byte characters to corrupt parsing, including cases where a character effectively consumes a quote or otherwise changes source interpretation.

Therefore:

* preserve existing encoding
* preserve BOM where present
* avoid unnecessary whole-file rewrites
* do not use tooling that silently changes encoding

After automated edits, inspect the resulting file if encoding may have changed.

---

## 7. Interactive input

Interactive input must go through the project's input abstraction.

Use:

* `Read-WuuAnswer`
* `Read-WuuYesNo`
* `Read-WuuSelection`

Do **not** introduce `Read-Host`.

Direct `Read-Host` calls interfere with automated testing and can cause scripted execution to hang.

If new interactive behaviour is required, extend the existing input abstraction rather than bypassing it.

---

# 8. Core invariants — TARGET, with current status

The following are **target invariants**. The table below identifies which are currently enforced.

**Do not describe an unimplemented invariant as current behaviour.** When implementing a change, work
toward the target invariant **without assuming it already exists** — several are not implemented, and
code that relies on one will be wrong in a way that does not announce itself.

Status is verified by inspection, not aspiration. `ENFORCED` means there is a
`Scripts\Validate-Release.ps1` gate that fails if the invariant regresses.

| # | Invariant | Status | Evidence / gap |
| --- | --- | --- | --- |
| 8.1 | One active operation per computer | **ENFORCED** | `Test-WuuComputerBusy` gate at the submission point; gate (u); `Test-ComputerBusy`, `Test-SchedulerSerialization` |
| 8.2 | Every operation has a unique `OperationId` | **ENFORCED** | `New-WuuOperationId` (GUID-based) in `Wuu.State`; created **before** `BeginInvoke`, carried on the job entry, injected into the worker runspace; gate (ah); `Test-OperationIdentity` (61 assertions) |
| 8.3 | Stale workers cannot modify newer operations | **ENFORCED** | Two rules — `Test-WuuOperationCurrent` (release only proven ownership) and `Test-WuuStaleWrite` (refuse only proven staleness) — mirrored in **6** sites; gate (ah); `Test-OperationIdentity` |
| 8.4 | Terminal operations stay terminal | **TARGET — partial** | No transition guard. `Failed`/`TimedOut`/`Cancelled`/`Refused` are not even `State` values today (see §9) |
| 8.5 | All remote execution goes through the scheduler | **ENFORCED (narrow)** | All per-computer work goes through **one submission point** `Start-UpdateCheckJob`; gate (x). "Scheduler-only" is stricter than this — see 8.6 |
| 8.6 | Concurrency limits are absolute | **TARGET — not implemented** | The cap is checked **only in the scheduler tick** (`Start-PendingUpdateCheck`). The submission point has **no** `jobs.Count` check, and its `MaxConcurrentJobs` mention is a **comment**. Direct handlers can therefore exceed the cap. **No validator gate exists** (the only validator mention is a comment) |
| 8.7 | Pending work is not silently discarded | **TARGET — not implemented** | `PendingOp` is overwritten in place; a second request replaces the first with nothing reported |
| 8.8 | Credential identity is deterministic | **ENFORCED** | `Resolve-WuuOperationCredential`; no fallback on either resolver; gate (ad); `Test-CredentialDeterminism`, `Test-CredentialPropagation` |
| 8.9 | `WhatIf` causes no remote mutation | **ENFORCED** | Returns before any handler and writes no audit record; gates (ae); `Test-WhatIfPlan`, `Test-AuditTrail` |
| 8.10 | Connectivity failure does not delete inventory | **ENFORCED** | Consecutive-failure threshold + reset on success in `Update-WuuConnectivityState`; gate (z); `Test-ConnectivityClassification` |

Also ENFORCED but not numbered above: per-operation timeouts with a recorded deadline and heartbeat
(8.5-adjacent, gate (ab)); exit-code semantics (gate (aa)); workflow state rather than display state
(gate (ac)); reboot/cancellation surfaces (gate (ag)); source encoding (gate (af)).

**Read the gap column before relying on an invariant.** **8.6** (absolute cap) and **8.7** (pending
work) are the two that matter most now: in each case the mechanism the architecture depends on does
not exist yet, so code that relies on either is wrong in a way that does not announce itself.

> **8.2/8.3 note (Phase 2):** these were TARGET. They are ENFORCED as of this revision. The distinction
> matters when reading older material, and it is why 8.3 was *unreachable* rather than *safe* —
> invariant 8.1 prevented the scenario from arising, but nothing rejected a stale result. Three paths
> could emit one: the cleanup loop settling a force-stopped job after the computer was resubmitted, a
> payload parked mid-write while the timeout path detached the runspace, and the out-of-band job
> removal in `Remove-WuuComputers`.

---

### 8.1 One active operation per computer

A computer must not have two independently executing operations at the same time.

This is enforced today at the single submission point. Do not create a second execution path that can
bypass it.

---

### 8.2 Every operation has an identity  *(ENFORCED — Phase 2)*

Every remote operation has a unique `OperationId`, retained across the request, queued state, running
state, worker execution, completion/failure, timeout/cancellation and audit record.

**Implemented.** `New-WuuOperationId` (computer prefix + process id + a monotonic counter + a 12-char
GUID fragment) is created **before** `BeginInvoke`, because the payload can start on its own thread
immediately — an identity stamped afterwards would leave a window in which a legitimate writer is
judged stale against the previous id. It is set on the row, on the **job entry** (the cleanup loop
holds the job, not the row), and injected into the worker runspace as `$WuuOperationId`.

Do not use the computer name or a timestamp as operation identity. The name is the row's *key*, so a
writer belonging to a finished operation still resolves a valid row; a timestamp is not unique.

### 8.3 Stale workers cannot modify newer operations  *(ENFORCED — Phase 2)*

A worker belonging to an old operation must never overwrite state belonging to a newer operation.

**Implemented as TWO rules, deliberately not one.** Do not collapse them:

| Rule | Question | Used by |
| --- | --- | --- |
| `Test-WuuOperationCurrent` | is this writer the **proven owner**? | the three cleanup-loop **release** paths |
| `Test-WuuStaleWrite` | is this write **proven stale**? | the two **row-writer** choke points |

They differ in one direction on purpose: against a row that names no operation, the release rule says
"not current" (an unattributed job must not unlock a row it cannot name) while the write rule says
"permit" (list loading writes rows that have no operation). Making either into the other breaks one
side — a strict write rule discards startup writes; a lenient release rule unlocks a busy computer.

The rule is written in **six** places because the cleanup loop and the injected worker writer run in
isolated runspaces where no module function resolves. Gate (ah) asserts every copy exists;
`Test-OperationIdentity` extracts each shipped condition and drives it on a truth table so a drifted
copy fails.

Also part of 8.3: the timeout path **detaches the row's runspace** before releasing the lock. The
guards stop a stale *writer*; detaching stops a resubmission from inheriting a runspace that is still
draining after the asynchronous `$PowerShell.Stop()`, while the old payload keeps writing through its
own module-scope store reference.

---

### 8.4 Terminal operations stay terminal  *(TARGET — partial)*

**Target:** `Complete`, `Failed`, `TimedOut`, `Cancelled` and `Refused` are terminal. A retry creates a
**new** operation; it never reactivates the old one.

**Current:** no transition guard exists, and four of those five names are not used as state values. See
§9 for the states the code actually writes. Implementing this requires the operation record from 8.2.

---

### 8.5 All remote execution goes through the scheduler  *(ENFORCED, narrowly)*

Every **per-computer** operation goes through the single submission point `Start-UpdateCheckJob`, and
gate (x) fails if a new `BeginInvoke` submission appears outside it. That is what is enforced.

What is **not** true is the stronger reading — that the *scheduler* decides when everything runs. The
scheduler tick admits `Pending` rows subject to the cap; direct handler calls admit immediately. See
8.6.

Do not add a direct remote execution path from CLI commands, menu handlers, navigation/session code or
convenience functions.

---

### 8.6 Concurrency limits are absolute  *(TARGET — not implemented)*

**Target:** `MaxConcurrentJobs` is never exceeded, regardless of how work entered the system.

**Current — this one is a live defect, not just a gap:**

* the cap is checked **only** in `Start-PendingUpdateCheck` (the scheduler tick);
* `Start-UpdateCheckJob` (the submission point) has **no** `jobs.Count` check. Its only
  `MaxConcurrentJobs` occurrence is inside a **comment which claims it counts toward the cap**;
* the console handlers call the submission point **directly, in a loop**, so a fleet-wide operation
  can start **more pipelines than the cap allows**;
* **no validator gate exists** — the single validator reference is also a comment;
* `Test-SchedulerSerialization` *does* assert `jobs.Count -le 2`, but it drives
  `Start-PendingUpdateCheck`. That test is honest and correctly scoped; it simply does not cover the
  direct path.

The combination is the hazard: a documented guarantee, plus a passing test, plus a comment asserting
enforcement, while the enforced path is a different one. Do not add another worker-launch path; fix
this one (Phase 3).

---

### 8.7 Pending work must not be silently discarded  *(TARGET — not implemented)*

**Target:** when new work is submitted for a computer that already has pending work, the existing work
must not simply disappear. Any replacement, merge, rejection or cancellation must be explicit and
follow a documented policy.

**Current:** there is a single `PendingOp` slot, assigned in place. Reproduced: a `download` request
against a busy computer followed by an `install` request leaves `PendingOp='InstallAndRecheck'` — the
download request is gone and nothing reports it. The policy must be chosen and documented (Phase 4).

---

### 8.8 Credential identity is deterministic

An operation must execute using the credential identity associated with that operation.

An explicitly supplied custom credential must never silently fall back to the default credential.
Resolution happens before execution, and a worker must not independently decide to use another
identity. Authentication failure must not silently trigger execution under another identity.

This is enforced: both resolvers fail loudly rather than substituting an identity, the runspace-side
copy is checked against the module-side one by a differential test, and a credential change invalidates
reused runspaces via an epoch.

---

### 8.9 WhatIf means no remote mutation

`WhatIf` must never perform remote mutation. It may validate, resolve, display or simulate as the
contract defines. It must not install, reboot, change remote state, write remote configuration, or
perform any other mutating operation.

It currently also writes **no audit record**, deliberately: a simulation is not a denied attempt, and
mixing plans into the compliance trail would make "refused the change" indistinguishable from "asked
what it would do". Keep that consistent if you change it — one layer must not record `WhatIf` while
another does not.

---

### 8.10 Connectivity failures do not delete inventory

A temporary connectivity failure must not silently remove a computer from inventory. Inventory state
and transient execution state are separate concepts.

Enforced by a consecutive-failure threshold with the counter reset on success, so individual blips
cannot accumulate into a removal.

---

## 9. Operation state machine

**This is the TARGET model. It is not what the code does today.**

```text
                 ┌──────────────┐
                 │    Queued    │
                 └──────┬───────┘
                        │
              ┌─────────┴─────────┐
              │                   │
              ▼                   ▼
        ┌───────────┐       ┌───────────┐
        │  Running  │       │ Cancelled │
        └─────┬─────┘       └───────────┘
              │
      ┌───────┼────────┬────────────┐
      │       │        │            │
      ▼       ▼        ▼            ▼
 Complete   Failed   TimedOut   Cancelled
```

Valid transitions are documented in `docs/STATE-MACHINE.md` (also labelled as the target).

Do not invent ad-hoc state transitions. In the target model these are invalid:

```text
Complete → Running
Failed → Running
TimedOut → Running
Cancelled → Running
```

A retry creates a new `OperationId`.

### What the code actually stores today

There is **no operation record**, so the target model above has nowhere to live. What exists is two
fields on the computer row:

| Field | Actual values written by the code | Meaning |
| --- | --- | --- |
| `State` | `Queued`, `Connecting`, `Connected`, `Checking`, `UpdatesFound`, `Downloading`, `Installing`, `RebootRequired`, `Rebooting`, `Complete`, `Error`, `Timeout`, `Offline` | a *workflow/presentation* label |
| `OpState` | `Idle`, `Running` | whether an operation pipeline is in flight — this is what the per-computer gate reads |

Consequences to respect when writing code:

* **`Failed`, `TimedOut`, `Cancelled` and `Refused` are not `State` values.** The code uses `Error` and
  `Timeout` for failure and timeout. Do not write the target names into `State` on the assumption they
  are already used.
* There is **no `Cancelled`** state at all.
* `State` is a display-oriented label, so decisions must not be made from it — that was a real defect
  (gate (ac)); `Test-PhaseCompletion` now decides from workflow state plus `CheckConcluded`.
* `Refused` exists as an **exit code (7)** and an audit outcome, not as a row state.

---

## 10. Timeout and race handling

Timeouts must be operation-specific.

Do not solve races using arbitrary `Start-Sleep` calls.

The following race must be safe:

```text
Operation A
    ↓
Running
    ↓
Timed out
    ↓
Operation B created
    ↓
Operation B running
    ↓
late worker from A completes
```

The late worker from A must not modify B's state.

The implementation must remain correct regardless of which event occurs first around the deadline:

```text
worker completes
timeout fires
cancellation occurs
retry starts
```

Do not assume timing based on testing convenience.

---

## 11. Scheduler responsibilities

The scheduler owns execution policy such as:

* admission
* queueing
* per-computer concurrency
* global concurrency
* worker startup
* operation deadlines
* completion handling
* timeout handling
* cancellation
* operation identity validation

The scheduler does **not** belong in the CLI presentation layer.

---

## 12. Worker responsibilities

A worker executes one operation and returns a result.

A worker must not decide:

* global concurrency policy
* whether another operation should start
* credential fallback
* replacement-operation policy
* whether a timed-out operation should become active again

Workers must return enough information for the scheduler/state store to make the appropriate state transition.

---

## 13. State ownership

There must be a clear source of truth for:

* computers
* operations
* pending work
* configuration
* operation state

The console/UI is not the source of truth.

Audit records are not the primary workflow state.

Do not use display state as application state.

---

## 14. Audit requirements

Mutating operations must carry:

```text
Mutating = $true
```

and must pass through the central audit choke point.

Mutating operations require an audit reason according to the existing audit contract.

Do not bypass auditing for convenience.

Do not infer mutability merely from a function name.

A wrong `Mutating` flag can silently bypass the audit rule, so preserve the flag accurately whenever adding or changing an operation.

Audit records should describe intent, execution, result, and integrity as appropriate.

Do not turn the audit subsystem into the primary operation-state store.

---

## 15. Phase/deployment behaviour

Do not conflate:

```text
operation completed
```

with:

```text
operation succeeded
```

A completed operation may have:

* succeeded
* failed
* timed out
* been cancelled
* been refused

Fleet/phase behaviour must explicitly define what happens after each outcome.

Policies such as:

```text
BlockOnFailure
ContinueOnFailure
ContinueOnTimeout
```

must be explicit where applicable.

A failed or timed-out computer must not accidentally be treated as successful merely because its worker finished.

---

## 16. CLI responsibilities

The command/console layer is responsible for:

* parsing input
* validating input
* creating operation requests
* displaying state/results
* returning appropriate exit codes

It must not:

* execute remote work directly
* manage runspaces directly
* implement scheduler concurrency
* invent credential fallback
* directly mutate operation state outside the defined state/store interfaces

For synchronous commands, success must represent actual operation completion according to the documented command contract, not merely successful submission to a queue.

For fleet operations, preserve the distinction between:

* all succeeded
* some succeeded
* some failed
* some timed out
* some cancelled
* submission failure

---

## 17. Testing

There is no Pester requirement.

The repository uses:

```text
tests\Test-*.ps1
```

The following are GUI leftovers and are excluded from the CLI test workflow:

```text
tests\Test-ColumnResize.ps1
tests\Test-DragResize.ps1
```

`Test-DragResize.ps1` can hang because it uses a blocking dispatcher pump.

Do not "fix" these tests as part of unrelated CLI work.

### `Test-RemoteTask.ps1` skips without elevation — this is correct

`tests\Test-RemoteTask.ps1` registers a SYSTEM scheduled task, so it requires an elevated shell. When
it is not elevated it prints `SKIP: must run elevated ...` and **exits 0**.

That exit code is deliberate. A suite that *could not run* has not failed, and exiting non-zero made
every non-elevated run report a spurious failure.

**Do not "fix" this skip**, and do not change it back to a non-zero exit. If you need it to run, run
the suite from an elevated prompt. Two consequences to keep in mind:

* a full-suite run legitimately reports `1 skip` on a normal shell — that is not a failure to
  investigate;
* if you are validating an invariant that only this suite covers, **you have not validated it** on a
  non-elevated run. Say so rather than claiming the suite passed.

### Release validation

The release gate is:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Validate-Release.ps1
```

Commands must run elevated where required and with `-STA`.

---

## 18. Development workflow for LLMs

For every non-trivial change:

### Step 1 — Inspect

Before editing:

* inspect the relevant modules
* inspect existing tests
* inspect callers
* inspect state ownership
* inspect related documentation
* identify the current source of truth

Do not immediately rewrite the apparent problem.

### Step 2 — Plan

Describe:

* affected files
* current behaviour
* desired behaviour
* invariants affected
* tests that should prove the change

### Step 3 — Implement minimally

Make the smallest coherent change.

Prefer extending existing abstractions over creating parallel ones.

Do not perform broad refactors merely because the surrounding code could be cleaner.

### Step 4 — Test narrowly

Run the smallest relevant test immediately.

### Step 5 — Test broadly

Run all relevant tests after the logical change is complete.

### Step 6 — Review the diff

Check for:

* unintended changes
* encoding changes
* BOM removal
* accidental generated files
* changes under `dist`
* WPF dependencies
* PowerShell 7 syntax
* direct `Read-Host`
* scheduler bypass
* credential fallback
* incorrect `Mutating`
* state-machine violations

### Step 7 — Release validation

Run:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Validate-Release.ps1
```

Do not claim the change is complete until the relevant validation has been run or the reason it could not be run is explicitly reported.

If a suite **skipped** (e.g. `Test-RemoteTask` without elevation), say it skipped. Do not report a
skipped suite as a pass.

---

## 18a. Destructive operations and uncommitted work

**Uncommitted work is never disposable.** Do not assume a dirty working tree contains only scratch
changes, and do not discard it to "get back to a known state".

Prohibited as a *restore* or *cleanup* step:

```text
git checkout -- <path>
git checkout <ref> -- <path>
git restore <path>
git reset --hard
git clean -fd / -fdx
git stash drop / git stash clear
```

Why this is called out explicitly: during the hardening work, a verification experiment modified a
source file, and `git checkout --` was used to restore it. Because that file's changes were **still
uncommitted**, the restore discarded them — silently reverting two completed fixes. `git status` was
the only thing that revealed it.

**Required pattern for any experiment that modifies a tracked file:**

```
1. COMMIT first, so the work is recoverable.       (preferred)
2. Or copy the file aside, and restore FROM the copy:
       Copy-Item $f "$env:TEMP\backup-$(Split-Path $f -Leaf)" -Force
       ... experiment ...
       Copy-Item "$env:TEMP\backup-..." $f -Force     # NOT git checkout
3. Verify the restore: git status must show the file as MODIFIED again
   (if it no longer appears modified, the restore reverted your work).
4. Re-run the tests after restoring.
```

Additional rules:

* Before **any** destructive command, run `git status --porcelain` and `git diff --stat` and confirm
  what would be lost. If anything uncommitted would be lost, stop and report it.
* Never use `git checkout` / `git reset` / `git clean` to resolve a merge or rebase conflict in this
  repository without explicit instruction.
* When preserving a file, set the encoding explicitly
  (`[System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($true)))`) — a
  `Set-Content` restore strips a BOM and corrupts files that contain non-ASCII text (§6).

---

### Step 6 — Review the diff (expanded)

Beyond the list above, check for:

* work lost by a destructive Git command (see §18a)
* an invariant claimed as implemented but not covered by a gate, and not covered by a test that
  actually exercises it
* a comment or doc asserting enforcement that the code does not perform
* a test whose **name** promises an invariant it does not drive

---

## 19. Stop conditions

Stop and report instead of guessing if any of the following occurs:

* existing tests fail unexpectedly
* two sources of truth disagree
* the intended state transition is ambiguous
* a worker can mutate state without an `OperationId`
* two operations can execute concurrently for one computer
* credential identity is unclear
* timeout/retry ownership is unclear
* a broad unrelated refactor appears necessary
* the requested behaviour conflicts with existing documented invariants
* PowerShell 5.1 compatibility is uncertain
* a change would require bypassing the scheduler
* audit behaviour is unclear
* an existing test contradicts the requested behaviour

Do not silently choose one interpretation.

---

## 20. Historical failure modes

These failures have occurred or are specifically guarded against in this project.

Treat them as regression hazards:

1. CLI code reading WPF state.
2. Direct `Read-Host` causing automated/scripted runs to hang.
3. Incorrect `Mutating` flags bypassing audit requirements.
4. PowerShell 7-only syntax entering a PowerShell 5.1 project.
5. BOM removal corrupting non-ASCII source.
6. Scheduler bypass creating uncontrolled remote execution.
7. Two operations executing for the same computer.
8. A stale worker overwriting a newer operation.
9. Credential fallback silently changing authentication identity.
10. A timed-out worker completing later and corrupting replacement state.
11. Pending work being silently overwritten.
12. Connectivity failure deleting inventory.
13. A completed-but-failed operation being treated as successful.
14. Console/UI state becoming an accidental second source of truth.
15. Generated `dist` files being edited instead of source files.

---

## 21. General LLM rules

When modifying this repository:

* Do not guess.
* Do not invent APIs that are not present.
* Do not assume GUI behaviour applies to CLI behaviour.
* Do not introduce a second implementation of an existing architectural responsibility.
* Do not perform unrelated cleanup.
* Preserve backwards-compatible behaviour unless the task explicitly changes it.
* Prefer explicit state and ownership over implicit state.
* Prefer deterministic behaviour over timing-dependent behaviour.
* Prefer tests that prove externally observable behaviour.
* Preserve existing file encoding.
* Keep changes reviewable.

When uncertain, inspect more code and tests before editing.
