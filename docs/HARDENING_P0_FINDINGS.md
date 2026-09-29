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
| §5 operation-specific timeouts | **DONE** | See "§5 — operation-specific timeouts" below. A per-op budget table replaces the flat 10-minute stop; the deadline is recorded at submission and read by the cleanup loop, with a heartbeat separating *slow* from *stuck*. `TimeoutExpiresAt`/`TimeoutSource` were dead fields (written, never read) and are now the read side of the decision. |
| §6 credential propagation | **DONE** | See "§6 — credential propagation" below. Auditing it found two real defects, not a clean bill: the saved credential block came from `$global:CredentialConfig.Username` (a variable assigned exactly **once** — its initialiser — so every config recorded `''`), and **nothing read that block on load**, so loading a list under a different credential mode silently changed which account remote operations used. Identity now comes from the `PSCredential` and is compared on load; only identity is persisted, never password material. |
| §7 reboot detection | **DONE** | The reboot wait was `While(Test-Connection ...)` - see below. Reboot STATE was already read correctly (`Microsoft.Update.SystemInfo.RebootRequired`); it was the online/offline TRANSITION that was ICMP-driven. |
| §8 workflow state vs display state | **DONE** | See "§8 — workflow state vs display state" below. The phase gate no longer decides from `UpdatesStatus` (a display string); it reads a three-state `CheckConcluded` plus the workflow `State`. The display-string read in the settled-failure test was also removed — every site that sets `UpdatesStatus='Error'/'Timeout'` sets the matching `State` on the adjacent line, so it could only add disagreement. |
| §9 phase failure policy | **DONE** | Explicit policy on the store: `PhaseFailurePolicy` = `BlockOnFailure` (DEFAULT) / `ContinueOnTimeout` / `ContinueOnFailure`, decided by the pure `Test-WuuPhaseFailureBlocks`. The old behaviour `continue`d past failed/timed-out rows, i.e. ContinueOnFailure was hard-coded and unreported. See "Phase failure policy" below. |
| §10 exit codes | **DONE** | Eight documented codes; `-Async` distinguishes *accepted* from *completed*, so a command that returns with work outstanding exits 3 instead of 0. A dead `$script:CommandExitCode` write in the wrong module scope (which made `audit verify` exit 0 on a **broken chain**) was removed. See "§10 — exit codes" below. |
| §11 WhatIf | **PARTIAL** | Non-destructive and audited already; reports the planned operation but not the per-computer update breakdown. |
| §12 inventory vs connectivity | **DONE** | `$RemoveOfflineComputer` deleted the row on a single failed `Test-Connection`. Now classified by `Update-WuuConnectivityState` (testable) with a consecutive-failure threshold. See below. |
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

1. **§10** (exit codes do not distinguish queued from completed), then **§5** (operation-specific
   timeouts with heartbeats - needs a design decision, not a patch).
2. **§6** (credential propagation audit), **§8** (workflow vs display state in the remaining
   predicates), **§16** (reboot/ICMP and cancellation test cases).
3. **§11** opportunistic.

---

## §7 / §12 — ICMP was load-bearing for state (done)

### The two defects

**§7 - the reboot wait could not terminate on a well-configured host.**

```powershell
While(Test-Connection -Count 1 -ComputerName $computer.Computer -Quiet){   # wait for offline
    Start-Sleep -Seconds 5; $offlineWait += 5
    if($offlineWait -ge 600){ throw "... did not go offline within 10 minutes ..." }
}
```

Windows Firewall blocks inbound echo by default. Against such a host the ping keeps succeeding, the
loop burns its full 600 s, and the restart is then reported as **FAILED** - on a machine that rebooted
perfectly. It is not "ICMP is slightly unreliable"; it is a false failure on the commonest
configuration.

**§12 - one lost packet evicted a server.**

```powershell
if(Test-Connection -Count 1 -ComputerName $computer.Computer -Quiet){ ...online... }
else{ Remove-WuuComputerRow ... }   # a single failure deleted the row
```

The computer then silently stopped being patched, with no record that it had ever been in the set.

### What replaced it

