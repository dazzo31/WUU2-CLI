# Phase 4 — Audit Trail: Progress Log

**Started / completed:** 2026-09-28
**Goal:** Make every change auditable and tamper-evident — the "fully auditable" requirement.
**Full plan:** [CLI_AUDIT_PLAN.md](CLI_AUDIT_PLAN.md) §5

---

## Status: DONE

| Deliverable | State |
|---|---|
| `src/Wuu.Audit.psm1` — chain, canonical JSON, verify, fail-closed, audited wrapper | **DONE** |
| Append-only JSONL in `%PROGRAMDATA%\WUU2\audit` (never a synced folder) | **DONE** |
| Hash chain (SHA-256 over canonical form + prevHash) | **DONE** |
| `audit verify` / `show` / `export` verbs | **DONE** |
| Required `-Reason` on mutating actions | **DONE** |
| Interactive menu audited (not just the command surface) | **DONE** |
| `tests/Test-AuditTrail.ps1` | **DONE — 39/39 PASS** |
| `tests/Test-AuditConcurrency.ps1` (multi-PROCESS chain integrity) | **DONE — 6/6 PASS** |
| Cross-process file locking for the append | **DONE** (fixed a real bug — see below) |
| Session transcript capture | **DONE** (best-effort, non-fatal, idempotent) |
| Validator audit invariants (9 structural checks) | **DONE — 17/17 PASS** |
| Non-repudiation anchor (Event Log mirror / signed digest) | NOT STARTED — see §9 decision |
| Retention / pruning of old audit files | NOT STARTED |

## Usage

```
WUU.ps1 install -Computer SRV01 -Reason "CHG-1041 security patches"
WUU.ps1 audit verify                 # walk the chain; exit 1 if broken
WUU.ps1 audit show [-Json]
WUU.ps1 audit export                 # bundle log + transcripts for handoff
WUU.ps1 audit wsus -Computer SRV01   # audits a TARGET's WSUS state (not the local trail)
```

Interactive: mutating menu keys (2 download, 3 install, 4 restart, w service) now prompt for a
reason and cancel on a blank one.

## Honesty about what this is — stated in the code, the CLI output, and the docs

**A hash chain makes silent edits DETECTABLE, not IMPOSSIBLE.** Anyone with write access to the
log *and* the code can recompute a chain over their own edits. That is a property of every
hash-chained log, not a defect here. Real non-repudiation needs the chain head anchored where the
operator cannot rewrite it (§5.6: Windows Event Log mirror or a certificate-signed daily digest).
Until that exists, this is **"tamper-evident to a careful auditor"** — not "non-repudiable". The
`audit export` output says so explicitly rather than letting a compliance reader assume more.

## Design decisions

1. **Fail-closed for mutations.** If the intent record cannot be written, the action does **not**
   run. An unlogged change to a remote host is worse than a refused one. Read-only writes degrade
   to a warning — blocking reads on a logging problem would be unhelpful.
2. **Intent + outcome, two records, one `correlationId`.** Intent is written *before* the action, so
   a process killed mid-flight still leaves evidence it was attempted. A single
   write-after-the-fact record cannot provide that.
3. **Hash over the canonical form, not the stored line** — so whitespace/key order cannot change
   the hash. Critically, the canonical form must distinguish an **array from a string** (see below).
4. **Never in a synced folder.** `%PROGRAMDATA%\WUU2\audit`, LocalAppData fallback, writability
   probed before use. Logs in a OneDrive tree caused real repeated failures in this codebase.
5. **Append only.** `FileMode::Append`; nothing rewrites an existing record.

## Increment 2 — a REAL cross-process bug, and the transcript

### The bug: concurrent writers forked the chain and produced FALSE tampering reports

The per-session `Monitor` lock was **in-process only**, and the append path did
`read head → compute hash → append` with no cross-process lock. Two processes could therefore
BOTH read the same `prevHash`, both compute a valid-looking hash, and both append — leaving two
records claiming the same predecessor. `audit verify` then reports **tampering** on a completely
intact trail.

That is the worst possible failure mode for an audit tool: a false accusation, and in practice the
operator learns to ignore the alarm.

