# WUU2-CLI v1.5.0-rc.2-cli

**Release Candidate 2: Critical remote probe envelope unwrapping, truthful credential resolution, pre-flight hardening, ASCII rollout presentation, and complete test suite alignment.**

WUU2-CLI v1.5.0-rc.2-cli hardens the CLI edition for production deployment following comprehensive call-graph inspections and adversarial multi-agent reviews. This release candidate eliminates silent failure masking across the remote execution layer, guarantees fail-closed credential verification under Invariant R04, delivers rich terminal presentation (ASCII timelines and status theming), and cleans up legacy test suite leftovers.

> **Release Candidate Notice.** The version is stamped on every audit record:
> `wuuVersion: v1.5.0-rc.2-cli` guarantees complete provenance for compliance and audit evidence.

---

## 1. Critical & High Severity Defect Fixes

### 1.1 Truthful Remote Probe Envelope Unwrapping (C1, G1)
* **Problem:** The exported `Invoke-CimWithTimeout` helper in `Wuu.Remote.psm1` inspected the worker pool wrapper's completion status (`$cimResult.Success`) rather than unwrapping the inner operation result. Failed probes (RPC unavailable, access denied, invalid class) returning `@{ Success = $false; Error = ... }` were reported to callers as `Success = $true`. This masked remote failures silently and rendered automatic RPC recovery hooks unreachable.
* **Resolution:** Corrected `Invoke-CimWithTimeout` to unwrap the inner result hashtable identically to the inlined worker payload copy. Failed probes now truthfully return `Success = $false` with preserved error details. Added dedicated non-timeout probe failure regression assertions in `tests/Test-RemoteHelpers.ps1`.
* **Commits:** `f17042a`, `9de7f6f`.

### 1.2 Remote Helper Copy Agreement (C2, G2)
* **Problem:** Two copies of `Invoke-CimWithTimeout` existed across the repository (`Wuu.Remote.psm1` module-level helper and `Wuu.Core.psm1` inlined worker runspace copy). While budget caps were checked for agreement, envelope handling differed between the two copies.
* **Resolution:** Added AST-based structural agreement checks and dynamic runspace execution testing in `tests/Test-RemainingBudget.ps1` (section 12) to enforce identical pool envelope unwrapping and error propagation across both copies.
* **Commit:** `9b1653d`.

### 1.3 Strict Credential Verification & No-Fallback Enforcement (C3, G3)
* **Problem:** Due to silent probe masking in `Invoke-CimWithTimeout`, credential verification in `Resolve-WuuOperationCredential` could never fail on remote authentication rejections. Custom credentials that failed authentication could not trigger the `Verified = $false` branch, threatening the core security invariant that prohibited falling back to unauthorized identities.
* **Resolution:** With truthful probe reporting restored, `Resolve-WuuOperationCredential` now accurately flags unverified identities with `Verified = $false`, annotates records with `"no fallback attempted"`, and preserves the exact remote error. Added live and mock-driven verification tests in `tests/Test-CredentialPropagation.ps1` proving that `Get-RemoteCredentials` throws fatal errors when an identity cannot be verified.
* **Commits:** `ed566aa`, `fee8b57`.

### 1.4 Pre-Flight Credential Resolution & StrictMode Safety (C4)
* **Problem:** In `Wuu.Navigate.psm1`, the pre-flight `Credentials` probe bypassed configured credentials and misreported failed probes as `'valid'`. The `OS` probe attempted direct indexing on truthy inner failure hashtables under StrictMode 2.0, emitting unformatted `" (build )"` strings. Uninitialized timeout variables could also throw runtime exceptions if modules were imported independently.
* **Resolution:** Updated pre-flight probes to resolve credentials via `Get-RemoteCredentials`, safely inspect OS properties without throwing under StrictMode 2.0, fall back to safe default timeouts if global variables are unset, and return truthful probe verdicts (`'valid'`, `'failed'`, `''`). Added live pre-flight verification in `tests/Test-Navigation.ps1`.
* **Commit:** `95bcdc4`.

---

## 2. Test Integrity & Suite Cleanups

### 2.1 Test Assertion Disentanglement (C5)
* Disentangled hard timeout assertions in `tests/Test-RemoteHelpers.ps1` so that `Success = $false`, error message content (`*timed out*`), and `Result = $null` are asserted individually rather than bundled.
* Added dedicated assertions verifying non-timeout probe failure against invalid CIM classes.

### 2.2 Aggregate Test Runner & Baseline Alignment (C6)
* Documented `Scripts/Invoke-TestSuites.ps1` in `docs/TESTING.md`, establishing aggregate test execution with accurate process exit-code capture, per-suite timeouts (default 300s), and `SKIP` vs `PASS` classification.
* Updated `docs/TESTING.md` baseline suite counts to reflect the current runnable suite count: **59 runnable suites, 58 pass / 1 skip / 0 fail** (1,860 assertions).

### 2.3 Retirement of Stale WPF GUI Leftovers
* Removed obsolete GUI-era test files `tests/Test-ColumnResize.ps1` and `tests/Test-DragResize.ps1` that referenced `WUU.xaml` and hung or failed in console environments.
* Cleared runner exclusions in `Scripts/Invoke-TestSuites.ps1` (`excluded: none`).

### 2.4 State-Machine Invariant 8.4 Enforced
* Formally documented Invariant 8.4 (*"terminal states are terminal"*) as enforced in `docs/TESTING.md`, covered by `tests/Test-TerminalStates.ps1` (65 assertions) and release validator gates `P1 / SS4`.

---

## 3. Console UX & Presentation Enhancements

### 3.1 Native ASCII Rollout & Phase Timeline Charts
* Implemented native line-oriented horizontal ASCII rollout and phase charts (`feat(presentation): implement native line-oriented horizontal ASCII rollout and phase charts`).
* Resolved parameter reassignments and preserved budget floors during chart formatting.

### 3.2 Truthful Status Tokens & Unified Theming
* Implemented consistent status token indicators across console tables, ensuring visual output truthfully reflects operational states and terminal outcomes (`feat(presentation): implement truthful status tokens and unified theming`).
* Added heartbeat staleness highlighting and phase dependency tickers.
* Resolved `State = 'Error'` contradictions and added console status table filtering.

---

## 4. Community & Multi-Agent Coordination Standards

* Added comprehensive multi-agent governance and coordination architecture in `AGENTS.md` and `.github/agents/` (`COPILOT-REVIEWER.md`, `OLLAMA-WORKER.md`).
* Added standard community health files: `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, tailored `SECURITY.md` (addressing ISO/IEC 27001 audit invariants and private vulnerability reporting), and `SUPPORT.md`.
* Standardized issue and pull request templates in `.github/ISSUE_TEMPLATE/` and `.github/pull_request_template.md`.

---

## 5. Verification & Compliance Evidence

| Gate / Test Suite | Result | Details |
| --- | --- | --- |
| **Release Validation Gate** (`Scripts/Validate-Release.ps1`) | **PASS** | 52 declared source structure, invariant, and security checks fully evaluated: 0 FAIL, 0 WARN |
| **Full Regression Suite** (`Scripts/Invoke-TestSuites.ps1`) | **PASS** | 59 suites run: **58 PASS, 1 SKIP, 0 FAIL** (1,860 assertions passed; `Test-RemoteTask.ps1` safely skipped due to unelevated environment) |
| **Version Provenance Gate** (SS18) | **PASS** | Embedded `$global:WuuVersion` matches git release tag `v1.5.0-rc.2-cli` |
