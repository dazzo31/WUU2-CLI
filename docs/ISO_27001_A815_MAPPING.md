# ISO/IEC 27001:2022 (A.8.15) logging compliance — WUU2-CLI

Scope: this document maps the WUU2-CLI audit trail onto **ISO/IEC 27001:2022 Annex A control
8.15 (Logging)** and the implementation guidance in **ISO/IEC 27002:2022 §8.15**. It states
what is implemented, where the evidence lives, how long it is kept, and — just as importantly
— what this system does **not** provide.

Related documents:

| Document | Purpose |
| --- | --- |
| `CLI_AUDIT_PLAN.md` §5 | Original audit design (tamper-evidence focus) |
| `PHASE4_PROGRESS.md` | Implementation history for Phase 4 |
| `docs/AUDIT_RETENTION.md` | Retention policy (keep forever) |

---

## 1. What A.8.15 requires, and how WUU2-CLI satisfies it

| A.8.15 requirement | Implementation | Where |
| --- | --- | --- |
| Event logs record **user activities**, exceptions, faults and information security events | Every command and every interactive menu action produces a record; failures/exceptions become `result='failed'` with the error text | `Write-WuuAuditRecord`, `Invoke-WuuAuditedAction` |
| Logs record **who** performed the activity | `operator.user`, `operator.machine`, `operator.elevated`, `runId` | session-start + every record |
| Logs record **when** | `timestampUtc`, ISO 8601 with explicit UTC designator (`Z`), millisecond precision | every record |
| Logs record **what** was done | `action`, `category`, `parameters` | every record |
| Logs record **which** target | `targets[]` (computer names, `all`) | every record |
| Logs record **where from** | `host`, `processId` | every record |
| Logs record **outcome** | `result`, `error`, `counts`, `durationMs` | every record |
| **Denied / unsuccessful** attempts are logged | `result='denied'` first-class records | `Write-WuuAuditDenial` |
| **Access to information** (reads) is logged, not only changes | Read-only verbs logged with `category='operational'` | `Invoke-WuuCommand` |
| **Privileged / administrative** operations are logged | Mutating verbs require `-Reason` and use the fail-closed choke point | `Invoke-WuuAuditedAction` |
| Logs are **protected against tampering** | SHA-256 hash chain; append-only file; `audit verify` reports modification, deletion, reordering and malformed records | `Add-WuuAuditRecordLocked`, `Test-WuuAuditChain` |
| Logs are **retained** per policy | Kept indefinitely (no deletion path exists) | `docs/AUDIT_RETENTION.md` |
| **Configuration changes** to logging are themselves logged | `category='configuration_change'`; credential/config actions logged | category classifier |

---

## 2. Record schema

One JSON object per line (JSONL), UTF-8 without BOM, one file per UTC day.

```jsonc
{
  "seq": 42,                    // 1-based position within the file
  "timestampUtc": "2026-09-15T14:03:11.4821730Z",
  "runId": "8f3c…",             // one per command run / interactive session
  "correlationId": "b91d…",     // ties an intent record to its outcome record
  "operator": { "user": "DOMAIN\\dazzo", "machine": "DARREN-PC", "elevated": true },
  "host": "DARREN-PC",          // "where from"
  "processId": 8124,
  "category": "data_change",    // see §3
  "action": "install",
  "targets": ["SRV01", "SRV02"],
  "parameters": { "computer": "SRV01,SRV02", "set": null, "json": false },
  "reason": "CHG-1041 security patches",
  "result": "succeeded",        // started | succeeded | failed | denied | whatif | info | started
  "error": "",
  "counts": {},
  "durationMs": 41233,
  "wuuVersion": "v1.3.4-cli",
  "prevHash": "9c1a…",          // hash of the previous record in this file
  "Hash": "77ef…"               // SHA-256 over the canonical record + prevHash
}
```

### 2.1 Field-by-field rationale

- **`seq` and `prevHash`/`Hash`** are filled in by the locked writer, never by the caller. They
  form the hash chain: `Hash = SHA-256(canonical(record without Hash) + "|" + prevHash)`.
- **`correlationId`** is what makes an action reconstructable as a single unit. A mutation writes
  two records — `result='started'` before the action runs and `result='succeeded'`/`'failed'`
  after — and both share a `correlationId`. An auditor reading only the `succeeded` line cannot
  tell when the action began or whether a crash left it half-done; the `started` line can.
- **`reason`** is mandatory for mutating actions. An audit trail that records *what* changed but
  not *why* has little value in a change review, so the reason is enforced rather than optional.
