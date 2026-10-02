# WUU2-CLI Interactive UI Specification

Status: **adopted, partially implemented.** This is the source of truth for the interactive
workflow redesign. It is deliberately written as a specification (not a UX discussion) so each
numbered section maps to concrete changes and acceptance tests.

## 1. Objective

Redesign the interactive UI around the administrator's workflow rather than around individual
commands.

> The interactive CLI must be **state-driven and task-oriented**; the non-interactive command
> interface remains **verb-oriented and scriptable**.

The first interactive task must be establishing the set of computers WUU2 will manage. The
current UI exposes operational commands too early — computer acquisition is treated as one
operation among many. That must change.

## 2. Core UX principle

```
START → ESTABLISH COMPUTER SET → REVIEW → PRE-FLIGHT → DASHBOARD
      → SELECT TASK → CONFIRM → EXECUTE → REVIEW RESULTS → NEXT ACTION → DASHBOARD/EXIT
```

Never assume the user already has a computer list.

## 3. Startup behaviour

Do **not** display the operational command menu on start. Show the acquisition screen:

```
WUU2 - Windows Update Utility
=============================

No computer set is loaded.

What would you like to do?

  1. Add computers manually
  2. Import computer list
  3. Add computers from Active Directory
  4. Load saved computer set
  5. Exit
```

The application must not expose update/deployment operations until a computer set exists.

## 4. Computer acquisition

Methods: manual entry, file import (TXT / CSV / saved WUU2 config), Active Directory, saved
computer set. **All methods must produce the same internal `ComputerSet` representation.**

Requirements:

- **4.1 Manual** — accept multiple names separated by commas, spaces or newlines; show what was
  parsed; offer add / edit / cancel before committing.
- **4.2 Import** — detect columns, identify the computer-name column, let the user confirm it,
  validate entries, detect duplicates, detect invalid names. Report `Valid / Duplicates / Invalid`
  and offer review / accept-valid / cancel. **Never silently discard invalid or duplicate entries.**
- **4.3 Active Directory** — explicit acquisition workflow (search by OU / name / OS, browse
  domain); preview, select individually or all, filter, then add to the set.

## 5. Computer set review

Always show a review screen after acquisition, before continuing:

```
COMPUTER SET REVIEW
Computers: 24

  #   COMPUTER
  1   SRV01
  ...

Actions:
  1. Add computers        6. Test connectivity
  2. Remove computers     7. Save computer set
  3. Edit computer        8. Continue
  4. Assign phases        9. Cancel
  5. Configure credentials
```

## 6. Computer set is the primary object

```
Session
└── ComputerSet
    ├── Computers[]
    ├── Credentials
    ├── Phases
    ├── Configuration
    └── DeploymentState
```

Operations operate against the current computer set. Do not make users re-specify the same
computers for every interactive operation.

## 7. Pre-flight

Before any disruptive operation, evaluate: reachability, credentials, Windows Update service, OS
compatibility, pending reboot, existing errors, phase configuration, operation-specific
prerequisites.

Report `Targets / Reachable / Offline / Credentials valid / WU service / Pending reboot / Phase
configuration` plus a `Potential problems` list, then offer:

```
  1. Continue with N available computers
  2. Remove offline computers
  3. Review problems
  4. Cancel
```

The user must not discover these problems halfway through a deployment.

## 8. Main dashboard

```
COMPUTER SET: Production Servers
Computers: 24
Last operation: Check completed 22:14

  #   COMPUTER     PHASE   STATE       UPDATES   STATUS
  1   SRV01        1       Ready       3         Updates available
  ...

  1. Update management     5. Diagnostics
  2. Computer management   6. Reports / audit
  3. Deployment phases     7. Save computer set
  4. Credentials           8. Exit
```

The dashboard must answer: what am I managing, what state is it in, what updates are pending, what
is running, and what should I do next.

## 9. Do not expose 25+ operations at the top level