* **`Test-WuuManagementEndpoint`** (`Wuu.Remote.psm1`, exported) - two cheap, non-hanging signals:
  name resolution, then a bounded TCP connect to the RPC endpoint mapper (the thing the DCOM/CIM calls
  depend on). It returns a hashtable, not a boolean, so "not resolvable" and "resolves but no
  endpoint" stay distinguishable - they are different operator actions.
  **It deliberately does not open a WUA session.** An earlier attempt did, and that is what made the
  wait loop unreliable: a WUA session against a host that is still shutting down blocks far longer
  than the surrounding timeout plumbing controls. A `TcpClient.BeginConnect` cannot be blocked by the
  remote host.
* **`Update-WuuConnectivityState`** (`Wuu.State.psm1`, exported) - the single place a probe result is
  turned into a row change: reachable → reset counter; unreachable → keep the row, cancel queued work,
  record the reason; unreachable at the threshold → remove. "Cannot tell" is never treated as offline.
* Config: `ConnectivityFailuresBeforeRemoval` (2 - a single blip cannot evict), `EndpointProbePort`,
  `EndpointProbeTimeoutMs`.

### Why the decision was EXTRACTED rather than left inline

As inline payload code the SS12 policy lived inside `Wuu.Core`'s module scope, so **no test could
reach it** - which is exactly how a one-packet delete survived. It is now a pure function taking a
probe RESULT, so the whole decision table is testable without a network, a runspace or a scheduler.

### One thing I broke and caught

While rewriting the wait loop I **deleted `Restart-Computer`**. The payload would then have waited
~30 minutes for a reboot it never requested - a failure that presents exactly like "the reboot is
slow". Restored, and validator gate (z) now asserts the restart is still issued. It is the second
time in this pass that a rewrite dropped a load-bearing line (`Restart-Computer` here, the
`$targetRows` assignment earlier); both were caught by a check rather than by reading.

**Tests.** `tests\Test-ConnectivityClassification.ps1` - 29 assertions across the probe (fast, honest
reason, resolvable/unresolvable distinguished), the decision table (one failure keeps, repeats remove,
recovery resets, missing probe does not evict, `$null` tolerated), and structurally that no live code
decides with ICMP while the restart is still issued.

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

---

## §10 — exit codes (done)

### The defect

Two things were wrong, and only the first was obvious:

1. **Only `0` and `1` existed.** Five different situations — usage error, operation failure, timeout,
   refusal, audit-integrity failure — all collapsed into `1`, so a script could not tell "you typed
   the verb wrong" from "the change was refused by policy" from "the audit trail is tampered with".
2. **`0` did not mean "completed".** `Invoke-WuuCommand` returns after a *bounded wait*
   (`$CommandWaitSeconds`), so `wuu install -Computer SRV01` could exit `0` while the install was
   merely **queued**. Every CI job that gated on that exit code was reading "accepted" as "done" —
   silently, which is the worst way for that to be wrong.

There was also a third, independent bug found while wiring this up:

3. `Invoke-WuuAuditCommand` set `$script:CommandExitCode = 1` on a broken hash chain. That is
   *Wuu.Command.psm1*'s script scope — **not the caller's** — so the assignment was discarded and
   `wuu audit verify` exited `0` on a broken chain. A gate that always passes is worse than no gate,
   because it is trusted.

### The contract

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | Success | the requested operation **completed** successfully |
| 1 | OperationFailed | one or more targets failed |
| 2 | UsageError | unknown verb, missing argument, invalid input |
| 3 | Timeout | the wait elapsed with work still outstanding |
| 4 | PartialSuccess | *reserved — not currently produced, see below* |
| 5 | AuditFailure | the audit chain failed to verify, or a fail-closed audit write failed |
| 6 | Queued | `-Async` was requested and the work was **accepted**, not completed |
| 7 | Refused | declined before running: missing `-Reason`, or a pre-flight/confirmation refusal |

`Get-WuuExitCode` (with a `ValidateSet`) maps names to numbers and `Get-WuuExitCodeMeaning` maps them
back to prose. They live together so the two cannot drift, and help documents both.

**Why 4 is reserved rather than produced.** With `-Computer A,B` the selection is resolved by *one*
shared answer, so "A worked and B failed" is not observable per target from here — the payload
updates rows, not a result set. Producing a genuine `4` needs per-target completion results, which is
a larger change than an exit-code pass. The number is reserved so it is never later assigned a
different meaning, and the honest answer today is `1`. This is noted in the code, not just here.

### How the classification is derived

`Invoke-WuuCommand` now returns a `Result` name (not merely `Ok`), so the caller maps outcome → code
without re-deriving anything:

