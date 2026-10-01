# WUU2-CLI v1.5.0-beta.5-cli

**Makes invariant 8.4 real: terminal operations stay terminal.**

Same commands, same options, same engine as beta.4. This release closes the last unverified invariant from
the review response — and the reason it was unverified turned out **not** to be the reason the invariant's
wording suggests.

> **This is a PRERELEASE.** The version is stamped on every audit record, so a trail is self-identifying:
> `wuuVersion: v1.5.0-beta.5-cli` tells an auditor the evidence came from pre-release software.

One behaviour change, described below. It is a *safety* fix: it removes a way for a recorded failure to
be silently turned into a success.

---

## Read this first — a counted failure could become a counted success

Invariant 8.4 says a terminal operation stays terminal. The gate reported it as `NOT_IMPLEMENTED`, and on
inspection the fault was not the missing state names. **Three functions each decided independently what
"finished" meant, and they disagreed:**

| Function | What it treated as "finished" |
| --- | --- |
| `Test-WuuStateTransitionAllowed` | `Complete`, `Error` |
| `Get-WuuTargetOutcome` | `Complete`, `Error`, **and `Timeout`** |
| `Test-WuuOperationStateInvariant` | `Complete`, `Error` |

So a **timed-out row was a counted failure to the exit-code classifier and a freely-rewritable row to the
transition guard.** The sequence, which is worth reading because the severity is not obvious from "a guard
is inconsistent":

1. an operation times out; the row is settled as `TimedOut` by the classifier, which is what produces
   **exit code 4** (`PartialSuccess`) in a mixed fleet;
2. the guard did not consider `Timeout` terminal, so it allowed the transition;
3. and because the first version of the rule only refused terminal → **non**-terminal, even
   `Timeout` → `Complete` was permitted;
4. so an unattributed writer could convert a counted **failure** into a counted **success**, and nothing
   anywhere recorded that it had happened.

The third copy had a quieter effect: a timed-out row still queuing a `PendingOp` or still holding its
runspace lock was **not flagged at all** by the invariant checker.

### The fix is single-sourcing, not new state names

One **ordered** declaration in `src/Wuu.State.psm1` now carries three things that must not be stated
separately:

- **membership** — which states are terminal (`Error`, `Timeout`, `Complete`);
- **the outcome word** — `Error`→`Failed`, `Timeout`→`TimedOut`, `Complete`→`Success`;
- **precedence** — failure is judged **before** completion, so a stale `Complete` cannot mask a current
  `Error`.

The guard, the outcome classifier and the invariant checker all read it. The rule is now:

> An unattributed write may not **change** a terminal row's state — **including terminal → terminal**,
> which is the hole the first rule left open. Writing the *same* state again is bookkeeping, not a
> transition, and remains allowed.

**Retries are unaffected.** A retry is a *new operation* with a new `OperationId`, and an attributed write
may leave a terminal state. Terminal protects the row's **recorded outcome** from being rewritten by a
writer that cannot name its operation — not the operator's ability to retry.

### Why this is safe for every existing caller

Every production call site of the mutation funnel passes an operation id — verified across `src/`: the
submission point passes `-OperationIdNew`, the row-writers and the cleanup loop pass `-OperationId`, and
the out-of-band detach passes the id it holds. An unattributed write can therefore only come from a caller
that has no operation, which is precisely the writer that must not be deciding a settled row's outcome.

---

## Behaviour change — read this

**An unattributed write can no longer change a terminal row's state.** If you have tooling that writes
row state directly without an operation id, it will now be refused *for terminal rows* and the refusal is
logged. All in-tree callers are unaffected. Non-terminal rows behave exactly as before.

---

## Also in this release

**A release-gate check was asserting the wrong thing.** A check on the outcome classifier matched a
literal line of source plus the relative line offsets of two `return` statements. Once the mapping became
table-driven those literals no longer existed, so the gate reported a **false failure on a correct tree**
— the class of defect a gate must not have, because it trains people to ignore it. It now **drives** the
classifier on the rows that matter (an error in `State` only, an error in `UpdatesStatus` only, and a
stale `Complete` alongside a current `Error`), which is strictly stronger *and* cannot fail correct code.
Structural ordering is still enforced, by requiring `Complete` to be declared **last** in the terminal
table.

**`Wuu.State.psm1` is now deliberately pure ASCII.** It shipped with no UTF-8 BOM, and the release gate
requires a BOM on any file containing non-ASCII bytes. Rather than add a BOM to an ASCII file, the section
reference that introduced the non-ASCII was written out in words.

**One honest `NOT_IMPLEMENTED` remains, and it is a documentation gap, not a behaviour gap.** §8.4 names
five terminal states; three exist under the names above. The other two are **intentionally not states**:

| §8.4 name | Status |
| --- | --- |
| `Cancelled` | **No producer.** There is no operator-facing cancel of a *running* operation. The one "cancelled" in the codebase is a declined UAC prompt; a pre-flight denial is recorded as a *refusal*. Adding the state would create one nothing can reach. |
| `Refused` | **Not a state, by design.** A refusal is a *pre-flight* outcome — the operation never started, so the row has no terminal workflow position. It is recorded as `RefusedCount` / `RefusedReason` / `RefusedAt`. A `State='Refused'` would duplicate that record and create a second source of truth. |

**Action:** §8.4's wording should be updated to name the states that exist. That is an edit to
`.github/copilot-instructions.md`, deliberately not bundled into a behavioural fix. Full detail is in
[`docs/STATE-MACHINE.md`](https://github.com/dazzo31/WUU2-CLI/blob/v1.5.0-beta.5-cli/docs/STATE-MACHINE.md)
sections 2a and 2b.

---

## Verification

| Check | Result |
| --- | --- |
| Release gate | **169 verdicts — PASS 167, FAIL 0, WARN 0, SKIP 1, NOT_IMPLEMENTED 1** |
| Behavioural suites | 43 run, 42 pass, 1 skip, **0 FAIL** |
| Assertions | **1175 pass, 0 fail** (was 1110) |
| Tautology proofs | **13/13** mutations caught by *both* the gate and the suite |

The four mutations proved for this release: revert the guard to the loose rule; drop `Timeout` from the
terminal declaration; reintroduce a second copy of the terminal set; and reorder the declaration so
`Complete` precedes `Error`.

The `SKIP` is the version guard, which declines to compare between release tags. The single
`NOT_IMPLEMENTED` is the §8.4 wording gap described above.

---

## Known limits

- §8.4's wording names states that do not exist (see above) — a documentation gap, reported rather than
  papered over.
- `Wuu.Core.psm1` remains a ~4200-line "god module". Decomposition is a structural change and was again
  not attempted inside a focused release.
- PowerShell 7 is **uncertified**. The shipped engine is Windows PowerShell 5.1.

---

**Full detail:** [`RELEASE_NOTES_v1.5.0-beta.5-cli.md`](https://github.com/dazzo31/WUU2-CLI/blob/v1.5.0-beta.5-cli/docs/RELEASE_NOTES_v1.5.0-beta.5-cli.md) ·
**Diff:** [`v1.5.0-beta.4-cli...v1.5.0-beta.5-cli`](https://github.com/dazzo31/WUU2-CLI/compare/v1.5.0-beta.4-cli...v1.5.0-beta.5-cli)
