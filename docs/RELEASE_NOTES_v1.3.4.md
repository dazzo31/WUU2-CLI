# WUU2 v1.3.4 — Auto Download/Install fix

**Stable release.** Promotes the 1.3.1 beta line to a stable build. Headline fix: **Auto Download** and **Auto Install** now actually run.

## Fixed: Auto Download / Auto Install did nothing

With *Auto Download* and/or *Auto Install* ticked, a check that found updates reported them correctly but then never downloaded or installed — the row just sat on *"N update(s) found. Right-click > Download Updates."*

### Root cause
The auto-chained steps (`GetUpdates` → `DownloadUpdates`, and `DownloadUpdates` → `InstallUpdates`) started a new PowerShell pipeline pointed at **the same per-computer runspace that was already busy** running the current step, and called `BeginInvoke()` from inside it.

A runspace runs one pipeline at a time. `BeginInvoke` on a busy runspace returns success and its handle reports complete instantly, but the chained payload **never executes** — the later `EndInvoke` throws *"pipeline already running"*, which the background cleanup swallowed. The follow-up was silently discarded. Manual buttons worked because they queue all steps as multiple `AddScript` calls in **one** pipeline on a free runspace.

### The fix
Chained operations now use the same proven pattern as the manual buttons:

- After a check finds updates, the auto logic **queues the follow-up** instead of firing it inline.
- Both boxes on → one unattended pipeline: **Download → Install → Reboot (if *Auto Reboot* is on and a reboot is required) → Re-check**.
- Only *Auto Download* on → just the download is queued.
- Manual *Download* with *Auto Install* on → *Install → Reboot → Re-check*.
- The existing 1-second job scheduler starts the chain once the computer's runspace is free, so pipelines never collide.

No UI or setting changes — the checkboxes now do what they always implied.

## Fixed: release packaging could silently drop the zip
`Compress-Archive` intermittently threw when writing into the OneDrive-synced `dist/` folder and left no file behind while still printing "Created package". The packager now uses `System.IO.Compression.ZipFile`, verifies the archive exists, and prints the real entry count — failing loudly if it is missing or empty.

## Carried forward from the 1.3.1 beta line
- **Recoverable timeouts** — a timeout marks a computer **Timeout** (yellow) rather than **Error** (grey); WUA session/search timeouts auto-retry twice, 60 s apart. A **State** column shows pipeline position at a glance.
- **PsExec removed** — remote download/install runs as a one-off SYSTEM scheduled task over the existing DCOM/WMI CIM session. No PsExec, no SMB admin share, no PSTools prompt.
- **Fault-tolerant logging** — debug logs live in `%TEMP%` (never a cloud-synced folder) and every write retries then gives up silently, so logging can never crash the app.
- **Worker pool** — bounded runspace pool replaces ad-hoc Start-Job usage.

## Validation
- Release checks pass (XAML load + control/event wiring).
- New regression test `tests\Test-AutoFlowChain.ps1` drives the real scheduler + worker runspace and asserts each op chain executes in order: `Download`, `InstallAndRecheck` (`INSTALL → RESTART → GET`), and `AutoFlow` (`DOWNLOAD → INSTALL → RESTART → GET`).
- Module import, cross-module runspace resolution, and pending-job drain tests pass.

## Notes
- Pure PowerShell + WPF; Windows PowerShell 5.1, STA, elevated. PS 5.1 / PS 7 compatible patterns (`Get-CimInstance`, `Invoke-Command`).
- Debug log: `%TEMP%\WUU_Debug_*.log`.
