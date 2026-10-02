# WUU2-CLI — LLM Development Instructions

## 1. Project identity
WUU2-CLI is the console edition of WUU2:

> Windows Update Utility — remote Windows Update check, download, install and reboot across a fleet of Windows computers.

This repository is independent from the GUI repository.

- CLI repository: `WUU2-CLI`
- GUI repository: `WUU2`
- Do not copy GUI/XAML/WPF architecture into this repository.
- Do not modify the GUI repository while working here.
- Do not assume behaviour from the GUI implementation unless explicitly requested.

The CLI is:

- PowerShell 5.1 first;
- Windows-oriented;
- console based;
- remotely managing Windows Update;
- asynchronous;
- concurrency-limited;
- operation/identity aware;
- auditable;
- designed to support unattended automation.

---

# 2. Primary development objective
The objective is NOT simply to make a requested feature work.

Every change must preserve:

1. correctness;
2. operation identity;
3. state-machine integrity;
4. concurrency limits;
5. timeout semantics;
6. audit integrity;
7. PowerShell 5.1 compatibility;
8. automation compatibility;
9. testability;
10. architectural boundaries.

Prefer the smallest change that satisfies the requirement without weakening an existing invariant.

Do not introduce new architecture merely because it appears cleaner.

Before changing an established mechanism, understand why it exists and identify the tests/release gates protecting it.

---

# 3. Source-of-truth rule
The actual source code and passing tests are authoritative for the CURRENT implementation.

Documentation may describe:

- intended architecture;
- future architecture;
- historical defects;
- planned improvements.

Do NOT assume documentation describes reality.

If documentation conflicts with:

- source code;
- tests;
- release-gate checks;

stop and report the discrepancy.

Do not silently "fix" the documentation by changing implementation behaviour.

When a specification describes functionality that is not implemented, label it as:

```
NOT IMPLEMENTED
```

Do not pretend it exists.

The current status of each core invariant is in **Appendix A**.

---

# 4. Required investigation before coding
Before modifying code:

1. identify the relevant module;
2. identify the public entry point;
3. identify the state mutations involved;
4. identify the asynchronous worker involved;
5. identify the OperationId flow;
6. identify relevant tests;
7. identify relevant release-gate assertions;
8. search for duplicate implementations;
9. search for direct state mutations;
10. determine whether the requested behaviour already exists.

Do not immediately edit the first matching function.

Use repository search first.

For significant changes, produce a short internal model:

```
Entry point
    ↓
Command/action
    ↓
Admission
    ↓
OperationId
    ↓
Worker
    ↓
Result
    ↓
State transition
    ↓
Audit
    ↓
Presentation/exit code
```

---

# 5. Architecture
The desired logical architecture is:

```
WUU.ps1
   │
   ▼
Application/Core
   │
   ├── Command / Actions
   │
   ├── Scheduler
   │      │
   │      ├── Admission
   │      ├── Concurrency
   │      ├── Operation lifecycle
   │      ├── Deadlines
   │      └── Cleanup
   │
   ├── Workers
   │
   ├── State
   │
   ├── Remote
   │
   └── Audit
```

The existing repository does not necessarily map perfectly to this diagram.

Treat the diagram as the architectural direction, not permission to perform a large rewrite.

---

# 6. WUU.ps1
`WUU.ps1` is the application entry point.

It should remain thin.

Do not place business logic in `WUU.ps1`.

Business logic belongs in `src/*.psm1`.

---

# 7. Module responsibility
Respect module boundaries.

## Inventory
Every shipped module, with the responsibility it owns. **This table is the canonical module set**:
`Scripts/Test-DocConsistency.ps1` fails if a module is missing from it, if it names a module that does
not exist, or if the two disagree in either direction. Add the row before adding the module.

<!-- module-inventory:start -->
| Module | Owns |
|---|---|
| `Wuu.Core` | Startup, orchestration, the console action layer, and the worker payloads that cannot move |
| `Wuu.State` | Computer/operation state, the mutation funnel, the row contract, invariant checks |
| `Wuu.WindowsUpdate` | Update search/download/install/recheck, the submission point, the scheduler tick |
| `Wuu.Scheduler` | Worker-runspace construction for the scheduling and cleanup machinery |
| `Wuu.Workers` | Worker-pool lifecycle, abandoned-worker handling, the job-cleanup payload |
| `Wuu.Remote` | Remote execution: endpoint probe, CIM/service invocation with timeout, task dispatch |
| `Wuu.Network` | Bounded pooled execution (replaced one child process per call) |
| `Wuu.Credentials` | Credential resolution and DPAPI protection |
| `Wuu.Audit` | Audit records: canonical JSON, hash chaining, verification, transcript capture |
| `Wuu.Logging` | Fault-tolerant log append; never throws into the caller |
| `Wuu.Models` | Collections shared between the console thread and worker runspaces |
| `Wuu.Session` | Computer-name parsing and computer sets |
| `Wuu.Console` | Console presentation: colours, table/status rendering, the menu |
| `Wuu.Presentation` | Presentation helpers shared by the display paths |
| `Wuu.Actions.Display` | The display/table actions |
| `Wuu.Navigate` | The navigation tree |
| `Wuu.Configuration` | Paths and `$global:*` settings, resolved from `$WuuRoot` |
| `Wuu.Command` | The `wuu` verb surface: parse, dispatch, exit codes, JSON for read verbs |
| `Wuu.Result` | The command result model and its JSON rendering |
<!-- module-inventory:end -->

