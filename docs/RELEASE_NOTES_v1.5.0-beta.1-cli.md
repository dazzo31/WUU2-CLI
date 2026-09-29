# WUU2-CLI v1.5.0-beta.1-cli

**Testing build.** The interactive UI was redesigned around the administrator's workflow rather
than around individual commands (`docs/INTERACTIVE_UI_SPEC.md`). This is the first build with
pre-flight, confirmation and results screens. It is a **beta**: the update *engine* is unchanged,
but the interactive shell gained a large amount of new orchestration.

Nothing here changes the command-line surface. `wuu check -All`, `wuu install -Computer SRV01
-Reason "..."` and `wuu audit verify` behave exactly as in v1.4.1-cli.

---

## What to test

The redesign's acceptance path (spec §26). A new user should be able to complete this **without
knowing any command syntax**:

```
START → add computers manually → review → save set → pre-flight → review problems →
check → review available → download → review plan → enter change reason → confirm →
install → reboot where required → verify → review failures → retry failures →
complete phase → start next phase → export report → dashboard → exit
```

### New in this build

| Area | What you should see |
| --- | --- |
| **Startup** | With no computer set, WUU2 offers acquisition (manual / import / AD / load saved) — it does **not** show update operations until a set exists |
| **Pre-flight** | Reachability, credential validity, WU service, OS, pending reboots and per-operation prerequisites, then `Continue with N available` / `Remove offline` / `Review problems` |
| **Confirmation** | Before any change: computer count (available vs total), updates to download/install, expected reboots, per-phase breakdown, and the explicit `Check → Download → Install → Restart → Re-check → Verify` sequence |
| **Full deployment** | `Update management → 6`, or `Deployment phases → 4` — runs the six steps, each with its own change reason |
| **Results** | Successful / Failed / Offline / Reboot required, failures **with their cause**, and actionable next steps |
| **Retry failed** | Narrows the next operation to **only** the computers that failed, and forces a fresh pre-flight |
| **Credentials** | Testable from `Credentials → 2` (pre-flight), not only discovered after an operation fails |

### Things that would be genuine bugs — please report these

1. An operation reaching an update step **without** a confirmation prompt or a change reason.
2. A **mutating** step whose change reason does not appear in `wuu audit show`.
3. **Retry failed** targeting more than the failed computers, or targeting none.
4. Pre-flight reporting every computer as **offline** when the network is fine.
5. `Cancel` at any prompt leaving the set modified or losing the computer list.
6. Full deployment running a **restart** on a computer that had no pending reboot.
7. Any state where the dashboard is unreachable, or a selection returns to the wrong screen.

---

## Fixed in this build

Found by inspecting the shipped tree while documenting the redesign — none of these are visible
from the happy path.

1. **The AD connectivity test destroyed itself.** `$TestADConnection` assembled its results and
   then displayed them with `[System.Windows.MessageBox]`. This edition deliberately does not load
   `PresentationFramework` (verified under both PS 5.1 and 7: the type does not resolve), so the
   diagnostic threw `Unable to find type [System.Windows.MessageBox]` **on its last line** — and it
   is only ever offered *after* AD access has already failed. It now prints to the console. It also
   no longer reports `[ERROR] OUSelector.xaml NOT found` for a file this edition purposely deleted.
2. **Phase-assignment errors were reported through a WPF message box**, which would have replaced
   the real error with a type-resolution failure. Now printed.
3. **Two unused assemblies were loaded at startup.** `Microsoft.VisualBasic` and
   `System.Windows.Forms` had **no live caller**. `Add-Type -AssemblyName` *throws* on failure and
   the catch calls `exit`, so carrying an unused assembly made a missing optional component a hard
   startup failure — contradicting this edition's claim that it runs wherever PowerShell 5.1 does.
4. **457 lines of dead GUI-era code removed** from `Wuu.Core.psm1` (3977 → 3520). Twelve closures
   that read `$uiHash.Listview.SelectedItems` (never populated in a console) or used
   `System.Windows.Clipboard` / an `InputFileDialog`. None was reachable; the console's equivalents
   are the `$consoleActions.*` adapters.
5. **Interactive audit records now carry their targets.** The hook discarded them, so a
   human-authorised change recorded **no** targets while `wuu install -Computer SRV01` recorded
   `SRV01` — the trail could not answer "which hosts did this person change?".
6. **`tests\Test-CredentialTyping.ps1` had been failing since the module split.** It parsed
   `WUU.ps1` for a function that moved to `src\Wuu.Remote.psm1`, so it threw
   `Invoke-CimWithTimeout not found` every run. Now 3/3 PASS.

### Validator

Two new gates, both of which immediately caught real defects:

- **GUI-only type forms** (`[System.Windows.MessageBox]`, `[System.Windows.Forms.*]`,
  `[Microsoft.VisualBasic.*]`, `OpenFileDialog`). The existing gate watched assembly/type *names*
  (`PresentationFramework`, `XamlReader`) and so could not see the fully-qualified forms — which is
  how defect 1 got in.
- **`System.Windows.Forms` must not be loaded by the engine** (`Test-HeadlessEngine`), so removing
  its startup load is verified rather than assumed.

---

## Known limitations (stated, not hidden)

These are unchanged from v1.4.1-cli unless noted.

- **The audit trail is tamper-*evident*, not non-repudiable.** A hash chain makes silent edits
  **detectable**; it does not make them impossible. Anyone with write access to the log *and* the
  code can recompute a chain over their own edits. Real non-repudiation needs the chain head
  anchored where the operator cannot rewrite it (Event Log mirror or a signed daily digest) — **not
  implemented**.
- **No retention/pruning of old audit files.** Deliberate: `Validate-Release.ps1` fails the build if
  a delete path appears in the audit module.
- **Audit records live in `%PROGRAMDATA%\WUU2\audit`** (LocalAppData fallback), never a synced
  folder — OneDrive paths caused real repeated failures in this codebase.
- **Per-computer details (spec §16) are not implemented**, and AD acquisition does not have the
  richer search/filtering of §4.3's P2 tier. Everything else in spec §25 P0 has an assertion in
  `tests\Test-Navigation.ps1`.
- **Pre-flight's credential and service probes are DCOM/WMI calls.** Their composition and
  offline-skipping logic are unit-tested with injected probes; the probes themselves against a
  real remote host are **not** verified in the development environment. If you have a host that
  answers ping but refuses WMI, that is the case worth exercising.
- `tests\Test-ColumnResize.ps1` and `tests\Test-DragResize.ps1` are GUI-edition leftovers and are
  expected to fail/hang. Both should be deleted; they are excluded from the suite run.

---

## Verification

```
Validator                            all checks passed
Tests (15 suites, headless)          all pass; Test-RemoteTask SKIPs without elevation
                                     Test-CredentialTyping 3/3 (was failing)
```

Run it yourself:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Validate-Release.ps1
Get-ChildItem .\tests\Test-*.ps1 | Where-Object {
    $_.Name -notin @('Test-ColumnResize.ps1','Test-DragResize.ps1') } | ForEach-Object {
    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $_.FullName }
```

---

## Upgrading

Extract over your existing folder. `ComputerList.config` is **not** in the zip — keep yours, or it
will be overwritten. The audit trail is untouched by an upgrade.

Requires an elevated PowerShell host and `-STA`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WUU.ps1
```

`--flat-menu` still restores the previous flat 25-operation list if the guided flow blocks you.
