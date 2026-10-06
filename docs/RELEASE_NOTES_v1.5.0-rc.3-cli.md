# WUU2-CLI v1.5.0-rc.3-cli

**Release Candidate 3: Remediation of false-failure defect C7 in Test-PoolDiagnostics, reproducible release-evidence baseline, and complete verification on tagged tree.**

WUU2-CLI v1.5.0-rc.3-cli resolves defect C7, a false-failure condition discovered during independent post-release verification of `v1.5.0-rc.2-cli`. All critical and high defect fixes (C1–C6, G1–G3) and presentation hardening delivered in rc.2 remain intact and independently verified.

> **Release Candidate Notice.** The version is stamped on every audit record:
> `wuuVersion: v1.5.0-rc.3-cli` guarantees complete provenance for compliance and audit evidence.

---

## 1. Defect Resolution: C7 in `Test-PoolDiagnostics.ps1`

### 1.1 Resolution of Unsatisfiable Runtime Non-PASS Check (C7)
* **Problem:** In `tests/Test-PoolDiagnostics.ps1`, the release gate JSON report validation asserted that at least one non-PASS verdict kind must exist at runtime (`$nonPassKinds.Count -ge 1`). On untagged development commits, gate check `SS18` legitimately emitted a `SKIP`, producing `SKIP=1` and satisfying the assertion. However, the moment a release candidate was tagged with valid provenance, `SS18` correctly transitioned from `SKIP` to `PASS`, producing 187 `PASS`, 0 `FAIL`, 0 `WARN`, 0 `SKIP`, and 0 `NOT_IMPLEMENTED`. The assertion therefore failed precisely on a 100% passing tagged tree, emitting a false failure on the very artifact it was designed to protect.
* **Resolution:** Replaced the environment-dependent runtime non-PASS count check with structural verification that all five verdict kinds (`FAIL`, `WARN`, `SKIP`, `NOT_IMPLEMENTED`) are representable and tracked in `$report.Totals` as non-negative counts, complementing the existing AST reachability check (`$skipSites -ge 1`).
* **Result:** `Test-PoolDiagnostics.ps1` now passes cleanly and reliably in both tagged and untagged environments.

---

## 2. Verified Inheritance from `v1.5.0-rc.2-cli`

All fixes and enhancements from rc.2 are preserved and verified:
* **C1 / G1:** Proper unwrapping of inner pool results in `Invoke-CimWithTimeout`, eliminating silent failure masking.
* **C2 / G2:** AST and dynamic runspace envelope agreement tests across both copies of `Invoke-CimWithTimeout`.
* **C3 / G3:** Strict credential verification failure reporting (`Verified = $false`, `no fallback attempted`), verified with live and mock probe tests.
* **C4:** Pre-flight credential resolution and safe OS property unwrapping under StrictMode 2.0.
* **C5:** Disentangled timeout assertions from probe failures in `Test-RemoteHelpers.ps1`.
* **C6:** Aggregate test runner documentation in `docs/TESTING.md` and baseline alignment.
* **Stale GUI Test Retirement:** Clean removal of obsolete `Test-ColumnResize.ps1` and `Test-DragResize.ps1`.
* **Presentation:** Native horizontal ASCII rollout timeline charts and unified status token theming.
* **Governance:** Comprehensive community health and multi-agent coordination architecture (`AGENTS.md`, `.github/`).

---

## 3. Measured Verification Evidence on Tagged Tree

| Gate / Test Suite | Result | Details |
| --- | --- | --- |
| **Full Regression Suite** (`Scripts/Invoke-TestSuites.ps1`) | **PASS** | 59 suites run: **58 PASS, 1 SKIP, 0 FAIL** (1,868 assertions passed; `Test-RemoteTask.ps1` safely skipped due to unelevated environment) |
| **Release Validation Gate** (`Scripts/Validate-Release.ps1`) | **PASS** | 52 declared source structure, invariant, and security checks fully evaluated: 187 PASS, 0 FAIL, 0 WARN |
| **Version Provenance Gate** (SS18) | **PASS** | Embedded `$global:WuuVersion` matches git release tag `v1.5.0-rc.3-cli` |