Group into the six categories above (plus Save and Exit).

## 10. Update management

```
  1. Check for updates     5. Restart computers
  2. Review available      6. Full deployment
  3. Download updates      7. Back
  4. Install updates
```

Make the lifecycle explicit: `CHECK → REVIEW → DOWNLOAD → INSTALL → REBOOT → VERIFY`. Do not make
the user infer this relationship from separate commands.

## 11. Full deployment

`CHECK → DOWNLOAD → INSTALL → REBOOT → RE-CHECK → VERIFY`, still respecting phases, connectivity
failures, credential failures, reboot requirements, errors and audit requirements.

## 12. Deployment confirmation

Before a mutating operation, show the complete execution plan (computer count, update breakdown,
expected reboots, per-phase plan, change reason) and require explicit confirmation. If a change
reason is required by the existing audit system, collect it naturally at this stage.

## 13. Deployment phases

Phases must be **visible as part of deployment**, not hidden configuration. Show per-phase computer
counts and status, offer start-next-phase / view / assign / change / settings, and on completion
report `completed / reboot-clean / failures` then offer to start the next phase.

## 14. Execution screen

Live per-computer progress. Distinguish: Waiting, Checking, Downloading, Installing, Rebooting,
Verifying, Complete, Failed, Offline.

## 15. Results screen

Never finish with only "Operation complete." Provide `Successful / Failed / Offline / Reboot
required`, list failures with their cause, and offer actionable next steps: retry failed, view
errors, view history, continue deployment, export report, return to dashboard.

## 16. Computer details

Selecting a computer shows state, updates, reboot, Windows Update service, WSUS detection, and
per-computer actions (check / show available / show installed / history / log / restart / service /
errors / back). This is the CLI equivalent of the GUI context menu.

## 17. Computer management

Add, import, add-from-AD, remove, edit, test connectivity, save set, load set, back.

## 18. Credentials

Available from main navigation **and surfaced contextually in pre-flight** (with a test result of
`N / M successful`). Do not make credential configuration something users only find after an
operation fails.

## 19. Diagnostics

Connectivity test, Windows Update service, update history, Windows Update log, error details, WSUS
audit, back.

## 20. Reports / audit

View audit history, verify audit chain, export audit, export deployment report, export computer
list, back. Also available immediately after an operation.

## 21. Saved computer sets

Treat saved configurations as reusable working sets. Offer create-new vs load-saved at startup,
list saved sets by name, and after modification offer `Save as "<current>" / Save as... / Don't
save`. Preserve membership, phase assignments, relevant configuration and existing
encryption/security semantics.

**Implementation mapping:** the existing encrypted config file (`ComputerList.config` via
`Save/Import-ComputerListConfig`) *is* the saved computer set. There is no separate "saved set
registry" — named sets are that file plus the export/import path. Do not invent a second store.

**One file, several named sets.** The config holds a list of named lists
(`{ Schema = 'wuu.computerlist.v2'; Lists = [ { Name; Computers; ... }, … ] }`), so "list saved sets by
name" is a read of `Lists[].Name`. Saving adds or replaces **one** named list and leaves the others
alone; `Import-ComputerListConfig -ListName <name>` selects one. Loading from the console shows the
numbered chooser; there is no prompt when the file holds a single list, because there is no decision.

Two rules exist because breaking either loses an operator's work. **A same-named save is refused, not
silently replaced** (confirm, or pass `AllowOverwrite`). **A failed decryption is reported as a wrong
passphrase, never as an empty file** — the ciphertext is one unit, so a typo cannot add a list, and
treating "could not decrypt" as "no lists saved yet" would overwrite every list in the file.

A v1 file (the legacy single-list shape) reads as **one** list named `default` and is **not rewritten
by reading it** — merely opening the tool must not modify the operator's only copy. It is upgraded on
the next save. Automatic loads (`wuu check -All`) prefer the `default` list, else the first, and say
which they chose, so a scripted run is never left at a prompt.