## Boundaries that matter
### `Wuu.WindowsUpdate`
Do not turn it into a general-purpose scheduler.

### Scheduler
Where practical, scheduler responsibilities should be isolated from Windows Update operation logic:

- admission;
- concurrency;
- queue/pending work;
- operation identity;
- deadlines;
- job lifecycle;
- cleanup.

Do not add new scheduler functionality to an unrelated module merely because it is convenient.

> **Current:** `Wuu.Scheduler.psm1` owns only the worker-helper surface. Admission still lives at the
> submission point `Start-UpdateCheckJob` in `Wuu.WindowsUpdate`, and the cleanup loop lives in
> `Wuu.Core`. **PARTIAL.**

---

# 8. Wuu.Core.psm1
`Wuu.Core.psm1` is currently large.

This is a known architectural limitation.

DO NOT perform a wholesale rewrite.

When modifying Core:

1. preserve existing behaviour;
2. avoid increasing its responsibility;
3. place genuinely new functionality in the correct module;
4. when practical, extract cohesive functionality rather than adding another large block.

Long-term goal:

```
Wuu.Core.psm1
    ↓
small bootstrap/orchestration layer
```

Do not move code merely to reduce line count.

Move it when responsibility becomes clearer.

---

# 9. State mutation — HARD RULE
This is one of the most important rules in the repository.

## Workers must not arbitrarily mutate application state.
State changes must go through the appropriate state-transition mechanism.

The central concept is:

```
Worker
   ↓
Result
   ↓
OperationId validation
   ↓
legal transition validation
   ↓
state mutation
```

Do not introduce code such as:

```
$computer.State = ...
$computer.Status = ...
$computer.OpState = ...
$computer.OperationId = ...
$computer.PendingOp = ...
$computer.TimeoutExpiresAt = ...
```

outside the approved state implementation.

Before adding a direct assignment, ask:

> Why is this not going through the state mutation funnel?

If there is no compelling architectural reason, use the state API.

> **Current:** the funnel is `Update-WuuOperationState` in `Wuu.State`. The invariant is **zero
> UNAUTHORISED module-scope operation-state writes** - not "zero occurrences of `$x.Prop =`".
> Operation state is legitimately mutated in four approved contexts:
>
> | Context | Where | Why approved |
> |---|---|---|
> | `StateFunnel` | `Wuu.State.psm1` | the authoritative implementation |
> | `WorkerStateFunnel` | `UpdateWuuOperationStateScript` (Wuu.WindowsUpdate) | a worker runspace has no module commands, so it MUST inline the rule; `Test-WuuOperationState` asserts the two copies agree |
> | `CoreWorkerPayload` | `$DownloadUpdates`, `$GetUpdates`, `$InstallUpdates`, `$RestartComputer`, `$RemoveOfflineComputer` | they execute in isolated worker runspaces |
> | `WorkerCleanupPayload` | `Get-WuuJobCleanupPayload` (Wuu.Workers) | the injected copy of the funnel |
>
> Measured 2026-10-02: **2 unauthorised module-scope writes remain**, both terminal-state writes in the
> submission/scheduler path (`settled -> Error` after a submission that never started; `settled ->
> Queued` for phase-wait bookkeeping). A third - the scheduler clearing `PendingOp` - was converted to
> `Update-WuuOperationState -ClearPendingOp`.
>
> **Do NOT convert the remaining two.** The funnel correctly REFUSES `settled -> Error` and `settled ->
> Queued`; that refusal is invariant 8.4 working. Converting them to funnel calls would trade the
> terminal-state invariant for a metric, and would silently stop phase gating from re-queueing. An
> operator RESET is a real future need but needs its own operation (`ResetOperation`) and its own
> specification - who may reset, whether it is interactive-only, whether it audits, whether the
> OperationId changes, what happens to late workers - not a widened transition rule.
>
> **Scope labels mislead - do not classify by "nearest enclosing function".** A payload defines its own
> helpers inside itself (Core defines `Invoke-ServiceWithTimeout` inside `$GetUpdates`), so a write that
> looks like a module-scope function body is usually payload code. Classification in gate (az) is
> **structural**: brace-matched line RANGES for each approved construction site, so no line numbers are
> encoded and a new write anywhere in a payload's range is judged by the same rule. Corroborate by hand
> with the runspace-only markers payload code calls (`$SetComputerTimeoutScript`,
> `$UpdateWuuOperationStateScript`, `$WriteLogFileScript`), which a module function would call directly.
>
> **The gate prevents regression, not approval.** It fails if the unauthorised count RISES, and it also
> fails if the approved ranges stop resolving in a file that should contain one - otherwise a renamed
> payload would look like a clean tree. A new legitimate mutation belongs inside an approved context, so
> it needs no gate change; a new exception needs a named classification, a documented reason, and its
> own regression test, never a bigger number.

