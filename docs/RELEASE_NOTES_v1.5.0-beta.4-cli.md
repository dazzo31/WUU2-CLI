# WUU2-CLI v1.5.0-beta.4-cli

**Response-to-review build.** The 18 findings of an external code review, addressed in priority order,
plus three defects found while doing it.

Same commands and same engine as beta.3. What changes is that several invariants which were *described*
are now **enforced**, and two silent failures were removed.

> This is a PRERELEASE. The version is stamped on every audit record, so a trail is self-identifying:
> `wuuVersion: v1.5.0-beta.4-cli` tells an auditor the evidence came from pre-release software.
> Do not reuse this string for a final release.

---

## Read this first: the defect that produced a WRONG DIAGNOSIS

**The worker pool was smaller than the concurrency cap.** `MaxConcurrentJobs` was 10; the pool had 8
workers.

Bounded probes (WMI / CIM / service / ping) are dispatched from inside the per-computer worker
runspaces, so the pool is what must run them. With a pool of 8 and a cap of 10, up to two admitted
operations had probes that could never start - and the failure was **silent in the worst way**. The cap
had already counted those operations as *running*, so:

- nothing was refused, so no refusal was recorded;
- nothing errored, so nothing was logged;
- the probe simply queued, and from the operator's side it presented as **a slow host**.

The investigation therefore went to the host, which was not the problem.

### How it survived

The two modules contradicted each other **in writing**:

| Where | Claim |
| --- | --- |
| `Wuu.Workers` above `$MaxPoolSize` | capacity "must comfortably exceed" `$MaxConcurrentJobs` - then set it *below* |
| `Wuu.State` above `MaxConcurrentJobs` | "NOT a bound on the worker pool (Wuu.Workers sizes its own pool separately)" |

Neither statement was checked by anything, and prose cannot fail a build. Both are now replaced by one
stated relationship, **pool size >= concurrency cap**, enforced by `Test-PoolCompatibility` and by gate
block (ax). The values are aligned at 10.

**If you operate this at scale and ever saw "slow hosts" that answered fine afterwards, this is a
candidate explanation.** A pool larger than the cap is harmless (a job's probes are sequential, so it
holds one slot at a time); a pool smaller than the cap is the defect, and the gate now fails on it.

---

## P0 - correctness

| Finding | Resolution |
| --- | --- |
| Debug logging defaulted `$true` while its comment claimed `$false` | default is `$false`; `WUU_DEBUG` overrides |
| No validation that the embedded version matched the released tag | `Resolve-WuuVersion` + gate: a mismatch fails the release |
| Four fatal paths `Read-Host 'Press Enter to exit'` then exited **0** | `Stop-WuuFatal`; a fatal exit reports failure |
| Version not single-sourced | one `$global:WuuVersion`, read by the banner and every audit record |

## P1 - state ownership

The reviewer's architectural conclusion drove this: *workers never directly own application state; one
state-transition layer validates `OperationId` and owns all state mutation.*

- **`Update-WuuOperationState` is the single mutation funnel.** Before it, six writers mutated operation
  state and 46 direct `$Computer.<prop> = ...` assignments bypassed all of them, so "a superseded
  operation cannot write" was true of **two of six** producers. Identity is checked *first* (before the
  transition rule), **nothing is written when refused**, and a refusal is an expected outcome rather
  than a fault.
- **The concurrency-slot reservation is atomic.** The cap was tested at the top of the submission path
  but consumed ~140 lines later at `$jobs.Add`, so a cap of 10 could start 12. The claim, the identity
  stamp and the append now happen under one lock.
- **Refusals are recorded and diagnosed.** A permanently-refused computer used to leave its phase gate
  blocked for ever with nothing saying why. A refusal is *not* an error - the operation never started and
  retrying is correct - so it is reported as a **stall** (consecutive refusals past a threshold) with the
  reason and count, not reclassified as a failure.
- **Every async write is identity-guarded**, proven per producer.

## P2 - structure

- **Silent `catch {}` is now policed.** A justified few remain, each with a stated reason; the rest were
  fixed.
