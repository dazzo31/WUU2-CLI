# WUU2-CLI — Console Edition with Audit Trail: Implementation Plan

**Status:** Planning
**Target:** Fully interactive console edition of WUU2 with a complete, tamper-evident audit trail. No WPF/GUI dependency.
**Baseline:** forked from `dazzo31/WUU2` at `v1.3.4` (2026-09-26)

---

## 1. Goal

Re-target WUU2's Windows Update engine so it runs **without WPF**, driven from an
interactive console, and makes **every action auditable**:

- Menu-driven for humans (same operations as the GUI context menu).
- Command-driven for scripting/CI (`wuu check -Computer SRV01`).
- Structured audit log (JSONL) + session transcript + hash-chained, tamper-evident records.
- Operator identity and a reason/ticket reference captured for every mutating action.

Everything the GUI can do must remain possible. Nothing about the update engine changes —
only how it is driven, and what it records.

---

## 2. Why this is a real refactor (not a wrapper)

The current code is **tightly coupled to WPF**: 552 `uiHash`/`Dispatcher`/`XamlReader`
references, mostly inside the worker payload script blocks. Key facts measured on v1.3.4:

| File | Lines | Role | WPF coupling |
|---|---|---|---|
| `src/Wuu.Core.psm1` | 4717 | app shell, all event handlers, worker payloads, GUI loop | **Heavy** — XAML load, `Dispatcher.Invoke` everywhere, `MessageBox`, `InputBox`, `OpenFileDialog`, `SaveFileDialog`, `ListView` items |
| `src/Wuu.WindowsUpdate.psm1` | 663 | runspace/job scheduling, phase gating | **Heavy** — dispatcher actions + row-object UI updates |
| `src/Wuu.Credentials.psm1` | 689 | credential collection/dialogs | **Medium** — XAML dialogs (replaceable by `Get-Credential`) |
| `src/Wuu.Remote.psm1` | 417 | CIM/RPC/service with timeouts | None ✅ |
| `src/Wuu.Workers.psm1` | 266 | bounded runspace pool | None ✅ |
| `src/Wuu.Network.psm1` | 137 | remote COM with timeout | None ✅ |
| `src/Wuu.Models.psm1` | 118 | state factories | None ✅ |
| `src/Wuu.Logging.psm1` | 98 | fault-tolerant logging | None ✅ |
| `Scripts\*.ps1` | ~370 | remote download/install tasks, WSUS audit | None ✅ |

**~2,500 of ~7,100 lines are GUI-shaped.** The reusable engine (Remote, Workers,
Network, Models, Logging, Scripts, and the WUA logic inside WindowsUpdate) is ~2,000
lines and needs no changes.

### The core architectural problem
Worker runspaces update "the UI" through `$uiHash.<Control>.Dispatcher.Invoke(...)`.
Without WPF there is no Dispatcher. The fix is to introduce a **presentation abstraction**
so payloads call `Set-ComputerStatus`/`Add-ComputerRow` and not WPF directly.

---

## 3. Target architecture

```
WUU2-CLI/
  wuu.ps1                     # new entry point (replaces WUU.ps1)
  src/
    Wuu.Core.psm1             # KEEP  -> engine/payloads, WPF removed
    Wuu.WindowsUpdate.psm1    # KEEP  -> scheduler; dispatcher actions -> state sink
    Wuu.Remote.psm1           # KEEP  unchanged
    Wuu.Workers.psm1          # KEEP  unchanged
    Wuu.Network.psm1          # KEEP  unchanged
    Wuu.Models.psm1           # KEEP  + AuditRecord/OperatorContext factories
    Wuu.Logging.psm1          # KEEP  unchanged
    Wuu.Credentials.psm1      # REWRITE console prompts (Get-Credential, SecureString)
    Wuu.State.psm1            # NEW   presentation-agnostic computer state store
    Wuu.Console.psm1          # NEW   menu rendering, tables, prompts, colour
    Wuu.Command.psm1          # NEW   subcommand parsing + dispatch (check/download/...)
    Wuu.Audit.psm1            # NEW   JSONL log, transcript, hash chain, identity/reason
  ui/                         # DELETE (MainWindow.xaml, CredentialDialog.xaml, OUSelector.xaml)
  Scripts/                    # KEEP  (+ exclude dev _*.ps1 from release, as in v1.3.4)
  tests/                      # KEEP  + new CLI/audit tests
  docs/                       # this plan + user/audit docs
```

