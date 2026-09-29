# WUU2-CLI Hardening Pass — P0 Findings and Status

**Date:** 2026-09-29
**Brief:** logic/architecture hardening (GUI state, per-computer serialization, unified scheduler,
timeouts, credentials, reboot detection, exit codes, phase policy, WhatIf, inventory, audit, debris).
**Scope of what is DONE here:** the P0 tier — GUI state removed from worker logic, and the dead
scheduler/queue repaired. **Everything else in the brief is still open**; see "Not done" below.
This document exists so the next pass does not have to rediscover any of it.

---

## The single root cause

`$global:uiHash` is created as an **empty** synchronized hashtable:

```powershell
# Wuu.Core.psm1
$global:uiHash = [hashtable]::Synchronized(@{})
```

and **nothing in `src/` ever populates it**. The only assignments of `uiHash.ListView` in the entire
repository are in **tests**, which hand-build one. Every live read therefore returned `$null`, and
the consequences were invisible because `Wuu.Core.psm1` is the *only* `src/` module without
`Set-StrictMode` — a missing hashtable key is `$null`, not an error.

| Site | Expression | Silently did |
| --- | --- | --- |
| `$GetUpdates` auto-download gate | `if ($null -and ...)` | never fired — auto-download dead |
| `$DownloadUpdates` auto-install gate | `if ($null -and ...)` | never fired — auto-install dead |
| `$RestartComputer` auto-reboot gate | `-not $null` → `$true` | **always** returned early — auto-reboot dead |
| `Start-PendingUpdateCheck` | `@($null)` → empty | **the queue was dead** |
| `Test-PhaseCompletion` | `@($null)` → count 0 | returned `$true` for **every** phase — phase gating dead |
| `$eventAuditWSUSUpdates` | `@($null)` → no rows | silent no-op from console *and* `wuu audit wsus` |

`Start-PendingUpdateCheck` is the **scheduler tick** (`$drainScheduler`, polled every 250 ms by the
console loop and by the guided workflow). Because it iterated `@($null)`:

* an operation queued by the auto chain (`Pending=$true`, `PendingOp` set) was **never started**;
* Phase-E retries (`RetryAt`) were **never promoted** — a timed-out computer never retried;
* phase gating **never applied** to queued items.

So fixing the settings gates alone would have changed nothing: nothing consumed what they queued.

## Why the tests did not catch it

Two suites built the missing object themselves and then asserted the code used it:

* `Test-PendingDrain.ps1` constructed `$global:uiHash.ListView = [pscustomobject]@{ Items = ... }`
  and passed — while production had no such object.
* `Test-AutoFlowChain.ps1` did the same, and additionally fabricated `AutoInstallCheckBox` /
  `AutoRebootCheckBox` with the values it wanted the gates to read.

**A test that supplies the object under test's dependencies from itself cannot fail the way the
application does.** Both suites now drive the real `$stateStore` and `Settings`.

---

## Changes made

### P0-1 — console settings control worker behaviour (brief §2)

Three gates moved to `$stateStore.Settings.*`. The migration had already been *begun and abandoned
mid-function*: `$DownloadUpdates` used `$stateStore.Settings.AutoInstall` to choose `PendingOp`
while the gate two lines above still read the checkbox, so the two disagreed.

Also asserted: the failure direction is safe. With no store, `-not $null` is `$true`, so an
unattended reboot is **refused** rather than performed unexpectedly.

### P0-3 (partial) — the scheduler and phase gating read the store

