# WUU2-CLI Operation State Machine

> ## Status: this is the TARGET model
>
> **Nothing in §2–§10 is implemented today.** There is no operation record and no `OperationId`, so
> the state machine below has nowhere to live. What the code actually stores is in §11 — read that
> first if you are writing code.
>
> The authoritative status of each invariant is in
> [`.github/copilot-instructions.md`](../.github/copilot-instructions.md) §8. The work to implement
> this model is Phases 2–5 of the hardening plan (see `docs/DEVELOPMENT.md`).
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

# 7. Operation identity (TARGET)

Every operation has a unique identity, and a state mutation originating from asynchronous work must be
associated with it:

```powershell
if ($worker.OperationId -ne $current.OperationId) {
    # stale result
    # do not modify current operation
}
```

The implementation may use a stronger abstraction, but the invariant must remain.

**Current:** no identity exists. Invariant 8.1 (one operation per computer) makes the scenario
unreachable, which is why this has not caused a visible failure — and why it is untested rather than
safe.

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

**Current:** Case C cannot arise (8.1 permits one operation per computer). Cases A and B are
*partially* handled by the cleanup loop's ordering — a settled completion is evaluated before the
deadline — but that is a timing arrangement in one loop, not an identity-checked guarantee.

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
