# WUU2-CLI Testing

> ## How to read this document
>
> **Part A** describes the test suite as it exists — the runner, the conventions, and what the current
> tests actually prove.
> **Part B** lists the tests that do **not** exist yet and are needed before the target invariants can
> be called ENFORCED.
>
> The per-invariant status is in [`.github/copilot-instructions.md`](../.github/copilot-instructions.md) Appendix A.
> A green suite is evidence about *current* behaviour; it is not evidence that a TARGET invariant holds.

---

# Part A — Current test suite

## 1. No Pester

The shipped test suite is plain PowerShell. Each suite:

* prints `PASS: <check>` or `FAIL: <check>` lines — **mostly**; see the exceptions below;
* exits `0` when everything passed and `1` when anything failed.

Pester is installed on some developer machines but **nothing in the repository depends on it**. Do not
add a Pester dependency to a shipped test.

### Two output styles, and one suite that is not really a test

A runner that greps for `^PASS:` will misreport the following. All three exit `0`:

| Suite | Output style | Verdict |
| --- | --- | --- |
| `Test-AutoFlowChain` | `PASS [key]: ...` | real assertions, different prefix — **counts** |
| `Test-CredentialTyping` | `PASS A: ...` then `RESULT: 4 passed, 0 failed` | real assertions, different prefix — **counts** |
| `Test-ModuleImport` | `IMPORTED ...` / `OK ...` / `MISSING ...` | **not a suite** — see below |

> **`Test-ModuleImport.ps1` cannot fail by assertion.** It imports each module (throwing only on an
> import error) and then prints `OK <cmd>` or **`MISSING <cmd>` in red** for six required commands.
> It never sets `$LASTEXITCODE` and never exits non-zero on a missing command.
>
> A scripted runner therefore reports it **PASS** even when a required command is gone. It is a smoke
> test for imports, not a regression test, and it must not be counted as coverage for the commands it
> names. Either add real exit codes or stop citing it as evidence.

When assessing a suite, confirm it can **fail**. A test that cannot fail is worse than no test, because
it is counted as protection.

## 2. Running the tests

**There is no aggregate runner.** Each suite is executed individually. To run everything applicable:

```powershell
Get-ChildItem .\tests\Test-*.ps1 |
    Where-Object { $_.Name -notin @('Test-ColumnResize.ps1','Test-DragResize.ps1') } |
    ForEach-Object { powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $_.FullName }
```

To run one suite:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-ComputerBusy.ps1
```

**Baseline:** 30 test files; 2 excluded because they are GUI-edition leftovers; **28 runnable**;
**27 pass / 1 skip / 0 fail**.

> Do not document or invoke a `Run-AllTests.ps1` — no such file exists. An earlier revision of this
> document named one; the reference was wrong for exactly one revision and was corrected here.

### Two stale GUI suites

`tests\Test-ColumnResize.ps1` and `tests\Test-DragResize.ps1` exercise WPF column drag-resize, which
does not exist in the console edition. ColumnResize **fails** on missing WPF assemblies; DragResize
**hangs** (blocking dispatcher pump). Both are excluded from the loop above and both should be deleted.

### Timeout the loop

Wrap a per-suite timeout with straggler cleanup around the loop. One hung suite must not stall a full
run — this is not hypothetical; DragResize hangs indefinitely.

## 3. The validator

`Scripts\Validate-Release.ps1` is the release gate and is stricter than the tests. It asserts source
shape (patterns that must exist, patterns that must not), not runtime behaviour. Both must pass.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Scripts\Validate-Release.ps1
```

## 4. Elevation-dependent tests

`Test-RemoteTask` (and anything that would need local WUA elevation or a remote target) **skips when
the required privileges are absent**, prints `SKIP:` and **exits 0**.

That is deliberate:

* a skip is not a failure — it is "not applicable in this environment";
* exit 0 keeps an unelevated developer from seeing a false red suite;
* **do not "fix" this** by making an unelevated run fail, and do not report the skip as coverage.

A skipped test proves nothing. When quoting evidence, say "skipped in this environment".

## 5. What the current tests prove

| Area | Coverage | Notes |
| --- | --- | --- |
| Per-computer busy gate (8.1) | **asserted** | `Test-ComputerBusy`, `Test-SchedulerSerialization` |
| Credential determinism (8.8) | **asserted, strong** | `Test-CredentialDeterminism` (30 assertions) + `Test-CredentialPropagation`; includes a differential driving the module-side and runspace-side resolvers on identical inputs |
| Single submission point (8.5) | **asserted** | shape check, plus validator gate (x) |
| `WhatIf` (8.9) | **asserted** | validator gate (ae) |
| Connectivity ≠ deletion (8.10) | **asserted** | threshold + reset |
| Timeouts (gate ab) | **asserted** | deadline recorded at submission and enforced by the cleanup loop |
| Exit codes | **asserted** | validator gate (aa) |
| Workflow state vs display state | **asserted** | validator gate (ac) |
| Reboot / cancellation | **asserted** | validator gate (ag) |
| Encoding / BOM | **asserted** | validator gate (af); measured per file |
| Migration debris (SS14) | **asserted** | gate (al): the GUI-era `SafeUpdateListViewItem` name is gone and both row-writer copies carry the accurate name |