`Start-PendingUpdateCheck` and `Test-PhaseCompletion` now use `Get-WuuComputerRow -Store`, and the
`ListView.Items.Refresh()` redraw became `$store.Touch()` (the store's existing redraw signal).

`Test-PhaseCompletion` now actually returns `$false` when a phase has work outstanding, which is a
**behaviour change**: phase gating was inert, so a Phase 2 operation could previously start while
Phase 1 was running.

### P2 — WSUS audit reachable

`$eventAuditWSUSUpdates` now resolves targets through `Read-WuuSelection`, the selector every other
console handler uses. The command surface already queues its `-Computer` answer for that call
(`Get-WuuCommandTable`'s `'audit'` entry), so `wuu audit wsus -Computer SRV01` is unchanged.

### Tests and gates

* **`tests\Test-AutoSettings.ps1` (new, 21 assertions)** — extracts the gate *expressions* from the
  shipped source with the AST and evaluates them against synthetic rows and all 8 setting
  combinations. It is not a copy of the logic, so it cannot drift from it.
  **Proven to have teeth:** against the pre-fix module it exits 1 ("found 0 gates"); against the
  fixed module it exits 0. (`-CorePath` exists precisely so that check is repeatable.)
* **`Test-PendingDrain.ps1`** — drives the store; plus a guard that **fails if any shipped source
  reads a GUI control member** (comments stripped with the tokenizer, not a regex).
* **`Test-AutoFlowChain.ps1`** — drives the store and `Settings`; all four chains
  (`Check`, `Download`, `InstallAndRecheck`, `AutoFlow`) verified end-to-end.
* **`Validate-Release.ps1` gates (r)/(s)/(t)** — no shipped code may read a GUI control member; the
  scheduler and phase gate must read the store; all three settings must be consulted. Enforced at
  release, not only in tests.

---

## Not done — still open from the brief

Deliberately **not** attempted in this pass. Listed with what I verified, so the next pass starts
from evidence rather than the brief's assumptions.

| Brief | Status | Verified detail |
| --- | --- | --- |
| §3 one operation per computer | **DONE** | See "Per-computer serialization" below. |
| §4 unify the scheduling model | **DONE** | Every per-computer operation now goes through `Start-UpdateCheckJob`. The five console handlers that composed their own `[powershell]::Create()` + `BeginInvoke` (check / download / install / restart / remove-offline / service-action) now delegate, so they share the per-computer gate **and** the global `MaxConcurrentJobs` cap. Validator gate (x) enforces it. |
| §5 operation-specific timeouts | **PARTIAL** | `TimeoutExpiresAt`/`TimeoutSource` are **written and never read** — dead fields, verified by counting uses vs assignments. A blanket 10-minute hard stop applies (in the cleanup loop) and does not distinguish slow from stuck. |
| §6 credential propagation | **NOT VERIFIED** | Needs a per-operation audit. |
| §7 reboot detection | **OPEN** | Reboot state correctly uses `Microsoft.Update.SystemInfo.RebootRequired`/`Win32_ComputerSystem`, but the online/offline transition in `$RestartComputer` **is** ping-authoritative (`While (Test-Connection ...)`) — up to 600 s offline wait, then an online wait. |
| §8 workflow state vs display state | **PARTIAL** | `State` has a `ValidateSet`, and `OpState` now separates operation state from display state. But `Test-PhaseCompletion` still uses `UpdatesStatus` (a display string) as its predicate. |
| §9 phase failure policy | **DONE** | Explicit policy on the store: `PhaseFailurePolicy` = `BlockOnFailure` (DEFAULT) / `ContinueOnTimeout` / `ContinueOnFailure`, decided by the pure `Test-WuuPhaseFailureBlocks`. The old behaviour `continue`d past failed/timed-out rows, i.e. ContinueOnFailure was hard-coded and unreported. See "Phase failure policy" below. |
| §10 exit codes | **OPEN** | Only `0` and `1` exist. Also `Invoke-WuuCommand` returns once work is *queued*, so a scripted `wuu install` can exit 0 without the install completing. |
| §11 WhatIf | **PARTIAL** | Non-destructive and audited already; reports the planned operation but not the per-computer update breakdown. |
| §12 inventory vs connectivity | **OPEN** | `$RemoveOfflineComputer` deletes rows on a **single** failed `Test-Connection`, and guided pre-flight's "Remove offline computers" calls it. |
| §13 audit integrity | **PARTIAL** | The limitation *is* already documented accurately. No external anchor exists. |
| §14 remaining GUI debris | **DONE for live reads and submissions** | No live GUI control read remains; no per-computer `BeginInvoke` remains in `Wuu.Core` other than the payload's own bounded sub-pipelines and the cleanup runspace. |
| §16 tests | **PARTIAL** | Concurrency is covered (`Test-ComputerBusy`, `Test-SchedulerSerialization`). Reboot/ICMP cases and cancellation are **not**. |

---

## Per-computer serialization (§3) — how it was established, and why it was urgent

### The measured hazard

Submitting a second pipeline to a busy runspace is **silently discarded**:

```
$ps.Runspace = $busyRunspace
$h = $ps.BeginInvoke()          # ACCEPTED - returns a handle
$h.AsyncWaitHandle.WaitOne()    # completes normally
$ps.EndInvoke($h)               # THROWS: "The pipeline was not run because a pipeline is
                                #          already running. Pipelines cannot be run concurrently."
$ps.InvocationStateInfo.State   # 'Failed'
$ps.Streams.Error               # EMPTY until EndInvoke is called
```

So the work never happens, the submission reports success, and the only trace is a log line from the
cleanup loop — the row keeps saying whatever it said before. `Start-UpdateCheckJob` reuses
`$ComputerItem.Runspace`, so this was reachable from every path.

### What now prevents it

* **`OpState`** (`Idle`/`Queued`/`Running`) on the row, distinct from the display `State`.
* **`Test-WuuComputerBusy`** (`Wuu.State.psm1`) — the single authority, consulted by the submission
  point and the scheduler. Read-only, `$null`-tolerant, and never throws (it is called in loops).
* **`Start-UpdateCheckJob`** refuses a busy computer *before* `BeginInvoke` and marks the row
  `Running` after a successful submit. This is the only submission point for scheduled work.
* **The cleanup loop releases `OpState`** on all three job-exit paths (completion, failed
  `EndInvoke`, 10-minute timeout). A failed `EndInvoke` additionally writes a row-level explanation,
  so a discarded pipeline tells the operator instead of vanishing.
* **The scheduler** skips a busy row **without clearing its `Pending` flag**, so a refused request is
  not lost — it runs on a later tick.

### Two traps this work hit, both now guarded

1. **`Test-WuuComputerBusy` must ignore `Pending` in the scheduler** (`-IgnorePending`). The
   scheduler's input queue *is* the rows with `Pending` set, so treating `Pending` as "busy" would
   make it skip every row it was handed, for ever. Found while wiring it, before it shipped; validator
   gate (v) now fails if the switch is dropped.
2. **The gate must run before `Pending` is cleared.** The reverse order loses the request entirely.
   Validator gate (v) checks the offsets.

Both are the kind of change that looks like a simplification and produces a dead scheduler, so they
are gated rather than commented.

### Verification

* `tests\Test-ComputerBusy.ps1` — 16 assertions on the gate itself, **including the measured platform
  behaviour** (so a future reader who thinks the gate is unnecessary sees the evidence in the test).
* `tests\Test-SchedulerSerialization.ps1` — 13 assertions through the real scheduler: a queued
  operation starts and completes; a busy computer is not re-submitted; the refused request stays
  queued and **runs later**; no two operations on one computer overlap (proven from enter/exit
  timestamps, since the payload runs in an isolated runspace and cannot share state); and
  `MaxConcurrentJobs=2` is never exceeded while all 6 queued computers eventually run.
* Validator gates (u)/(v)/(w) enforce the wiring, the deadlock switch, and the release-on-every-exit.

### Recommended next order

1. **§7** (reboot detection is ping-authoritative), then **§12** (a single failed ping deletes
   inventory), then **§10** (exit codes do not distinguish queued from completed).
2. **§5/§6/§8/§16** as a group; §5 needs a design decision (heartbeats) rather than a patch.
3. **§11** opportunistic.

---

## §9 — phase failure policy (done)

**The defect.** `Test-PhaseCompletion` skipped any computer whose `UpdatesStatus` was `Error` or
`Timeout` with a bare `continue`. That hard-coded `ContinueOnFailure` as the only behaviour, and
nothing in the UI or the audit trail said so - so a failed canary silently permitted the next phase.
For patch deployment the safe default is the opposite: stopping is recoverable, continuing past a
failed canary is not.

**What now exists.**

* `$stateStore.Settings.PhaseFailurePolicy` - `BlockOnFailure` (**default**) / `ContinueOnTimeout` /
  `ContinueOnFailure`, set through `Set-WuuPhaseFailurePolicy` (validated).
* `Test-WuuPhaseFailureBlocks` - pure, side-effect free, so the policy is testable without a store,
  a scheduler or a network. An **unknown policy blocks**: a configuration error must not become
  "proceed past a failure".
* `Test-PhaseCompletion` consults it, and reports failures separately from outstanding work.
* Both failure signals are honoured (`State` **and** `UpdatesStatus`). The payloads write one and the
  timeout paths write the other, so checking a single signal lets a failed computer look "settled but
  fine".

### The second bug, found by the test rather than by reading

Adding the policy was not enough. On the first run three assertions failed, exposing that the FAILED
row fell through to the outstanding-work check, where `UpdatesStatus -ne 'All updates installed'` is
true for an errored row - so the phase could **never** complete and `ContinueOnFailure` /
`ContinueOnTimeout` had **no effect on the only case they exist for**. The policy was dead
configuration until a settled failure was handled *before* that check, with its own `continue`.

Validator gate (y) now enforces the ordering, because this is exactly the kind of bug that a
settings-shaped change hides: the setting reads back correctly, the code looks like it consults it,
and it does nothing.

**Tests.** `tests\Test-PhaseFailurePolicy.ps1` - 28 assertions: the default, every policy against
both failure kinds, both signals independently, unknown/empty policy failing safe, `$null` tolerance,
and - through the real `Test-PhaseReady` - that a failed Phase 1 blocks Phase 2 by default and is
*unblocked by changing only the policy*, with every row state held identical.

---

## §4 — one submission point (done in the same pass)

The per-computer gate only helps if submissions go through it. Two problems made that untrue
initially:

1. **`EventGetUpdates` bypassed it entirely on re-check.** It called `Start-UpdateCheckJob` only when
   the row had *no* runspace; otherwise it took an unguarded `BeginInvoke` branch. So the very common
   "check again" path could submit to a busy runspace and be silently discarded.
2. **Four more handlers composed their own pipelines** — download, install, restart, remove-offline,
   service-action — none of which set `OpState` (so the gate could not see them) and none of which
   counted toward `MaxConcurrentJobs`.

All six now delegate to `Start-UpdateCheckJob`, which gained `Restart`, `RemoveOffline` and
`ServiceAction` ops (plus a `-ServiceAction` parameter). Consequences:

* one place composes and submits a per-computer operation, so the gate and the cap cannot be bypassed;
* a busy computer's **restart is refused and reported** rather than queued, because the operator
  explicitly confirmed it (deferring a confirmed reboot silently would be wrong);
* check/download/install **defer with `Pending` set** so the request runs when the computer frees up;
* `MaxConcurrentJobs` now genuinely bounds every console-initiated operation, not just scheduled ones.

Concurrency in the resulting design: per-computer strictly serial; across computers up to
`MaxConcurrentJobs`; the cap is checked by the scheduler *and* implicitly by the gate.

---

## A test that hung, caused by this pass

`tests\Test-CredentialTyping.ps1` hung for 20+ minutes during a full-gate run, twice. **My earlier
"repair" of this suite caused it.** The original test called `Invoke-CimWithTimeout -Credential
'PlainTextPassword'` from a child job where the prompt could not appear. I changed the suite to
extract the function and dot-source it into the test process — so PowerShell tried to **prompt for a
password** and blocked on the inherited console. It had reported 3/3 PASS before that because the
prompt happened to be satisfied by whatever was on stdin.

Test C is now **static**: it asserts `-Credential` is declared `[PSCredential]` (so a string can never
be silently used as a password — binding must convert or fail) and that the typed value is what
reaches `New-CimSession`. That is strictly stronger than the dynamic check and takes 0.5 s instead of
60 s. A "pass" that is really a timeout is not evidence.

The gate script (`C:\Temp\wuu-gate.ps1`, dev-only) now applies a **per-suite timeout and kills
stragglers**, so one hang cannot stall a full run again.
