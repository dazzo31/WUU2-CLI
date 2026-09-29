# WUU2-CLI Development Guide

> ## How to read this document
>
> This guide is written for humans **and** LLM coding agents.
>
> It describes two different things and the difference matters:
>
> * **CURRENT** — the workflow, commands and constraints that are true today.
> * **TARGET** — the invariants and behaviour the project is working toward.
>
> **Phases 2–6 of the hardening plan are implementation work, not established behaviour.** The
> invariants they describe (operation identity, stale-worker protection, terminal-state protection,
> the absolute concurrency cap, the pending-work policy) **do not exist in the code today**. Read the
> status table in [`.github/copilot-instructions.md`](../.github/copilot-instructions.md) §8 before
> assuming any invariant is real.
>
> Do not describe an unimplemented invariant as current behaviour. When implementing a change, work
> toward the target invariant without assuming it already exists.

---

# 1. Purpose

This document defines the development workflow for humans and LLM coding agents.

The objective is to make changes:

* small
* reviewable
* testable
* deterministic
* compatible with Windows PowerShell 5.1
* resistant to asynchronous race conditions

---

# 2. Before changing code

First establish:

1. What currently happens?
2. Where is that behaviour implemented?
3. What tests cover it?
4. What state does it modify?
5. Which component owns that state?
6. Does the requested change affect an architectural invariant?

Do not begin by rewriting the obvious function.

**Then check the status table.** If the behaviour you are about to rely on is TARGET, the code does
not do it yet — no matter how confidently a document (including this one) describes it.

---

# 3. Inspect before editing

For a non-trivial task, inspect:

```text
entry point
relevant module
callers
called functions
state representation
tests
related documentation
```

Also search for:

* duplicate implementations
* alternate execution paths
* legacy `$event*` closures
* direct engine calls
* direct input calls
* credential resolution
* audit handling
* worker creation
* scheduler entry points

---

# 4. Establish a baseline

Before modifying behaviour:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Validate-Release.ps1
```

Run the relevant existing tests.

If an existing test already fails unexpectedly:

**stop and report it.**

Do not hide the failure by changing unrelated tests.

**Known baseline:** 28 runnable test files → 27 pass / 1 skip / 0 fail; validator all gates pass.
A `SKIP` is not a failure (see `docs/TESTING.md` §4) and is not coverage either.

---

# 5. Work in bounded changes

A single work item should have a clear boundary.

Good:

```text
Add OperationId validation to scheduler completion handling.
```

Poor:

```text
Refactor scheduler architecture and clean up all state handling.
```

unless the latter is explicitly the requested task.

---

# 6. Phase boundaries — current state of the hardening plan

This is the single most important section in this document for avoiding false claims.

| Phase | Work | Status |
| --- | --- | --- |
| 0 | Baseline capture | **done** |
| 1 | Deterministic credential identity (no silent fallback) | **done** |
| 2 | Operation identity (`OperationId`) | **not started** |
| 3 | Absolute concurrency cap at admission | **not started** — currently exploitable |
| 4 | Pending-work policy | **not started** |
| 5 | Stale-worker protection | **not started** — blocked on Phase 2 |
| 6 | Terminal-state protection | **not started** — blocked on Phase 2 |

**Phases 2–6 are not implemented.** Anything they introduce must not be described as existing
behaviour, and any documentation, comment or test that implies otherwise is a defect to fix.

The recommended implementation sequence remains:

```text
1. Credential determinism          (done)
2. Operation identity              (Phase 2)
3. Stale-worker protection         (Phase 5)
4. Timeout behaviour               (partially current)
5. Scheduler concurrency           (Phase 3)
6. Pending work                    (Phase 4)
7. Phase/deployment policy
8. CLI result semantics
9. WhatIf
10. Inventory safety
11. Audit verification
12. Documentation
13. Adversarial tests
```

This order is not mandatory for every task, but dependencies should be respected.

---

# 7. Testing strategy

The repository does not use Pester.

Tests are script-based:

```text
tests\Test-*.ps1
```

Run the smallest relevant test after each logical change.

Then run the affected suite.

Finally run the release validator.

**There is no aggregate runner** — each suite is invoked individually. See `docs/TESTING.md` §2 for the
loop, the GUI exclusions and the reason to wrap it in a timeout.

---

# 8. Test hierarchy

Use this order:

```text
single relevant test
        ↓
related tests
        ↓
full applicable test suite
        ↓