---

# 10. OperationId invariant
Every asynchronous operation must have an OperationId.

Operation identity protects against:

```
operation A starts
operation A times out
operation B starts
operation A finishes late
operation A overwrites operation B
```

The required model is:

```
Operation A
OperationId = A

Operation B
OperationId = B
```

A worker result belonging to A must never mutate state owned by B.

Identity validation must occur BEFORE mutation.

Never:

```
mutate
then validate identity
```

Correct:

```
validate identity
then mutate
```

Do not remove or weaken OperationId checks.

---

# 11. OperationId propagation
When adding asynchronous functionality, verify that OperationId is propagated through:

```
command
→ admission
→ job
→ worker
→ result
→ state update
→ cleanup
→ audit correlation
```

If a new asynchronous path cannot preserve OperationId, stop and redesign the path.

---

# 12. State-machine rules
State transitions must be explicit.

Do not add states casually.

Current terminal states are:

```
Complete
Timeout
Error
```

The canonical definition is `$script:WuuTerminalStates` in `Wuu.State` (read via `Get-WuuTerminalStates`).
The transition guard, the outcome classifier and the invariant checker all read it.

Do not invent:

```
Cancelled
Refused
```

as state-machine states unless the architecture is deliberately changed.

`Refused` and similar outcomes may be command/admission results rather than workflow states.

> **Current:** a refusal is recorded on the row as `RefusedCount` / `RefusedReason` / `RefusedAt`, and a
> refused command exits `7`. No operator-facing cancel of a running operation exists.

When changing transitions:

1. update the canonical transition definition;
2. update tests;
3. update release validation;
4. update documentation.

Do not maintain several independent terminal-state lists.

---

# 13. Terminal-state precedence
Terminal states must remain terminal.

Current precedence is conceptually:

```
Error
  >
Timeout
  >
Complete
```

A late success must not overwrite an Error or Timeout.

Never "fix" this with sleeps or timing assumptions.

Use identity and state validation.

> **Current:** an unattributed write (no OperationId) may not change a terminal row's state, including
> terminal → terminal. A retry is a new operation with a new OperationId and is permitted.

---

# 14. Concurrency
The global concurrency limit is a hard invariant.

It must never be exceeded regardless of how work entered the system.

This includes:

- normal commands;
- `-All`;
- pending work;
- scheduler work;
- retries;
- chained operations;
- automatic follow-up operations.

Do not create a new asynchronous submission path that bypasses the central admission mechanism.

The authoritative capacity check must occur at the actual submission boundary.

An advisory check alone is insufficient.

The worker pool size must be at least `MaxConcurrentJobs` (`Test-PoolCompatibility`, gate block (ax)):
a smaller pool leaves admitted operations with probes that can never start.

---

# 15. Per-computer concurrency
Only one active operation may own a computer at a time.

Do not allow:

```
Computer A
 ├── operation A
 └── operation B
```

simultaneously.

If another request arrives:

- queue it;
- reject it;
- merge it;
- or otherwise handle it according to the pending-operation policy.

Do not silently start a second operation.

---

# 16. Pending operations
The current implementation uses a single pending slot.

Do not silently discard pending work.

Any replacement must be observable.

Semantic operation precedence is used rather than blindly applying newest-wins.

Recommended conceptual ordering:

```
Check
  <
Download
  <
Install
  <
Restart
```

Therefore:

```
existing = Install
requested = Download
result = Install
```

rather than downgrading the pending request.

