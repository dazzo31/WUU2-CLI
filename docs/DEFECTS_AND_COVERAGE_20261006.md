# WUU2-CLI — Defects and Verification-Coverage Record

Recorded: 2026-10-06. Repository: `C:\Users\dazzo\OneDrive\GitHub\WUU2-CLI` (branch `master`, HEAD
`0566164bba3eb24d86121405bdbb39d58ff2c4ab`). No file in this repository was modified while producing
this record.

Method: direct source inspection of the call graph, cross-checked against the existing suites and the
project's own documentation. Where a claim below is behavioural rather than structural, it is labelled
as such; the primary defect (C1) is confirmed by reading both the producer and the consumer of the
value in question.

Scope: this document covers the **CLI edition only**. Defects specific to the GUI edition (`WUU2`) are
recorded separately and are not carried here.

---

## 1. Summary

| ID | Severity | Status | Resolution / Commit | Area | Affects |
|----|----------|--------|---------------------|------|---------|
| C1 | **CRITICAL** | CLOSED | `f17042a` | `Invoke-CimWithTimeout` misreads the pool envelope | Credentials, pre-flight, connectivity |
| C2 | HIGH | CLOSED | `9b1653d` | Two copies of the same helper diverged (module vs inlined payload) | Maintenance, correctness |
| C3 | HIGH | CLOSED | `ed566aa` | Credential verification cannot fail → "no fallback" is unenforceable | R04 identity safety |
| C4 | MEDIUM | CLOSED | `95bcdc4` | Pre-flight misreports credential validity and OS data | `wuu` pre-flight, guided workflow |
| C5 | LOW | CLOSED | `9de7f6f` | `Test-RemoteHelpers` timeout assertion passes for the wrong reason | Test integrity |
| C6 | LOW | CLOSED | `ed36cce` | `docs/TESTING.md` suite counts are stale | Documentation |

Six logic defects in the operation state machine (failed-install outcome, reset fencing, pending
consumption, cleanup identity retirement, implicit phase transition, terminal-state laundering) were
found and **fixed** in this repository earlier in the v1.5.0 cycle. They are documented in
`RELEASE_NOTES_v1.5.0-rc.1-cli.md`, covered by suites, and are **not** re-listed here.

---

## 2. Defect detail

### C1 — CRITICAL — the exported `Invoke-CimWithTimeout` reports every failed probe as a success

**Location:** `src\Wuu.Remote.psm1`, `function Invoke-CimWithTimeout` (defined at line 75; the defect is
at line 124, with a mirrored read at line 155).

**Mechanism.** The inner scriptblock handed to `Invoke-WithPoolTimeout` catches its own errors and
returns `@{ Success = $false; Error = <message> }`. `Invoke-WithPoolTimeout`
(`src\Wuu.Workers.psm1`, line ~296) wraps whatever the scriptblock returns in its **own** envelope:

```powershell
return @{ Success = $true; Result = $resultValue; Error = $null }
```

where `Success` means only *"the scriptblock ran to completion"* — it says nothing about whether the
work inside succeeded. On a failed probe the wrapper is therefore `Success = $true`, with the real
failure nested in `Result`.

`Invoke-CimWithTimeout` reads the **wrapper's** `Success` and treats it as the operation's:

```powershell
if ($cimResult.Success) {
    return @{ Success = $true; Result = $cimResult.Result }   # Result is @{ Success = $false; Error = ... }
}
```

So a probe that connected, failed (bad credentials, RPC unavailable, access denied, class not found),
and returned `Success = $false` is reported to the caller as `Success = $true`, carrying a hashtable in
`Result` that most callers never inspect. The failure is *silent*: no exception, no error text.

**The recovery branch is consequently dead.** The `$errorMsg = $cimResult.Error` line is only reached
when the wrapper itself failed — a timeout or a terminated pipeline. Its error text is
`"<OperationName> timed out after N seconds"` or an exception message, neither of which contains an
`0x…` HRESULT, so the RPC-recovery hook (`0x800706ba` / `0x800706be`) can never match. RPC-class errors
were expected to trigger `Invoke-AutoRecovery` and a retry; they do not.

**Why it is CRITICAL, not HIGH.** Failures are reported as successes, so no caller and no operator can
see them. The downstream consequence (C3) silently defeats an explicit security rule — the module's
own documentation states the resolver must never fall back to another identity.

