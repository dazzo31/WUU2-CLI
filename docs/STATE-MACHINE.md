# WUU2-CLI Operation State Machine

> ## Status: this is the TARGET model
>
> **Nothing in §2–§6 is implemented today.** There is no operation **record**, so the state machine
> below has nowhere to live — an operation's state is a per-computer `State`/`OpState` pair, not a
> lifecycle. What the code actually stores is in §11; read that first if you are writing code.
>
> **The operation identity does exist** (Phase 2): `OperationId` is created per submission and both
> release and write rules enforce it (§7). Identity is not a state machine, though — terminal-state
> protection and the transition table above still need the record.
>
> The authoritative status of each invariant is in
> [`.github/copilot-instructions.md`](../.github/copilot-instructions.md) Appendix A. The work to implement
> this model is Phases 4 and 6 of the hardening plan (see `docs/DEVELOPMENT.md`).
>
> Do not write code that assumes these states exist, and do not describe them as current behaviour.

---

# 1. Purpose

This document defines the intended lifecycle of a remote operation.

The state machine exists to prevent:

* duplicate execution
* stale worker updates
* unsafe retries
* ambiguous timeout behaviour
* terminal-state resurrection
* incorrect success reporting

---

# 2. States (TARGET)

```text
Queued
Running
Complete
Failed
TimedOut
Cancelled
Refused
```

`Refused` is terminal and represents an operation that was not permitted to execute according to
application policy.

---

## 2a. Terminal states (CURRENT, ENFORCED) — invariant 8.4

Section 2 above is the TARGET vocabulary. What is **enforced today** is narrower, and the difference
matters because two functions used to define "finished" differently — see §2b. The single declaration is
`$script:WuuTerminalStates` in `src/Wuu.State.psm1`, read by the transition guard, by the outcome
classifier and by the invariant checker. Its ORDER is load-bearing: failure is judged before completion,
so a stale `Complete` cannot mask a current `Error`.

| Terminal state | Outcome word | Why |
| --- | --- | --- |
| `Error` | `Failed` | judged **first**, so it wins over a stale `Complete` on the same row |
| `Timeout` | `TimedOut` | recoverable, but not freely **rewritable** — see below |
| `Complete` | `Success` | judged **last**, deliberately |

Not terminal: `RebootRequired` (transient — `RebootRequired` → `Rebooting` → `Complete`), and every
in-flight state.

### Why `Timeout` is terminal even though it is recoverable

These are different questions, and conflating them produced the 8.4 defect:

* **Recoverable** means a retry is the right response. A retry is a **new operation** with a new
  `OperationId`, and the guard permits a terminal state to be left by an attributed operation. Retries
  are therefore unaffected.
* **Terminal** means an **unattributed** writer may not change the state. That is what stops a settled
  outcome being rewritten by a writer that cannot name the operation it belongs to.

### The rule, exactly

An unattributed write (`-OperationId` empty) is refused when the row is terminal **and the target state
differs** — including terminal → terminal. Writing the *same* state again is bookkeeping, not a
transition, and is permitted. `Timeout` → `Complete` was the specific hole: it is terminal → terminal, and
because the classifier already counted a timed-out row as a settled failure, permitting it let a counted
failure become a counted success with nothing recording the change.

### Section 8.4 names states that do not exist — deliberately

`Failed`, `TimedOut` and `Complete` exist under the names in the table above. The other two are
**intentionally not states**, and the release gate reports this (one `NOT_IMPLEMENTED` verdict) so it is
not mistaken for enforcement:

| Name in the former §8.4 wording | Status |
| --- | --- |
| `Cancelled` | **no producer.** There is no operator-facing cancel of a **running** operation. The one "cancelled" in the codebase is a declined UAC prompt, and a pre-flight denial is recorded as a *refusal*. Adding the state would create something nothing can reach. |
| `Refused` | **not a state, by design.** A refusal is a *pre-flight* outcome: the operation never started, so the row has no terminal workflow position. It is recorded as `RefusedCount` / `RefusedReason` / `RefusedAt`. A `State='Refused'` would duplicate that record and introduce a second source of truth. |

**Resolved:** `.github/copilot-instructions.md` §12 now names the terminal states that exist (`Complete`,
`Timeout`, `Error`) and forbids inventing `Cancelled` or `Refused` as states.

### 2b. What the defect was

`Test-WuuStateTransitionAllowed` treated only `Complete` and `Error` as terminal, while
`Get-WuuTargetOutcome` **also** treated `Timeout` as settled and counted it toward exit code 4. A third
copy of the same literal sat in `Test-WuuOperationStateInvariant`, where it meant a timed-out row still
queuing a `PendingOp` or still holding the runspace lock was not flagged at all.