> **Current:** semantic precedence **IS IMPLEMENTED**. `Set-WuuPendingOperation` consults
> `Get-WuuPendingOpRank` (also exported): `Check`(1) < `Download`(2) < `Install`/`InstallAndRecheck`(3)
> < `Restart`/`AutoFlow`(4). An UPGRADE replaces and reports the displaced request; a DOWNGRADE is
> DECLINED, the higher request is KEPT, and the decline is reported (`Refused` + `Existing` + `Reason`).
> Equal ranks replace, so arrival order settles the genuine ambiguity. An UNKNOWN operation ranks 0,
> so it is declined in favour of anything already queued rather than silently displacing real work.
>
> Refusing a DOWNGRADE loses nothing: the higher request still runs and is still what the operator
> asked for. The note above about refusing a second request applies to an UPGRADE, which is why an
> upgrade still replaces. The returned hashtable is ADDITIVE (SS34): `Set`/`Op`/`Replaced` keep their
> former meaning, and `Refused`/`Existing` are new. Gate (aj) drives every ordered pair of the rank
> table, because the behaviour that was wrong is a single cell of that matrix.

However, do NOT implement this merely by changing one comparison.

Before changing pending-operation semantics:

1. identify all consumers;
2. define incompatible operations;
3. define replacement rules;
4. add tests;
5. update documentation;
6. update release validation.

---

# 17. Scheduler
The scheduler is responsible for orchestration, not Windows Update business logic.

Scheduler responsibilities:

```
admit
schedule
track
timeout
complete
cleanup
release
```

Windows Update logic belongs in the Windows Update worker.

Do not make the scheduler understand update-specific details unless necessary.

---

# 18. Worker model
Workers execute remote operations.

Workers should ideally return structured results rather than owning application state.

Preferred model:

```
WorkerContext
    OperationId
    Computer
    Deadline
    Required configuration
    Logging context

        ↓

Worker executes

        ↓

OperationResult

        ↓

central state transition
```

Do not make workers responsible for:

- global scheduling;
- UI rendering;
- command parsing;
- audit-file management;
- global concurrency.

---

# 19. Worker duplication
Some worker functions are necessarily duplicated/injected because runspaces do not automatically share normal module scope.

Treat such duplication as deliberate.

When changing duplicated worker logic:

1. find every copy;
2. update all relevant copies;
3. update the corresponding test;
4. search the repository for the old implementation.

Do not assume one occurrence is authoritative.

Where a rule must exist both as a module function and as an inlined copy, a test must drive both on the
same inputs and assert they agree (example: `tests/Test-RemainingBudget.ps1` section 11).

Long-term goal:

> Minimise duplicated worker logic through small, explicit worker APIs.

---

# 20. Worker pool
The worker pool contains defensive handling for operations that cannot be stopped cleanly.

Do not remove abandoned-worker handling simply because it appears unusual.

Do not replace forced cancellation with arbitrary sleeps.

Monitor:

```
active workers
pool capacity
abandoned workers
pool utilisation
```

These are exposed by `Get-WuuWorkerPoolDiagnostics` and `Test-WuuWorkerPoolStarved` (`Wuu.Workers`).

If changing worker lifecycle, test:

- normal completion;
- timeout;
- cancellation;
- exception;
- abandoned worker;
- subsequent worker admission.

---

# 21. Timeout model
Every asynchronous operation has an outer operation deadline.

The deadline is authoritative.

Nested calls must respect the remaining operation budget.

Conceptually:

```
Operation deadline
        ↓
remaining budget
        ↓
remote call timeout
        ↓
retry timeout
```

Never create:

```
45-minute operation
+
45-minute retry
+
45-minute retry
```

without considering the outer deadline.

Preferred calculation:

```
remaining = OperationDeadline - Now
callTimeout = minimum(configuredTimeout, remaining)
```

> **Current:** `Get-WuuEffectiveInnerTimeout` implements this with a 5-second floor, and no recorded
> deadline means no cap. It is applied (inlined) to `Invoke-CimWithTimeout` and
> `Invoke-ServiceWithTimeout`. Other remote calls are not yet budget-capped. **PARTIAL.**

Do not use arbitrary `Start-Sleep` to solve races or timeout problems.

---

# 22. Credentials
Credential identity must remain deterministic.

Do not introduce silent credential fallback.

When adding remote operations, explicitly establish which credential is used.

Do not accidentally change:

```
configured credential
```

into:

```
current interactive user
```

unless that is explicitly intended.

---

# 23. Connectivity
Connectivity detection must represent actual management capability.

Do not use ICMP/ping as the sole authority for management connectivity.

Connectivity failure must not automatically mean:

```
computer should be deleted
```

Inventory membership and temporary connectivity are separate concepts.

Removal requires the existing threshold/counter policy.

Do not weaken that policy without tests.

---

# 24. WhatIf
`WhatIf` means:

> Do not perform remote mutation.

It must not:

- invoke a remote mutating handler;
- install updates;
- download updates;
- restart machines;
- modify remote services.