**Related reads in the same file (different functions, *not* affected — see C2):**
`Invoke-ServiceWithTimeout` (line 236) and `Test-SystemDependencies` (line 319) read the wrapper's
`Success` too, but their inner scriptblocks return the **bare value** (or `$null`), not a nested
hashtable. Their second-level read (`$serviceResult.Result.Success`) therefore *is* the operation's
`Success`, and they happen to behave correctly. This is correct by accident and fragile: if either
inner scriptblock is ever changed to return a nested result hashtable — as the CIM one does — the same
silent masking is introduced.

---

### C2 — HIGH — the same helper exists twice and the copies have diverged

**Locations:**
- `src\Wuu.Remote.psm1` line 75 — the module-level, exported helper. **Broken (C1).**
- `src\Wuu.Core.psm1` line 974 — an *inlined* copy defined inside the injected per-computer payload
  scriptblock. **Correct.**

The inlined copy unwraps the wrapper explicitly:

```powershell
if ($cimResult.Success) {
    $inner = $cimResult.Result
    if ($inner -and $inner.Success) { return @{ Success = $true; Result = $inner.Result } }
    else { return @{ Success = $false; Error = ... } }
}
```

The duplication is deliberate and documented (an isolated payload runspace cannot call the module's
script-scope functions, so the helper is re-declared locally). The problem is that a fix applied to one
copy does not reach the other, and **here the two copies disagree about how to read the same
envelope**. A reader who checks the payload copy — the one that runs on every computer during a real
download/install — sees correct code and reasonably concludes the helper is fine.

**Consequence:** any future review, refactor or "port the helper" change will preserve or re-introduce
C1 depending on which copy is copied from.

**Note:** `src\Wuu.Core.psm1` line 1316 (`$wmiResult = Invoke-CimWithTimeout …`) sits inside the payload
scriptblock and therefore resolves to the **local, correct** copy at line 974 — it is not affected by
C1. The `Test-RemainingBudget` suite already asserts that the two copies' budget-cap logic agrees;
nothing asserts that their envelope handling agrees.

---

### C3 — HIGH — credential verification cannot fail, so "no fallback" cannot be enforced

**Locations:** `src\Wuu.Credentials.psm1` lines 155 and 158, inside `Resolve-WuuOperationCredential`
(the `-Verify` branch).

```powershell
$probe = Invoke-CimWithTimeout -ComputerName $ComputerName … -Credential $credential -Operation "credential verification ($username)"
if ($probe -and $probe.Success) { $verified = $true }
else { $verified = $false; $errorText = … }
```

Because of C1, `$probe.Success` is `$true` whenever the probe **ran**, regardless of outcome. The
`else` branch — which sets `$verified = $false`, records the reason, and annotates it *"no fallback
attempted"* — is unreachable for every failure mode except a pool timeout.

**Impact.** The resolver's designed contract (documented in-file: a custom credential that cannot be
used yields `Verified = $false` and `$reason` explaining it, so the caller refuses rather than falling
back) silently becomes "always verified". Any caller gating on `Verified` accepts an identity that was
never confirmed to work. The rule exists precisely to prevent running as an unintended identity; the
verification step that enforces it does not report failures.

This is the security-relevant consequence that raises C1 to CRITICAL.

---

### C4 — MEDIUM — pre-flight misreports credential validity and OS data

**Locations:** `src\Wuu.Navigate.psm1` line 949 (`Credentials` probe) and line 959 (`OS` probe).

```powershell
Credentials = { param($Name)
    $r = Invoke-CimWithTimeout -ComputerName $Name -ClassName 'Win32_ComputerSystem' …
    if ($r -and $r.Success) { 'valid' } else { 'failed' }
}
OS = { param($Name)
    $r = Invoke-CimWithTimeout -ComputerName $Name -ClassName 'Win32_OperatingSystem' …
    if ($r -and $r.Success -and $r.Result) { $os = @($r.Result)[0]; '{0} (build {1})' -f $os.Caption, $os.BuildNumber }
}
```

- **Credentials:** unreachable or rejected credentials are reported as `valid`, because the probe
  "ran". The pre-flight summary ("Continue with N available") can therefore include hosts whose
  credentials do not work.
- **OS:** `$r.Result` is the nested `@{ Success = $false; Error = … }` hashtable, which is truthy, so
  `@($r.Result)[0]` yields the hashtable; `$os.Caption` and `$os.BuildNumber` are `$null`, and the row
  renders as `" (build )"` rather than falling through to the empty-string branch.