Validate-Release.ps1
```

Do not wait until the end of a large change to discover a basic regression.

---

# 9. Before editing: strip comments before pattern-matching

If you are verifying source shape (a predicate, a gate, a "this pattern must not appear" check), **strip
comments first**. PowerShell comments come in two forms and both must go:

* `#` line comments
* `<# ... #>` block comments

Otherwise the check matches the comment that explains why the pattern was removed.

This has produced a false failure **four times** in this repository: the §8 predicate, the §6
`CredentialConfig` read, a "never a password" check matching a block comment, and the Phase 1 removed
guard.

The validator provides both helpers:

| Helper | Behaviour | Use for |
| --- | --- | --- |
| `Get-WuuTextWithoutComments` | strips both styles; **preserves newlines and `$`** | slicing function bodies, positional checks |
| `Get-WuuCodeWithoutComments` | tokenizer-based; **discards newlines, drops `$`** | presence checks only |

Never use the code-tokenizer helper to slice a function body — line information is gone.

---

# 10. Never claim enforcement without locating a gate

"The pattern appears in `Scripts\Validate-Release.ps1`" is **not** evidence that a gate enforces it.

The validator's only mention of `MaxConcurrentJobs` is *inside a comment*. A check that greps for the
symbol would report the cap as gated. It is not gated.

To claim ENFORCED you must be able to point at the specific gate block and the specific assertion
inside it. If you cannot, the status is TARGET.

---

# 11. A test proves only what it drives

Two failure modes, both seen in this repository:

1. **Counting words instead of assertions.** `OperationId` appears throughout `tests\` — in fixtures
   and in comments — but the number of *assertion lines* about it is **0**. A test can mention a symbol
   without asserting anything about it.
2. **A name that promises more than the body drives.** A test named "rejects stale worker results" that
   only exercises the per-computer gate asserts nothing about staleness.

When assessing coverage, grep for **assertion lines**, then read the bodies of the tests that matter.

---

# 12. Destructive Git operations and uncommitted work

> **This rule exists because it was violated.** During Phase 1 an intentionally-broken file was
> restored with `git checkout --`, which silently discarded **two completed fixes** that were still
> uncommitted. The loss was only detected because the file stopped showing as modified in
> `git status --porcelain`.

**Never use these to "restore" or "clean up" a file that may hold uncommitted work:**

```text
git checkout -- <path>
git restore <path>
git reset --hard
git clean -fd
git stash drop / git stash clear
```

They destroy work with no confirmation and no reflog entry for uncommitted content.

**Required pattern** when you need the original of a file you have modified:

```powershell
# 1. commit the work first, OR
# 2. copy to a scratch location, then restore FROM the copy
Copy-Item src\Wuu.X.psm1 "$env:TEMP\Wuu.X.backup.psm1" -Force

# ... experiment ...

Copy-Item "$env:TEMP\Wuu.X.backup.psm1" src\Wuu.X.psm1 -Force

# 3. verify the restore actually worked — do not assume
git status --porcelain
```

Step 3 is not optional. `git status` showing the file as **modified again** is the proof that the
restore brought the work back. A file that has silently become clean is the signature of this bug.

**Prefer committing to a scratch branch** over any in-place restore when the work is more than trivial.

---

# 13. Race-condition testing

Timing-sensitive code must not rely solely on normal successful runs.

Tests should intentionally create situations such as:

### Forced timeout

```text
deadline = 1 second
worker duration = 5 seconds
```

Verify that the operation becomes timed out and remains protected from the late worker.

### Completion near deadline

Exercise both:

```text
worker completes just before deadline
```

and:

```text
deadline occurs before worker completion
```

### Timeout followed by retry

Verify:

```text
Operation A → TimedOut
Operation B → Running
Operation A late completion
```

does not corrupt Operation B.

> **Note:** this scenario cannot occur today because invariant 8.1 permits only one operation per
> computer. That makes it **unreachable, not safe** — there is no identity check to reject a stale
> result. The test is a Phase 5 deliverable and will fail until Phase 2 exists.

### Credential binding

Queue an operation with credential A.

Change the default credential.

Verify the queued operation still uses credential A.

### Concurrent submissions

Submit operations for:

* same computer
* different computers
* multiple simultaneous callers

Verify concurrency invariants.

> **Note:** the absolute-cap test belongs to Phase 3 and **fails today** for direct submissions to
> `Start-UpdateCheckJob`, because the cap is applied only in the scheduler tick.

### Synchronisation discipline

`Start-Sleep` is not a synchronisation primitive. Poll observable state with a bounded deadline, or
inject a completion signal.

---

# 14. Behaviour over implementation

Prefer tests such as:

```text
"late completion cannot modify replacement operation"
```

over tests such as:

```text
"function X calls function Y three times"
```

unless the internal interaction itself is part of the contract.

The strongest tests establish externally observable correctness.

---

# 15. Encoding checks

After editing files containing non-ASCII text:

* confirm the file remains UTF-8 BOM
* inspect the diff for unexpected encoding changes
* avoid unnecessary complete-file rewrites

Do not allow an editor or script to silently convert the project to BOM-less UTF-8. `Set-Content`
under PowerShell 7 writes BOM-less and will corrupt non-ASCII files — use
`[System.IO.File]::WriteAllText` with an explicit encoding, or edit in place.

**Measured non-ASCII files** (must keep their BOM): `Wuu.Command.psm1`, `Wuu.Core.psm1`,
`Wuu.Session.psm1`, `Package-WUU2.ps1`. The remaining shipped files contain zero non-ASCII bytes.
Before a full-file rewrite, snapshot the byte length and BOM state and compare after.

---

# 16. PowerShell 5.1 checks

Before committing code, check for accidental use of newer PowerShell functionality.

Particular hazards include:

```text
ForEach-Object -Parallel
```

and newer syntax/APIs.

The application must remain executable under:

```text
Windows PowerShell 5.1
```

Notes that have caused confusion:

* `[Type]::new()` is **PowerShell 5.0+** — it is fine here.
* PS7 is only best-effort for remote worker paths, never a requirement for shipped code.
* One `#Requires -Version 5.1` applies across all shipped files.

