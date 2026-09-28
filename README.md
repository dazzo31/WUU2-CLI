# WUU2-CLI

**Windows Update Utility — console edition.** Check, download, install and reboot Windows Updates
across a fleet of remote machines from a terminal, with a hash-chained **audit trail** built for
**ISO/IEC 27001:2022 A.8.15** review.

No GUI, no WPF, no XAML. Pure PowerShell 5.1. Same update engine as the
[GUI edition](https://github.com/dazzo31/WUU2), driven from a menu or from scriptable commands.

```
  WUU2-CLI - Windows Update Utility (console edition)
  Press ? for help, t to toggle auto download/install/reboot, q to quit.
  Run with -Help for scriptable commands (wuu check -All, wuu install -Computer X).

  COMPUTER             PHASE     STATE          UPDATES           STATUS
  ------------------------------------------------------------------------
  SRV01                Phase 1   Complete       A:3 D:3           Updates installed
  SRV02                Phase 1   Checking       A:0 D:0           Searching...
  SRV03                Phase 2   Queued         A:0 D:0           Waiting for Phase 1

  Auto download: on    Auto install: on    Auto reboot: off
```

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
- **It is scriptable.** Every operation the menu offers is also a verb, which is what makes the
  audit trail meaningful: a change made by a scheduled task is recorded exactly like a change made
  by a human.

---

## Quick start

Clone or extract a release, then from an elevated PowerShell prompt:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WUU.ps1
```

It requests elevation itself if you forget — accept the UAC prompt. You get the interactive menu:
a live status table of your computers plus 25 keyed operations.

Prefer commands? Every operation is a verb:

```powershell
.\WUU.ps1 -Help                                              # full verb list
.\WUU.ps1 check  -All
.\WUU.ps1 show available -Computer SRV01 -Json
.\WUU.ps1 install -Computer SRV01 -WhatIf                    # dry run, changes nothing
.\WUU.ps1 install -Computer SRV01 -Reason "CHG-1041 security patches"
.\WUU.ps1 audit verify                                       # check the audit chain
```

Exit codes in command mode: `0` success, `1` failure — including a broken audit chain, so a
pipeline can gate on it.

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
| `config` | `save` \| `load` — encrypted computer-list config |
| `export` | Export the computer list to a file |
| `logs` | View a target's Windows Update log |
| `audit` | `wsus` (audit a target) \| `verify` \| `show` \| `export` (the local audit trail) |

Common options: `-Computer`, `-All`, `-Reason`, `-Path`, `-LogPath`, `-Json`, `-WhatIf`, `-Help`.
`-Reason` is **required** for verbs that change remote state — see the audit trail below.

---

## Features

### Phased deployment (5 phases)

Assign computers to up to 5 phases. A phase's checks do not start until every computer in the
previous phase is fully patched and reboot-clean, so you roll updates across an estate in waves
instead of hitting everything at once. Errored or timed-out hosts never block later phases, and
phase assignments persist in saved computer lists.

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

### Encrypted computer lists

Save and load computer lists — including phase assignments — protected by a password-derived AES
key, replacing the original tool's plain-text export.

### Hang protection

Every remote call is wrapped in a hard timeout (`Invoke-CimWithTimeout`, `Invoke-ServiceWithTimeout`,
`Invoke-RemoteComWithTimeout`). Stuck jobs are stopped after 10 minutes rather than starving the
concurrency throttle. A genuinely unreachable host therefore takes longer to report than a naive
fast-fail — that is the trade for never hanging.

---

## Audit trail (ISO/IEC 27001:2022 A.8.15)

This is the main reason the console edition exists. Every operation — from the menu or the command
line — is recorded to `%PROGRAMDATA%\WUU2\audit\audit-YYYYMMDD.jsonl`: one JSON object per line, one
file per UTC day.

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

The standard control is a non-repudiation anchor — mirroring a periodic digest somewhere the
operator cannot rewrite, such as the Windows Event Log. **That is designed but not implemented**,
and it is the largest known gap. Full detail, including the other limitations (clock trust, the
transcript has no integrity protection, scope):

- [`docs/ISO_27001_A815_MAPPING.md`](docs/ISO_27001_A815_MAPPING.md) — control-to-artefact map and limitations
- [`docs/AUDIT_RETENTION.md`](docs/AUDIT_RETENTION.md) — retention policy and archival rules

---

## How it differs from the GUI edition

Same engine, different presentation layer. What actually changed:

| Area | GUI edition | This edition |
| --- | --- | --- |
| Presentation | WPF + XAML (`ui/`), `$uiHash` control access, `Dispatcher.Invoke`, `DispatcherTimer` | Console shell: status table + keyed menu. `ui/` is deleted and no WPF assemblies are loaded |
| State | WPF controls were the source of truth | Thread-safe state store (`src/Wuu.State.psm1`), rendered by the shell |
| Scheduler | A `DispatcherTimer` on the UI thread — worked only because `ShowDialog()` pumped a message loop | The input loop polls and drains the scheduler each tick. A console blocked in `Read-Host` has no message loop, so a timer would silently never fire |
| Interface | Mouse-driven context menus | 25 keyed menu operations **and** 17 scriptable verbs |
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
  Wuu.Console.psm1       console shell: status table, menu, input choke point
  Wuu.Command.psm1       verb table, argument parser, dispatcher, help
  Wuu.Audit.psm1         ISO 27001 A.8.15 audit trail: schema, hash chain, verification
  Wuu.State.psm1         thread-safe computer state store (replaces the WPF ListView)
  Wuu.WindowsUpdate.psm1 update search/download/install, per-computer runspaces, phases
  Wuu.Remote.psm1        DCOM CIM sessions, remote task execution, timeouts
  Wuu.Network.psm1       connectivity and system performance probes
  Wuu.Credentials.psm1   credential cache, encrypted computer-list config
  Wuu.Workers.psm1       bounded runspace pool for remote work
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

---

## Development

Validate before packaging or releasing:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Validate-Release.ps1
```

This is a real gate, not a smoke test. It parses every shipped file under the PS 5.1 engine,
asserts no WPF/XAML references remain in code, checks that every menu handler and verb handler
resolves, requires a UTF-8 BOM on every non-ASCII file, and enforces structural invariants over the
audit trail (array-vs-string canonicalisation, append-only writes, the exclusive lock, the complete
A.8.15 field set, first-class denials, no delete path) plus a case-insensitive
parameter-collision check.

Run the regression suites (all headless, no admin required):

```powershell
Get-ChildItem .\tests\Test-*.ps1 | ForEach-Object {
    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $_.FullName
}
```

> `tests\Test-ColumnResize.ps1` and `tests\Test-DragResize.ps1` are stale — they load
> `PresentationFramework` (GUI-edition leftovers) and will hang. They are not part of the suite.

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
- **Debug logging ships enabled** and writes large files — set `$global:EnableDebugLogging = $false`
  in `src/Wuu.Core.psm1` for production use.
- **Update search must run in-process.** WUA COM objects cannot cross a job/process boundary, so
  update-search concurrency is bounded by design.
- **MSRT is not counted.** A WUA API limitation — Windows Settings may show one more pending update
  than WUU when a Malicious Software Removal Tool release is pending.
- **Retry logic is patient.** 5-second backoffs and bounded timeouts mean an unreachable host takes
  longer to report than a naive fast-fail.

---

## License

MIT — see [LICENSE](LICENSE).

Based on the original Windows Update Utility by **Tyler Siegrist** (TechNet / PoshPIAG):
<https://gallery.technet.microsoft.com/scriptcenter/Windows-Update-Utility-WUU-1d72e520>

The GUI edition of this fork lives at <https://github.com/dazzo31/WUU2>. Its release notes and
GUI-specific documentation remain in `docs/` for history — they describe the WPF edition, not this
one.