- **Four copies of the log lock-and-retry loop became one** (`Get-WuuWorkerLogAppender`), and the
  duplicated worker-helper scriptblocks moved into `Wuu.Scheduler`.
- **Historical commentary relocated** - with one exception, deliberately. Of 4113 comment lines in
  `src/`, the long runs turned out to be module-header *contracts*, comment-based help (which `Get-Help`
  reads), and rationale at the site. Acting on the finding as written would have deleted load-bearing
  constraints, including the one about payload runspaces documented below. The single genuine history
  block was also **factually wrong** - `Wuu.Core`'s header described the file as a GUI application with a
  2016 author and a 40-line GUI changelog, in a tree the gate asserts contains no WPF or `ui` references.
  See `docs/CODE_COMMENT_POLICY.md`.

## P3 - observability

- **Worker-pool diagnostics**: capacity, utilisation, and abandoned wrappers. Abandoned wrappers matter
  because each permanently holds a slot until a stuck call returns, so sustained abandonment walks
  capacity to zero - which also presents as "every host is slow".
- **Remaining-budget propagation.** An operation's deadline was enforced only at the outermost level,
  so an operation **one second from expiry still started a 30-second probe** - holding a pool slot 29
  seconds after the cleanup loop had given up, and reporting a timeout for a host that was merely slow
  at the wrong moment. An inner probe now takes `min(own timeout, remaining budget)`, behind a floor, and
  a missing deadline means *do not cap* (never a fabricated zero).
- **External audit anchoring.** A hash chain is tamper-evident only to someone who already knows what the
  head was: anyone with write access to the log *and* the code can rebuild a complete, internally
  consistent chain, and `Test-WuuAuditChain` then reports a clean log. `New-WuuAuditAnchor` holds the head
  somewhere the log's editor does not control, refuses to anchor *beside* the log (which would prove
  nothing while appearing to), and records that it is tamper-evident - **not** non-repudiation.

## P4 - tooling

`Validate-Release.ps1 -Json` emits a machine-readable report, and five verdict kinds make "did not run"
(`SKIP`) and "no verifier exists" (`NOT_IMPLEMENTED`) distinguishable from `PASS`. CI consumes the report
and runs the behavioural suite **once** (it previously ran twice).

---

## Verification

| Check | Result |
| --- | --- |
| Release gate | 164 verdicts - PASS 163, FAIL 0, WARN 0, SKIP 0, NOT_IMPLEMENTED 1 |
| Behavioural suites | 42 run, 41 pass, 1 skip, 0 FAIL |
| Assertions | 1110 pass, 0 fail |
| Tautology proofs | 9/9 mutations caught by both the gate and the suite |

The single `NOT_IMPLEMENTED` is invariant 8.4: it names five terminal states and only two exist
(`Complete`, `Error`). Naming the others is a state-machine change, so it is reported rather than claimed.

There is no `SKIP` here, and that is worth noting: the `SKIP` in beta.3 was the version guard declining to
compare off a release tag. It now compares the embedded literal against the tag created for this release,
so the check actually evaluates - and it passes.

---

## Behaviour changes to be aware of

1. **Refused operations are reported as stalls** after a threshold instead of waiting silently for ever.
   If you had a permanently-refused target, it will now be diagnosed in the log.
2. **Inner probes may use a shorter timeout than their own** when the operation is near its deadline. A
   probe near an expiring budget is bounded by the budget - by design, so that it cannot outlive the
   operation that owns it.
3. **A fatal error now exits non-zero.** Anything parsing the exit code should see the difference.

---

## Known limits

- Invariant 8.4 (`Cancelled` / `Refused` / `Failed` / `TimedOut` as terminal *states*) is not
  implemented; refusals are recorded on the row, not as a state.
- `Wuu.Core.psm1` remains a ~4200-line "god module". Decomposition is a structural change and was
  deliberately not attempted inside a review-response build.
- PowerShell 7 is uncertified. The shipped engine is Windows PowerShell 5.1.
