# WUU2-CLI v1.5.0-beta.7-cli

**A trust-and-capability release: the audit trail becomes externally anchored, the encrypted
computer list holds several named lists, and the release gate is restructured so its own claims
are checked by measurement.**

Same commands, same engine behaviour as beta.6 for every workflow that does not involve the audit
anchor, the saved computer list, or `-WhatIf`/`-Json` output.

> **This is a PRERELEASE.** The version is stamped on every audit record, so a trail is
> self-identifying: `wuuVersion: v1.5.0-beta.7-cli` tells an auditor the evidence came from
> pre-release software.

---

## Read this first — the audit trail can now be anchored outside itself

Through beta.6 the trail was **tamper-evident but not tamper-resistant**: each daily file restarts
its own chain, so an administrator on the log host could delete a whole day's file, or a trailing run
of records, and the remainder still verified. The gap was documented in the README and in the ISO
27001 mapping, and was the largest known one.

It is now closed by two mechanisms, deliberately chosen to fail differently:

| Mechanism | What it is | What it depends on |
| --- | --- | --- |
| `wuu audit anchor` | Writes a chain-head anchor **file** (per log, named for the log) | That the holder keeps it somewhere the audited operator cannot write |
| `wuu audit anchor -EventLog` | Mirrors the head into the **Windows Event Log** | Nothing about the operator's discipline — the log is not theirs to edit |

`wuu audit verify` compares the chain against the anchor and reports `consistent`, `REWRITTEN`, or
`unavailable`. **`unavailable` is not `consistent`** — an unanchored log is never presented as
verified, which is the failure mode that would make the whole control theatre.

The anchor file placement is enforced rather than advised: `New-WuuAuditAnchor` **refuses** an anchor
in the log's own directory, because an anchor written through the same access path as the log offers
no separation from what it anchors. The default lives in a sibling tree
(`%ProgramData%\WUU2\anchors`) for exactly that reason.

> **This is a higher price for tampering, not non-repudiation.** Hiding a rewrite now costs "edit the
> log, the anchor file, and the event log" instead of "edit the log". `docs/ISO_27001_A815_MAPPING.md`
> states the remaining boundary and why it is not closed.

---

## Also new

### One file holds several named computer lists

`wuu config save -ListName prod` adds a list called `prod`; saving that name again replaces it, and
the other lists in the file are untouched. `wuu config load` shows a numbered menu and accepts a
number, a name, or an unambiguous prefix — and does not prompt at all when the file holds one list,
because there is no decision to make.

Three rules exist because each is a way an operator could lose work:

* **A wrong passphrase is reported as a wrong passphrase.** The file is encrypted as a unit, so a typo
  cannot add a list. It is never mistaken for "no lists saved yet" — the two look identical at a
  prompt and mean opposite things — and nothing is written.
* **A same-named save is refused**, not silently replaced, unless confirmed or `-AllowOverwrite`.
* **A passphrase being chosen is typed twice.** Every list shares one passphrase, so a typo while
  creating the file produces a file that opens with *neither* entry, indistinguishable from an empty
  one later. The confirmation runs only when the file would be *created*: an existing passphrase is
  being proved, not chosen, and opening the file is what proves it.

The comparison is case-sensitive (`-ceq`): PowerShell's `-eq` is case-*insensitive*, so `Password1` and
`password1` would compare equal and a real typo would pass the check meant to catch it.

**A single-list file from any earlier build still works.** It reads as one list named `default`,
reports `IsLegacy`, and is **not rewritten by reading it** — opening the tool never modifies your only
copy. It upgrades on the next save.

### The command result model, and a versioned JSON envelope

Every `-Json` document is now rendered through one function, so all commands carry the same envelope:

```json
{ "SchemaVersion": 1, "Command": "audit verify", "LogPath": "...", "Ok": true }
```

`SchemaVersion` is bumped only for a **breaking** change. Adding a field is compatible and does not
bump it — so a consumer can detect a contract change rather than discover it.

### Exit code 4 is produced, not reserved

`4` (PartialSuccess) used to be reserved-but-unproduced: a `-Computer A,B` selection was resolved by
one shared answer, so "A succeeded, B failed" was not observable and a mixed fleet reported a flat
`1`. Per-target verdicts now exist, so a mixed result reports `4`.

Unsettled targets are **ignored, not counted as failures** — a target still running has not failed,
and counting it would make `wuu check -All` report partial success merely for working through a large
estate. Outstanding work is signalled by `3` (or `6` with `-Async`). Every settled target failing is
`1`, because there is nothing partial about it.

### `-WhatIf` prints a per-computer plan

