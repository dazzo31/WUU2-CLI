# WUU2-CLI v1.5.0-beta.3-cli

**Sequential hardening build.** Same verbs, same options, same engine as beta.2. What changed is that
the concurrency and identity guarantees the architecture *described* are now **enforced** — and there
is a release gate plus a regression suite behind each one.

Read "Behaviour changes" before deploying: two of them change what a script or an operator will see.

Everything here was verified against the shipped code rather than against the documentation. The
per-invariant status table — what is enforced versus still target — is
[`.github/copilot-instructions.md`](../.github/copilot-instructions.md) §8, and the pass is recorded in
[`HARDENING_COMPLETION_REPORT.md`](HARDENING_COMPLETION_REPORT.md).

---

## Why this is a release and not a patch

beta.2 was a correctness pass over behaviour that failed **silently**. This one closes defects that
were **exploitable** — reachable, unbounded, or silently destructive — plus four that mattered for
confidence rather than behaviour:

| Was happening | Consequence |
| --- | --- |
| The global concurrency cap was applied only in the scheduler tick | Every console handler calls the submission point **directly, in a loop**. A fleet-wide operation could start one pipeline per computer with **no ceiling** |
| A second request to a busy computer silently replaced the queued one | `download` then `install` destroyed the download and said nothing. `install` then `download` destroyed the install — an operator who asked for more got less |
| No operation identity existed | Invariant "one operation per computer" made the stale-worker race *unreachable*, not *safe*. Nothing rejected a stale result |
| Exit code `4` was reserved but unreachable | A mixed fleet reported a flat `1`, which tells a script nothing about which targets to re-run |
| `.vscode/settings.json` set `files.encoding: "utf8"` | In VS Code `utf8` means **without BOM** — the setting worked against the documented requirement |

---

## Behaviour changes — read these

### 1. Fleet operations are now throttled by `MaxConcurrentJobs`

If you raise `MaxConcurrentJobs`, this is the release where it starts meaning what it says. Previously
it bounded the *scheduler*, and the scheduler was not the path a `wuu check -All` took.

* A submission beyond the cap is **deferred, not dropped**: the computer stays queued and the
  scheduler admits it on a later tick. You will see the operation run later rather than immediately.
* The refusals are logged at INFO, so a throttled run is distinguishable from one that never started.
* If you have **lowered** the cap to control load, expect operations to complete more slowly. That is
  the cap working.

The semantic is documented at the point of definition: the cap counts **in-flight operations across the
whole estate**, which — because one computer may have only one operation at a time — is also the number
of computers currently working.

### 2. A displaced pending request is now reported

One queued request per computer; a newer request wins. The difference is that the replacement is now
**printed**:

```
  Download started for 2 computer(s).
  1 already busy - queued to run when they finish.
  1 had a queued request REPLACED by this one (one request per computer): SRV07 (Download -> InstallAndRecheck)
```

Automatic follow-ups (the auto-download / auto-install tails) are **not** allowed to displace a request
you made — they fill an empty slot or skip.

### 3. `4` — partial success — is now produced

| Code | Meaning |
| --- | --- |
| `0` | success — the operation **completed** |
| `1` | operation failed (one or more targets) |
| `2` | usage error |
| `3` | timeout — work still outstanding |
| `4` | **partial success — some settled targets succeeded and some did not** |
| `5` | audit failure — chain broken, or a fail-closed audit write failed |
| `6` | queued (`-Async`: accepted, not completed) |
| `7` | refused (most often a missing `-Reason`) |

**If you gate on `$LASTEXITCODE -ne 0`, `4` is non-zero — nothing breaks.** If you gate on `-eq 1`, a
mixed run that used to report `1` now reports `4`. Re-run the failing targets rather than all of them.

Two rules that keep this from flapping: targets that have **not settled** are ignored (a large estate
still working is not a partial failure — outstanding work is signalled by `3`, or `6` with `-Async`),
and *every* settled target failing is `1`, not `4`.

### 4. A superseded worker cannot touch the replacement

Not usually visible, but it is the reason the timeout path is now safe. If an operation is stopped and
the computer resubmitted before the cleanup loop settles the old job, the old job can no longer release
the new operation's lock or overwrite its status. Before, that could admit a third operation against a
runspace that was still draining — which the runspace then discards silently.

---

## Also in this release

**Correctness and safety**

* Every operation carries an identity (`OperationId`), created **before** the pipeline starts, recorded
  on the job entry and injected into the worker. Two rules enforce it: a release requires *proven*
  ownership, a write is refused only when *proven* stale. They are deliberately not the same rule.
* The timeout path detaches the computer's runspace before releasing the lock, so a resubmission cannot
  inherit one that is still tearing down.
* `Remove-WuuComputers` — which bypassed the cleanup loop entirely — now releases the lock, clears the
  deadline and retires the identity.

**Tooling**

* **New aggregate test runner:** `Scripts\Invoke-TestSuites.ps1`. The documented loop discarded every
  suite's exit code, so a failing tree reported success. The runner captures exit codes, separates
  `SKIP` from `PASS`, imposes a per-suite timeout, and returns non-zero on any failure.
* **New CI:** `.github/workflows/validate.yml` runs the release gate and the full suite on every push
  and pull request, on Windows PowerShell 5.1.
* `Test-ModuleImport.ps1` could not fail — it printed `MISSING <cmd>` in red and exited `0`. It now
  reports and exits non-zero.
* `.vscode/settings.json` sets `files.encoding: "utf8bom"` for PowerShell files.

**Tests:** 5 new suites, 735 assertions, 32 pass / 1 skip / 0 fail. The one skip is `Test-RemoteTask`,
which needs elevation — it is reported as a skip, not counted as coverage.

---

## Upgrade notes

* **No command or option changed.** Scripts that avoid exit code `4` as a specific value keep working
  unchanged.
* **Re-read your exit-code handling** if you branch on individual codes rather than on `0`/non-zero.
* **A beta audit trail is self-identifying** — records carry `wuuVersion: v1.5.0-beta.3-cli`. Do not
  treat beta evidence as production evidence.
* **The credential behaviour from beta.2 is unchanged**: a configured custom credential is used or the
  operation fails. It never falls back to the process identity.

---

## Known limitations

Stated so they are not mistaken for done:

* **Terminal state is not guarded.** `TimedOut` is deliberately recoverable, not terminal, and there is
  no transition guard preventing a settled operation from later changing state. This needs the
  operation **record** (below), and it is the last invariant the §8 table still marks TARGET.
* **No operation record.** Identity exists, but there is no object carrying
  `RequestedAt`/`OperationType`/`Result`. Per-computer row fields remain the only granularity.
* **No process-lifecycle test battery.** Cancellation and reboot paths have suites; CLI-exit-mid-run,
  Ctrl+C and worker-crash cases do not.
* **`Test-RemoteTask` cannot run in CI** — it needs elevation, so the remote scheduled-task path is
  exercised by hand only.
* **Two stale GUI suites remain** (`Test-ColumnResize`, `Test-DragResize`). Excluded by the runner;
  ColumnResize fails and DragResize hangs by design. Both should be deleted.

The audit trail remains **tamper-evident, not tamper-proof** — a host administrator can delete it, and
no external anchor exists.