### Presentation abstraction (the keystone change)
Replace every `$uiHash.<Control>.Dispatcher.Invoke(...)` with a call on a **state sink**
object that either:
- **console mode** — writes to the state store + redraws a status table on a timer; or
- (optionally, later) an in-memory store with no output, for pure scripting.

Payloads become free of any UI framework and are unit-testable headlessly.

---

## 4. Operation parity map (GUI → console command)

Every GUI operation becomes a subcommand **and** a menu item. Source is the event
handler inventory in `src/Wuu.Core.psm1`.

| GUI operation | Handler | New subcommand | Mutating? | Needs reason? |
|---|---|---|---|---|
| Check For Updates | `$eventGetUpdates` / `$GetUpdates` | `wuu check [-Computer x,y] [-All]` | No | No |
| Download Updates | `$eventDownloadUpdates` / `$DownloadUpdates` | `wuu download [-Computer …]` | **Yes** | **Yes** |
| Install Updates | `$eventInstallUpdates` / `$InstallUpdates` | `wuu install [-Computer …] [-Reboot]` | **Yes** | **Yes** |
| Restart Computer | `$eventRestartComputer` / `$RestartComputer` | `wuu restart [-Computer …] [-Force]` | **Yes** | **Yes** |
| Add Computers (manual) | `$eventAddComputer` | `wuu add -Computer a,b,c` | Config | No |
| Add from AD | `$eventAddAD` | `wuu add -FromOU "OU=…"` | Config | No |
| Add from file (CSV/TXT) | `$eventAddFile` | `wuu add -FromFile x.csv [-Column n]` | Config | No |
| Import/Paste computers | `$eventPasteComputers` | `wuu add -FromClipboard` (or stdin) | Config | No |
| Remove computers | `$removeEntry` | `wuu remove [-Computer …] [-Offline]` | Config | No |
| Clear list | `$clearComputerList` | `wuu clear` | Config | No |
| Assign Phase | `$eventAssignPhase` | `wuu phase -Set 2 [-Computer …]` | Config | No |
| Export list to file | `$eventSaveComputerList` | `wuu export -Path x.csv` | No | No |
| Save encrypted config | `$eventSaveConfig` | `wuu config save` | Config | No |
| Load encrypted config | `$eventLoadConfig` | `wuu config load` | Config | No |
| Set domain credentials | `$eventSetDomainCredentials` | `wuu credentials set` | Config | No |
| Show available updates | `$eventShowAvailableUpdates` | `wuu show available [-Computer …]` | No | No |
| Show installed updates | `$eventShowInstalledUpdates` | `wuu show installed [-Computer …]` | No | No |
| Update history | `$eventShowUpdateHistory` | `wuu history [-Computer …]` | No | No |
| Audit WSUS Updates | `$eventAuditWSUSUpdates` | `wuu audit wsus [-Computer …]` | No | No |
| View update log | `$eventViewUpdateLog` | `wuu logs [-Computer …]` | No | No |
| WU service start/stop/restart | `$eventWUServiceAction` | `wuu service start|stop|restart [-Computer …]` | **Yes** | **Yes** |
| Remove offline computers | `$eventRemoveOfflineComputer` | `wuu prune [-WhatIf]` | Config | No |
| Copy cells / status | `$eventCopyCellContent` / `$eventCopyComputers` | `wuu export -Format json|table` | No | No |
| View errors / suggestions | `$GetErrors` | `wuu errors` | No | No |
| Select all (GUI-only) | `$eventKeyDown` | n/a — `-All` switch | — | — |
| Right-click menu enable/disable | `$eventRightClick` / `$eventActionMenu` | n/a — menu availability logic | — | — |
| Column resize / window init / close | `$eventWindowInit` / `$eventWindowClose` | n/a — replaced by console lifecycle | — | — |

