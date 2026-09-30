# WUU2-CLI Architecture

> ## How to read this document
>
> **Part A (Current)** describes what exists in `src\` today. The source is authoritative.
> **Part B (Target)** describes the intended architecture — the direction work should move.
>
> **Part B is not implemented in full.** Where the two differ, Part A is what the code does. The
> authoritative per-invariant status is the table in
> [`.github/copilot-instructions.md`](../.github/copilot-instructions.md) §8.
>
> Do not describe a Part B mechanism as current behaviour.

---

# Part A — Current architecture

## A1. Entry and wiring

```text
WUU.ps1
  └─ Start-WuuApplication                      (Wuu.Core)
       ├─ Import-WuuModules                    all modules, -Global
       ├─ [command mode]  ConvertTo-WuuCommandLine → Invoke-WuuCommand   (Wuu.Command)
       └─ [interactive]   Start-WuuGuidedWorkflow                        (Wuu.Navigate)
                             └─ $consoleActions.*                        (Wuu.Core)
                                   │
                                   ▼
                         Start-UpdateCheckJob   ◄── the single submission point
                                   │                 (Wuu.WindowsUpdate)
                                   ▼
                         per-computer runspace (New-ComputerRunspace)
                                   │
                                   ▼
                         $jobs  (synchronized ArrayList)
                                   │
                                   ▼
                         job-cleanup loop (separate runspace, Wuu.Core)
                             ├─ completion  → EndInvoke, release OpState, clear deadline
                             ├─ failure     → mark Error, release OpState
                             └─ deadline    → Stop, mark Timeout, release OpState
                                   │
                                   ▼
                         Audit (Wuu.Audit): intent before, outcome after; fail-closed
