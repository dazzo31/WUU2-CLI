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
| `tests/Test-AuditTrail.ps1` | **DONE — 35/35 PASS** |
| Validator audit invariants (6 structural checks) | **DONE — 14/14 PASS** |
| Session transcript capture | **PARTIAL** — path allocated; `Start-Transcript` wiring not done |
| Non-repudiation anchor (Event Log mirror / signed digest) | NOT STARTED — see §9 decision |

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

## Verification

`tests\Test-AuditTrail.ps1` — **35/35 PASS**:

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

`Scripts\Validate-Release.ps1` — **14/14 PASS**, including six new structural **audit invariants**
so a future edit cannot quietly remove a property the trail depends on:

```
PASS: audit canonical serialiser handles arrays separately from strings
PASS: audit hash mixes in prevHash (removal/reordering is detectable)
PASS: audit supports fail-closed writes for mutating actions
PASS: audit writes are append-only (no rewrite path found)
PASS: audit resolves its own directory (not a synced path)
PASS: mutating verbs enforce -Reason
```

All 8 test suites green under PS 5.1.

## Not done (deliberately, and stated rather than implied)

1. **Non-repudiation anchor.** The plan's §5.6 decision — Windows Event Log mirror of each run's
   terminal hash, or a certificate-signed daily digest. This is an operational choice, so it is
   left as a decision rather than silently defaulted.
2. **Session transcript.** `TranscriptPath` is allocated per session but `Start-Transcript` is not
   yet wired. Console output is already line-oriented (no progress redraws) so it will be readable
   when it is.
3. **Retention / pruning.** Nothing deletes or rolls over audit files yet.
4. **Multi-operator concurrency.** Each process has its own `RunId`, and the chain is continued
   per file, but two concurrent sessions appending to the same daily file rely on `Add-Content`
   append atomicity plus a per-session monitor lock (which does **not** cover cross-process). Worth
   a file-lock test before relying on it with several operators.