- **`category`** exists so a report can be filtered ("show me every configuration change in
  September") without the caller classifying each call site by hand, which would drift over time.

---

## 3. Event categories

| Category | Meaning | Examples |
| --- | --- | --- |
| `session` | Start/end of a WUU session | `session-start`, `session-end` |
| `access` | Authentication / credential handling | `Set domain credentials` |
| `configuration_change` | Changes to WUU's own configuration | save/load encrypted config, export list, add/remove computers |
| `data_change` | Changes to a **target's** state | download, install, restart, service control |
| `operational` | Read-only operations | check for updates, view history, WSUS audit, view logs |
| `outcome` | The outcome half of a mutating action, and all denials | paired with its intent by `correlationId` |

Inference lives in `Resolve-WuuAuditCategory`. Precedence is deliberate: session lifecycle is
classified first (a session *start* carries `result='started'` but is a session event, not an
outcome), then outcome/denied, then the action-name patterns. Callers that know the right answer
pass `-Category` explicitly and bypass inference entirely.

---

## 4. Mutation lifecycle (the fail-closed contract)

A mutating action writes **three** records at most:

| # | When | `result` | Failure behaviour |
| --- | --- | --- | --- |
| 1 | Before the action runs | `started` | **Fail-closed** — if this write fails, the action does **not** run |
| 2 | Action completed | `succeeded` / `failed` | Best-effort — the action already happened; throwing would misreport it |
| 3 | `-WhatIf` (no action) | `whatif` | Best-effort |

The ordering is the whole point. Write-after-the-fact logging cannot distinguish "the change was
made and logged" from "the change was made and the process died before logging". Because the
intent record is written **first** and is fail-closed, a process killed mid-action still leaves
evidence that the action was attempted. An unlogged remote change is treated as worse than a
refused one.

### 4.1 Refusals are a different case

A refused action (no `-Reason`, or cancelled at the interactive prompt) deliberately does **not**
use the fail-closed path, and writes **no** intent record. Instead it writes a single
`result='denied'` record on a best-effort basis:

- it must be logged, because A.8.15 expects denied attempts to be recorded and a run of refusals
  is exactly the pattern an auditor looks for;
- it must not be fail-closed, because the operation was **already blocked** — surfacing "audit
  failed" for an action that never ran would be actively misleading;
- it must not write an intent record, because a `started` row would falsely imply the change had
  begun.

---

## 5. Read-only operations

Reads (checks, views, exports) are logged, but on the opposite footing from mutations:

- **one** record per operation, `result='info'`, no intent row;
- **best-effort** — a viewing action must never fail because the audit sink is momentarily
  unwritable;
- **no `-Reason`** required — asking *why* for a read is noise, and a mandatory reason would train
  operators to type "x";
- reported to callers as `Logged = $true`, distinct from `Audited = $true` (which means "went
  through the fail-closed mutating choke point"). Conflating the two would make `Audited`
  meaningless.

Rationale: A.8.15 covers access to **information**, not only modification of it. "Who inspected
which hosts' update state, and when" is a question an auditor asks after an incident, and it is
unanswerable if only mutations are logged.

---

## 6. Storage, integrity and verification

| Property | Implementation |
| --- | --- |
| Location | `%PROGRAMDATA%\WUU2\audit\` (fallback: `%LOCALAPPDATA%\WUU2\audit\`) |
| File naming | `audit-YYYYMMDD.jsonl` — one file per **UTC day** |
| Format | JSONL, UTF-8 **without** BOM, one complete record per line, newline-terminated |
| Append-only | The only write path opens the file for append under an exclusive lock; no code path rewrites existing records |
| Cross-process safety | `FileShare::None` held for the entire read-modify-write, plus an in-process `Monitor` on the path. A probe lost 86 of 100 records before this fix, and produced **false tampering reports on intact trails** |
| Flush | `FileStream.Flush($true)` to force OS buffers to disk before the lock is released |
| Verification | `wuu audit verify` (`Test-WuuAuditChain`) — reports the first break with its line number, distinguishing modified / deleted / reordered / malformed records |
| Session transcript | `transcript-<ts>-<runid>.log` — console capture answering "what did the operator see?" |

### 6.1 Daily files and the chain

Each day's file begins a **new** hash chain (the first record's `prevHash` is empty). A day
boundary is therefore a natural verification break, and `audit verify` must be run per file.
This is a deliberate trade-off: a single ever-growing chain would make one file the bottleneck
for every writer and make per-day retention or archiving impossible.

> Cross-day chain linkage is **not** currently implemented. See §8 (gaps).

---

## 7. Retention

**Policy: keep forever.** No automatic deletion, no pruning, no rotation-to-trash exists in the
codebase — retention is enforced by the *absence* of a deletion path rather than by a scheduled
job that could itself fail or be tampered with. See `docs/AUDIT_RETENTION.md`.

---

## 8. Honest limitations

Stating these plainly is part of the control, not a caveat against it.

1. **Tamper-evident, not tamper-proof, and not non-repudiable.** The hash chain detects
   modification of an existing record and deletion of an interior record. It does **not** stop an
   actor with administrator rights on the log host from deleting the file (or a trailing run of
   records) and regenerating a consistent chain from any point. An attacker who replaces the
   whole file produces a file that verifies.

   The standard mitigation is a non-repudiation anchor: mirror a periodic digest to a destination
   the operator cannot rewrite (Windows Event Log, or a remote sink). This is **implemented** — two
   sinks, both reachable from the command surface (`CLI_AUDIT_PLAN.md` SS5.6):

   * `wuu audit anchor` writes a chain-head anchor **file**. Written and compared by
     `New-WuuAuditAnchor` / `Test-WuuAuditAnchor`, which refuse an anchor in the log's own directory
     (it would offer no separation from what it anchors). Its strength depends on the holder's
     discipline: it must live where the audited operator cannot write.
   * `wuu audit anchor -EventLog` mirrors the head into the **Windows Event Log**, which needs no such
     discipline - it is written through a different mechanism, by a different service, and an
     unprivileged account cannot rewrite it. The first write on a machine needs a one-time elevated
     source registration.

   `wuu audit verify` compares the chain against the anchor and reports `consistent`, `REWRITTEN`, or
   `unavailable`. A rebuilt chain that hash verification accepts is caught by this comparison, which is
   the whole point: the chain alone cannot see it.

   **What this does NOT establish.** A local administrator can still clear the event log and can still
   rewrite both the log and the anchor file. The cost of hiding a rewrite rises from "edit the log" to
   "edit the log, the anchor file, and the event log" - and any copy a third party already holds still
   catches it. That is a higher price for tampering, **not** non-repudiation, and the anchor artifacts
   record that boundary in their own `Claim` field so it need not be inferred from this document.

2. **No cross-day chain linkage.** Each daily file restarts the chain, so deleting whole days is not
   detectable *by the chain alone*. An anchor is per-log and names the log it describes, so a day's
   anchor still shows that a log was expected even after the file is removed - but only for days that
   were actually anchored, and only while the anchor itself survives.

3. **Trailing-record truncation is undetectable UNLESS the log was anchored.** Cutting the last N lines
   leaves a chain that still verifies, because there is no record of the expected length inside the
   file. An anchor supplies exactly that: it records the sequence number and head hash the log had when
   it was anchored, so a log that is now SHORTER is reported as `REWRITTEN`. Without an anchor taken
   before the truncation, this remains undetectable - which is why anchoring is a control an operator
   must actually exercise, not a property of the trail.

4. **The transcript is not integrity-protected at all.** It is a plain text console capture,
   written best-effort, and is not hashed. It is a debugging and context aid for the JSONL
   records, not a primary audit artefact.

5. **Clock trust is assumed.** Timestamps come from the local system clock. There is no trusted
   time source, no NTP verification, and no monotonic ordering guarantee across hosts.

6. **Scope is administrative activity.** The trail records actions *taken through WUU2-CLI*. It
   does not record activity on the target machines beyond what WUU's operations report.

---

## 9. Auditor quick reference

```powershell
# Where the evidence is
Get-WuuAuditDirectory

# Verify integrity (per daily file), non-zero exit on failure
wuu audit verify

# Show recent records
wuu audit show

# Export a day (with its transcript) for hand-off
wuu audit export -Path C:\evidence\wuu-20260915

# Inspect by category — e.g. every configuration change
Get-Content (Join-Path (Get-WuuAuditDirectory) 'audit-20260915.jsonl') |
    ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object category -eq 'configuration_change'

# Reconstruct a single action as one unit (intent + outcome)
Get-Content (Join-Path (Get-WuuAuditDirectory) 'audit-20260915.jsonl') |
    ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object correlationId -eq '<id from the record>'

# Every refused attempt (security-relevant signal)
... | Where-Object result -eq 'denied'
```

---

## 10. Control-to-artefact summary

| Question an auditor asks | Answer |
| --- | --- |
| Where are the logs? | `%PROGRAMDATA%\WUU2\audit\audit-YYYYMMDD.jsonl` |
| What format? | JSONL, UTF-8 (no BOM), one record per line |
| What time format? | ISO 8601 UTC, `Z` suffix, ms precision |
| How long kept? | Forever — no deletion path exists |
| How do I know they are intact? | `wuu audit verify` (hash chain) |
| What if they are not intact? | Verification names the first broken line and the break kind |
| Are denied attempts logged? | Yes — `result='denied'`, first-class, no intent row |
| Are read-only actions logged? | Yes — `category='operational'`, best-effort |
| Can logs be deleted without detection? | **Yes, by a host administrator.** See §8.1 — the trail is tamper-evident, not tamper-proof |