**How it was found.** A probe (4 processes x 25 records, naive append) lost **86 of 100 records**,
which is what prompted looking at the write path properly instead of trusting "appends are atomic".
`tests/Test-AuditConcurrency.ps1` then spawned 4 real child processes through the *real* writer and
was run against the **pre-fix** code to confirm it has teeth:

```
FAIL: concurrently-written chain does NOT verify: line 8: sequence gap (expected 8, found 1)
FAIL: duplicate seq number(s): 1,2,3,...,28 - two writers shared a chain head
```

Note that its "no records lost" check **passed** on the broken code. A loss-only test would have
missed this entirely — the damage is in the chain *structure*, not the record count.

**The fix.** `Add-WuuAuditRecordLocked` runs the whole read-modify-write under an exclusive OS lock
(`FileShare::None` on the log itself, so the file is its own mutex — no separate lock file to leak).
In-process sessions serialise on a per-path `Monitor` lock *first*, since with `FileShare::None` two
same-process sessions would otherwise deadlock on the open. The chain head is read **inside** the
lock. Retries use capped backoff (60 x ~25 ms, max 500 ms) to absorb AV/indexer contention. The tail
read seeks back 64 KB rather than reading the whole file, keeping appends O(1) instead of O(n)
(an O(n²) audit log would eventually matter). Records are `Flush($true)`-ed: a record that is not
durable is not evidence.

**Evidence.** 4 processes x 20 records through the real writer: 84 records present (80 + 4
session-starts), chain **verifies**, sequence contiguous 1..84, **zero duplicates**, and tampering is
still detected in the concurrently-written file.

### Transcript

`Start-WuuAuditTranscript` / `Stop-WuuAuditTranscript`, wired into the interactive session
lifecycle. Deliberately **best-effort and never fatal** — failing an update because transcript
capture failed would be the wrong trade — and it only stops a transcript *it* started, so it never
kills one the operator began themselves. Console output in this edition is line-oriented (no cursor
positioning or progress redraws) precisely so the transcript stays readable and diff-able.

## Bugs found while building this

Each was caught by a check; none by inspection.

1. **`-Error` as a parameter name.** `$Error` is a read-only automatic variable — the linter caught
   it before it could fail at runtime. Renamed to `-ErrorMessage`.
2. **False tampering: a new session restarted `seq` at 1** while appending to the same daily log, so
   `audit verify` reported *"record deleted"* on a completely intact trail. Fixed by having a
   session continue **both** the hash and the sequence from the existing chain head.
3. **The interactive menu was unaudited** (command mode only). Found by inspection *after* the
   command surface was done. A human could change remote hosts with nothing recorded, which would
   make the trail actively misleading — it would look like only scripted changes ever happened.
   The loop now takes an injected `-AuditHook`, asks for a reason, and cancels on blank.
4. **`-Reason` was recorded but never *required*.** A record saying "changed 12 servers" with no
   reason has little change-review value. Now enforced before anything runs.
5. **Three validator bugs of my own:** a bad regex escape; matching the module's own explanatory
   *comment* about OneDrive as a synced path; and pattern-matching token-stripped text without
   accounting for the loss of `$` and quotes. The last cost three attempts until I **dumped the
   actual text instead of guessing the pattern** — the lesson is to inspect, not infer.

### The collision the probe prevented

Before writing the module I probed the JSON round-trip. The first canonical serialiser produced
`{"a":"one","b":""}` for input `{"a":["one"],"b":[]}` — i.e. an **array serialised as a string**.
Two structurally different records would then hash identically: a collision in the one component a
hash chain depends on. Fixed by giving arrays their own branch and ordering the type checks so
`[string]` is handled **before** the `IEnumerable` branch (a string is enumerable). Locked by a
regression test, and now a release-gate invariant.

## Increment 3 — the pivot to ISO 27001 A.8.15 collection

The original brief was tamper-evidence. That was re-prioritised: **detailed collection of an
administrator's actions** mattered more than attack-resistance, with daily logs kept to ISO
standards. Target control: **ISO/IEC 27001:2022 A.8.15 (Logging)**, retention **forever**.

The hash chain was kept (it is nearly free and it is genuine evidence of tampering), but the
record **content** was reshaped so every event answers the six questions A.8.15 cares about:

| Question | Field |
| --- | --- |
| WHO | `operator.user`, `operator.machine`, `operator.elevated`, `runId` |
| WHAT | `action`, `category`, `parameters` |
| WHICH | `targets[]` |
| WHEN | `timestampUtc` (ISO 8601 UTC, ms), `durationMs` |
| WHERE | `host`, `processId` |
| OUTCOME | `result`, `error`, `counts` |

Three gaps had to be closed for that to be true rather than aspirational, and each one was a real
gap before this increment:

1. **Host and process were not recorded at all.** Now captured once on the session so every
   record inherits them without each call site remembering to pass them.
2. **Denied attempts were not recorded.** The command surface refused a mutating verb with no
   `-Reason` and wrote *nothing* — the refusal was invisible. The interactive menu was worse:
   cancelling at the reason prompt produced no trace whatsoever. Both now write
   `result='denied'` first-class records (`Write-WuuAuditDenial` + a `-DenialHook` on the menu).
3. **Read-only actions were not recorded.** Only mutations were audited. A.8.15 covers access to
   *information*, not just change to it, so "who inspected which hosts' update state, and when"
   was unanswerable. Reads are now logged too.

### The design constraint that shaped #2 and #3

Both denials and reads had to be logged **without** using the fail-closed path, and this is not a
detail — it is the difference between a usable tool and an unusable one:

- a **refusal** was already blocked; a logging failure surfacing as "audit failed" would report an
  error for an action that never ran, and train operators to distrust the audit messages;
- a **read** changes nothing; failing a status check because the log sink was momentarily
  unwritable would make the tool unreliable for no security benefit.

So both are **best-effort**, and both deliberately write **no** `started` intent row — an intent
row on a read is meaningless, and an intent row on a refusal falsely implies the change had begun.
The command surface reports them as `Logged = $true` (`Audited = $true` still means specifically
"went through the fail-closed mutating choke point"), because collapsing the two would make
`Audited` meaningless for callers.

### Categories

`Resolve-WuuAuditCategory` classifies each event so reports can be filtered without per-callsite
drift: `session`, `access`, `configuration_change`, `data_change`, `operational`, `outcome`.
Inference order is load-bearing — session lifecycle is checked **first**, because a `session-start`
record carries `result='started'` and would otherwise be classified as the outcome half of a
mutation.

### Documentation

- `docs/ISO_27001_A815_MAPPING.md` — control-to-artefact map, field rationale, category taxonomy,
  the mutation lifecycle, storage/integrity, and an explicit **honest limitations** section.
- `docs/AUDIT_RETENTION.md` — the keep-forever policy, implemented as the *absence of a delete
  path* rather than a scheduled job (a job can fail silently or be widened; an absent path cannot),
  plus archival rules for the operator: **copy never move, whole files only, verify before/after**.

### The uncomfortable part, stated plainly

The trail is **tamper-evident, not tamper-proof, and not non-repudiable.** Someone with
administrator rights on the log host can delete a day's file, or a trailing run of records, and
the remainder still verifies. Whole days can go missing without detection because the chain
restarts per file. The standard fix is a non-repudiation anchor (mirror a digest somewhere the
operator cannot rewrite) — that remains designed-but-unimplemented. Writing this down is part of
the control: an auditor who is told the boundary can work with it, whereas one who discovers it
later cannot trust anything else in the report.

## Verification

`tests\Test-AuditTrail.ps1` — **45/45 PASS** (35 at Increment 2, extended in Increment 3):

- array vs string do **not** collide; arrays serialise as arrays; key order does not change the hash
- a clean chain verifies; verification is read-only
- **four tamper classes** each detected at the correct line: modified field, deleted record,
  reordered record, malformed line
- the chain continues across sessions and still verifies
- `-FailClosed` refuses when the sink is unwritable; read-only writes degrade to a warning
- intent + outcome are two correlated records with duration and reason
- `-WhatIf` records intent without running the body; no mutation records on the command surface
- valid JSONL; append adds one line and rewrites nothing
- `-Reason` enforced; the menu flags 4 mutating entries; the menu hook audits with its reason
- end-to-end: a mutating **command** is audited (intent+outcome, target, correlationId)
- **Increment 3 additions:** reads are logged (exactly one record, no intent row, category
  `operational`, no `-Reason` demanded) and refusals are logged as one `denied` record naming the
  cause, with no intent row and the action confirmed not to have run

