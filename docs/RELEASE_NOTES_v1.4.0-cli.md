# WUU2-CLI v1.4.0-cli

**First release of the console edition.** WUU2-CLI is the GUI-free edition of WUU2: same
engine, no WPF/XAML, fully interactive from a terminal, with a hash-chained audit trail built
for **ISO/IEC 27001:2022 A.8.15** compliance review.

> **Edition note.** This repository was seeded from `dazzo31/WUU2` (the WPF GUI edition,
> v1.3.4). Everything below v1.4.0-cli in the history — including `docs/RELEASE_NOTES_v1.3*.md`
> and any GUI/column-resize material in `docs/` — documents the **GUI** edition and does not
> describe this one. The GUI edition is unchanged and still available separately.

---

## What it does

Same operational capability as the GUI edition, driven from a terminal:

- **Interactive menu** — status table + keyed menu, no XAML.
- **Command mode** — 17 verbs, one operation per invocation, scriptable:

  ```powershell
  WUU.ps1 check   -All
  WUU.ps1 show available -Computer SRV01 -Json
  WUU.ps1 install -Computer SRV01 -Reason "CHG-1041 security patches"
  WUU.ps1 audit verify
  WUU.ps1 -Help
  ```

- **Phased deployment** — up to 5 phases; a phase does not start until the previous one is
  fully patched and reboot-clean.
- **Full automation** — check → download → install → reboot → re-check.
- **WSUS audit**, **custom remote credentials**, **encrypted computer-list configs**.
- **Audit trail** — see below.