---

# 17. Input testing

New interactive functionality must use:

```text
Read-WuuAnswer
Read-WuuYesNo
Read-WuuSelection
```

Never add:

```powershell
Read-Host
```

Interactive code should remain testable without an actual console.

---

# 18. Audit testing

Every new mutating operation must be checked for:

```text
Mutating = $true
```

and the central audit path.

Tests should verify that:

* mutation is audited
* audit reason requirements are enforced
* non-mutating operations are not incorrectly treated as mutations
* WhatIf does not create remote mutation

**And deliberately:** `-WhatIf` writes **no** audit record. A simulation is not a denied attempt, so
this is correct behaviour — do not "fix" it by adding a record.

---

# 19. Scheduler testing

Any scheduler change should consider:

* global concurrency
* per-computer concurrency
* queue ordering
* duplicate requests
* cancellation
* timeout
* stale workers
* operation identity
* worker startup failure
* worker completion failure
* credential binding

A scheduler test suite should make it difficult to accidentally create a second execution path.

**State the deviation honestly:** there are two admission paths today, and only the scheduler tick is
capped. `Test-SchedulerSerialization` asserts `jobs.Count -le 2` but drives `Start-PendingUpdateCheck`;
it does not cover direct submission. Do not describe the cap as global until Phase 3 lands.

---

# 20. Diff review

Before declaring a task complete, inspect the entire diff.

Look specifically for:

```text
dist/ changes
WPF imports
System.Windows.*
Read-Host
PowerShell 7 syntax
encoding changes
BOM removal
direct engine calls
scheduler bypass
credential fallback
incorrect Mutating flags
state-machine violations
unrelated refactoring
work lost by a destructive Git operation
```

---

# 21. Source-of-truth review

For every changed value ask:

```text
Where is the authoritative value stored?
```

Avoid creating:

```text
state copy A
state copy B
display copy C
worker copy D
```

unless synchronization is explicitly designed and tested.

In particular: `State` is display-oriented. Decisions must read workflow fields, not `State`. Reading
`State` to make a decision was a real defect, now covered by validator gate (ac).

---

# 22. Stop conditions

Stop rather than guessing when:

* existing tests unexpectedly fail
* two implementations disagree
* a requirement is ambiguous
* state ownership is unclear
* a worker can update state without operation identity
* scheduler bypass appears necessary
* credential identity is ambiguous
* timeout semantics are unclear
* a broad refactor is required unexpectedly
* a requested change conflicts with an existing invariant

Report:

```text
What was found
What is ambiguous
What evidence conflicts
What decision is required
```

---

# 23. Completion checklist

Before reporting a task complete:

1. Baseline captured and re-run; no new failures.
2. Relevant tests added or updated, and they **fail without** the change.
3. Validator passes all gates.
4. Every claim of enforcement points at a specific gate or assertion.
5. No TARGET invariant described as current behaviour.
6. Diff reviewed against the §20 list.
7. Encoding and BOM state unchanged for non-ASCII files.
8. No destructive Git operation was used on uncommitted work.
9. Any work lost during the task was detected and restored, and `git status` was checked.
10. Remaining risks stated plainly, with the phase that will address each.