```

Per-computer state lives in the `Wuu.State` store (`Rows` / `ByName`); the shell renders it.

## A2. Where execution actually enters

| Site | Kind | Subject to the cap? |
| --- | --- | --- |
| `Wuu.WindowsUpdate.psm1` — `Start-UpdateCheckJob` | the single per-computer submission point | **No** — see A3 |
| `Wuu.Core.psm1` — job-cleanup loop | one instance, started at wiring | n/a (singleton) |
| `Wuu.Core.psm1` — WUA search sub-pipeline | **inside** the Check payload | n/a (bounded, sequential) |
| `Wuu.Core.psm1` — reboot-probe sub-pipeline | **inside** the Install payload | n/a (bounded, sequential) |
| `Wuu.Workers.psm1` — bounded probes | worker pool | bounded by pool size, not the job cap |

The two sub-pipelines are payload-internal and are not submissions. Gate (x) asserts no per-computer
submission exists outside `Start-UpdateCheckJob`.

## A3. Concurrency as it exists today — read this before assuming a cap

There are **two** admission paths, and only one is capped:

| Path | Who uses it | Cap applied? |
| --- | --- | --- |
| `Start-PendingUpdateCheck` (scheduler tick) | rows with `Pending = $true` | **Yes** — `if ($jobs.Count -ge $MaxConcurrentJobs) { break }` |
| `Start-UpdateCheckJob` called **directly** | every console handler and the command layer | **No** — no `jobs.Count` check |

So a `Pending`-driven drain respects `MaxConcurrentJobs`; a direct fleet-wide operation **does not**.
This is an open defect (Phase 3), not a design choice. The comment in `Start-UpdateCheckJob` claiming it
counts toward the cap is inaccurate, and there is **no validator gate** for the cap — the only
validator mention of `MaxConcurrentJobs` is itself a comment.

Related trap: `Test-SchedulerSerialization` does assert `jobs.Count -le 2`, but it drives
`Start-PendingUpdateCheck`. The test is honest and correctly scoped; it simply does not cover the
direct path. Do not read it as covering submission.

## A4. Per-computer state as it exists today

| Field | Actual values | Meaning |
| --- | --- | --- |
| `State` | `Queued`, `Connecting`, `Connected`, `Checking`, `UpdatesFound`, `Downloading`, `Installing`, `RebootRequired`, `Rebooting`, `Complete`, `Error`, `Timeout`, `Offline` | workflow/presentation label |
| `OpState` | `Idle`, `Running` | whether a pipeline is in flight — what the per-computer gate reads |
| `Pending` / `PendingOp` | boolean / op name | **one** deferred slot |
| `TimeoutExpiresAt` / `TimeoutSource` / `OpName` | deadline recorded at submission | enforced by the cleanup loop |
| `LastHeartbeatAt` / `Heartbeats` | liveness | shown in the status table |
| `CheckConcluded` | `$null` / `$false` / `$true` | three-state workflow predicate for phase gating |
| `CredentialEpoch` / `CredentialIdentity` | the identity a reused runspace was built with | invalidates a stale runspace || OperationId | the operation that currently owns this row | **added in Phase 2** — see B10 |
Notes that matter when writing code:

* there is **no operation record** (RequestedAction, CreatedAt, Deadline, Result and AuditContext as one object); `OperationId` **does** exist as a row field, but per-computer state is the only granularity;
* **no `Cancelled` state exists**, and failure/timeout use `Error` / `Timeout` rather than
  `Failed` / `TimedOut`;
* `State` is display-oriented, so decisions must come from workflow fields (this was a real defect —
  gate (ac));
* `PendingOp` is a **single slot**, overwritten in place with nothing reported.

---

# Part B — Target architecture

Everything below is the intended design. It is **not** all implemented; the status table in
`.github/copilot-instructions.md` §8 names which parts are, and the gaps.

## B1. Purpose

The architecture exists primarily to guarantee:

* deterministic execution
* controlled concurrency
* operation identity
* safe retries
* timeout isolation
* deterministic credentials
* auditable mutations
* separation of presentation and execution state

## B2. Target layering

```text
                         ┌─────────────────────┐
                         │       WUU.ps1       │
                         │    Entry Point      │
                         └──────────┬──────────┘
                                    │
                                    ▼
                         ┌─────────────────────┐
                         │   Command / CLI     │
                         │ Parsing / Display   │
                         └──────────┬──────────┘
                                    │
                                    ▼
                         ┌─────────────────────┐
                         │  Wuu.Navigate       │
                         │  Wuu.Session        │
                         └──────────┬──────────┘
                                    │
                                    ▼
                         ┌─────────────────────┐
                         │ $consoleActions     │
                         │ Console adapters    │
                         └──────────┬──────────┘
                                    │
                                    ▼
                         ┌─────────────────────┐
                         │     Scheduler       │
                         │ Admission / Queue   │
                         │ Concurrency / Time  │
                         └──────────┬──────────┘
                                    │
                         ┌──────────┴──────────┐
                         ▼                     ▼
                ┌─────────────────┐   ┌─────────────────┐
                │ Operation State │   │      Audit      │
                │     Store       │   │    Subsystem    │
                └────────┬────────┘   └─────────────────┘
                         │
                         ▼
                ┌─────────────────┐
                │     Worker      │
                │ One operation   │
                └────────┬────────┘
                         │
                         ▼
                ┌─────────────────┐
                │ Windows Update  │
                │ Remote Engine   │
                └─────────────────┘
