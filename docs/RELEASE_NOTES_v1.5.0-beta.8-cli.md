# WUU2-CLI v1.5.0-beta.8-cli

**A reporting release: a deployment and reliability report you can read at a console or from a
script, with the guided UI wired to the same engine — plus one defect fixed that had been corrupting
the interactive workflow's navigation.**

Same commands, same engine behaviour as beta.7 for every workflow that does not involve the new
`report` verb.

> **This is a PRERELEASE.** The version is stamped on every audit record, so a trail is
> self-identifying: `wuuVersion: v1.5.0-beta.8-cli` tells an auditor the evidence came from
> pre-release software.

---

## New: deployment and reliability reporting

`wuu report` answers *"did the roll-out work, and what keeps failing?"* from the audit trail.

```powershell
wuu report                                  # last 7 days, by day
wuu report -Period 30d -GroupBy Week        # wider window, weekly buckets
wuu report -FailedOnly -Json                # just failures, machine-readable
wuu report -Out report.csv -Dataset Runs    # CSV: Runs | Targets | Causes
wuu report -LogPath D:\handover\audit-20261001.jsonl   # one file, e.g. an air-gapped bundle
```

In the console the same report is reachable three ways — `Reports / audit` → `Deployment report`, the
flat menu's `y` key, and option 5 on the results screen — so a roll-out can be reviewed without
leaving the workflow. The menu offers period presets (24h / 7d / 30d / everything) rather than the
`<n>d` grammar; the CLI still takes the grammar for scripts. **Both entry points call the same engine
functions**, so they cannot report different numbers for the same window.

### What it reports, and what it deliberately does not

The trail records a deployment **batch** — its outcome and the list of machines it targeted — but not
a per-machine result. A fleet-wide "95% of machines patched" therefore cannot be derived from it, and
the report says so rather than printing a rate that implies it.

| Figure | Level | Meaning |
| --- | --- | --- |
| Succeeded / Failed / Refused | per run | the batch outcome; success rate is over settled runs |
| Failing targets | per machine | machines that **failed** a deployment, with attempts and last error |
| Top causes | per run | why runs did not settle, refusals marked separately from failures |

**A refusal is not a machine failure**, and this is the distinction that matters most. On a machine
carrying 112 runs refused for a missing `-Reason`, counting refusals as failures put that host at the
top of a "failing machines" table showing **112 failures at a 100% rate** — for runs that never
touched the machine, caused by an operator omitting an argument. Refusals are reported (they are a
real process finding, worth surfacing), but separately, and they never appear as failing machines.
`declined` is likewise kept distinct from `denied`.

Reporting is **read-only** over the audit trail: it never writes a record and never modifies a log.
Its own invocation is recorded by the ordinary read path, like `show` and `export`, so a report never
appears in its own figures. Exit code `0` even when the report is full of failures — reporting a
failure is a successful report, and a non-zero code would make the command useless in the CI job that
wants to act on the content.

---

## Fixed: the interactive workflow misread its own navigation

Two field messages, which looked like unrelated bugs and were in fact one:

```
DEFECT: unknown workflow state 'DASHBOARD' - returning to dashboard
DEFECT: unknown workflow state '@{Timestamp=...; Message=Computer is not accessible via network}'
```

`Invoke-WuuGuidedHandler` invoked the handler **unpiped**, so the handler's output joined the
pipeline. Every screen that calls it *returns a workflow state* — so the screen's return value became
an **array** of `(handler output…, state)` instead of the state.

Two symptoms followed from that single mistake:

* **"View errors"** calls the error-reporting handler, which emits objects carrying a `Timestamp`.
  The workflow loop's state *became* one of those objects, and its `default` arm printed it.
* The other message was stranger. **A `switch` over a two-element array runs *every* matching arm** —
  so for the valid state `DASHBOARD`, both the `DASHBOARD` arm *and* `default` ran, and `default`
  printed the state **after** the `DASHBOARD` arm had reassigned it. That is why a perfectly valid
  state was reported as unknown.

**Fixed**, and the loop now validates the hand-off **before** dispatching: a screen that returns
something other than a state name is reported for what it really is, where it happens, instead of
being passed to a switch that cannot interpret it. That change is the more valuable half — the two
messages above named their symptoms and hid their cause entirely.

11 screens depended on the handler not leaking, and the audit branch beside it had always piped its
call. Only the plain path did not.

### `-LogPath` on the audit verbs was silently ignored

Found while adding the report options to the same parser. `-LogPath` was registered as a known
option but missing from the list of options that **consume a value**, so
`wuu audit show -LogPath D:\copy.jsonl` set the option to `$true` and left the path as a stray
positional — the command then inspected the **newest** log instead of the one named, with no error
and no hint the argument had been dropped. The release gate asserted that `-LogPath` was
*registered* (it was) and never that it consumes a value.

---

## Documentation

The README had drifted from the product in ways a reader could not detect, which is worse than a gap:
someone looking for a module that is not listed concludes it does not exist, and someone reading a
stated count trusts it. Corrected, each verified against the tree rather than by re-reading the prose:

* **the module inventory listed 14 of the 20 shipped modules**, including the one holding the version
  and timeouts and the one that produces the report;
* "26 keyed operations" → 27; "17 scriptable verbs" → 18;
* a stated count of exit codes, which had already rotted — replaced by the contract it describes,
  because the same number would rot again;
* the audit-trail section never said where the trail lives or how it is named;
* the document did not say which version it describes.

The audit anchor, the command result model and exit code `4` were also described as unimplemented or
reserved in earlier releases; those claims were corrected before this one.

---

## Verification

| Check | Result |
| --- | --- |
| Release gate | pass — 184 verdicts, 0 FAIL, 0 WARN |
| Test suites | 47 run, 46 pass, 1 skip, 0 fail — **1,415 assertions** |
| Mutation proofs | report classification 3/3 caught; handler-output leak caught by both the suite and the gate; restored byte-identically (SHA-256) |

**These totals are from the TAGGED tree, not a pre-tag run.** The version guard only evaluates once a
tag exists, so an off-tag run reports a SKIP where the released tree reports a PASS.

New suite: `tests\Test-Reporting.ps1` — 49 assertions over the window parsing, the aggregation, the
refusal/failure separation, the CSV exports, and the guided integration. It runs on a synthetic log
and never reads the host's real audit store.

---

## Known limitations

* **Per-machine success is not derivable.** The trail records batch outcomes and target lists, not
  per-machine results. Deriving a per-machine rate would mean inventing a number; the report states
  the limit instead. Closing it means recording per-target outcomes at write time — a change to what
  the audit trail *contains*, not to how it is read.
* **The report reads the default audit directory in the console.** The CLI takes `-LogPath` for an
  air-gapped bundle; the guided screen does not yet.
* **41 direct operation-state writes** remain outside the state funnel, most inside payload runspaces
  where the funnel is not callable. The gate ratchets the count: it fails if it rises and warns if it
  falls.
* **`Wuu.Core.psm1` is still the largest module.** The extractions that remain each need a measured
  plan, because the regions have real in/out coupling.