* unknown verb / bad subverb / unregistered action → `UsageError`
* mutating verb without `-Reason` → `Refused` (the refusal path, which does not run the handler)
* fail-closed audit write failure → `AuditFailure`
* handler threw → `OperationFailed`
* `audit verify` on a broken chain → `AuditFailure`

Then Core decides completion **from the store**, not from the fact that a call returned:

```powershell
$outstanding = @($targetRows | Where-Object { ($_.OpState -eq 'Running') -or [bool]$_.Pending })
```

* outstanding **and** no `-Async` → `Timeout` (3)
* outstanding **and** `-Async` → `Queued` (6)
* otherwise → the result's own classification (falling back to `OperationFailed`)

Two properties are load-bearing and are enforced by validator gate **(aa)**:

* **the timeout branch is evaluated first.** If `-not $result.Ok` were tested first, a command that
  reported `Ok` but left work running would be classified by the result object alone — i.e. success.
* **the code is assigned unconditionally** (`$script:CommandExitCode = $exitCode`), so a success
  *clears* an earlier value instead of leaving a stale non-zero code behind.

### `-Async`

`-Async` makes "queue it and give me my prompt back" an explicit request, which is what lets the
default be strict. It is parsed in `ConvertTo-WuuCommandLine`, forwarded by Core, and documented in
`-Help`. A script that wants fire-and-forget says so and gets `6`; a script that does not say so gets
`3` rather than a false `0`.

### Verification

* `tests\Test-CommandExitCodes.ps1` — 33 assertions. It checks the vocabulary against the *real*
  function (a test that re-listed the numbers would pass forever while the function drifted), that
  all eight codes are distinct and all have meanings, that an out-of-range code is reported unknown,
  and that each classification is produced by the production path. The Core side is checked
  statically, with a comment explaining why (driving the shell needs elevation, a live WSUS target
  and minutes).
* Validator gate **(aa)** asserts the same invariants in the release gate, plus the two ordering
  properties above and the absence of the wrong-scope `$script:CommandExitCode` write.
* Full suite: **21 pass, 1 skip (elevation-gated), 0 fail.**

### Two test-quality bugs this work exposed

Both were in *my own* new checks, and both produced **false failures** rather than false passes:

* `$coreRaw -match "Async'\]\s*-and\s*\$busy"` — in a double-quoted string `$busy` **interpolates to
  empty**, so the pattern became `...-and\s*\` and the trailing backslash threw *"Illegal \ at end of
  pattern"*. Patterns containing `$` must be single-quoted.
* The validator's equivalent check used `$.Pending` where the code says `$_.Pending`. A bare `$` in a
  regex is an end-of-line anchor, so the check could never match. It now uses literal `.IndexOf`.

### Also fixed: a skip that reported failure

`Test-RemoteTask.ps1` exits `1` when not elevated — but its own header says `1 = failure`, and
`Test-ComputerBusy`/`Test-AutoSettings` signal a skip with a `SKIP:` marker and exit `0`. The result
was a **spurious failure in every non-elevated run**, which is how it surfaced here. It now exits `0`
with the marker, and the harness matches `(?m)^\s*SKIP:` — anchored, because the earlier unanchored
`SKIP` match also caught assertion *names* like "the reboot gate **skips** the reboot" and reported
passing suites as skipped.

---

## §5 — operation-specific timeouts (done)

### The defect

One flat "timeout after 10 minutes" in the job-cleanup loop, applied to every operation. That is wrong
in **both** directions, which is why it is worth more than a constant tweak:

* **healthy long work was killed and reported as a timeout.** A reboot's own waits are
  `$OfflineWaitSeconds` (600) + `$OnlineWaitSeconds` (1800) = **40 minutes**, so a flat 10-minute stop
  guaranteed a false timeout on *every* reboot. A large-estate WSUS search regularly exceeds 10
  minutes too.
* **genuinely hung short work was tolerated for 10 minutes.** A service-control call that needs 5
  seconds held a runspace for ten minutes before anyone noticed, and the global `MaxConcurrentJobs`
  cap counts runspaces — so a few stuck short operations could stall the whole estate.

`TimeoutExpiresAt`/`TimeoutSource` already existed on the row, written in two places — and **read
nowhere**. They are the natural home for a per-op deadline, and they were dead fields.

### What replaced it

A per-operation budget table in the config region:

| Op | Budget | Why |
| --- | --- | --- |
| `Check` / `Download` | 45 min | large-estate search; a flat 10 killed healthy runs |
| `InstallAndRecheck` | 2 h | a servicing-stack update alone can exceed 10 minutes |
| `AutoFlow` | 4 h | must exceed its own reboot waits (600s + 1800s) |
| `Restart` | 45 min | covers the 40-minute wait pair, with margin |
| `RemoveOffline` | 5 min | it is a connectivity probe |
| `ServiceAction` | 5 min | a hung service control is stuck, not slow |
| `default` | 30 min | anything unrecognised is bounded, but not punishing |

Three properties make this work, and each is enforced by a gate:

1. **The deadline is recorded at SUBMISSION** (`Set-WuuOperationDeadline` in the single submission
   point), not recomputed by the loop. One source of truth: the deadline an operator can inspect is
   the deadline enforced. A job entry holds only `(Computer, Runspace, StartTime)`, so the loop cannot
   otherwise know *which* budget applies — that missing piece is exactly why the old code needed one
   number for everything. **This is why the row gained `OpName`.**
2. **The loop reads it, with a bounded fallback.** No deadline on the row (work not submitted through
   the normal path) → the job's own start time plus the `default` budget. Still bounded, and the basis
   is reported so an operator can tell the fallback was used.
3. **A heartbeat distinguishes slow from stuck.** A deadline alone only says "not finished"; the loop
   records `LastHeartbeatAt`/`Heartbeats` while the job is within its deadline, and the status table
   shows `[ServiceAction 4m left beat 12s ago]`. The heartbeat deliberately does **not** extend the
   deadline — it proves the thread is alive, not that progress is being made, and letting it extend
   would mean a hung operation could never be stopped.

### The trap that had to be handled

The deadline is **read, never recomputed**, so a finished row that kept a deadline in the past would
make the *next* operation look expired on its first loop pass — i.e. every operation after the first
would be killed instantly. `Clear-WuuOperationDeadline` is therefore called at **every** place
`OpState` returns to `Idle` (3 sites: success, EndInvoke failure, timeout). The gate asserts the counts
match, so a future exit path cannot be added without clearing.

### The runspace-binding discovery this depended on

The cleanup loop runs in an isolated runspace where module functions do not resolve, so the decision
exists **twice** — once as `Test-WuuOperationExpired` (testable) and once inline in the loop. Injecting
the table required understanding a subtlety, which I probed on this host rather than assumed:

| Scriptblock form | Sees `SetVariable`'d values? |
| --- | --- |
| literal `{ ... }` | **no** — silently `$null` |
| `[scriptblock]::Create("<string>")` | yes |
| `.ToString()` of a literal | yes |

A **plain object** (the hashtable) assigned with `SetVariable` *is* visible to the runspace body; only
*nested literal scriptblocks* fail to bind. That is why the existing log block works (it is built with
`::Create`) and why a naive literal injection of the table would have silently returned "no budget" for
every op. Both facts are recorded in the code at the injection site.

### Verification

* `tests\Test-OperationTimeouts.ps1` — the important part is a **differential**: the loop's decision
  snippet is extracted from the shipped source, injected into a real runspace the way `Wuu.Core`
  injects it, and run on the same 5 inputs as `Test-WuuOperationExpired`; the verdicts must match.
  Without it, two copies of one rule drift and the enforced budget silently stops matching the
  documented one. I verified the differential is not a tautology by breaking the function
  (`if ($false -and ...)`) and confirming the suite fails (3 failures), then reverting.
* Gate **(ab)** asserts the five properties above in the release gate, including that the table has
  **≥3 distinct values** (a table of one repeated number is not per-op) and that `AutoFlow` exceeds its
  own reboot waits.
* Live check: a real store + row driven through a real runspace resolved `op=ServiceAction`,
  `budget=300`, and the recorded deadline — so the wiring works, not just the text.
* Full suite: **22 pass, 1 skip (elevation-gated), 0 fail.**

### Two harness bugs this work produced (both false failures)

* `Test-WuuOperationExpired` initially read the deadline **only** from the row, so the start-time
  fallback the loop needs did not exist in it — the two copies could not agree. Fixed by giving the
  function the same two bases the loop has.
* The differential check cut the snippet at an `$elapsedMin` line that sits *after* the heartbeat, and
  at a marker that did not match the source, producing an unbalanced snippet that threw before
  emitting a verdict ("block produced no verdict") — reported as a *disagreement* rather than an
  extraction failure. It also tried to inject a fake clock, which cannot work: the snippet calls
  `Get-Date` itself, so `$nowTs` was overwritten and three "future deadline" cases came back expired.
  The harness now cuts at the `} else {` that opens the timeout action, asserts the snippet contains
  the deadline computation, uses real time with ≥5 minutes of margin, and says in a comment why a fake
  clock is impossible.

---

## §8 — workflow state vs display state (done)

### The defect

`Test-PhaseCompletion` decided "has this row settled?" from
`UpdatesStatus -ne 'All updates installed'` — a **display string**, written from eight sites with five
different values. Two consequences:

* re-wording a status message was a silent change to **phase gating**;
* the string can disagree with the row's actual work, and then it decides whether a phase advances.

The production-reachable failure: a row with `Available = 3` whose `UpdatesStatus` still reads
`All updates installed` (stale wording) was considered **settled**, so its phase advanced with updates
outstanding. That case is now a named test.

### What replaced it

The row gained `CheckConcluded`, a **three-state** boolean:

| Value | Meaning |
| --- | --- |
| `$null` | **not established** — never checked (a row loaded from config gets `State='Queued'` + `UpdatesStatus='Unknown'` with a "run wuu check" message) |
| `$false` | a check ran and concluded with nothing outstanding |
| `$true` | a check ran and there **is** work outstanding (updates available, or a reboot pending) |

`$null` is deliberately **not** "clean": a phase must not pass on machines nobody has checked — that
would be advancing the workflow on ignorance, and it is the same class of ambiguity this pass exists to
remove. The gate therefore requires the row to be *visibly* settled (`State` not mid-operation, no
counts, no reboot) before `$null` advances, and logs when it does so a skipped row is visible rather
than silent.

While in the file, the settled-failure test was also reduced to `State` alone. It previously read the
display sentinels too (`$status -in @('Error','Timeout')`) — and every site that sets
`UpdatesStatus='Error'/'Timeout'` sets the matching `State` on the adjacent line, so the extra test
could only **add** a way to disagree, never catch a case `State` missed.

### A claim I had to retract mid-change

I initially wrote, in both the code and the test, that the old predicate made a config-loaded row
"outstanding **forever**, so its phase could never complete". Checking the row constructor showed a
fresh row is `State = 'Queued'`, **not** `'Unknown'` — so under the old predicate that row was
*blocked* (not falsely completed) and would unblock once it was checked. The comment now describes the
real defect (the stale-wording case, which is production-reachable and is tested), and the test asserts
what the code actually does rather than what I had assumed. The lesson is the same one the brief opens
with: verify from the code, not from the comment — including my own.

### Verification

* `tests\Test-PhaseWorkflowState.ps1` — 17 assertions driving the **real** `Test-PhaseCompletion`
  through a real store. Covers: the stale-wording defect; re-wording the status does not change the
  verdict; concluded-clean settles; updates-available, reboot-required, installing and Pending all
  block; `$null` is not read as clean; the SS9 policy ordering is preserved; and the payload records
  all three outcomes. It invokes the gate by publishing `$script:WuuCtx` **inside the module's own
  scope** (`& $mod { ... }`), since `Import-Module -Global` does not populate a module's `$script:`
  scope.
* Gate **(ac)** asserts the same, against comment-stripped raw text. It uses **line-based** stripping
  rather than `Get-WuuCodeWithoutComments`, which joins tokens with spaces, **discards newlines** (so
  `Get-WuuFunctionBody` sliced the whole file) and drops `$` (so `\$state -in` could never match) —
  three false failures from one helper. That helper is still correct for its own callers; this gate
  just cannot use it.
* `tests\Test-PhaseFailurePolicy.ps1` **had to change**: one assertion flipped a row to complete by
  setting `UpdatesStatus` alone — it encoded the very defect SS8 removes. It now sets the workflow
  fields, and a comment says why.
* Full suite: **23 pass, 1 skip (elevation-gated), 0 fail.**

---

## §6 — credential propagation (done)

### Method

The brief marked this **NOT VERIFIED**, so the first step was to *probe* rather than read. Two defects
came out of it, neither of which was visible from the comments:

**A. The saved credential identity was always empty.** `Save-ComputerListConfig` wrote
`CredentialConfig.Username` from `$global:CredentialConfig`, a variable assigned exactly **once** in the
whole codebase — its initialiser (`@{ Username = ''; Domain = ''; ... }`). The real name lives in
`$global:CustomCredentials.UserName`. Measured: with a credential configured as `CONTOSO\svc-wuu`, the
saved config loaded back with `Username=''` and `Domain=''`. Every configuration ever saved recorded
nothing.

**B. Nothing read that block on load.** `$eventLoadConfig` never looked at
`$loadResult.Config.CredentialConfig`, so loading a list saved under one credential mode into a session
using another **silently changed which account every remote operation would run as**. Nothing failed —
the operations simply ran as a different principal, which is exactly the kind of difference that stays
invisible until an access-denied appears on some host, or does not appear when it should.

### What replaced it

* `Get-WuuCredentialStateSignature` — the credential mode as `{ Enabled; UserName; Mode }`, read from
  `CustomCredentials.UserName`. **Identity only**: no password, no SecureString, nothing derived from
  one. The list itself is already encrypted with the operator's passphrase, and putting reversible
  credential material inside it would widen the blast radius of a weak passphrase for no benefit.
* `Test-WuuCredentialStateMatches` — compares a saved mode against the running session and returns a
  specific reason (`saved with 'custom' credentials but this session is using 'current-process'`, or the
  two account names) rather than a vague "mismatch".
* The load path now compares and **warns without auto-correcting**. Silently switching the operator's
  credentials on load would be a bigger surprise than the warning; the operator is told which
  credentials will actually be used and how to change them.

The propagation matrix was then verified rather than assumed — the gate and the test together assert:

| Property | Assertion |
| --- | --- |
| the two remote task paths that **change** a machine both resolve a credential | `Windows Update download` and `Windows Update install` |
| the resolved credential is actually **passed** to the remote task | ≥2 `InvokeRemoteTaskScript ... -Credential $remoteCred` sites |
| custom credentials are **not** applied to the local machine | `-ne 'localhost' -and -ne $env:COMPUTERNAME` guard at both sites (the process token is already the right principal, and local DCOM rejects explicit credentials) |
| the resolver order is custom → default, with the outcome **cached** | including `CredentialCache[$name] = $null` as an explicit "use default" entry, not an absent key |
| the module-side and runspace-side resolvers agree | same order, same cache semantics |
| the probe credential is typed `[pscredential]` | so a plain-string password cannot be passed as one |
| no password reaches a log or the audit trail | matched as password-shaped **expressions**, not the word "password" |

### Verification

* `tests\Test-CredentialPropagation.ps1` — 26 assertions, including a real Save/Import round trip that
  **fails against the pre-fix code** (it asserts the identity survives).
* Gate **(ad)** — the same properties in the release gate, including "the credential identity is still
  read from `$global:CredentialConfig.Username`" as an explicit failure.
* Full suite: **24 pass, 1 skip (elevation-gated), 0 fail.**

### A test bug worth recording, because it recurred three times

The first version of the leak check flagged any log line containing the word "password" — and reported
**four false failures** on correct lines: `Write-ErrorLog "Secure password prompt unavailable: ..."` logs
that the secure *prompt* failed and interpolates only the exception text. It now matches password-shaped
expressions (`$password`, `.Password`, `GetNetworkCredential`, `SecureStringToBSTR`, …).

The same class of mistake appeared three times in this pass — a check matching the comment that
explains the code it is checking (SS8 quoting the removed predicate, SS6 quoting the removed
`CredentialConfig` read, and SS6 matching "never a password" in its own comment). Each was fixed
ad-hoc before it was recognised as **one** problem, so the validator now has a shared
`Get-WuuTextWithoutComments` helper that strips **both** comment lines and block comments. The
existing `Get-WuuCodeWithoutComments` could not be reused: it joins tokens with spaces, which discards
newlines (breaking `Get-WuuFunctionBody`, which slices to the next `"\nfunction "`) and drops `$`
(so a `\$state -in` pattern could never match). The first draft of the new helper was itself broken the
same way — its doc comment contained the literal block-comment delimiters, which closed the comment
early. That is noted in the helper so the next person does not repeat it.