Do not treat local display/audit preparation as remote mutation.

Preserve the current behaviour unless deliberately changing the command contract.

---

# 25. Audit
Audit records are security-relevant.

Preserve:

- canonical record structure;
- hash chaining;
- previous-hash linkage;
- locking;
- verification;
- operation correlation.

Do not modify audit canonicalisation casually.

If changing audit fields:

1. determine compatibility implications;
2. update verification;
3. update tests;
4. update documentation.

Long-term improvement:

```
local hash chain
      ↓
daily digest
      ↓
external/immutable anchor
```

Do not claim that a local hash chain alone provides full non-repudiation.

---

# 26. Audit deletion/durability
Recognise the current limitation:

A privileged administrator may be able to delete an entire audit-day file.

Do not "solve" this with another local hash.

The proper long-term solution is an external anchor or immutable storage.

> **Current — PARTIAL:** `New-WuuAuditAnchor` / `Test-WuuAuditAnchor` write and compare a chain-head anchor
> file, refuse an anchor in the log's own directory, and detect a rewritten or truncated chain. The anchor
> is only as strong as wherever it is stored: it is tamper-evident, **not** WORM storage and **not**
> non-repudiation. No daily digest, Event Log, SIEM or signed external digest exists.

Potential mechanisms include:

- Windows Event Log;
- remote SIEM;
- immutable network storage;
- WORM storage;
- signed external digest.

Choose based on deployment requirements.

---

# 27. Error handling
Avoid:

```
catch { }
```

unless the operation is deliberately best-effort.

Every catch should conceptually be one of:

```
EXPECTED / RECOVERABLE
EXPECTED / BEST-EFFORT
TERMINAL
PROGRAMMING ERROR
```

For terminal failures, return structured failure information.

Do not swallow exceptions that could cause the scheduler to believe an operation succeeded.

Silent catches are policed by gate block (aq) against the allowlist in `Scripts/Wuu.CatchAudit.ps1`.

---

# 28. Interactive input
Do not introduce direct:

```
Read-Host
```

for application interaction.

Use the existing input abstraction:

```
Read-WuuAnswer
Read-WuuYesNo
Read-WuuSelection
```

Interactive input must remain testable.

Fatal/error paths should not wait for:

```
Press Enter to continue
```

unless explicitly required by the interactive UI contract.

The CLI must remain usable by:

- scripts;
- scheduled tasks;
- automation;
- tests;
- remote invocation.

---

# 29. PowerShell compatibility
PowerShell 5.1 is the baseline.

Do NOT introduce:

```
ForEach-Object -Parallel
```

or PowerShell 7-only features.

Avoid unsupported syntax/features.

Do not use 3-argument `Join-Path`.

When unsure whether a feature exists in PowerShell 5.1:

1. check documentation;
2. search existing compatibility tests;
3. prefer the PowerShell 5.1-compatible form.

---

# 30. Encoding
Shipped files containing non-ASCII characters must retain UTF-8 BOM where required by the repository.

Do not blindly rewrite files with tools that remove the BOM.

After editing:

```
verify encoding
```

especially for:

- PowerShell files;
- documentation containing non-ASCII;
- generated files.

A BOM change is a functional compatibility issue for this project, not merely formatting.

The release gate enforces this for shipped PowerShell files. `src/Wuu.State.psm1` is deliberately pure
ASCII with no BOM — do not add non-ASCII characters to it.

---

# 31. `dist`
Never edit or search:

```
dist/
dist/staging/
```

Treat them as generated/package output.

Make changes to source files.

---

# 32. Versioning
There must be one authoritative application version.

Do not manually change multiple copies.

Version information must remain consistent between:

```
Git release/tag
application version
CLI --version
audit records
package/release metadata
```

If these disagree, fix the release process rather than creating another manually maintained version string.

> **Current:** the single literal is `$global:WuuVersion` in `Wuu.Core`; `Resolve-WuuVersion` and the gate
> compare it against the git tag at HEAD. That check reports `SKIP` until the release tag exists, so take
> published verification totals from the **tagged** tree.

---

# 33. Command result model
Commands should ultimately produce a structured result.

The conceptual model should include:

```
schemaVersion
command
operationId
status
exitCode

requestedCount
startedCount
completedCount
failedCount
timedOutCount
refusedCount
queuedCount

targets[]
```

Human-readable output and JSON output should derive from the same result.

Do not implement one result for console output and another independent result for JSON.

> **Current: NOT IMPLEMENTED.** There is no structured command result. Per-target outcomes come from
> `Get-WuuTargetOutcome` / `Get-WuuAggregateOutcome`.

---

# 34. JSON output
`-Json` is an automation interface.

Treat its schema as an API.