Run it elevated; the script will request elevation itself if it is not.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WUU.ps1
```

---

## The audit trail (ISO/IEC 27001:2022 A.8.15)

Every action — by a human at the menu or by a script — is recorded to
`%PROGRAMDATA%\WUU2\audit\audit-YYYYMMDD.jsonl` (one JSON object per line, one file per UTC day).

Each record answers the six questions A.8.15 cares about:

| Question | Fields |
| --- | --- |
| **WHO** | `operator.user`, `operator.machine`, `operator.elevated`, `runId` |
| **WHAT** | `action`, `category`, `parameters` |
| **WHICH** | `targets[]` |
| **WHEN** | `timestampUtc` (ISO 8601 UTC, ms precision), `durationMs` |
| **WHERE** | `host`, `processId` |
| **OUTCOME** | `result`, `error`, `counts` |

Events are grouped into six categories: `session`, `access`, `configuration_change`,
`data_change`, `operational`, `outcome`.

**What gets logged**

- Mutating actions (download / install / restart / service) — **two** records sharing a
  `correlationId`: `started` **before** the action runs, then `succeeded`/`failed`. The intent
  record is **fail-closed**: if it cannot be written, the action does not run. An unlogged remote
  change is treated as worse than a refused one.
- **`-Reason` is required** for mutating actions — an audit entry saying "changed 12 servers"
  without saying why has little value in a change review.
- **Refused attempts** — `result='denied'`, first-class. A missing `-Reason`, or a menu action
  cancelled at the prompt, is recorded rather than vanishing.
- **Read-only actions** (checks, views, exports) — `category='operational'`, best-effort, one
  record, no reason required. A.8.15 covers access to information, not only change to it.
- **Environment/session context** — OS, PowerShell edition/version, culture, host, PID.

**Integrity**

- SHA-256 hash chain: `Hash = SHA256(canonical(record) + '|' + prevHash)`. Detects modified,
  deleted, reordered and malformed records.
- Append-only, cross-process safe (exclusive `FileShare::None` lock held across the whole
  read-modify-write), flushed to disk.
- `WUU.ps1 audit verify` reports the first break with its line number and exits non-zero, so a
  pipeline can gate on it.
- `WUU.ps1 audit export -Path <dest>` bundles the day's log, its session transcript, and the
  compliance documentation for hand-off.

**Retention: forever.** Enforced by the *absence* of a delete path, not by a scheduled job — a
job can fail silently or be widened; an absent code path cannot.

### Read this before relying on it for assurance

The trail is **tamper-evident, not tamper-proof, and not non-repudiable.** Someone with
administrator rights on the log host can delete a whole day's file, or a trailing run of records,
and the remainder still verifies. Each daily file restarts its own chain, so a missing day is not
detected by the chain alone.

The standard control is a non-repudiation anchor (mirror a periodic digest somewhere the operator
cannot rewrite, e.g. the Windows Event Log). That is **designed but not implemented** in this
release, and it is the largest known gap. Full detail, including the other honest limitations
(clock trust, transcript has no integrity protection, scope):
`docs/ISO_27001_A815_MAPPING.md` §8 and `docs/AUDIT_RETENTION.md` §5.

---

## Fixed in this release

These were found by **running the entry point**, not by reading it — three of them were
invisible until exercised end-to-end.

1. **Command arguments were silently discarded on elevation.** A non-elevated
   `WUU.ps1 install -Computer SRV01` relaunched elevated into the **interactive menu**. The
   relaunch used `if ($args)`, which is always empty inside a `param()` function, so the
   forwarding branch never ran. The relaunch now forwards the real `-CommandArguments` (quoting
   each token) and passes `-STA`, which it previously did not.
2. **`audit verify` / `show` / `export` all crashed.** `-ServiceAction` was bound to
   `$parsed.SubVerb`, so every sub-dispatched verb sent its subverb into a
   `ValidateSet('','start','stop','restart')` parameter and hard-threw
   (`Cannot validate argument on parameter 'ServiceAction'`), surfacing as
   `CRITICAL ERROR - console shell failed`. `service restart` worked only by coincidence — the
   word `restart` happens to be a valid service action. Since `audit verify` is *the* way an
   auditor checks the trail, this was release-blocking.
3. **The STA relaunch dropped arguments a second time.** It also ran hidden with no `-NoExit`,
   producing a window that flashed and vanished. It now forwards arguments and, for a one-shot
   command, exits cleanly so the caller can read the exit code.
4. **A declined UAC prompt produced a stack trace and then hung.** A cancellation is a choice,
   not an error; it now says so and exits non-zero. The `Read-Host` that followed it would hang
   any unattended invocation forever.
5. **`audit export -Path` was ambiguous with `-Path` for verify/show.** For verify/show `-Path`
   is the log to inspect; for export it is the output destination — but it was assigned to
   `$logPath` first, so export tried to read a log from the output path and threw
   `ItemNotFoundException`. `-Path` is now interpreted per subverb, and `-LogPath` names the log
   unambiguously. Export also creates its destination directory, bundles the compliance docs,
   and verifies the archive before reporting success.
6. **Release zips shipped no documentation.** The packager's `-Filter "*.md"` was not
   `-Recurse`, so everything under `docs/` was omitted — including the ISO control mapping and
   the retention policy. A package could not answer "what are these records, and how long are
   they kept?". Now included, with GUI-edition documents excluded.
7. **The version was not single-sourced.** The log banner and the audit records each hardcoded
   their own string, so a release could ship with the log claiming one version and the audit
   trail (an ISO field) recording another. Now `$global:WuuVersion`.
8. **Command mode left no trace of its arguments.** It now logs its argv, which is what you need
   when the parse itself is the suspect.

---

## Verification

- `Scripts\Validate-Release.ps1` — **37/37**, including 19 structural invariants. Ten new
  release-readiness gates cover the defects above, so this class of regression fails the build
  rather than reaching a tester.
- 10 headless test suites green under PS 5.1 (audit trail, cross-process concurrency, command
  surface, state store, headless engine, worker pool, log fault tolerance, remote helpers,
  auto-flow chain, cross-module resolution).
- End-to-end verified on an elevated host: elevation forwards arguments and `-STA` (confirmed in
  the debug logs of both the parent and the elevated child), `audit export` produces a 4-entry
  bundle, `audit verify` and `audit show` run clean, and new audit records carry
  `wuuVersion = "v1.4.0-cli"`.

## Known gaps

1. **Non-repudiation anchor** — not implemented (largest gap; see above).
2. **Cross-day chain linkage** — each daily file restarts its chain, so whole days can be removed
   undetectably by a host administrator.
3. **Two stale test files hang**: `tests\Test-ColumnResize.ps1` and `tests\Test-DragResize.ps1`
   still load `PresentationFramework` (GUI-era leftovers from before `ui/` was removed). They are
   not part of the suite and should be deleted or stubbed.
4. **Multi-operator across machines** over a network share is not covered by the file lock.
5. **Clock trust** is assumed; there is no trusted time source.
6. No test yet asserts that credential *values* never reach the audit log (they are not logged by
   design; the event is recorded, the secret is not).
