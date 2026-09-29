# WUU2-CLI v1.5.0-beta.2-cli

**Hardening build.** The command surface and the update engine are unchanged — same verbs, same
options, same menu. This release is a **correctness pass over behaviour that used to fail silently**,
plus the regression suites and release gates to keep it fixed.

Read the "Behaviour changes" section before deploying: four of them change what you will *see*, and
one changes what a script must expect from an exit code.

Everything here was verified against the shipped code rather than against the documentation, and the
reasoning — including the findings that were wrong at first — is in
[`HARDENING_P0_FINDINGS.md`](HARDENING_P0_FINDINGS.md).

---

## Why "silent" is the theme

The defects this build fixes share one property: **nothing failed loudly**. They were found by
inspecting the code against the state store, not by any error surfacing.

| Was happening | Why nobody noticed |
| --- | --- |
| Auto-download, auto-install and auto-reboot never fired; the scheduler never ran; phase gating passed everything | The gates read WPF control members that are `$null` in this edition, and `Wuu.Core` has no `Set-StrictMode`, so a missing key is `$null` rather than an error |
| The audit trail's operation deadline was recorded and never read | The field was written in two places and read nowhere |
| The saved credential identity was always empty, then ignored on load | Written from a variable assigned exactly once (its initialiser) |
| `wuu install` exited `0` while the install was still queued | The wait is bounded, and "accepted" was reported as "success" |

---

## Behaviour changes — read these

### 1. Exit codes: `0` now means *completed*

Eight documented codes instead of `0`/`1`, so a script can gate on the specific outcome:

| Code | Meaning |
| --- | --- |
| `0` | success — the operation **completed** |
| `1` | operation failed (one or more targets) |
| `2` | usage error |
| `3` | timeout — work still outstanding |
| `4` | partial success *(reserved, not produced — see below)* |
| `5` | audit failure — chain broken, or a fail-closed audit write failed |
| `6` | queued (`-Async`: accepted, not completed) |
| `7` | refused (most often a missing `-Reason`) |

**If you script against this tool, re-read your exit-code handling.** Previously a broken audit chain
exited `1`; it now exits `5`. A queued install previously exited `0`; it now exits `3`, or `6` if you
pass the new `-Async`.

`4` is reserved but never produced: with `-Computer A,B` the selection resolves through one shared
answer, so per-target outcomes are not observable from the command layer. Reporting `1` is the honest
answer. See [`EXIT_CODES.md`](EXIT_CODES.md).

### 2. Phase gating stops on failure by default

`PhaseFailurePolicy` defaults to **`BlockOnFailure`**. Earlier builds advanced past a failed
computer, silently — the unsafe option. Use `ContinueOnTimeout` (timeouts tolerated, failures block)
or `ContinueOnFailure` to restore the old behaviour, but note that a failed canary permitting the
next wave is exactly the case the default exists to prevent.

### 3. Timeouts are per operation, and report which one

The flat 10-minute stop is gone. It was shorter than a restart's own waits (600 s offline + 1800 s
online), so **every** reboot was reported as a timeout, while a hung 5-minute service action held a
runspace for ten minutes.

| Operation | Deadline |
| --- | --- |
| check / download | 45 min |
| install + re-check | 2 h |
| full self-driving chain | 4 h |
| restart | 45 min |
| remove-offline / service action | 5 min |
| anything unrecognised | 30 min |

The status line shows the operation, remaining budget and heartbeat while it runs:

```
  SRV01  Phase 1  Downloading  A:3 D:1  [Download 12m left beat 18s ago] Downloading 2/3...
```

### 4. Credential mode is recorded and compared

A saved computer list now records the credential **mode** and username (identity only — never a
password), and loading it into a session using a different mode **warns** instead of silently
switching which account every remote operation runs as.

### 5. `-WhatIf` prints a per-computer plan

Not cosmetic. A busy computer is **deferred** for check/download/install but **refused** for
`restart` and `service` — so the old one-line "would restart 10 servers" could be false for three of
them. The plan lists each computer's action, why, and any name that resolved to nothing:

```
  would run 'restart' against SRV01,SRV02 - no changes made.
    COMPUTER               PHASE      ACTION    NOTE
    SRV01                  Phase 1    run
    SRV02                  Phase 1    skip      busy (Running) - a confirmed restart is never silently deferred
  Total: 1 would run now, 1 would be SKIPPED (busy).
```

`-WhatIf` still changes **nothing** — including the audit trail, so it can be repeated freely.

---

## What to re-test

1. **A queued install must not look successful.** With a slow target, `wuu install -Computer X
   -Reason "..."` should exit `3` (or `6` with `-Async`) if it has not finished.
2. **`wuu audit verify` on a deliberately damaged log must exit `5`**, not `0` or `1`.
3. **Phase gating:** with a failed host in Phase 1, Phase 2 must **not** start (default policy).
4. **Reboot a host.** With the old 10-minute stop a healthy reboot reported a false timeout; it
   should now complete, and a host that never appears to go offline should succeed with a
   fast-reboot note rather than a failure.
5. **Credential warning:** save a list with custom credentials, disable them, reload — a warning
   should name both modes.
6. **`wuu restart -All -WhatIf`** should list each computer's action, and any busy ones as skipped.
7. **Long-running operations** should show the deadline and a live heartbeat, not a bare
   "Searching...".

---

## Verification

- **26 regression suites pass, 1 skips** (`Test-RemoteTask` needs elevation; it exits `0` with a
  `SKIP:` marker rather than reporting a false failure). That is **27 runnable suites, up from 16**
  at `v1.5.0-beta.1-cli` — the 11 new ones cover the behaviours this release fixes.
- The release gate ([`Validate-Release.ps1`](../Scripts/Validate-Release.ps1)) now enforces this
  release's invariants structurally, so a regression fails a build rather than shipping. New gates
  cover exit codes, per-operation deadlines, workflow-vs-display state, credential handling,
  `-WhatIf` semantics, reboot/cancellation surfaces, and source encoding.
- Each behavioural fix has a suite that **fails against the pre-fix code**, and the differential
  assertions were checked for tautology by deliberately breaking the behaviour and confirming the
  suite fails.

### A note on the test suites

Several suites were quietly *wrong* before this build, in ways that mattered:

- `Test-PendingDrain` and `Test-AutoFlowChain` **hand-built the very objects whose absence was the
  bug** — they supplied a fake `uiHash.ListView`, so they passed while the real scheduler did
  nothing. A test that supplies the dependency under test cannot fail the way the app fails.
- `Test-RemoteTask` exited `1` when not elevated, making every non-elevated run report a failure.
- `Test-PhaseFailurePolicy` asserted a row completes by setting the *display string* alone — it
  encoded the defect it was meant to catch.

---

## Known gaps, unchanged

- **The audit trail is tamper-evident, not tamper-proof.** No external anchor exists, so a
  sufficiently privileged operator can delete a whole day's file and the remainder still verifies.
  Designed, not implemented — the largest known gap.
- **`4` (partial success) is reserved but not produced**, for the reason given above.
- **Debug logging still ships enabled** (`$global:EnableDebugLogging = $true`) and writes large
  files. Set it to `$false` in `src/Wuu.Core.psm1` for production.
- `tests\Test-ColumnResize.ps1` and `tests\Test-DragResize.ps1` are GUI leftovers that should be
  deleted (`DragResize` hangs).