**Parity target:** 25 of 25 meaningful operations. The 5 GUI-chrome items have no
console equivalent by design.

---

## 5. Audit design

### 5.1 Record shape (one JSON object per line, `audit-YYYYMMDD.jsonl`)
```json
{
  "seq": 42,
  "timestampUtc": "2026-09-27T09:14:03.221Z",
  "runId": "3f2a…",
  "operator": { "user": "DAZZO\\dazzo", "machine": "DARREN-PC", "elevated": true },
  "action": "install",
  "targets": ["SRV01","SRV02"],
  "parameters": { "reboot": true, "reason": "CHG-1041" },
  "dryRun": false,
  "result": "success",
  "counts": { "installed": 3, "errors": 0, "rebootRequired": 1 },
  "durationMs": 184322,
  "wuuVersion": "1.3.4-cli",
  "prevHash": "9c1f…",
  "hash": "a7e3…"
}
```

### 5.2 Hash chain (tamper-evidence)
- `hash = SHA256(canonical(record without hash) + prevHash)`; first record chains from a
  per-run genesis.
- A `wuu audit verify [-Path …]` command re-walks the chain and reports the first break
  (line number + expected vs actual). Used in the compliance handoff and in CI.

### 5.3 Transcript
- `Start-Transcript`-equivalent capturing the full session (commands + output) next to the
  JSONL. Console output must be line-oriented and free of progress-bar control codes so the
  transcript stays readable and diff-able.

### 5.4 Operator identity + reason
- Identity from `[WindowsIdentity]::GetCurrent().Name` + machine + elevation flag, resolved
  once per run and stamped on every record.
- Mutating actions require `-Reason "<ticket/change ref>"`. Interactive mode prompts for it;
  non-interactive mode **fails** without it (configurable strictness: `required` (default) /
  `optional`). Reason is recorded verbatim.