## 6. Method: how these tests were verified

Two checks produced **false positives** during this work. Both were caught, and both are worth
repeating here:

**(a) Count assertions, not words.** Grepping for `OperationId` in `tests\` returns matches — the
string appears in fixture setup and in comments. Counting *assertion lines* yields **0**. A test can
mention a symbol without asserting anything about it.

**(b) Strip comments before pattern matching.** A predicate that searches source for a forbidden
pattern will match the comment explaining why the pattern was removed. This has now happened four
times in this repository: the §8 predicate, the §6 `CredentialConfig` read, a "never a password" check
matching a block comment, and the Phase 1 removed guard.

Before pattern-matching PowerShell source, strip both `#` line comments and `<# #>` block comments.
Two helpers exist in the validator for this:

* `Get-WuuTextWithoutComments` — strips both styles, **preserves newlines and `$`**. Use this for
  slicing function bodies.
* `Get-WuuCodeWithoutComments` — tokenizer-based; **discards newlines and drops `$`**. Accurate for
  presence checks, unusable for positional slicing.

**(c) "The word appears in `Validate-Release.ps1`" is not a gate.** The validator's single mention of
`MaxConcurrentJobs` is inside a comment. Check that a gate contains real assertions about the thing it
names.

## 7. Concurrency tests

Concurrency tests must not depend on wall-clock timing.

**`Start-Sleep` is not a synchronisation primitive.** Prefer:

* polling the observable state with a bounded deadline;
* injecting a completion signal;
* asserting the invariant (e.g. `jobs.Count`) rather than a timing window.

A `Start-Sleep` long enough to pass reliably is a slow test; one short enough to be fast is flaky.

## 8. Test names should describe behaviour

Prefer:

```text
per-computer busy gate refuses a second submission
```

over:

```text
Test-ComputerBusy-2
```

**But a name is not evidence.** A test named "rejects stale worker results" that only drives the
per-computer gate asserts nothing about staleness. When a name promises an invariant, the body must
drive that invariant.

## 9. Assertions should be specific

Check the message, the state value, or the returned object — not merely that a call succeeded. A
broad catch-and-assert-no-throw will hide the regression it was written to catch.

## 10. Test isolation

Each test should run without depending on another test's side effects. Avoid global state leakage:
reset shared state (`$global:CredentialCache`, `$global:CredentialEpoch`, the state store) at the
start of a run, not merely at the end of a previous one.

## 11. Encoding in tests

Read source as UTF-8 with BOM awareness. Files containing non-ASCII bytes must keep their BOM —
`Set-Content` under PowerShell 7 writes BOM-less and will corrupt them. Assert on **bytes** when the
test is about encoding.

---

# Part B — Tests needed for the TARGET invariants

These do not exist. Their absence is why the corresponding invariant is TARGET rather than ENFORCED.

| Target invariant | Test to write | Why it cannot pass today |
| --- | --- | --- |
| 8.4 terminal states are terminal | every transition out of `Complete`/`Failed`/`TimedOut`/`Cancelled`/`Refused` is rejected | no transition guard exists, and four of those names are not `State` values |

**8.2, 8.3, 8.6 and 8.7 are no longer on this list** — they are implemented and enforced:

| Invariant | Suite | Assertions |
| --- | --- | --- |
| 8.2 operation identity, 8.3 stale-worker rejection | `tests\Test-OperationIdentity.ps1` | 61 |
| 8.6 absolute concurrency cap | `tests\Test-ConcurrencyCap.ps1` | 20 |
| 8.7 pending-request policy | `tests\Test-PendingPolicy.ps1` | 42 |

Each has a validator gate alongside it ((ah), (ai), (aj)). The identity and pending suites use a
**differential**: they extract each shipped guard condition from source and drive it on a truth table
against the function it must mirror, so an inlined copy that drifts fails. The cap suite drives the
**real submission point** — the path the cap was missing on — rather than the scheduler.
`tests\Test-OperationIdentity.ps1` (61 assertions) proves operation identity exists and that a proven
stale writer is refused. Its core is a differential that extracts each of the six shipped guard
conditions from source and drives it on a truth table, so an inlined copy that drifts from the module
function fails.

Rules for these tests:

* state the invariant in the test name;
* drive the invariant, not the nearest gate;
* assert on observable state, not private variables;
* fail if the mechanism is absent — do not skip when the feature is missing, because that would
  reproduce the "green suite implies enforcement" problem this section exists to prevent.

## Sequencing

Phase 2 introduced the operation identity, so the release/write rules now have something to compare.
The admission cap (Phase 3) and the pending-work policy (Phase 4) are independent and can land first.
Terminal-state protection (Phase 6) still needs the operation **record** (§7 of the state machine),
not merely the identity.

See `docs/DEVELOPMENT.md` for the phase boundaries.