```

**Deviation from the current code, stated plainly:** `$consoleActions` is **defined inside
`Wuu.Core.psm1`**, not a separate layer beneath it. The diagram shows the intended separation of
concerns; today it is one module, and the adapters frequently delegate to `$event*` closures.

## B3. Layer responsibilities

### B3.1 Entry point

`WUU.ps1` — startup, argument handling, module initialisation, application invocation. It should not
contain substantial business logic.

### B3.2 Command / CLI layer

Interpret commands, validate arguments, **create operation requests**, display results, return exit
codes.

It must not own remote execution, create workers, implement concurrency, or decide credential
fallback.

### B4. Navigation and session

`Wuu.Navigate` / `Wuu.Session` provide the console-level session abstraction. They operate on the
selected `ComputerSet` and must delegate execution through `$consoleActions` — never call the update
engine directly. This prevents a second execution architecture.

### B5. Console action adapters

`$consoleActions.*` is the intended execution interface. When adding a CLI operation:

```text
CLI → Navigate/Session → consoleActions → scheduler → operation → worker → engine
```

Do not create `CLI → engine` as a shortcut.

> **Current reality:** existing `$event*` closures are still live and are still dispatched. The rule is
> about **new** work: do not copy the old structure, and do not restore GUI-era behaviour. See
> `.github/copilot-instructions.md` §4.

### B6. Scheduler

The scheduler owns admission, queueing, global and per-computer concurrency, worker startup,
deadlines, completion, timeout handling, cancellation, and operation-identity validation.

**Target:** it is the only component allowed to decide when an operation executes.
**Current:** per-computer *submission* is centralised, but admission is not — see §A3.

### B7. Operation

**Target:** one requested unit of remote work with a unique identity.

```text
Operation
 ├── OperationId
 ├── Computer
 ├── RequestedAction
 ├── CredentialContext
 ├── State
 ├── CreatedAt
 ├── StartedAt
 ├── Deadline
 ├── CompletedAt
 ├── Result
 └── AuditContext
```

**Current:** no such record exists. Per-computer fields on the state store are the only granularity.
The exact implementation may differ, but the ownership principles must remain — and `OperationId` in
particular is what stale-worker protection depends on.

### B8. Worker

A worker executes **one** operation and receives the context it needs.

A worker must not: launch another operation, modify another operation, decide global concurrency,
choose a different credential, revive a timed-out operation, or replace a newer operation.

Worker output should be treated as a result the scheduler validates against operation identity.

### B9. State store

The source of truth for inventory, operations, operation state, pending work and relevant
configuration. The console display is not state; the audit log is not workflow state; a worker's local
variables are not authoritative.

### B10. Operation identity

Required to prevent stale execution from corrupting current state:

```text
Computer A
  Operation 1: Running → TimedOut
  Operation 2: Running
  Operation 1's worker finally returns   ← must not update Operation 2
