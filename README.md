# WUU2-CLI

**Windows Update Utility — console edition.** Check, download, install and reboot Windows Updates
across a fleet of remote machines from a terminal, with a hash-chained **audit trail** built for
**ISO/IEC 27001:2022 A.8.15** review.

No GUI, no WPF, no XAML. Pure PowerShell 5.1. Same update engine as the
[GUI edition](https://github.com/dazzo31/WUU2), driven from a menu or from scriptable commands.

> **This document tracks the released version.** When a release changes behaviour described here,
> this file is updated in the same commit as the version bump; see
> [`docs/RELEASE_NOTES_v1.5.0-rc.1-cli.md`](docs/RELEASE_NOTES_v1.5.0-rc.1-cli.md) for what
> changed most recently.

```
  WUU2-CLI - Windows Update Utility (console edition)
  Press ? for help, t to toggle auto download/install/reboot, q to quit.
  Run with -Help for scriptable commands (wuu check -All, wuu install -Computer X).

  COMPUTER             PHASE     STATE          UPDATES           STATUS
  ------------------------------------------------------------------------
  SRV01                Phase 1   Complete       A:3 D:3           Updates installed
  SRV02                Phase 1   Downloading    A:3 D:1           [Download 12m left beat 18s ago]
  SRV03                Phase 2   Queued         A:0 D:0           Waiting for Phase 1

  Auto download: on    Auto install: on    Auto reboot: off
```

The bracketed field appears only while an operation is running: it names the operation, its remaining
budget and how long since the last heartbeat, so "still working" is distinguishable from "stuck"
without reading a log.

---

## Why this edition exists

The GUI edition is a WPF application: `uiHash.<Control>.Dispatcher.Invoke` marshalling, a
`DispatcherTimer`, a ListView you right-click. That is a lot of machinery for a tool an
administrator runs headless, on a jump box, over RDP, or during a change window.

This edition keeps the engine and removes the presentation layer. The state that used to live in
WPF controls now lives in a thread-safe store (`src/Wuu.State.psm1`), and the UI is a console shell
(`src/Wuu.Console.psm1`) that renders it. Everything downstream — update search, download, install,
WSUS audit, credentials, phases, throttling — is the same code.

Two consequences worth stating up front:

- **It runs anywhere PowerShell 5.1 runs.** No WPF assembly dependency for the interface, so it
  works in a plain console, a remoting session, or an unattended job. (`-STA` is still required —
  the Windows Update COM APIs and the worker runspaces are apartment-affine.)
- **It is scriptable.** The operations that change remote state are also verbs, which is what makes
  the audit trail meaningful: a change made by a scheduled task is recorded exactly like a change
  made by a human. (A few menu-only conveniences — phase display, the settings toggle, the AD
  acquisition screen — have no verb; see [Commands](#commands).)

### Two interactive front ends

Running `WUU.ps1` with no arguments gives the **guided workflow**: an acquisition-first shell that
walks you through add → review → save → pre-flight → check → download → install → restart → verify,
confirming each change and asking for its reason. It does not show update operations until a
computer set exists.

```powershell
.\WUU.ps1                 # guided workflow (default)
.\WUU.ps1 --flat-menu     # the older single-screen menu (27 keyed operations)
```

The flat menu is retained as a deliberate fallback: the guided workflow is newer orchestration, and
the flat menu is the path that still works if a screen misbehaves. Its design is described in
[`docs/INTERACTIVE_UI_SPEC.md`](docs/INTERACTIVE_UI_SPEC.md).

---

## Quick start

Clone or extract a release, then from an elevated PowerShell prompt:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WUU.ps1
```

It requests elevation itself if you forget — accept the UAC prompt. With no computers in the list
you get the guided acquisition path; once a set exists you get the update workflow.

Prefer commands? The operations that change remote state are verbs:

```powershell
.\WUU.ps1 -Help                                              # full verb list
.\WUU.ps1 check  -All
.\WUU.ps1 show available -Computer SRV01 -Json
.\WUU.ps1 install -Computer SRV01 -WhatIf                    # dry run, changes nothing
.\WUU.ps1 install -Computer SRV01 -Reason "CHG-1041 security patches"
.\WUU.ps1 audit verify                                       # check the audit chain
```

### Exit codes

The numbers are the contract: a script branches on them. This table names each code; the full
contract - per-verb causes, the `-Async` interaction, and what the `-Json` document carries - is in
[`docs/EXIT_CODES.md`](docs/EXIT_CODES.md), which is the normative copy if the two ever disagree.

| Code | Meaning |
| --- | --- |
| `0` | success — the operation **completed** |
| `1` | operation failed (one or more targets) |
| `2` | usage error — check the verb and its arguments |
| `3` | timeout — the wait elapsed with work still outstanding |
| `4` | partial success — some settled targets succeeded and some did not |
| `5` | audit failure — the chain failed to verify, or a fail-closed audit write failed |
| `6` | queued — `-Async` was requested and the work was **accepted**, not completed |
| `7` | refused — declined before running (most often a missing `-Reason`) |

**`0` means completed, not queued.** `wuu install` submits work to a background runspace and waits a
bounded period. If work is still outstanding when that window closes, the command exits **`3`**, not
`0` — a script must never read "accepted" as "done". Pass `-Async` when fire-and-forget is what you
actually want, and that becomes an explicit **`6`**. Gate on specific codes rather than `-ne 0`: a
blanket "non-zero = retry" would retry a tampered audit log.

`4` means **some settled targets succeeded and some did not** — `-Computer A,B,C` where C failed. Work
that has not settled is not a failure and is not counted, so a large estate working through its queue
does not read as partial success; outstanding work is signalled by `3` (or `6` with `-Async`). Every
settled target failing is `1`, not `4`. See [`docs/EXIT_CODES.md`](docs/EXIT_CODES.md) for the full
contract, including what JSON `-WhatIf` returns and how `-Async` interacts with the exit code.

**Tip** — create a `wuu.cmd` on your PATH to avoid typing the host:

```bat
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0WUU.ps1" %*
```

---

## Requirements

| | |
| --- | --- |
| **Host** | Windows PowerShell 5.1 (recommended). PowerShell 7 is a best-effort target for the remote worker paths. |
| **Privileges** | Administrator on the host. WUU requests elevation if it is not already elevated. |
| **Apartment** | `-STA` required — the update COM APIs and per-computer runspaces are apartment-affine. WUU detects a non-STA host and restarts itself in STA mode. |
| **Targets** | Admin rights for the account running WUU (or configured alternate credentials), and WMI/DCOM reachable through the firewall. **No WinRM listener, PsExec or admin share is needed** for check/download/install. |
| **Target OS (download/install only)** | Windows 8 / Server 2012 or later. Download and install run as a temporary SYSTEM scheduled task on the target; Windows 7 targets are not supported for those two operations. |

---

## Commands

```
wuu                          interactive menu (default)
wuu <verb> [options]         run one operation and exit
```

| Verb | Does |
| --- | --- |
| `check` | Search for available updates on the given computers |
| `download` | Download pending updates to the targets |
| `install` | Install downloaded updates |
| `restart` | Restart the targets |
| `service` | Start/stop/restart the Windows Update service |
| `show` | `available` \| `installed` \| `history` \| `errors` \| `phases` |
| `add` / `add-file` | Add computers manually or from a CSV/TXT list |
| `remove` / `clear` / `prune` | Remove named computers, clear the list, or prune offline ones |
| `phase` | Assign computers to a deployment phase |
| `credentials` | Configure alternate remote credentials |
| `config` | `save` \| `load` — encrypted computer-list config (one file, several named lists) |
| `export` | Export the computer list to a file |
| `logs` | View a target's Windows Update log |
| `audit` | `wsus` (audit a target) \| `verify` \| `show` \| `export` \| `anchor` (the local audit trail) |
| `report` | Deployment/reliability report over the audit trail (read-only) |

Common options: `-Computer`, `-All`, `-Reason`, `-Path`, `-LogPath`, `-Json`, `-WhatIf`, `-Async`,
`-ListName`, `-Help`. `-Reason` is **required** for verbs that change remote state — see the audit
trail below.

`-WhatIf` on a mutating verb prints a **per-computer plan**, not one sentence: what each computer
would do (`run` / `queue` / `skip` / `noop`), why, and any name that resolved to nothing. It changes
**nothing**, including the audit trail — a dry run may be repeated freely while preparing a change.

The distinction that matters: a computer that is already busy is **deferred** for check/download/
install (the request is honoured when the current operation finishes) but **refused** for `restart`
and `service` — a confirmed reboot is never silently postponed. The plan says which.

---

## Features

### Phased deployment (5 phases)

Assign computers to up to 5 phases. A phase's checks do not start until every computer in the
previous phase is settled, so you roll updates across an estate in waves instead of hitting
everything at once. Phase assignments persist in saved computer lists.

An errored or timed-out computer is **not** skipped by default. `PhaseFailurePolicy` defaults to
`BlockOnFailure` — for patch deployment, stopping is recoverable and continuing past a failed canary
is not. The other two values are `ContinueOnTimeout` (timeouts tolerated, failures block) and
`ContinueOnFailure`; the policy is a store setting, decided by a tested function, and reported.

> **This changed.** Earlier builds advanced past a failed computer and had **no** policy at all —
> errors and timeouts silently permitted the next phase, which is the unsafe behaviour. If you relied
> on a failed canary not stopping the roll-out, set `ContinueOnFailure` explicitly.

### Full automation

Auto-download, auto-install and auto-reboot toggles (menu key `t`) run the complete per-computer
pipeline: **check → download → install → reboot (if required) → re-check**.

### WSUS audit

`wuu audit wsus -Computer SRV01` compares WSUS-assigned updates against the standard Windows Update
count, including download states, WSUS server detection and reboot status.

### Alternate credentials

For non-domain or restricted hosts. Credentials are held as `SecureString`/`[pscredential]`
end-to-end and cached per computer to avoid repeat prompts. Note that PowerShell 5.1's
`Get-CimInstance` has no `-Credential` parameter, so alternate credentials flow through
`New-CimSession -Protocol DCOM`.

A saved computer list records the credential **mode** (custom account vs the process account) and
its username — identity only, never a password. On load, a session whose credential mode differs is
**warned about**, not silently switched: every remote operation would otherwise run as a different
principal, which is the sort of difference that stays invisible until an access-denied appears (or,
worse, does not).

> **This changed.** Earlier builds wrote an always-blank identity into the saved config *and* read
> nothing back on load, so the warning did not exist.

### Deployment reporting

`wuu report` answers "did the roll-out work, and what keeps failing?" from the audit trail.

```powershell
wuu report                                  # last 7 days, by day
wuu report -Period 30d -GroupBy Week        # wider window, weekly buckets
wuu report -FailedOnly -Json                # just failures, machine-readable
wuu report -Out report.csv -Dataset Runs    # CSV: Runs | Targets | Causes
wuu report -LogPath D:\handover\audit-20261001.jsonl   # one file, e.g. an air-gapped bundle
```

**What it reports, and what it deliberately does not.** The trail records a deployment BATCH: its
outcome and the list of machines it targeted. It does **not** record a per-machine result, so a
fleet-wide "95% of machines patched" cannot be derived from it — and the report says so rather than
printing a rate that implies it. What it does report, and what those numbers mean:

| Figure | Level | Meaning |
| --- | --- | --- |
| Succeeded / Failed / Refused | per RUN | the batch outcome; success rate is over settled runs |
| Failing targets | per MACHINE | machines that **failed** a deployment, with attempts and last error |
| Top causes | per RUN | why runs did not settle, refusals marked separately from failures |

**A refusal is not a machine failure.** This distinction is the one that matters most, and getting it
wrong is easy: on this machine's own store, one host had 112 runs refused for a missing `-Reason`.
Counting those as failures would put it top of a "failing machines" table at a 100% failure rate —
telling you a host is broken when in fact nobody ever tried to patch it. Refusals are reported (they
are a real process finding), but separately, and they never appear as failing machines.

**In the console**, the report is reachable three ways: `Reports / audit` → `Deployment report`, the
flat menu's `y` key, and option 5 on the results screen after an operation — so a roll-out can be
reviewed without leaving the workflow. The menu offers period presets (24h / 7d / 30d / everything)
rather than the `<n>d` grammar, and each screen calls the same engine functions the CLI does, so the
two entry points cannot report different numbers for the same window.

Reporting is **read-only** over the audit trail: it never writes a record and never modifies a log.
Its own invocation is recorded by the ordinary read path, like `show` and `export`, so a report never
appears in its own figures.

### Encrypted computer lists
Save and load computer lists — including phase assignments — protected by a password-derived AES
key, replacing the original tool's plain-text export.

**One file holds several named lists.** `wuu config save -ListName prod` adds a list called `prod`,
or replaces it with `-ListName prod` again; the other lists in the file are untouched. Names are
free text. `wuu config load` shows a numbered menu and takes a number, a name, or an unambiguous
prefix; in the console, saving asks for a name (press Enter for the default) and loading shows the
same menu.

Three things this design guarantees, because each is a way an operator could otherwise lose work:

* **A wrong passphrase is reported as a wrong passphrase.** The file is encrypted as a unit, so a
*typo* cannot add a list. It is never mistaken for "no lists saved yet" — the two look identical at
a prompt and mean opposite things. Nothing is written, and every list already in the file survives.
* **A same-named list is not silently replaced.** Saving over an existing name is refused unless you
confirm (interactively) or pass `-AllowOverwrite`.
* **A new passphrase is typed twice.** Every list in a file shares one passphrase, so a typo while
creating it produces a file that opens with *neither* entry — and a file you cannot identify, holding
lists you can no longer read, looks exactly like an empty one at the next load. The confirmation runs
only when the file would be created: an existing passphrase is not being chosen, it is being proved,
and opening the file is what proves it.
* **An older single-list file still works, and is not modified by reading it.** It is read as a list
named `default` and is upgraded the next time you save. Merely opening the tool never rewrites your
only copy.

For scripts, `wuu config load -ListName prod` skips the menu entirely. With no `-ListName`, an
automatic load (e.g. `wuu check -All`) prefers the list named `default` and otherwise takes the first
one in the file, printing which list it chose — a scripted run is never left waiting at a prompt.

### Hang protection, and timeouts that distinguish slow from stuck

Every remote call is wrapped in a hard timeout (`Invoke-CimWithTimeout`, `Invoke-ServiceWithTimeout`,
`Invoke-RemoteComWithTimeout`). A genuinely unreachable host therefore takes longer to report than a
naive fast-fail — that is the trade for never hanging.

Each operation also has its **own deadline**, because one number cannot be right for all of them:

| Operation | Deadline |
| --- | --- |
| check / download | 45 min |
| install + re-check | 2 h |
| full self-driving chain | 4 h |
| restart | 45 min (its own offline + online waits already total 40 min) |
| remove-offline / service action | 5 min |

The deadline is recorded when the work is **submitted**, so the budget you can inspect is the budget
enforced, and it is cleared when the operation ends. A **heartbeat** is refreshed while the job runs,
which is what separates "slow" from "stuck": a deadline alone only says "not finished", whereas the
status line shows the operation, its remaining budget and how long since the last beat:

```
  SRV01  Phase 1  Downloading  A:3 D:1  [Download 12m left beat 18s ago] Downloading 2/3...
```

> **This changed.** Earlier builds force-stopped **every** job at a flat 10 minutes. That killed
> healthy work — a restart's own waits exceed it, so *every* reboot was reported as a timeout — while
> a hung 5-minute service action held a runspace for ten minutes.

---

## Audit trail (ISO/IEC 27001:2022 A.8.15)

Every action is appended to a hash-chained log under `%PROGRAMDATA%\WUU2\audit`, one file per UTC day
(`audit-YYYYMMDD.jsonl`). Mutating actions are **two** records - an intent and an outcome, linked by a
correlation id - so evidence exists that the action was attempted even if the process dies mid-flight.
Each record carries WHO (`operator`/`runId`), WHAT (`action`/`category`/`parameters`), WHICH
(`targets`), WHEN, WHERE (`host`/`pid`) and OUTCOME (`result`/`error`/`counts`), which is the field set
A.8.15 asks for. Use `wuu report` to read it back as operational figures - run outcomes, failing
machines and their causes - without inspecting JSONL by hand.

This is the main reason the console edition exists.

**One deliberate exception: `-WhatIf`.** A dry run writes **nothing** to the trail and changes
nothing anywhere else — so it can be repeated freely while preparing a change, with no artefacts to
explain. A simulation is not a denied attempt, and mixing plans into the trail would make "this
system refused the change" indistinguishable from "an operator asked what it would do".

Each record answers the six questions A.8.15 cares about:

| Question | Fields |
| --- | --- |
| **WHO** | `operator.user`, `operator.machine`, `operator.elevated`, `runId` |
| **WHAT** | `action`, `category`, `parameters` |
| **WHICH** | `targets[]` |
| **WHEN** | `timestampUtc` (ISO 8601 UTC, ms precision), `durationMs` |
| **WHERE** | `host`, `processId` |
| **OUTCOME** | `result`, `error`, `counts` |

Events are categorised as `session`, `access`, `configuration_change`, `data_change`,
`operational` or `outcome`.

**What is recorded**

- **Mutating actions** (download / install / restart / service) write **two** records sharing a
  `correlationId`: `started` **before** the action runs, then `succeeded`/`failed`. The intent
  record is **fail-closed** — if it cannot be written, the action does not run. An unlogged remote
  change is treated as worse than a refused one.
- **`-Reason` is mandatory** for mutating verbs. An audit entry saying "changed 12 servers" with no
  reason has little value in a change review.
- **Refused attempts** are first-class `result='denied'` records — a missing `-Reason`, or a menu
  action cancelled at the prompt, is recorded rather than silently dropped.
- **Read-only actions** (checks, views, exports) are recorded too, as `category='operational'`.
  A.8.15 covers access to information, not only change to it. These are best-effort: a status check
  must not fail because the log sink was momentarily unwritable.
- **Environment and session context** — OS, PowerShell edition/version, culture, host, PID.

**Integrity**

- SHA-256 hash chain: `Hash = SHA256(canonical(record) + '|' + prevHash)`. Detects modified,
  deleted, reordered and malformed records.
- Append-only. Cross-process safe: an exclusive file lock is held across the whole read-modify-write,
  so concurrent writers cannot fork the chain.
- `wuu audit verify` reports the first break with its line number and exits non-zero.
- `wuu audit export -Path <dest>` bundles the day's log, its session transcript, and the compliance
  documentation for hand-off.

**Retention: forever.** Enforced by the *absence* of a delete path, rather than by a scheduled job
that could fail silently or be widened.

### ⚠️ Read this before relying on it for assurance

**The trail is tamper-evident, not tamper-proof, and not non-repudiable.** Someone with
administrator rights on the log host can delete a whole day's file, or a trailing run of records,
and the remainder still verifies. Each daily file restarts its own chain, so a missing day is not
detected by the chain alone.

The standard control is a non-repudiation anchor — mirroring a periodic digest somewhere the operator
cannot rewrite. This is implemented: `wuu audit anchor` writes a per-log chain-head anchor (it refuses
an anchor placed in the log's own directory, which would offer no separation from what it anchors), and
`-EventLog` additionally mirrors the head into the Windows Event Log, which does not depend on the
operator's discipline about where the file lives. `wuu audit verify` compares the chain against the
anchor and reports `consistent`, `REWRITTEN`, or `unavailable`.

That raises the price of tampering — from "edit the log" to "edit the log, the anchor file, and the
event log" — but it is **not** non-repudiation; the gap is smaller, not closed. Full detail, including
the remaining limitations (clock trust, the transcript has no integrity protection, scope):

- [`docs/ISO_27001_A815_MAPPING.md`](docs/ISO_27001_A815_MAPPING.md) — control-to-artefact map and limitations
- [`docs/AUDIT_RETENTION.md`](docs/AUDIT_RETENTION.md) — retention policy and archival rules

---

## How it differs from the GUI edition

Same engine, different presentation layer. What actually changed:

| Area | GUI edition | This edition |
| --- | --- | --- |
| Presentation | WPF + XAML (`ui/`), `$uiHash` control access, `Dispatcher.Invoke`, `DispatcherTimer` | Console shell: status table + keyed menu, and a guided workflow. `ui/` is deleted and no WPF assemblies are loaded |
| State | WPF controls were the source of truth | Thread-safe state store (`src/Wuu.State.psm1`), rendered by the shell |
| Workflow gating | A failed or timed-out host was skipped, permitting the next phase | An explicit, reported `PhaseFailurePolicy`, defaulting to blocking |
| Scheduler | A `DispatcherTimer` on the UI thread — worked only because `ShowDialog()` pumped a message loop | The input loop polls and drains the scheduler each tick. A console blocked in `Read-Host` has no message loop, so a timer would silently never fire |
| Concurrency | No per-computer guard: a second operation was silently discarded | One operation per computer, decided at a single submission point, plus a global cap |
| Timeouts | One flat 10-minute stop | A per-operation budget, recorded at submission, with a heartbeat |
| Liveness | ICMP (`Test-Connection`) decided online/offline | The management endpoint decides — ICMP is blocked by default on Windows |
| Interface | Mouse-driven context menus | A guided workflow (default) **and** 27 keyed operations **and** 18 scriptable verbs |
| Exit codes | n/a | A documented code per outcome, not one failure number; `0` means completed |
| Audit | none | Hash-chained ISO 27001 A.8.15 audit trail with a required change reason |

**Not carried over:** column drag-resize/auto-fit, clipboard and context-menu affordances, the AD
OU picker dialog, and other GUI-only conveniences. The underlying operations are all present — the
interaction model is a terminal, not a grid.

The plan and per-phase progress notes are in [`docs/CLI_AUDIT_PLAN.md`](docs/CLI_AUDIT_PLAN.md),
[`docs/PHASE1_PROGRESS.md`](docs/PHASE1_PROGRESS.md),
[`docs/PHASE2_PROGRESS.md`](docs/PHASE2_PROGRESS.md) and
[`docs/PHASE4_PROGRESS.md`](docs/PHASE4_PROGRESS.md).

---

## Repository layout

```
WUU.ps1                  entry point: interactive menu, or a single verb + options
src/
  Wuu.Core.psm1          application wiring, action layer, validation, elevation/STA handling
  Wuu.Configuration.psm1 paths and $global:* settings (version, timeouts, deadlines, concurrency)
  Wuu.Console.psm1       console shell: status table, menu, input choke point
  Wuu.Presentation.psm1  presentation helpers shared by the display paths
  Wuu.Actions.Display.psm1  the display/table actions (show updates, installed, history, log)
  Wuu.Command.psm1       verb table, argument parser, dispatcher, help
  Wuu.Result.psm1        the command result model and its versioned JSON rendering
  Wuu.Audit.psm1         ISO 27001 A.8.15 audit trail: schema, hash chain, verification, anchoring
  Wuu.Reporting.psm1     deployment reporting: reads the audit trail, aggregates runs and failures
  Wuu.State.psm1         thread-safe computer state store (replaces the WPF ListView)
  Wuu.WindowsUpdate.psm1 update search/download/install, per-computer runspaces, phases
  Wuu.Scheduler.psm1     worker-runspace construction for the scheduling and cleanup machinery
  Wuu.Remote.psm1        DCOM CIM sessions, remote task execution, timeouts
  Wuu.Network.psm1       connectivity and system performance probes
  Wuu.Credentials.psm1   credential cache, encrypted computer-list config, credential-mode check
  Wuu.Workers.psm1       bounded runspace pool for remote work
  Wuu.Session.psm1       the computer set as a first-class object (add/import/export/prune)
  Wuu.Navigate.psm1      the guided interactive workflow: screens, pre-flight, confirmation, results
  Wuu.Models.psm1        state factories and error suggestions
  Wuu.Logging.psm1       fault-tolerant debug logging
Scripts/
  Download-Patches.ps1   runs ON the target (via a SYSTEM scheduled task)
  Install-Patches.ps1    runs ON the target (via a SYSTEM scheduled task)
  Audit-WSUSUpdates.ps1  WSUS-vs-Windows-Update comparison
  Diagnostic-FindMissingUpdates.ps1  diagnose updates the target should have but does not
  Validate-Release.ps1   release gate: parse, structure and audit invariants
  Package-WUU2.ps1       builds the release zip (dev tool; not shipped in the zip)
tests/                   headless regression suites
docs/                    design, progress and compliance documentation
```

Not listed above but part of the surface: `Scripts\Test-*.ps1` are the release gate's constituent
checks (dot-sourced by `Validate-Release.ps1` in verdict order), and `Scripts\Invoke-TestSuites.ps1`
is the suite runner. Both are dev tooling and are not run by the application.

---

## Development

Validate before packaging or releasing:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Validate-Release.ps1
```

This is a real gate, not a smoke test, and it is what CI should run. It:
- parses every shipped file under the PS 5.1 engine;
- asserts no WPF/XAML reference remains in code (comments excluded, so explanatory notes do not
  trip it);
- checks that every menu entry and verb resolves to a wired handler;
- requires a **UTF-8 BOM on every shipped file containing non-ASCII bytes** — a BOM-less non-ASCII
  file is encoding-dependent, and rewriting it with `Set-Content` corrupts it silently;
- enforces that behaviour is decided from **workflow state**, not from a display string;
- enforces the **exit-code** contract, including that `0` cannot mean "queued";
- enforces the **per-operation timeout** design: a budget per operation, a deadline recorded at
  submission, cleared on every exit path, and a heartbeat;
- enforces that **one operation per computer** is decided at a single submission point;
- enforces that no state transition is decided by **ICMP**, and that a single lost probe cannot
  evict a computer from the set;
- enforces the **credential** rules: identity recorded from the `pscredential`, compared on load,
  and no password-shaped expression interpolated into a log;
- enforces the structural audit invariants (array-vs-string canonicalisation, append-only writes, the
  exclusive lock, the complete A.8.15 field set, first-class denials, no delete path);
- rejects case-insensitive parameter collisions (a local `$all` silently *is* a `[switch]$All`).

Every invariant above has a matching regression suite in `tests\`, and the two are meant to be read
together: a gate catches a structural regression, a suite catches a behavioural one. The reasoning
behind each — including the ones that were wrong first — is in
[`docs/HARDENING_P0_FINDINGS.md`](docs/HARDENING_P0_FINDINGS.md).

Run the regression suites (all headless, no admin required):

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Invoke-TestSuites.ps1
```

The runner captures each suite's exit code, distinguishes `SKIP` from `PASS`, imposes a per-suite
timeout, and **exits non-zero if any suite failed** — so it is safe to use as a CI gate. `-Json` emits
a machine-readable summary; `-Suite <name>` runs one suite; `-TimeoutSeconds` raises the deadline.

> **Do not replace it with a `ForEach-Object` loop.** That is the pattern it was written to fix: the
> loop printed each suite's output but discarded every exit code, so a failing tree reported success.

All suites are headless and need no admin. **`Test-RemoteTask` skips** (exit 0 with a `SKIP:` marker)
when it is not elevated, because it registers a SYSTEM scheduled task; run it from an elevated prompt
to exercise it. The runner reports skips separately, because a skip is not a failure but it is also
not coverage — if you are validating something only that suite covers, say it was skipped rather than
claiming it passed.

CI runs both gates on every push and pull request: the release validator (structure) and the suite
runner (behaviour). See [`.github/workflows/validate.yml`](.github/workflows/validate.yml).

> **Two stale suites:** `tests\Test-ColumnResize.ps1` and `tests\Test-DragResize.ps1` are GUI-edition
> leftovers that exercise WPF column drag-resize, which does not exist here. ColumnResize fails on
> its missing WPF assemblies; **DragResize hangs** (blocking dispatcher pump). Both should be deleted,
> and both are excluded by the runner (the exclusion list is `$excludedSuites` in
> `Scripts\Invoke-TestSuites.ps1`). The per-suite timeout exists because of DragResize.

Build a release zip:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Scripts\Package-WUU2.ps1
```

---

## Drawbacks and trade-offs

Stated plainly, because they are real:

- **Elevation required.** Admin-only by design — it patches remote machines.
- **WinRM is still used by the service *actions*.** Start/Stop/Restart `wuauserv` and RPC
  auto-recovery go through `Invoke-Command`. Update checks, downloads and installs are WinRM-free.
- **Download/install use a temporary SYSTEM scheduled task** on the target (no PsExec), reporting
  progress through `HKLM\SOFTWARE\WUU2\Jobs`. Requires Windows 8 / Server 2012+ on the target.
- **Debug logging is OFF by default**, because an unattended run cannot act on a log size it was never
  told about. Set `WUU_DEBUG=1` to enable it for a run; do not edit a shipped file, because a reinstall
  silently reverts it and the change is invisible to anyone reading the configuration.
- **Update search must run in-process.** WUA COM objects cannot cross a job/process boundary, so
  update-search concurrency is bounded by design.
- **MSRT is not counted.** A WUA API limitation — Windows Settings may show one more pending update
  than WUU when a Malicious Software Removal Tool release is pending.
- **Retry logic is patient.** 5-second backoffs and bounded timeouts mean an unreachable host takes
  longer to report than a naive fast-fail.

---

## License and Provenance

MIT - see [LICENSE](LICENSE) and [NOTICE](NOTICE).

This project is a multi-generation evolution of open-source PowerShell patch management utilities:
- **PoshPAIG** (2011–2014) by **Boe Prox** ([GitHub](https://github.com/proxb/PoshPAIG) / CodePlex)
- **Windows Update Utility / WUU** (2016) by **Tyler Siegrist** ([TechNet](https://gallery.technet.microsoft.com/scriptcenter/Windows-Update-Utility-WUU-1d72e520) / [GitHub](https://github.com/HashGambit97/WindowsUpdateUtility))
- **WUU2** (2018) by **HanSolo71** with forum fixes by **Phaere** ([GitHub](https://github.com/HanSolo71/WUU2))
- **WUU2 (GUI) & WUU2-CLI (Console)** (2025–2026) by **dazzo31**

For the detailed lineage, architectural evolution, and code ancestry matrix, see [docs/PROVENANCE.md](docs/PROVENANCE.md).

The companion GUI edition of this fork lives at <https://github.com/dazzo31/WUU2>. Its release notes and
GUI-specific documentation remain in docs/ for historical reference.