## 22. Session state model

```
WELCOME → COMPUTER_SET → COMPUTER_SET_REVIEW → PREFLIGHT → DASHBOARD
        → OPERATION_SELECTION → CONFIRMATION → EXECUTION → RESULTS → DASHBOARD
```

Child states:

```
COMPUTER_SET  ├── ManualEntry ├── Import ├── ActiveDirectory └── LoadSavedSet
DASHBOARD     ├── UpdateManagement ├── ComputerManagement ├── Deployment
              ├── Credentials ├── Diagnostics └── Reports
RESULTS       ├── Retry ├── InspectFailure ├── ContinuePhase ├── Export └── Dashboard
```

## 23. Architectural requirement

**Do not rewrite the update engine to implement this UI.** Reuse the existing action/engine layer:

```
        ┌──────────────────────────────┐
        │  Action Layer                │
        │  State/Engine, Workers,       │
        │  Credentials, Audit          │
        └──────────────┬───────────────┘
                       │
        ┌──────────────┴───────────────┐
┌───────▼──────────┐        ┌─────────▼────────┐
│ Interactive CLI  │        │ Command CLI      │
│ task-oriented    │        │ verb-oriented    │
│ guided workflow  │        │ scriptable       │
└──────────────────┘        └──────────────────┘
```

Both interfaces invoke the same operations.

## 24. Preserve command-line automation

Do **not** convert the non-interactive CLI into a guided workflow. `wuu check -All`,
`wuu install -Computer SRV01 -Reason "..."`, `wuu audit verify` and every other verb must keep
working unchanged.

> Interactive mode asks "what are you trying to accomplish?" — command mode says "execute this
> specific operation." Both invoke the same action layer and audit mechanisms.

## 25. Required UX properties

**P0 (mandatory):** acquisition is the first task; manual entry; list import; saved sets loadable;
AD acquisition where supported; review before operations; operations grouped not flat; pre-flight
before disruptive operations; explicit confirmation for mutating operations; lifecycle visible as a
workflow; phases visible; execution progress visible; results summarized; failures actionable;
command-line automation still functional.

**P1 (high):** individual computer details; credential testing in pre-flight; named saved sets;
deployment dashboard; retry failed; continue to next phase; export from the results screen.

**P2 (secondary):** rich AD search/filtering; advanced import formats; extra report formats; UI
polish and keyboard navigation.

## 26. Acceptance test — new user

A new user must complete this without knowing any command syntax:

```
START → add computers manually → review → save set → pre-flight → review problems →
check → review available → download → review plan → enter change reason → confirm →
install → reboot where required → verify → review failures → retry failures →
complete phase → start next phase → export report → dashboard → exit
```

## 27. Acceptance test — existing operator

An experienced operator must still bypass the guided UI entirely:

```
wuu check -All
wuu download -All
wuu install -All -Reason "Monthly patching"
wuu restart -All
wuu audit verify
```

The redesign must not reduce automation capability.

## 28. Primary design rule

> Organize the interactive UI according to the administrator's task, not according to the
> implementation's command structure.

The administrator thinks "I need to patch these servers" — not "I need the `check`, `download`,
`install`, `restart` and `audit` verbs as independent concepts."

## 29. Implementation priority

```
1.  Introduce ComputerSet as the primary interactive state.
2.  Replace the current startup menu with computer acquisition.
3.  Implement manual computer entry workflow.
4.  Implement import workflow.
5.  Implement saved computer-set loading.
6.  Refactor the flat menu into grouped navigation.
7.  Implement the dashboard.
8.  Implement pre-flight.
9.  Implement operation confirmation.
10. Implement the explicit Check → Download → Install → Reboot → Verify workflow.
11. Integrate deployment phases into dashboard/workflow.
12. Improve execution/progress display.
13. Implement the actionable results screen.
14. Add individual computer details.
15. Integrate credentials into pre-flight.
16. Add AD acquisition workflow.
17. Add reporting/audit navigation.
18. Preserve and regression-test all direct command functionality.
```