Prefer:

```
{
  "schemaVersion": 1,
  "command": "install",
  "operationId": "...",
  "status": "completed",
  "exitCode": 0,
  "targets": []
}
```

Do not casually rename/remove JSON fields.

Breaking JSON output is a compatibility change.

> **Current: PARTIAL.** `-Json` is honoured by read verbs only (`Wuu.Command`); mutating verbs return a
> status string, and there is no `schemaVersion`. The release gate's `-Json` report is versioned
> separately (`wuu.gate.v1`).

---

# 35. Exit codes
Exit codes are part of the CLI API.

Do not change them casually.

Current documented categories must remain internally consistent with implementation.

If an exit code is documented but not actually produced:

1. either implement it properly;
2. or remove it from the public contract.

Do not leave permanently unreachable public behaviour without explicitly documenting it as planned.

The contract is `docs/EXIT_CODES.md` (`0`–`7`); every code there has a producer, asserted by gate blocks
(aa) and (ak).

---

# 36. Release gates
The release validator is a critical part of the architecture.

Do not weaken or remove a release-gate check merely because it makes development inconvenient.

If a gate is wrong:

1. prove why;
2. fix the gate;
3. add a regression test;
4. document the reason.

Every important invariant should ideally have:

```
implementation
+
behavioural test
+
release-gate assertion
+
documentation
```

---

# 37. Tests must test behaviour, not comments
Avoid tests that merely confirm:

```
function exists
comment exists
string exists
```

for important behaviour.

A test claiming:

```
OperationId prevents stale writes
```

must actually:

1. create operation A;
2. create/represent operation B;
3. attempt a late A write;
4. prove B remains unchanged.

Similarly:

```
concurrency limit
```

must prove the actual submission path cannot exceed the limit.

A passing test is not evidence of correctness if the test never exercises the failure mode.

---

# 38. Mutation testing
For critical invariants, tests should fail when the protection is deliberately removed.

Important targets:

```
OperationId validation
terminal-state protection
global concurrency
pending-operation handling
phase blocking
credential selection
audit chaining
timeout enforcement
```

When practical, perform mutation-style validation.

Do not merely increase assertion counts.

Existing harnesses: `tests/Prove-*Tautology.ps1`. They back up by byte copy (never `git checkout --`),
refuse to run unless the tree is already green, and run detached with output to a file. A detection
needle must be a message you have **seen** the gate print for that mutation, not a guess.

---

# 39. Release validator architecture
`Scripts/Validate-Release.ps1` is itself becoming large.

Do not keep adding hundreds of unrelated checks to one file.

Long-term target:

```
Scripts/
    Validate-Release.ps1
    Test-SourceStructure.ps1
    Test-Architecture.ps1
    Test-Contracts.ps1
    Test-Encoding.ps1
    Test-AuditContract.ps1
    Test-ReleaseMetadata.ps1
```

The top-level validator should aggregate results.

Do not perform this extraction as an unrelated refactor during feature work.

---

# 40. Documentation
Documentation must distinguish:

```
IMPLEMENTED
PARTIAL
NOT IMPLEMENTED
PLANNED
```

Do not describe future architecture as though it already exists.

Historical debugging information belongs primarily in:

```
docs/
```

not huge comments inside production functions.

Source comments should explain:

```
what invariant must remain true
why the unusual implementation is necessary
```

They should not contain a complete history of previous development sessions.

---

# 41. Forbidden architectural shortcuts
Do NOT solve concurrency/race problems with:

```
Start-Sleep
```

Do NOT solve stale-worker problems with:

```
"probably finished by now"
```

Do NOT solve state corruption with:

```
last writer wins
```

Do NOT bypass the state mutation funnel.

Do NOT bypass scheduler admission.

Do NOT introduce a second job submission mechanism.

Do NOT silently swallow worker exceptions.

Do NOT make an interactive prompt required for an automated path.

Do NOT copy GUI code into CLI code.

Do NOT modify `dist`.

---

# 42. LLM-specific development rules
When working as an LLM agent:

## First search
Before editing:

```
Search for symbol
Search for callers
Search for tests
Search for release-gate references
Search for duplicate implementation
```

## Change minimally
Do not rewrite an entire file to change one function.

Do not reformat unrelated code.

Do not rename unrelated symbols.

Do not "clean up" nearby code unless required.

## Preserve existing conventions
Match:

- naming;
- parameter conventions;
- error handling;
- comments;
- module boundaries;
- test style.

## Never infer missing behaviour
If the code does not clearly establish a behaviour:

```
STOP
REPORT UNCERTAINTY
```

Do not invent semantics.

---

# 43. LLM change protocol
For every non-trivial change:

### Phase 1 — Understand
Identify:

```
requested behaviour
current behaviour
relevant files
relevant state
relevant tests
relevant invariants
```

### Phase 2 — Plan
State:

```
files to change
functions to change
tests to add/change
release gates affected
```

### Phase 3 — Implement
Make the smallest coherent change.

### Phase 4 — Verify
Run:

```
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Validate-Release.ps1
```

and relevant:

```
tests\Test-*.ps1
```

excluding known GUI-only tests.

The aggregate runner `Scripts\Invoke-TestSuites.ps1` runs every suite and excludes the GUI-only ones.

### Phase 5 — Inspect diff
Check:

```
git diff
git status
```

Specifically look for:

- unintended files;
- encoding changes;
- deleted code;
- accidental formatting;
- version changes;
- debug changes;
- generated files;
- `dist` changes.

### Phase 6 — Report
Report:

```
Changed
Tests
Release-gate result
Known limitations
Potential follow-up
```

---

# 44. Git safety
Never use destructive Git commands to "clean up" the workspace unless explicitly instructed.

Do not use:

```
git reset --hard
git checkout -- .
git clean -fd
```

as a convenience.

Before any operation that could overwrite work:

```
inspect status
inspect diff
preserve unrelated changes
```

Never assume uncommitted changes belong to you.

---

# 45. Current architectural priorities
These are the recommended development priorities. Status corrected 2026-10-02 against the tree (the
previous revision had drifted - three entries marked NOT IMPLEMENTED were done or partly done); see
Appendix A for per-invariant evidence.

## P0

1. Enforce zero UNAUTHORISED module-scope operation-state mutation outside approved state code. —
   **PARTIAL** (2 remain, both terminal-state writes the funnel must keep refusing; see SS9). The
   scheduler's `PendingOp` clear was converted to the funnel operation `-ClearPendingOp`.
2. Keep OperationId validation before mutation. — **ENFORCED** (gates (ah), (an)).
3. Preserve global concurrency admission. — **ENFORCED** (gates (ai), (ao), (ax)).
4. Preserve terminal-state protection. — **ENFORCED** (gate (ay)).
5. Preserve timeout/deadline semantics. — **ENFORCED** (gates (ab), (av)).
6. Fix documentation/version drift. — ongoing; the version is gated against the tag (SS18).

## P1

1. Formalise command result model. — **DONE**: `Wuu.Result.psm1` (6 functions) is the single model;
   command mode builds ONE result via `New-WuuCommandResult` and renders both JSON and prose from it.
2. Make JSON output a versioned API. — **PARTIAL**: the command-result JSON carries `schemaVersion`
   (`Wuu.Result.psm1`), but the READ verbs do not use the model — `audit verify`, `audit show` and
   `-WhatIf` each hand-build their own shape in `Wuu.Command.psm1` with no version field. A consumer
   therefore cannot write one stable parser. This is the remaining external-contract gap.
3. Implement/remove unreachable exit code contracts. — **DONE**: all of `0`–`7` have producers.
4. Improve pending-operation precedence. — **DONE**: semantic precedence in `Set-WuuPendingOperation`
   via `Get-WuuPendingOpRank` (SS16); a downgrade is declined and reported, an upgrade replaces.

## P2

1. Extract scheduler responsibility. — **PARTIAL** (`Wuu.Scheduler` owns the worker-helper surface only;
   the tick `Start-PendingUpdateCheck` and admission still live in `Wuu.WindowsUpdate`).
2. Reduce `Wuu.Core.psm1`. — **PARTIAL**: 4,129 -> 3,430 lines (Configuration, Presentation, Display
   actions, the job-cleanup payload and 6 code-less GUI regions have moved out). Still the largest
   file; the remaining regions all have real in/out coupling, so each move needs a measured plan.
3. Reduce `Validate-Release.ps1`. — **DONE**: 3,312 -> 265 lines; 12 fragments under `Scripts/`,
   dot-sourced in verdict order (two of them by another fragment, to keep that order).
4. Reduce worker duplication. — **PARTIAL** (one log appender; guard copies remain by necessity).

## P3

1. External audit anchoring. — **PARTIAL** (file-based anchor; no immutable/external store).
2. Better worker-pool diagnostics. — **IMPLEMENTED** (gate (at)).
3. More complete operation-deadline propagation. — **PARTIAL** (CIM and service probes only).

---

# 46. Definition of done
A change is NOT complete merely because the code runs.

A change is complete when:

- requested behaviour works;
- existing behaviour is preserved;
- PowerShell 5.1 compatibility is preserved;
- OperationId semantics remain correct;
- concurrency remains bounded;
- state transitions remain legal;
- audit behaviour remains correct;
- relevant tests pass;
- release gates pass;
- documentation reflects reality;
- no unrelated files changed;
- encoding remains correct.