`Scripts\Validate-Release.ps1` — **27/27 PASS**, including sixteen structural **audit invariants**
so a future edit cannot quietly remove a property the trail depends on.

Original nine (tamper-evidence and the concurrency fix):

```
PASS: audit canonical serialiser handles arrays separately from strings
PASS: audit hash mixes in prevHash (removal/reordering is detectable)
PASS: audit supports fail-closed writes for mutating actions
PASS: audit writes are append-only (no rewrite path found)
PASS: audit resolves its own directory (not a synced path)
PASS: mutating verbs enforce -Reason
PASS: audit append takes an exclusive cross-process lock
PASS: audit reads the chain head inside the exclusive lock (no read-modify-write race)
PASS: audit flushes records to disk
```

Ten added for ISO 27001 A.8.15:

```
PASS: audit records carry the full A.8.15 event field set (who/what/which/when/where/outcome)
PASS: audit timestamps are ISO 8601 UTC (round-trip format)
PASS: refused attempts are recorded as first-class denied events
PASS: denials are recorded best-effort (a refusal is never blocked by logging)
PASS: denials write no intent record (a refused change never began)
PASS: audit category taxonomy is complete (6 categories)
PASS: read-only access is logged (reported distinctly from the fail-closed path)
PASS: read-only access bypasses the mutating choke point (no spurious intent records)
PASS: audit module has no delete/truncate path for audit data (retention is structural)
```

**The retention gate was probed before it was trusted.** A compliance check that cannot fail is
worse than none: it produces confident, wrong assurance. Probed against the benign write-probe
cleanup (which legitimately calls `Remove-Item`) and against five realistic violations
(`Remove-Item $LogPath`, `[IO.File]::Delete`, `Clear-Content *.jsonl`, whole-file rewrite of
`$LogPath`, `FileMode::Truncate`) — result: **0 false positives, 0 misses**. The first draft of
this check *did* fail loudly on correct code (it matched the probe cleanup), which is exactly the
outcome that justified probing rather than assuming.

All 8 test suites green under PS 5.1. `Test-AuditTrail.ps1` grew from 35 to 45 checks; the three
checks that asserted the *old* contract ("read-only command writes no audit records", "a refused
command still wrote audit records" — an expected-value assertion that would have been satisfied by
writing nothing!) were rewritten to assert the new one, including that a read produces exactly one
record with no intent row and a refusal produces exactly one `denied` record.

## Not done (deliberately, and stated rather than implied)

1. **Non-repudiation anchor.** The plan's §5.6 decision — Windows Event Log mirror of each run's
   terminal hash, or a certificate-signed daily digest. Deferred when the brief moved from
   tamper-evidence to collection breadth. This is now the **largest remaining gap**, because
   without it whole days and trailing record runs can be removed undetectably; see
   `ISO_27001_A815_MAPPING.md` §8 and `AUDIT_RETENTION.md` §5.
2. **Cross-day chain linkage.** Each daily file restarts its chain, so a missing day is invisible
   to `audit verify`. Fixing this properly is the same work as #1.
3. **Credential-change records carry no secret material** — by design, not by omission: the
   credential actions are logged as events (category `access`) but the values are never captured.
   Worth an explicit test asserting the password never reaches the log.
4. **`audit export` is not yet per-day aware.** `-Path` exists and bundles the log plus
   transcripts, but selecting a specific day for hand-off still needs a manual copy. Documented as
   an operator procedure in `AUDIT_RETENTION.md` §3 in the meantime.
5. **Multi-operator concurrency across processes.** Fixed by `Add-WuuAuditRecordLocked` (exclusive
   `FileShare::None` lock for the whole read-modify-write; `Test-AuditConcurrency.ps1` covers 4
   writers). What is *not* covered is several operators on **different machines** sharing one
   audit directory over a network share — `FileShare::None` is not a network-wide guarantee.
6. **Clock trust.** Timestamps come from the local clock; no trusted time source and no
   monotonic ordering across hosts.

