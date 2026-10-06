# WUU2-CLI v1.5.0-rc.4-cli

**Release Candidate 4: Auto-recovery resolution (C8), harness assertion accounting (C9), Exempt.txt packaging retirement, and updated suite baseline.**

WUU2-CLI v1.5.0-rc.4-cli delivers remediation for defect C8 (making RPC auto-recovery resolvable from `Wuu.Remote` with robust HRESULT/error extraction) and defect C9 (standardizing test output prefixes so that `Invoke-TestSuites.ps1` accurately counts all passing assertions). It also formalizes the retirement of obsolete `Exempt.txt` from repository root and release packaging.

> **Release Candidate Notice.** The version is stamped on every audit record:
> `wuuVersion: v1.5.0-rc.4-cli` guarantees complete provenance for compliance and audit evidence.

---

## 1. Defect Remediations

### 1.1 Resolution of Unreachable RPC Auto-Recovery (C8)
* **Problem:** In `src/Wuu.Remote.psm1`, `Invoke-CimWithTimeout` attempted to invoke `Invoke-AutoRecovery` on RPC errors (`0x800706BA` / `0x800706BE`). `Invoke-AutoRecovery` lived only as a module-internal function in `Wuu.Core.psm1` (which exports only `Import-WuuModules` and `Start-WuuApplication`), making resolution fail silently at runtime. Furthermore, RPC errors often surface as localized message strings (e.g. `The RPC server is unavailable.`) without embedded `0x...` hex literals in `.Message`.
* **Resolution:**
  - Defined and exported `Invoke-AutoRecovery` directly in `src/Wuu.Remote.psm1`, ensuring immediate, intra-module resolution.
  - Added and exported `Get-WuuErrorSuggestions` in `src/Wuu.Models.psm1` with fallback auto-fix mappings.
  - Enhanced `Invoke-CimWithTimeout` to capture `HResult` and `ErrorId` (`$_.FullyQualifiedErrorId`), detecting RPC failures from HResult, ErrorId, and standard RPC messages.
  - Normalized error codes prior to switch evaluation in `Invoke-AutoRecovery`.
  - Added 4 new assertions in `tests/Test-RemoteHelpers.ps1` covering resolution and auto-recovery execution.

### 1.2 Resolution of Invisible Assertion Counting (C9)
* **Problem:** `tests/Test-AutoFlowChain.ps1` and `tests/Test-CredentialTyping.ps1` printed assertions using custom prefixes (`PASS [Op]:` and `PASS A:`), which failed to match the aggregate harness regex (`^PASS:`). Both suites reported `pass=0 fail=0`, silently omitting 8 passing assertions from the suite totals.
* **Resolution:** Standardized assertion output formatting to `PASS: [Op]` and `PASS: A -` prefixes. Both suites now contribute all 8 assertions to the aggregate total.

### 1.3 Formal Retirement of `Exempt.txt`
* Removed obsolete PoshPAIG placeholder file `Exempt.txt` from repository root.
* Excluded `Exempt.txt` from release packaging (`Scripts/Package-WUU2.ps1`).
* Updated `docs/PROVENANCE.md` to reflect `Exempt.txt` retirement.

---

## 2. Measured Verification Evidence on Tagged Tree

| Gate / Test Suite | Result | Details |
| --- | --- | --- |
| **Full Regression Suite** (`Scripts/Invoke-TestSuites.ps1`) | **PASS** | 59 suites run: **58 PASS, 1 SKIP, 0 FAIL** (**1,880 assertions passed**; `Test-RemoteTask.ps1` safely skipped due to unelevated environment) |
| **Release Validation Gate** (`Scripts/Validate-Release.ps1`) | **PASS** | 52 declared source structure, invariant, and security checks fully evaluated: 187 PASS, 0 FAIL, 0 WARN |
| **Version Provenance Gate** (SS18) | **PASS** | Embedded `$global:WuuVersion` matches git release tag `v1.5.0-rc.4-cli` |
| **Release Packager** (`Scripts/Package-WUU2.ps1`) | **PASS** | Generates distribution `.zip` with zero operator data or legacy exemptions |
