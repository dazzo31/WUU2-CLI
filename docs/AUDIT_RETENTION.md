# Audit log retention policy — WUU2-CLI

**Policy:** audit records are retained **indefinitely**. Nothing is deleted, pruned, rotated to
an archive and expired, or otherwise removed by the application.

**Owner:** the operator administering the WUU2-CLI installation.
**Applies to:** everything under the audit directory.

---

## 1. Why "keep forever" is implemented as the absence of a delete path

The retention policy is enforced by there being **no code path that removes audit data**, rather
than by a scheduled job. This is a deliberate choice:

- a scheduled deletion job is itself a component that can fail silently (logs stop being pruned,
  nobody notices) or be manipulated (someone widens the window, or adds a path);
- a retention policy that exists only as configuration can be changed by whoever holds the
  configuration, with no trace;
- with no deletion path, "was anything deleted?" is answered by reading the code, not by trusting
  a job's history.

Consequently: **no `Remove-Item`, no `Clear-Content`, no truncate, no overwrite-by-rewrite exists
anywhere in the audit module.** The release validator asserts the append-only property
structurally, so a future change that introduces a rewrite path fails CI rather than shipping.

---

## 2. What is retained

| Artefact | Pattern | Retention |
| --- | --- | --- |
| Audit records | `audit-YYYYMMDD.jsonl` | Forever |
| Session transcripts | `transcript-<timestamp>-<runid>.log` | Forever |
| Exported bundles (`wuu audit export`) | operator-chosen `-Path` | Forever (copies; **does not** move or delete the originals) |

Retention covers **all** record categories, including `denied` and `whatif` records. A refused
attempt is retained on exactly the same terms as a completed one — a deletion policy that spared
"noise" would be the first thing an attacker with deletion capability would exploit.

---

## 3. Growth and capacity

Records are one JSON object per line. A `download` or `install` produces three records
(`started`, `succeeded`, plus the session-start/read records for the run); a read produces one.
At an illustrative 1 KB per record and a few hundred operations per day, a year of records is on
the order of tens of megabytes.

Because retention is unbounded, capacity planning is the **operator's** responsibility. The
supported approach is to archive **complete daily files** to long-term storage:

```powershell
# Copy a closed day to archival storage. Copy, never move — the original stays in place so the
# day remains verifiable in situ.
Copy-Item (Join-Path (Get-WuuAuditDirectory) 'audit-20260914.jsonl') \\archive\wuu\2026\09\
```

**Rules for any archival process:**

1. **Copy, never move.** Moving a file out of the audit directory removes it from the chain's
   context and looks identical to tampering.
2. **Archive whole files only**, never partial extractions or filtered subsets. A filtered export
   cannot be verified — the hash chain covers every line in the file.
3. **Archive the transcript alongside its day's JSONL** so the two stay associated.
4. **Verify before and after** with `wuu audit verify`; an archive operation must never be the
   only copy of an unverified file.
5. **Never edit an archived file.** Editing breaks its chain permanently and irreversibly.

WUU2-CLI does not automate archival. Automating it would place a copy-or-delete decision in the
product, and getting that wrong destroys evidence.

---

## 4. Verification obligations

Retention without verification is retention of an unknown quantity. Because the chain is
**per-day** (each daily file restarts the chain — see `ISO_27001_A815_MAPPING.md` §6.1), every
file must be verified individually.

Recommended schedule:

| When | Action |
| --- | --- |
| Daily | Verify the current day's file is readable and well-formed |
| Monthly | `wuu audit verify` over every daily file, including archived copies |
| Before an audit / hand-off | Verify the full set; export the required days with `wuu audit export` |
| After any restore from backup | Verify immediately — a restore that silently corrupts a chain is worse than a known gap |

A verification failure is a **security event**, not a maintenance task: it means either
corruption or modification. Preserve the file as-is, record the finding, and investigate before
attempting any repair.

---

## 5. Deletion

There is no supported deletion procedure, by design.

If legal or regulatory requirements ever mandate deletion of specific records, deleting them
**breaks the hash chain for that day** from the point of deletion onward — and that break is the
correct, visible outcome. Silent, chain-preserving deletion is not possible, which is the point:
any such deletion is detectable by `wuu audit verify`.

Any deletion performed outside the application (by an administrator on the filesystem) is
likewise detectable for interior records, but **not** for:
- a trailing run of records at the end of a file (see §8.3 of the mapping document);
- an entire day's file, since daily chains are independent.

Both gaps are closed only by the non-repudiation anchor described in
`ISO_27001_A815_MAPPING.md` §8.1, which is designed but not yet implemented.

---

## 6. Summary

| Question | Answer |
| --- | --- |
| How long are logs kept? | Forever |
| How is that enforced? | No deletion path exists in the code; asserted structurally by the release validator |
| Can the application delete logs? | No |
| How do I reduce the footprint? | Copy complete daily files to archival storage; never move or filter |
| How do I prove nothing was deleted? | `wuu audit verify` per day — detects modified, deleted and reordered interior records |
| What is the residual risk? | Whole days, and trailing runs of records, can be removed undetectably by a host administrator (§8 of the mapping document) |