```

Every mutation caused by an asynchronous worker must therefore establish which operation it belongs
to before applying its result.

**Current: implemented (Phase 2).** `New-WuuOperationId` creates the identity; it is stamped on the
row, carried on the job entry, and injected into the worker runspace. Two rules enforce it —
`Test-WuuOperationCurrent` (release only proven ownership) and `Test-WuuStaleWrite` (refuse only
proven staleness) — mirrored in six sites. See
[`.github/copilot-instructions.md`](../.github/copilot-instructions.md) §8.3.

**Still TARGET:** the operation **record** in §B7. Identity exists; the object it would live on does
not, and per-computer row fields remain the only granularity.

### B11. Credential architecture

Resolution happens **before** remote execution; the operation receives a fixed credential context; the
worker must not reinterpret the request. An explicitly supplied credential must never silently become
the default.

**Current: implemented.** See `.github/copilot-instructions.md` §8.8.

### B12. Audit

A cross-cutting concern. Mutating actions pass through a central choke point that records intent and
outcome. It records execution history and integrity; it does not replace operation state.

Note: `-WhatIf` deliberately writes **no** audit record — a simulation is not a denied attempt.

### B13. Inventory

A failed remote connection does not mean the computer no longer exists. Inventory state must not be
implicitly mutated by a transient connectivity failure.

**Current: implemented** via a consecutive-failure threshold with the counter reset on success.

### B14. WhatIf

Follows the same command/admission path where practical but must not cross into remote mutation:

```text
Request → Validate → Resolve → Simulate/describe → Display
```

Never `WhatIf → remote mutation`.

**Current: implemented** — it returns before any handler and writes no audit record.

### B15. Legacy GUI boundary

The repository contains historical GUI-origin code: **12** `$event*` closures defined in `Wuu.Core.psm1`
(`$eventAddAD`, `$eventAuditWSUSUpdates`, `$eventLoadConfig`, `$eventRemoveOfflineComputer`,
`$eventSaveComputerList`, `$eventSaveConfig`, `$eventSetDomainCredentials`, `$eventShowAvailableUpdates`,
`$eventShowInstalledUpdates`, `$eventShowUpdateHistory`, `$eventViewUpdateLog`, `$eventWUServiceAction`).
They once expected WPF state.

**No shipped source reads a GUI control member today.** `SelectedItems`, `IsChecked`, `CheckBox`,
`Dispatcher` and `System.Windows.*` appear **only inside comments** in `src\` — verified by tokenizing
each module and blanking comment text in place, which leaves **zero** code references.

Two related facts:

* `uiHash` still exists and is passed into runspaces, but it is an **empty** synchronized hashtable;
  no control member is ever assigned to it.
* The row-writer is `Update-WuuComputerRow` / `UpdateWuuComputerRowScript` — **renamed** from
  `SafeUpdateListViewItem`, a GUI-era name for a WPF control this edition does not have. It is defined
  twice (module scope and runspace-injected) and invoked once through the injected copy; gate (al)
  asserts the misleading name does not return.
* `$eventInstallUpdates` is mentioned in comments but **not defined**; it is not an existing closure.

**Do not introduce WPF dependencies into new code.**

### B16. Architectural decision rule

When a change could reasonably go in two places, choose the existing layer that owns the
responsibility.

| Requirement | Owner |
| --- | --- |
| Parse command | CLI |
| Display result | CLI |
| Select computers | Navigation/session |
| Create operation | Scheduler/application service |
| Queue operation | Scheduler |
| Limit concurrency | Scheduler |
| Start worker | Scheduler |
| Execute one remote operation | Worker |
| Remote update action | Existing update engine |
| Workflow state | State store |
| Audit record | Audit subsystem |
| User input | Input abstraction |

Do not duplicate responsibility across layers.

---

# Appendix — Validator gate index

`Scripts\Validate-Release.ps1` holds the gates that make an invariant ENFORCED. There are **63** gate
comment blocks in five cycles, so letters repeat — always cite a letter *with* its subject:

| Cycle | Letters | Subject |
| --- | --- | --- |
| 1 | (a)–(i) | audit integrity: canonical form, hash chain, fail-closed, append-only, locking, durability |
| 2 | (a)–(i) | audit evidence + ISO 27001 A.8.15: actor/host/timestamp, refusals, read-only access, retention |
| 3 | (a)–(k) | startup: elevation relaunch, argv logging, version single-sourcing, packaging, help, parameter reassignment |
| 4 | (a)–(q) | guided UI and spec conformance: entry state, delegation, handler resolution, mutating flags, reason consumption |
| 5 | (r)–(ag) | console correctness and the hardening pass: **continuous**, `(r)` → `(ag)` with no gap |

Cycle 5 is continuous, so `(y)` phase-failure policy and `(z)` ICMP/inventory sit between `(x)` and
`(aa)`.

Gates that correspond to §8 invariants:

| Invariant | Gate |
| --- | --- |
| 8.1 one operation per computer | (u), (v), (w) |
| 8.2 operation identity / 8.3 stale writers | (ah) |
| 8.5 single submission point | (x) |
| 8.6 absolute concurrency cap | (ai) |
| 8.7 pending-request policy | (aj) |
| 8.8 credential determinism | (ad) |
| 8.9 WhatIf | (ae) |
| 8.10 inventory vs connectivity | (z) |

Gates covering adjacent behaviour: (ab) per-operation timeouts, (aa) exit codes, (ac) workflow vs
display state, (ag) reboot/cancellation, (af) source encoding, (r) no GUI control member in shipped
source, (s)/(t) scheduler and settings read the store.

**No gate exists for 8.4 only** — which is why its status is TARGET. Gate (ah) covers 8.2/8.3
(operation identity and stale-writer rejection), **(ai)** covers 8.6 (the absolute concurrency cap) and
**(aj)** covers 8.7 (the pending-request policy).