Key architectural constraint:

> **Change the interactive orchestration and presentation first; reuse the existing WUU2 engine
> wherever possible.**

---

## Implementation status (this repo)

| Section | Status | Where |
| --- | --- | --- |
| 1–2 objective / lifecycle | adopted | this document |
| 3 startup acquisition | **implemented** | `Show-WuuAcquisitionScreen` (`Wuu.Navigate.psm1`) |
| 4.1 manual entry | **implemented** | `Show-WuuManualEntryScreen` |
| 4.2 import | **implemented** | `Show-WuuImportScreen` (TXT/CSV; duplicate + invalid reporting) |
| 4.3 AD acquisition | **implemented** | `Show-WuuAcquisitionScreen` → `EventAddAD` (handler existed but was unwired) |
| 5 review screen | **implemented** | `Show-WuuComputerSetReviewScreen` |
| 6 ComputerSet as first-class object | **implemented** | `New-WuuComputerSet` (`Wuu.Session.psm1`) |
| 7 pre-flight | **implemented** | `Show-WuuPreflightScreen` + `Get-WuuPreflightReport` + `Test-WuuPrerequisite` |
| 8 dashboard | **implemented** | `Show-WuuDashboardScreen` |
| 9 grouped navigation | **implemented** | `Get-WuuNavigationTree` |
| 10–11 update lifecycle / full deployment | **implemented** | `Get-WuuWorkflowSpec` + `Start-WuuDeploymentSequence` |
| 12 confirmation | **implemented** | `Confirm-WuuMutation` + `New-WuuOperationPlan` |
| 13 phases visible | **implemented** | Dashboard phase summary; per-phase plan in confirmation |
| 14–15 execution / results screens | **implemented** | `Show-WuuExecutionScreen`, `Show-WuuResultsScreen` |
| 16 computer details | not yet | planned |
| 17–21 management / credentials / diagnostics / reports / saved sets | **implemented (navigation + delegation)** | grouped submenus delegate to existing handlers; credentials and connectivity are also reachable *as pre-flight* (§18) |
| 22 state model | **implemented** | `Wuu.Navigate.psm1` state machine |
| 23–24 reuse engine / preserve automation | **enforced** | no engine change; verbs unchanged (regression-tested) |
| 25 P0 | **complete** | all eleven P0 properties have an assertion in `tests\Test-Navigation.ps1` |
| 26–27 acceptance tests | **27 covered**; 26 covered up to results/retry/export | `tests\Test-Navigation.ps1` |
| 28–29 design rule / priority | adopted | — |

### P0 coverage (spec 25), each with an assertion

| P0 property | Assertion |
| --- | --- |
| acquisition is the first task | `Test-Navigation` §9 — an empty set starts at `ACQUIRE` |
| manual entry | §8 — parses, reviews and commits, including the single-name case |
| list import | §4 / §11 — reports added / duplicate / invalid; CSV column detection |
| saved sets loadable | §6 — `EventLoadConfig` reachable from every relevant menu |
| AD acquisition | §6 — `EventAddAD` resolves to a wired handler |
| review before operations | §8 — review screen gates the dashboard |
| operations grouped, not flat | §5 — ≤ 12 top-level entries, no mutating one among them |
| pre-flight before disruptive operations | §13 — verdicts, availability, offline skipping |
| explicit confirmation for mutating operations | §15 — decline, blank reason, reason recorded |
| lifecycle visible as a workflow | §14 / §19 — the deploy spec is the full sequence |
| phases visible | §4 — all five phases reported, including empty ones |
| execution progress visible | §17 — state mapping covers every row state |
| results summarised | §18 — successful / failed / offline / reboot required |
| failures actionable | §18 — retry narrows to the failures; cause printed |
| command-line automation still functional | §7 / §9 — verbs intact, mutating set unchanged |

