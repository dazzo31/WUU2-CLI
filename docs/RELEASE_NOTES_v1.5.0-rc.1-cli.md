# WUU2-CLI v1.5.0-rc.1-cli

**Release Candidate 1: Core defect resolution, audit integrity hardening, scheduler isolation, and verifiable export bundles.**

WUU2-CLI v1.5.0-rc.1-cli prepares the utility for general production release, resolving critical defect classes discovered during security and architectural reviews. All core commands and workflows retain established operational syntax while ensuring fail-closed integrity, leak-free runspace lifecycle, and strict state machine invariants.

> **Release Candidate Notice.** The version is stamped on every audit record:
> `wuuVersion: v1.5.0-rc.1-cli` guarantees complete provenance for compliance and audit evidence.

---

## 1. Verified Defect Fixes

### 1.1 Audit Verification Verdict Unification (CLI-AUDIT-VERIFY-01)
* **Problem:** Audit verification previously reported success (`Ok=$true`, `Result='Success'`) even when an external anchor rewrite was detected (`AnchorRewritten=$true`). Automation parsing the JSON output could accept tampered or overwritten log files as authentic.
* **Resolution:** Computed a single combined verification verdict before evaluating exit codes or emitting JSON envelopes. Any detected anchor rewrite now forces `Ok=$false` and `Result='Failed'`, and the JSON envelope explicitly carries `AnchorConsistent`, `AnchorRewritten`, and `AnchorReason`.

### 1.2 Runspace Disposal on Computer Removal (CORE-RUNSPACE-DISPOSE-01)
* **Problem:** Removing an offline or decommissioned computer (`RemoveOfflineComputer`) cleared state via `ClearOperation`, which nulled `$Computer.Runspace` before the subsequent conditional attempted to close it. The original PowerShell runspace remained open, leaking system threads and handles.
* **Resolution:** Cached the local runspace reference prior to calling `ClearOperation`, ensuring the underlying runspace is reliably closed and disposed before discarding the computer record.

### 1.3 Public CLI Dispatch for Protected Anchor Paths (CLI-ANCHOR-PARAM-01)
* **Problem:** Although the underlying audit verification dispatcher supported `-AnchorPath`, the public entry point `Invoke-WuuCommand` did not declare the parameter, and the argument parser did not recognize it as a value-taking option. Operators could not supply external protected anchor files through standard command invocations.
* **Resolution:** Declared `[string]$AnchorPath` on `Invoke-WuuCommand`, registered `-anchorpath` in known options, and added it to the value-taking argument parser list.

### 1.4 Windows Event Log Anchor Verification (AUDIT-EVENTLOG-VERIFY-01)
* **Problem:** While an Event Log reader helper existed, `wuu audit verify` only validated file-based anchors. Operators writing anchors into Windows Event Log records could not verify them via the CLI.
* **Resolution:** Shared verification logic via `Test-WuuAuditAnchorData`, added `-TargetLogPath` filtering, and wired `Test-WuuAuditEventLogAnchor` directly into `wuu audit verify -EventLog`. Legitimate log appends subsequent to anchor creation are recognized and verified correctly.

### 1.5 Strict Terminal-State Protection Against Cleanup Bypasses (STATE-TERMINAL-RESET-01)
* **Problem:** Cleanup routines performed unattributed `Timeout -> Queued` transitions, bypassing the state mutation funnel's terminal-state guard (§13 invariant).
* **Resolution:** Removed unattributed `Timeout -> Queued` rewrites across all mutation funnels, preventing implicit state overwrites on settled rows. Narrowed Invariant 4 so that deadlines are cleared only while operations are genuinely non-running.

### 1.6 Verifiable Audit Export Bundles & Documentation Reconciliation (IMPROVEMENTS-EXPORT-DOCS-01)
* **Problem:** Audit exports bundled all available logs regardless of scope and lacked cryptographic manifest verification. Audit documentation also described guarantees beyond implemented mechanisms.
* **Resolution:**
  * Scoped export bundles to day-matched transcripts, including corresponding external anchor files.
  * Generated an `evidence-manifest.json` containing SHA-256 hashes for all bundled files (excluding the manifest itself).
  * Reconciled audit documentation to accurately distinguish implemented cryptographic invariants from operational security guarantees.

---

## 2. Architectural Hardening & Modularization

### 2.1 Explicit ResetOperation Contract (STATE-RESET-OP-01)
* Implemented `New-WuuResetOperationContext` and established an explicit `ResetOperation` contract.
* Replaced all remaining unauthorized module-scope operation-state writes in `Wuu.Core.psm1` (including phase-wait parking and abort flows) with authenticated, auditable transitions through the state mutation funnel.

### 2.2 Dedicated Scheduler Module Extraction (SCHEDULER-EXTRACT-01)
* Migrated `Start-PendingUpdateCheck` and admission queueing from `Wuu.WindowsUpdate.psm1` into `Wuu.Scheduler.psm1`.
* Added synchronized context isolation via `Initialize-WuuSchedulerContext`.
* Isolated update execution business logic from scheduler orchestration and queue promotion.

---

## 3. Verification & Compliance Evidence

| Gate / Test Suite | Result | Details |
| --- | --- | --- |
| **Release Validation Gate** (`Scripts/Validate-Release.ps1`) | **PASS** | 187 checks evaluated: 187 PASS, 0 FAIL, 0 WARN |
| **Full Regression Test Suite** (`Scripts/Invoke-TestSuites.ps1`) | **PASS** | 50 suites run: 49 pass, 1 skip (`Test-RemoteTask.ps1`), 0 fail |
| **Total Test Assertions** | **1,561 PASS** | 100% passing rate across all active test suites |
| **PowerShell Compatibility** | **PowerShell 5.1** | Native PS 5.1 engine syntax, strict UTF-8 BOM encoding |

---

## 4. Known Operational Notes

* `Test-RemoteTask.ps1` remains marked as SKIP during automated runs because it requires live target credentials and accessible remote endpoints.
* Air-gapped bundles and export packages require operator verification using the generated `evidence-manifest.json`.
