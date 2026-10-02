# WUU2-CLI exit codes (command mode)

The console edition exits with one of eight documented codes. The numbers are the contract: a script
branches on them, so the meaning is fixed and is implemented in exactly one place
(`Get-WuuExitCode` in `src\Wuu.Command.psm1`).

| Code | Name | Meaning | Typical cause |
| --- | --- | --- | --- |
| 0 | Success | the requested operation **completed** successfully | `wuu check -All` finished |
| 1 | OperationFailed | one or more targets failed | a handler threw, or a target errored |
| 2 | UsageError | unknown verb, missing argument, invalid input | `wuu shwo`, `wuu show` with no subverb |
| 3 | Timeout | the wait elapsed with work still outstanding | work still running after `$CommandWaitSeconds` |
| 4 | PartialSuccess | **some settled targets succeeded and some did not** | `wuu install -Computer A,B,C` where A and B succeeded and C failed |
| 5 | AuditFailure | the audit chain failed to verify, or a fail-closed audit write failed | `wuu audit verify` on a tampered log |
| 6 | Queued | `-Async` was requested and the work was **accepted**, not completed | `wuu install -All -Async` |
| 7 | Refused | declined before running | a mutating verb without `-Reason` |

## The rule that matters most

**Exit 0 means the operation COMPLETED. It does not mean the work was queued.**

`wuu install` submits work to a background runspace and then waits a bounded period. Earlier builds
returned `0` as soon as the submission succeeded, so a CI job could read "success" for an install that
had not run. That is now impossible:

* outstanding work (a row with `OpState = 'Running'` or `Pending`) and **no** `-Async` → **exit 3**
* outstanding work and `-Async` → **exit 6**
* nothing outstanding → the operation's own classification

Pass `-Async` when you genuinely want fire-and-forget:

```powershell
wuu install -Computer SRV01 -Reason "CHG-1041" -Async
# exit 0 = completed inside the wait window
# exit 6 = accepted and still running (NOT a success)
```

## Scripting

```powershell
wuu check -All
switch ($LASTEXITCODE) {
    0 { 'all good' }
    2 { throw 'bad command line' }
    3 { 'slow - poll state and re-check' }
    5 { throw 'AUDIT TRAIL COMPROMISED - stop and investigate' }
    default { 'operation did not complete' }
}
```

Gate on **specific codes** rather than on `-ne 0`. Codes 2, 3, 5, 6 and 7 mean very different things,
and a blanket "non-zero = retry" would retry a tampered audit log.

`-Json` output includes the code and the completion state, so a script need not trust the exit code
alone:

```json
{ "Command": "install", "Ok": true, "ExitCode": 6, "Completed": false, "Outstanding": 2, "Computers": [ ] }
```

### Every `-Json` document is versioned

All commands emit the same envelope, so a consumer can detect a contract change rather than discover it:

```json
{ "SchemaVersion": 1, "Command": "audit verify", "LogPath": "...", "Ok": true }
```

`SchemaVersion` is bumped only for a **breaking** change - a renamed, removed or re-typed field. Adding a
field is compatible and does not bump it. The mutating verbs additionally carry `ExitCode`, `Status` and
the per-status counts; those are listed above and are unchanged.

| Command | Fields (beyond the envelope) |
|---|---|
| `check`, `download`, `install`, `restart`, … | `Ok`, `ExitCode`, `Status`, `Completed`, `Outstanding`, the `*Count` fields, `Computers`, `ErrorMessage` |
| `<verb> -WhatIf` | `WhatIf`, `Detail`, `Policy`, `Selected`, `WouldRun`, `WouldQueue`, `WouldSkip`, `WouldNoOp`, `Unresolved`, `Targets`, `Would`, `Ok` |
| `audit verify` | `LogPath`, `Ok`, `Checked`, `FirstBreak`, `Problems` |
| `audit show` | `LogPath`, `Count`, `Records` |

A field that is present when empty is present when empty on purpose: a field that vanishes when it has
no value is a field a consumer crashes on.

## Partial success (4)

**4 means the settled targets disagreed**: at least one succeeded and at least one did not.

```powershell
# A and B succeeded, C failed
wuu install -Computer A,B,C -Reason "CHG-1041"
echo $LASTEXITCODE   # 4 - re-run C, not all three
```

Three details that decide the number, because each one is a way a script can flap:

* **Unsettled targets are IGNORED, not counted as failures.** A target still running or still queued
  has not failed; counting it would make `wuu check -All` report partial success merely for working
  through a large estate. Outstanding work is signalled separately by **3** (or **6** with `-Async`).
* **Every settled target failing is `1`, not `4`.** There is nothing partial about it.
* **Nothing settled is neither.** The classifier returns no verdict and the existing code stands.

The classification is `Get-WuuAggregateOutcome` over the per-target verdicts from
`Get-WuuTargetOutcome` (`src\Wuu.State.psm1`), consumed by the command-mode classifier in
`src\Wuu.Core.psm1`, and pinned by `tests\Test-TargetOutcomes.ps1`.

> **This changed.** `4` used to be reserved-but-unproduced, because a `-Computer A,B` selection was
> resolved by one shared answer so "A succeeded, B failed" was not observable anywhere. A mixed fleet
> therefore reported a flat `1`. The per-target verdicts now exist, so a mixed result is reported as
> `4`.

## Non-command mode

The interactive menu does not use these codes (it is not a scriptable entry point). The two
startup-failure paths in `Wuu.ps1`/`Wuu.Core.psm1` still exit `1`, because a shell that failed to load
its modules has no command result to classify — and `1` is the correct reading of that.

## Where this is enforced

* `src\Wuu.Command.psm1` — `Get-WuuExitCode`, `Get-WuuExitCodeMeaning`, and the `Result`
  classification on every return.
* `src\Wuu.Core.psm1` — the completion check, the branch ordering, and the single
  `$script:CommandExitCode = $exitCode` assignment.
* `tests\Test-CommandExitCodes.ps1` — 33 assertions over the vocabulary and the classifications.
* `Scripts\Validate-Release.ps1` gate **(aa)** — the release gate for the same invariants, including
  branch ordering and the removal of a dead `$script:CommandExitCode` write that made
  `audit verify` exit `0` on a broken chain.