### Deliberate deviations, and why

- **The flat menu is retained as `Advanced (all operations)`.** Section 9 forbids exposing 25+
  operations *at the top level*, which is satisfied — but the flat list is still valuable for an
  operator who already knows WUU2, and removing it would reduce capability (contradicting §27's
  spirit). It is one level down, under a clearly-labelled entry. Its mutating entries route through
  the same audit choke point; they ask for a reason at the point of dispatch, because the flat menu
  has no confirmation screen of its own.
- **AD acquisition routes to the pre-existing `EventAddAD` handler** rather than being reimplemented.
  That handler existed and worked but was **never wired into any menu or verb** — so the operation
  was unreachable despite appearing implemented. Wiring it is §23 (reuse the engine) rather than
  §4.3 being written from scratch.
- **Named saved sets are not a new registry.** Per §21's own requirement to preserve existing
  encryption/security semantics, the saved set is the existing encrypted config file. Loading and
  saving route to `EventLoadConfig` / `EventSaveConfig`.
- **Pre-flight probes are injected, not called in place.** §23 forbids presentation code reaching
  into the engine, and a real ping timeout per host would make the property untestable in
  reasonable time. `New-WuuPreflightContext` is the only place the live probes are named.
- **Pre-flight runs per operation, not per workflow step.** A full deployment is confirmed once
  (with the complete sequence and per-phase plan shown); re-probing the estate before each of the
  six steps would multiply the cost while telling the operator nothing new within one run. Each
  mutating step still collects its own change reason, so the audit trail explains each change
  independently.
- **`-Targets` travels to the handlers through a guided-target override on `Read-WuuSelection`**
  rather than a new handler parameter. The handlers are shared verbatim with the command surface
  (§23/§24); adding a parameter would either fork them or change the shape the verb table
  dispatches into. An *empty* override means "target nothing" and is distinguished from "not
  decided" by an explicit `$null` test — otherwise a retry with no failures would silently become
  an all-computers run.

### Defects found and fixed while implementing §7 / §12 (each was caught by an assertion, not by inspection)

1. **`Get-WuuWorkflowSpec` had no `param` block**, so `$Name` was undefined and the function threw
   the moment any workflow ran under `Set-StrictMode`. The test caught it; nothing else would have,
   because an unused workflow is only reached from the deployment path.
2. **Single-target plans threw.** `$targetRows = if (...) { @(...) } else { $rows }` unwraps a
   one-element array to a scalar, so `.Count` threw for exactly the retry-failed case — the same
   unwrapping class that once crashed manual entry on a single computer name.
3. **"Cannot tell" was reported as "offline".** The offline count was derived unconditionally as
   `(total - reachable)`, so with no ping probe every computer was reported down. Both the count
   and the screen now state that reachability was not probed.
4. **The interactive audit hook discarded its targets**, so a human-authorised change recorded no
   targets while a scripted `wuu install -Computer SRV01` did — the trail could not answer "which
   hosts did this person change?".
5. **The guided handler passed the audit body positionally** into `-Reason`, which would have
   written a record whose reason read `System.Management.Automation.PSDataCollection...`. It now
   passes `-Reason` and `-Targets` by name.
6. **The change reason was not consumed**, so the second step of a deployment silently inherited
   the first step's justification.
7. **A pre-flight refusal was recorded by the screen, not the gate** — so any other caller of the
   confirmation gate produced an unrecorded refusal, which is the specific gap A.8.15 addresses.
   The gate now records it.
8. **`tests/Test-Navigation.ps1` reported `ALL PASS` after failures** because the summary read
   `$failed` while the helper sets `$fail`. An undefined variable under no strict mode is falsy, so
   the suite's verdict was independent of its own assertions. Every failure above was being printed
   and then contradicted one line later.