So a timed-out row was a **counted failure to the exit-code classifier** and a **freely-rewritable row to
the guard**. The fix is single-sourcing — not new state names. `tests/Test-TerminalStates.ps1` drives both
functions across the whole canonical vocabulary, and gate block (ay) asserts that no second copy survives,
so the two cannot diverge again.

---

# 3. State diagram (TARGET)

```text
                         ┌──────────────┐
                         │    Queued    │
                         └──────┬───────┘
                                │
                   ┌────────────┴────────────┐
                   │                         │
                   ▼                         ▼
             ┌───────────┐             ┌───────────┐
             │  Running  │             │ Cancelled │
             └─────┬─────┘             └───────────┘
                   │
       ┌───────────┼────────────┬──────────────┐
       │           │            │              │
       ▼           ▼            ▼              ▼
   Complete      Failed      TimedOut      Cancelled
```

`Refused` may occur before execution where policy prevents the operation from starting.

---

# 4. Valid transitions (TARGET)

| From    | To        | Meaning                                                   |
| ------- | --------- | --------------------------------------------------------- |
| Queued  | Running   | Scheduler admitted operation                              |
| Queued  | Cancelled | Operation cancelled before execution                      |
| Queued  | Refused   | Policy prevented execution                                |
| Running | Complete  | Operation succeeded                                       |
| Running | Failed    | Operation executed but failed                             |
| Running | TimedOut  | Operation exceeded its deadline                           |
| Running | Cancelled | Operation was cancelled                                   |
| Running | Refused   | Execution was refused according to the operation contract |

The exact distinction between `Failed` and `Refused` must remain consistent with the application
contract — note that `Refused` already exists as **exit code 7** and as an audit outcome, which is the
closest thing to it today.

---

# 5. Invalid transitions (TARGET)

Never valid:

```text
Complete  → Running
Complete  → Queued

Failed    → Running
Failed    → Queued

TimedOut  → Running
TimedOut  → Queued

Cancelled → Running
Cancelled → Queued

Refused   → Running
Refused   → Queued
```

A retry is a new operation.

**No such guard exists today.** Enforcing this requires the operation record from §7.

---

# 6. Retry (TARGET)

Retry must create a **new `OperationId`**:

```text
Operation A: Running → TimedOut
Operation B: Queued  → Running
```

Operation A remains `TimedOut`; it must never be converted into Operation B.

---

# 7. Operation identity (CURRENT for the identity, TARGET for the operation record)

**The identity now exists (Phase 2).** Every submission creates a `OperationId` via
`New-WuuOperationId`, stamps it on the row and on the job entry, and injects it into the worker
runspace as `$WuuOperationId`. A state mutation originating from asynchronous work is therefore
associated with it:

```powershell
# the rule, in Wuu.State:
Test-WuuOperationCurrent -Row $current -OperationId $worker.OperationId   # release only if owned
Test-WuuStaleWrite      -Row $current -OperationId $writer.OperationId    # refuse only if provably stale
```

These are **two rules, not one**, and deliberately so - see the description of `Test-WuuStaleWrite` in
`src/Wuu.State.psm1` for the asymmetry and why collapsing them breaks a side.

The rule is written in **six** places, because the cleanup loop and the injected row-writer run in
isolated runspaces where no module function resolves. Gate (ah) asserts each copy exists;
`tests\Test-OperationIdentity.ps1` drives each shipped condition so a drifted copy fails.

**What is still TARGET:** the **operation RECORD** in §7's list (RequestedAction, CredentialContext,
CreatedAt, Result, AuditContext as one object). Identity exists; the record it would live on does not.
Per-computer row fields remain the only granularity, so §4's transition table and §5's terminal-state
rejections above are still not implementable - they need that record.

---

# 8. Timeout (TARGET)

A timeout is a **state transition**, not merely a UI message:

```text
Running → TimedOut
```

The operation becomes terminal. A worker that continues after the deadline must be treated as stale if
a replacement operation has since been created.

**Current:** the deadline *is* enforced (per-operation budget, recorded at submission, with a
heartbeat), and a timed-out computer is marked `State='Timeout'`. What is missing is the operation
record this section assumes.

---

# 9. Timeout race (TARGET)

### Case A

```text
worker completes → completion accepted → timeout arrives
```

The timeout must not turn a completed operation back into an active or failed state.

### Case B

```text
timeout accepted → worker completes
```

The late worker must not change the terminal timed-out operation in a way that violates the contract.

### Case C

```text
timeout → retry → new operation running → old worker completes
```

The old worker must not modify the new operation.