### 5.5 Files & retention
- Default location: `%PROGRAMDATA%\WUU2\audit\` (not a synced folder — see the OneDrive
  locking lesson from WUU2 v1.3.1-beta.2).
- Per-run files + a rolling index. Never rewritten after close (append-only); the chain
  makes edits detectable regardless.

### 5.6 Non-repudiation boundary (be explicit)
Hash-chaining makes **silent edits detectable**, not impossible — anyone with write access
to the log and the code can recompute the chain. Real non-repudiation needs the chain head
written somewhere append-only (Windows Event Log via `Write-EventLog`, or a
`certutil`-signed daily digest). Plan: implement the chain first, then add **one of**
(a) Event Log mirroring of each run's terminal hash, or (b) optional signing of the daily
digest with a certificate. Choose at Phase 5.

---

## 6. Phased implementation

### Phase 0 — Scaffolding & guardrails (small)
- Retarget repo docs/README to the CLI edition; keep the WUU2 lineage and credit.
- Add `AGENTS`/copilot instructions describing the new architecture + audit rules.
- Keep the existing `Validate-Release.ps1` pattern but re-point it at the console shell.
- Delete `ui/` and the XAML load path once the console shell exists.

### Phase 1 — Presentation abstraction (keystone)
- Add `Wuu.State.psm1`: a synchronized computer-state store (`AddComputer`, `RemoveComputer`,
  `SetComputerStatus`, `SetComputerState`, `GetComputers`) — the single source of truth
  instead of `$uiHash.clientObservable`.
- Replace `$uiHash.<Control>.Dispatcher.Invoke(...)` in payloads with state-store calls.
  This is the bulk of the work (~200 call sites) and is mechanical but must be done
  carefully — the dispatcher actions previously ran **on the UI thread** and were bound to
  the worker runspace session state; the store must be thread-safe (synchronized hashtable /
  concurrent collections) and use **language constructs only** where the old code did (no
  pipeline cmdlets in cross-runspace callbacks — see the WUU2 deadlock lesson).
- Add a headless test harness proving a payload can run with no WPF assembly loaded.

### Phase 2 — Console shell + state rendering
- `Wuu.Console.psm1`: table renderer (fixed-width, no ANSI dependency for transcript
  cleanliness), colour, prompts, confirmation, paging.
- A refresh timer (equivalent of the old `JobTimer` + `listView.Refresh()`) that redraws
  the status table from the state store.
- Replace `MessageBox` → `Write-Host`/prompt; `InputBox` → `Read-Host`; `OpenFileDialog` →
  path argument + glob; `SaveFileDialog` → path argument.
- Interactive menu mirroring the GUI context menu (numbered), with a persistent status view.

### Phase 3 — Command surface
- `Wuu.Command.psm1`: parse `wuu <verb> [options]`, map to the Phase-1 store + payloads.
- Implement the parity table in §4. `-WhatIf`-style dry run on all mutating verbs.
- Machine-readable output mode (`-Json`) for every read verb.

### Phase 4 — Audit subsystem
- `Wuu.Audit.psm1`: record writer, hash chain, transcript management, identity/reason capture,
  retention/pruning.
- Wire every mutating operation through the audit path (single choke point — not scattered).
- `wuu audit verify`, `wuu audit show`, `wuu audit export`.

### Phase 5 — Hardening & evidence
- Non-repudiation choice from §5.6 (Event Log mirror **or** signed digest).
- Concurrency/thread-safety tests for the state store under the real worker pool.
- Tests: parity test that every GUI-equivalent operation exists as a command; audit tests
  that the chain detects a tampered line; dry-run test proving no state change.
- Release pipeline: adapt `Package-WUU2.ps1` (already excludes dev `_*.ps1`), version banner,
  release notes, tag, GitHub release — same workflow proven for v1.3.4.

---

## 7. Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Dispatcher removal breaks thread affinity in payloads | Stalls/deadlocks, hard to see headlessly | Phase 1 does the swap first, with a headless harness + the existing `Test-CrossModuleResolution`/`Test-PendingDrain` patterns; keep language-constructs-only rule |
| Losing GUI-only behaviours users rely on | Silent feature loss | §4 parity table is the checklist; automated parity test in Phase 5 |
| Audit log becomes the bottleneck / throws into operations | Kills the operation being audited | Reuse the fault-tolerant writer pattern (lock + retry + silent give-up); audit failures never throw into an update operation, but are surfaced as a warning + non-zero exit at end of run |
| Hash chain gives false sense of security | Compliance mis-statement | §5.6 states the boundary explicitly; Phase 5 adds an append-only anchor |
| Transcript unreadable due to progress redraws | Poor evidence quality | Line-oriented output; no in-place redraw when `-Transcript` is on |
| Console prompt blocks in CI | Hung pipelines | Non-interactive mode: no prompts; missing required input = explicit failure |

---

## 8. Definition of done

- [ ] No WPF/XAML reference anywhere in shipped code (`ui/` deleted; no `PresentationFramework`).
- [ ] 25/25 parity operations available as commands and in the interactive menu.
- [ ] Every mutating action writes a hash-chained JSONL record with operator + reason.
- [ ] `wuu audit verify` detects a deliberately tampered line and reports the break location.
- [ ] `-WhatIf` on all mutating verbs performs no state change (test-proven).
- [ ] Session transcript produced and readable.
- [ ] Test suite green: module import, cross-module resolution, scheduler drain, op chains,
      parity, audit chain, dry-run, state-store concurrency.
- [ ] Packaged release zip + tag + GitHub release via the proven workflow.

---

## 9. Open questions (decide before Phase 5)

1. **Non-repudiation anchor**: Windows Event Log mirror vs certificate-signed daily digest?
2. **Reason strictness**: hard-require a reason for all mutating actions, or allow an
   "optional" deployment mode?
3. **Audit retention**: keep forever, or prune with a configurable retention (e.g. 365 days)?
4. **Multi-operator**: is a single interactive session per operator, or should concurrent
   sessions share one audit file (needs file-level serialisation)?