For significant changes, also verify:

```
normal path
failure path
timeout path
stale-worker path
concurrent path
automation path
```

---

# 47. Final rule
When in doubt:

> **Preserve the invariant before improving the implementation.**

A smaller, slightly less elegant change that preserves the existing state/concurrency/audit model is preferable to a cleaner-looking rewrite that introduces an untested race.

The project's most important architectural contract is:

```
COMMAND
   ↓
ADMISSION
   ↓
OperationId
   ↓
WORKER
   ↓
RESULT
   ↓
IDENTITY VALIDATION
   ↓
STATE TRANSITION
   ↓
AUDIT
   ↓
RESULT / DISPLAY / EXIT CODE
```

New functionality should fit this model.

If it cannot, stop and explain why before changing the architecture.

---

# Appendix A. Invariant status

Invariant IDs `8.1`–`8.10` are identifiers, not section numbers: source comments and gate messages cite
them (for example "invariant 8.6"). **ENFORCED** means a `Scripts\Validate-Release.ps1` gate block fails if
the invariant regresses. Status is verified against the source, not the documentation.

| ID | Invariant | Status | Evidence |
| --- | --- | --- | --- |
| 8.1 | One active operation per computer | **ENFORCED** | `Test-WuuComputerBusy` at the submission point; gate (u); `Test-ComputerBusy`, `Test-SchedulerSerialization` |
| 8.2 | Every operation has a unique `OperationId` | **ENFORCED** | `New-WuuOperationId`, created before `BeginInvoke`, carried on the job entry and injected into the worker; gate (ah); `Test-OperationIdentity` |
| 8.3 | Stale workers cannot modify newer operations | **ENFORCED** | `Test-WuuOperationCurrent` (release) and `Test-WuuStaleWrite` (write), mirrored in six sites; funnel `Update-WuuOperationState` checks identity first; gates (ah), (an); `Test-OperationIdentity`, `Test-WuuOperationState` |
| 8.4 | Terminal operations stay terminal | **ENFORCED** | One ordered declaration (`Error` > `Timeout` > `Complete`) read by guard, classifier and checker; gate (ay); `Test-TerminalStates` |
| 8.5 | All per-computer remote execution goes through one submission point | **ENFORCED (narrow)** | `Start-UpdateCheckJob`; gate (x). The scheduler tick and direct handler calls both admit through it |
| 8.6 | Concurrency limits are absolute | **ENFORCED** | `Test-WuuConcurrencyAvailable` at the submission point and the scheduler tick; atomic reservation under the submission lock; pool ≥ cap; gates (ai), (ao), (ax); `Test-ConcurrencyCap`, `Test-SubmissionAtomicity`, `Test-PoolCompatibility` |
| 8.7 | Pending work is not silently discarded | **ENFORCED** | `Set-WuuPendingOperation`: one slot, semantic precedence via `Get-WuuPendingOpRank` (SS16) - an upgrade replaces and reports, a downgrade is declined and the higher request kept; gate (aj); `Test-PendingPolicy` |
| 8.8 | Credential identity is deterministic | **ENFORCED** | `Resolve-WuuOperationCredential`, no fallback on either resolver; gate (ad); `Test-CredentialDeterminism`, `Test-CredentialPropagation` |
| 8.9 | `WhatIf` causes no remote mutation | **ENFORCED** | returns before any handler and writes no audit record; gate (ae); `Test-WhatIfPlan`, `Test-AuditTrail` |
| 8.10 | Connectivity failure does not delete inventory | **ENFORCED** | consecutive-failure threshold, reset on success; gate (z); `Test-ConnectivityClassification` |
| — | Refusals are recorded, and a stalled refusal is diagnosed | **ENFORCED** | `Update-WuuRefusalRecord`, `Test-WuuRefusalStalled`; gate (ap); `Test-RefusalSemantics` |
| — | Inner probes respect the remaining operation budget | **PARTIAL** | CIM and service probes only; gate (av); `Test-RemainingBudget` |
| — | Audit chain head can be anchored outside the log | **PARTIAL** | file-based, tamper-evident only; gate (aw); `Test-AuditAnchoring` |
| — | Zero unauthorised module-scope operation-state writes | **PARTIAL** | 2 remain, both terminal-state writes the funnel correctly REFUSES (`settled -> Error` after a submission that never started; `settled -> Queued` for phase-wait bookkeeping). The scheduler's `PendingOp` clear routes through `Update-WuuOperationState -ClearPendingOp`. Gate (az) classifies by brace-matched payload RANGE, not by enclosing function, and fails if the count rises or an approved range stops resolving |