**Note:** the `Service` probe in the same table uses `Invoke-ServiceWithTimeout`, which is unaffected
(see C1's note), and correctly returns `'unknown'`.

---

### C5 — LOW — `Test-RemoteHelpers` timeout assertion passes for the wrong reason

**Location:** `tests\Test-RemoteHelpers.ps1` lines 46–47.

```powershell
$timeoutTest = Invoke-CimWithTimeout -ComputerName '192.0.2.1' -TimeoutSeconds 3
Assert-True ((-not $timeoutTest.Success) -and ($timeoutTest.Error -like '*timed out*')) "hard timeout fires on unreachable host"
```

This passes because the probe genuinely times out, which is handled correctly (the wrapper's `Success`
is `$false` on timeout). It is the only failing-path assertion in the suite, and it exercises the one
path C1 does **not** break. The suite therefore appears to cover probe failure while covering only
timeout. See gap G1.

---

### C6 — LOW — `docs/TESTING.md` suite counts and the "stale GUI suites" note are out of date

**Location:** `docs\TESTING.md` lines ~65 and ~93.

The document states:

> **Baseline:** 30 test files; 2 excluded because they are GUI-edition leftovers; **28 runnable**;
> **27 pass / 1 skip / 0 fail**.

The `tests\` directory now contains **61 `Test-*.ps1` files** (59 excluding the two GUI-edition
leftovers, `Test-ColumnResize` and `Test-DragResize`), plus 5 developer tools that are not suites
(`DryRun-Mutations`, `Probe-PayloadFunctionReach`, `Prove-P3Tautology`, `Prove-PoolTautology`,
`Prove-TerminalTautology`) — 66 files in total. The quoted "30 / 28 / 27 pass" is the
`v1.5.0-beta.2-cli` figure carried forward; roughly thirty suites were added during the Phase 3/4
hardening work without refreshing it. The `HARDENING_BETA3_FINDINGS.md` header quotes a third
variant ("29 total, 27 runnable"), so the counts disagree with each other as well.

**Impact:** low, but it is the same class of problem as C2 and C6's sibling in the GUI edition — a
document that no longer describes the tree, which misleads a reader about how much coverage exists.
It matters here because C1 shows that suite *count* is not the same as suite *rigour*: the two
assertions that would have caught C1 (see G1) are absent regardless of how many suites exist.

The qualitative guidance in that file — the SKIP policy, "a skipped test proves nothing", "do not
document a `Run-AllTests.ps1`" — remains correct and valuable, and is quoted approvingly in this
record's section 5.

---

## 3. Verification-coverage gaps

### G1 — no suite exercises a *non-timeout* probe failure

`Test-RemoteHelpers` asserts the timeout path (C5). `Test-PoolCompatibility` asserts pool settings by
**reading source with a regex**, not by driving the helper. `Test-SilentCatchPolicy` targets empty
catch bodies specifically. No suite drives `Invoke-CimWithTimeout` to a failure that is *not* a
timeout, and no suite asserts on the shape of the returned hashtable.

That gap is exactly why C1 survived review and release: the one failing-path test in existence
happens to take the branch that works.

### G2 — the duplication of payload helpers has no agreement test

`Test-RemainingBudget` asserts that the two `Invoke-CimWithTimeout` copies agree on their **budget
cap**. Nothing asserts that they agree on **envelope handling** — the divergence in C2.

### G3 — module-level helpers are not exercised end-to-end from the workflow

The exported `Invoke-CimWithTimeout` is reachable from `Wuu.Credentials` and `Wuu.Navigate`, but no
suite asserts the credential-verification contract through it with a mock that returns a *failed*
probe. Confirming C3 behaviourally requires such a mock.

---

## 4. Correction to an earlier external claim

An earlier summary (in the GUI edition's planning records) stated that this repository **also**
suffered from unreliable child-process exit-code capture — specifically that `Start-Process -PassThru`
or a `%ERRORLEVEL%` wrapper silently returned `0`. **That claim is wrong for this repository and is
withdrawn here.**

`Scripts\Invoke-TestSuites.ps1` already uses `System.Diagnostics.Process` directly, with an explicit
in-source comment recording the measurement ("`Start-Process -NoNewWindow -PassThru` returns an object
whose ExitCode stays EMPTY even after `WaitForExit()` and `Refresh()`"), a bounded wait, asynchronous
stdout/stderr reads, and a process-tree kill. The false-green exit-code capture was a defect of the
**GUI** edition's runner only.

---

## 5. Checked and confirmed **not** defective

Recorded so a future review does not have to re-derive these.

| Area | Finding |
|------|---------|
| Packaging | `Scripts\Package-WUU2.ps1` **deliberately excludes** `ComputerList.config`; an in-source comment states it is gitignored operator data. Unlike the GUI edition, operator data is not shipped. |
| Test runner | Uses `System.Diagnostics.Process`; classifies PASS/FAIL/SKIP/TIMEOUT; a SKIP is not treated as a failure. (Section 4.) |
| `Test-RemoteTask` | Exits **0** with a `SKIP:` marker when not elevated, by design, with a comment recording that exiting 1 previously made an unrunnable suite look failed. |
| Versioning | `$global:WuuVersion = 'v1.5.0-rc.1-cli'` is single-sourced in `src\Wuu.Configuration.psm1`, resolved from git tags with a documented mismatch warning, and stamped on every audit record. (The GUI edition has no version constant at all.) |
| State-machine defects | The six v1.5.0-cycle defects are fixed and covered: `Test-InstallOutcome` (lines 45–58 assert `InstallErrors > 0` → `Failed` even when `State = 'Complete'`, and all-failed → `OperationFailed`), plus `Test-WorkerIdentityFence`, `Test-PendingPolicy`, `Test-CleanupIdentityRetire`, `Test-TerminalStates`, `Test-TargetOutcomes`, `Test-RefusalSemantics`. |
| `Invoke-ServiceWithTimeout`, `Test-SystemDependencies` | Read the wrapper correctly **by accident** — their inner scriptblocks return bare values, not nested hashtables. Correct today; fragile for the reason given in C1. |
| `Set-StrictMode` | `Wuu.Core.psm1` was the module lacking it (the root cause of the beta.2 settings/scheduler defects). The documented policy is to guard it rather than remove it; the v1.5.0 fixes removed the reliance on missing-key silence rather than removing the guard. |

---

## 6. Recommended remediation order

1. **C1 first, and in both copies.** Unwrap the pool envelope in the module-level
   `Invoke-CimWithTimeout` (`Wuu.Remote.psm1`) exactly as the inlined payload copy already does, then
   confirm the inlined copy is unchanged and still correct. Do not "fix" one and assume the other.
2. **Add the missing test before or with the fix (G1).** Drive the helper to a failure that is not a
   timeout — a mock inner result of `@{ Success = $false; Error = … }` — and assert the caller sees
   `Success = $false` with that error. Without this, the fix is unverifiable and can regress.
3. **C3 then C4.** Once the helper reports failure, re-check that credential verification actually
   reaches its `Verified = $false` branch, and add a test that asserts it with a failing probe.
4. **C2 as a structural guard.** Add an agreement assertion (alongside `Test-RemainingBudget`) that the
   two `Invoke-CimWithTimeout` copies handle the envelope identically, so the divergence cannot recur.
5. **C5, C6 last.** Correct the assertion's stated intent and refresh the counts in
   `docs/TESTING.md`.

Because C3 makes an explicit security rule unenforceable and C1 makes the failure invisible, C1 and C3
should be treated as release-blocking for any version that claims the no-silent-fallback contract.

---

## 7. Remediation status (completed 2026-10-06)

All recommended remediation steps were executed in sequence, verified against the test runner (58 pass / 1 skip / 0 fail) and `Scripts/Validate-Release.ps1`, and committed:
- **Step 1 & 2 (C1, G1):** `f17042a` (`fix(remote): unwrap pool envelope correctly in Invoke-CimWithTimeout (C1)`)
- **Step 3 (C3, C4):** `ed566aa` (`fix(credentials): enforce truthful verification failure and no-fallback security invariant (CRED-VERIFY-01)`) and `95bcdc4` (`fix(navigate): correct pre-flight credential resolution and OS safe formatting (NAV-PREFLIGHT-01)`)
- **Step 4 (C2, G2):** `9b1653d` (`test(remote): assert envelope agreement between Invoke-CimWithTimeout copies (REMOTE-AGREE-02)`)
- **Step 5 (C5, C6):** `9de7f6f` (`test(remote): disentangle timeout from probe failure assertion in Test-RemoteHelpers (TEST-ASSERT-01)`) and `ed36cce` (`docs(testing): update baseline suite counts and document aggregate runner (DOCS-TEST-01)`)
- **Gap G3:** `fee8b57` (`test(credentials): add mock-driven probe failure test asserting no-fallback and caller refusal (TEST-GAP-G3)`)
