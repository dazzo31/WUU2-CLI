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
| 7 pre-flight | not yet | planned |
| 8 dashboard | **implemented** | `Show-WuuDashboardScreen` |
| 9 grouped navigation | **implemented** | `Get-WuuNavigationTree` |
| 10–11 update lifecycle / full deployment | **implemented (grouping)** | Update management submenu |
| 12 confirmation | not yet | planned |
| 13 phases visible | **implemented** | Dashboard phase summary |
| 14–15 execution / results screens | not yet | planned |
| 16 computer details | not yet | planned |
| 17–21 management / credentials / diagnostics / reports / saved sets | **implemented (navigation + delegation)** | grouped submenus delegate to existing handlers |
| 22 state model | **implemented** | `Wuu.Navigate.psm1` state machine |
| 23–24 reuse engine / preserve automation | **enforced** | no engine change; verbs unchanged (regression-tested) |
| 25 P0 | **mostly** | see gaps above; automation preserved and tested |
| 26–27 acceptance tests | **27 covered**; 26 partial | `tests\Test-Navigation.ps1` |
| 28–29 design rule / priority | adopted | — |

### Deliberate deviations, and why

- **The flat menu is retained as `Advanced (all operations)`.** Section 9 forbids exposing 25+
  operations *at the top level*, which is satisfied — but the flat list is still valuable for an
  operator who already knows WUU2, and removing it would reduce capability (contradicting §27's
  spirit). It is one level down, under a clearly-labelled entry.
- **AD acquisition routes to the pre-existing `EventAddAD` handler** rather than being reimplemented.
  That handler existed and worked but was **never wired into any menu or verb** — so the operation
  was unreachable despite appearing implemented. Wiring it is §23 (reuse the engine) rather than
  §4.3 being written from scratch.
- **Named saved sets are not a new registry.** Per §21's own requirement to preserve existing
  encryption/security semantics, the saved set is the existing encrypted config file. Loading and
  saving route to `EventLoadConfig` / `EventSaveConfig`.