**Current:** Case C is now **guarded** (Phase 2): the old worker holds a different `OperationId, so
both the release rule (`Test-WuuOperationCurrent`) and the write rule (`Test-WuuStaleWrite`) stop it
touching the new operation's row. Cases A and B are additionally protected by the cleanup loop's
ordering, but that ordering is a timing arrangement in one loop; the identity check is what makes the
rejection deliberate rather than incidental.

---

# 10. Cancellation (TARGET)

Cancellation must have clear ownership.

```text
Queued  → Cancelled      (while queued)
Running → Cancelled      (while running)
```

A cancellation must not accidentally cancel a replacement operation, so it should be associated with
`OperationId`, not merely a computer name.

**Current:** there is **no `Cancelled` state**. Cancellation exists as (a) an exit code (7), (b) a
queued-work clear on an unreachable computer, and (c) `Pending` being dropped. None of these is an
operation lifecycle transition.

The association this section asks for now **exists** (Phase 2): a cancellation or release can name the
`OperationId` it belongs to, which is what stops it cancelling a replacement operation. What is still
missing is the `Cancelled` state itself, and that needs the operation record.

---

# 11. What the code actually stores today (CURRENT)

There is no operation record. State lives on the **computer row**, in two separate fields:

| Field | Values the code writes | Role |
| --- | --- | --- |
| `State` | `Queued`, `Connecting`, `Connected`, `Checking`, `UpdatesFound`, `Downloading`, `Installing`, `RebootRequired`, `Rebooting`, `Complete`, `Error`, `Timeout`, `Offline` | workflow/presentation label |
| `OpState` | `Idle`, `Running` | whether a pipeline is in flight — what the per-computer gate reads |

Alongside these, the fields that behave like the target model's per-operation data:

| Field | Role |
| --- | --- |
| `Pending`, `PendingOp` | the **single** deferred-work slot |
| `TimeoutExpiresAt`, `TimeoutSource`, `OpName` | the deadline, recorded at submission, read by the cleanup loop |
| `LastHeartbeatAt`, `Heartbeats` | liveness, so "slow" is distinguishable from "stuck" |
| `CheckConcluded` | three-state workflow predicate (`$null` = not established) used by phase gating |
| `CredentialEpoch`, `CredentialIdentity` | the identity a reused runspace was built with |
| `OperationId` | the operation that CURRENTLY owns this row, stamped at submission (Phase 2) |

Mapping from the target names to what exists:

| Target state | Today |
| --- | --- |
| `Queued` | `State='Queued'`, or `Pending=$true` |
| `Running` | `OpState='Running'`, with `State` showing the phase |
| `Complete` | `State='Complete'` (+ `CheckConcluded=$false`) |
| `Failed` | `State='Error'` |
| `TimedOut` | `State='Timeout'` |
| `Cancelled` | **nothing** — not represented |
| `Refused` | exit code 7 / audit outcome — not a row state |

Consequences to respect:

* do **not** write `Failed`/`TimedOut`/`Cancelled`/`Refused` into `State`;
* `State` is display-oriented — decisions must come from workflow fields (this was a real defect,
  gate (ac));
* `OpState` answers exactly one question ("may another operation be submitted?") and must not be
  overloaded.

---

# 12. Pending work

Pending work must have explicit semantics. The policy must be chosen, documented and tested.

Today there is a **single** `PendingOp` slot, assigned in place, so a second request silently replaces
the first. Reproduced: a `download` request against a busy computer followed by an `install` request
leaves `PendingOp='InstallAndRecheck'` with nothing reported.

Candidate policies (choose one, document it, test it — this is Phase 4):

* reject the duplicate request, reporting it;
* merge compatible requests;
* queue distinct requests (a real per-computer queue);
* cancel the old request and replace it, reporting that.

**Current:** none of these is implemented. Do not rely on pending work being preserved.

---

# 13. Result semantics (TARGET)

A worker finishing does not automatically mean `Success`. The final state must reflect the actual
result:

```text
worker completed + remote operation failed   = Failed
worker completed + deadline already passed   = TimedOut
```

The latter must also preserve stale-result protection.

**Current:** mostly present in effect — the cleanup loop distinguishes completion, failure and
deadline — but expressed against the per-computer fields in §11 rather than the target model.

---

# 14. Tests required for state-machine changes

Any change to operation state should include tests for:

1. normal success
2. normal failure
3. queued cancellation
4. running cancellation
5. timeout
6. retry after timeout
7. late old-worker completion
8. duplicate operation admission
9. terminal-state protection
10. concurrent submissions
11. operation identity mismatch

Tests should prove observable behaviour rather than implementation details, and the name must describe
the invariant it protects (see `docs/TESTING.md`).

> **Beware the word test.** A test whose name mentions stale workers or terminal states while driving
> only the per-computer gate asserts nothing about staleness or terminality. Check what a test
> *exercises*, not what it is called.