It used to print one sentence — "would run 'install' against all computers" — which is not reviewable
before a production change. For a **restart** it was also wrong in the most expensive direction: a
busy computer is *refused* rather than deferred for restart/service, so "would restart 10 servers"
could be false for three of them. The plan now states, per computer, what it would do
(`run` / `queue` / `skip` / `noop`), whether it is busy, and why.

---

## Fixed

### A pending follow-up could sit on a settled row

`Set-WuuPendingOperation` had no settled-row check, so a row could be **settled** and advertise queued
work at the same time — counted as finished while its next operation was still queued. The setter now
refuses a settled row with a reason, and the funnel resolves a row holding a queued follow-up back to
`Queued`. The follow-up is not lost; the scheduler still drains it.

### The scheduler-serialization suite was flaky (~1 in 16)

`Add-Content` from more than one runspace to a single file **loses whole lines** — measured at 30 of
800 lost, against 800 of 800 with per-writer files. The test now uses one marker file per computer.
A read could also throw *"being used by another process"* after `EndInvoke` (the handle outliving the
pipeline), so reads retry.

### The packager shipped operator data, and a zip that only Windows could extract

`ComputerList.config` — an encrypted computer list plus its credential block, and `.gitignore`d for
that reason — was in the include list, so a zip built on a working machine carried that operator's
estate and encrypted credentials. It is no longer packaged; the application creates it at runtime.

Separately, entries were written with the platform separator (`docs\ARCHITECTURE.md`, 85 of 91
entries in a measured build). The ZIP spec requires `/`, and extractors on Linux and macOS take the
name literally, so the compliance documentation an ISO 27001 review needs arrived as files *named*
`docs\ARCHITECTURE.md`. Entries are now built one at a time with `/`, and the packager **fails** if any
entry carries a backslash rather than writing a broken archive.

### Three drifted claims in the shipped README

Found while preparing this release, and fixed because a README that misdirects is worse than a short
one:

* It still described exit `4` as "reserved but not produced" — two releases after it became produced.
* It still said the audit anchor was "designed but not implemented" — one release after it shipped.
* It told operators that **"debug logging ships enabled"** and to edit `src\Wuu.Core.psm1` to turn it
  off. Both halves were wrong: logging ships **off**, and editing a shipped file is not a supported
  way to change behaviour (a reinstall silently reverts it). It now documents the supported switch,
  `WUU_DEBUG=1`.

---

## Structural work

`Scripts\Validate-Release.ps1` was a 1,673-line file whose checks were interleaved with the runner.
It is now a 249-line orchestrator over **13 fragments** under `Scripts\`, dot-sourced in verdict
order. The verdict list is unchanged, in the same order, and every extraction was verified against a
frozen verdict/behaviour baseline.

The decomposition had a second purpose: a single file that both *runs* the checks and *contains* them
cannot be checked without reading its own prose. The fragments can.

A new `Test-DocConsistency` fragment measures the development document against the tree, which is
what caught the SS45 priorities **understating** finished work (claiming the command result model was
unimplemented while `Wuu.Result.psm1` shipped and Core built results through it), and now fails on a
gate block citation that points at no block. It also forbids stating a module's *current* line count,
because that number rots on the next edit.

---

## Verification

| Check | Result |
| --- | --- |
| Release gate | pass — 183 verdicts, 0 FAIL, 0 WARN |
| Test suites | 46 run, 45 pass, 1 skip, 0 fail — **1,363 assertions** |
| Mutation proofs | multi-list failure paths 7/7 caught; confirm-field 2/2 caught; restored byte-identically (SHA-256) |

**These totals are from the TAGGED tree, not a pre-tag run.** The SS18 version guard only evaluates
once a tag exists, so an off-tag run reports a SKIP where the released tree reports a PASS.

### New suites

* `tests\Test-ComputerLists.ps1` — 32 assertions over the multi-list format, backward compatibility,
  the wrong-passphrase distinction, and the confirm field.
* `tests\Test-AuditAnchoring.ps1` — the anchor round trip, the same-directory refusal, and the Event
  Log sink.
* `tests\Test-ResultModel.ps1`, `tests\Test-JsonContract.ps1` — the result model and the versioned
  envelope.

---

## Known limitations

* **41 direct operation-state writes** remain outside `Wuu.State`. Many are inside payload runspaces
  where the funnel is not callable. The gate ratchets this: it fails if the count rises, and warns
  when it falls, so the ceiling can be lowered.
* **The audit anchor's strength is partly environmental.** The Event Log sink does not depend on
  operator discipline; the anchor *file* does. Choosing a location the audited operator cannot write
  is the operator's responsibility, and the tool cannot verify that for you.
* **`Wuu.Core.psm1` is still the largest module.** The extractions that remain each need a measured
  plan, because the regions have real in/out coupling.
* **More complete operation-deadline propagation.** CIM and service probes are covered; other paths
  are not.
