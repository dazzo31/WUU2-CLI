# WUU2-CLI hardening pass (post-beta.2) — phased findings

Working record for the sequential hardening brief. Each phase is implemented, verified against the
shipped code, and gated by tests before the next begins.

**Baseline for this pass:** `v1.5.0-beta.2-cli` = commit `955ae2a`, clean tree.

---

## Phase 0 — Baseline (PASS)

### Environment

| | |
| --- | --- |
| Commit | `955ae2aa060f2c87221d329b8f6f7cddec201d7e` |
| Tag | `v1.5.0-beta.2-cli` |
| Host PowerShell | 5.1.26100.9444 |
| `#Requires` | `-Version 5.1` (single directive, all shipped files) |
| Test framework | **Not Pester.** Plain `.ps1` suites printing `PASS:`/`FAIL:`, exit 0/1. (`Pester` is present on the host but nothing depends on it.) |
| Test files | 29 total, **27 runnable** (2 GUI leftovers) |
| Baseline result | **26 pass, 1 skip, 0 fail** — the skip is `Test-RemoteTask`, elevation-gated, exits 0 with a `SKIP:` marker |

No pre-existing failures, so every failure from here is one this pass introduced.

### Implementation map (as actually built)

```
WUU.ps1
  └─ Start-WuuApplication            (Wuu.Core)
       ├─ Import-WuuModules          all 13 modules, -Global
       ├─ [command mode]  ConvertTo-WuuCommandLine → Invoke-WuuCommand
       │                                            (Wuu.Command)
       └─ [interactive]   Start-WuuGuidedWorkflow   (Wuu.Navigate)
                          └─ $consoleActions.*       (Wuu.Core action layer)
                                │
                                ▼
                    Start-UpdateCheckJob  ◄── THE single submission point (Wuu.WindowsUpdate)
                                │                (one per-computer operation pipeline)
                                ▼
                    per-computer Runspace (New-ComputerRunspace)
                                │
                                ▼
                    $jobs  (synchronized ArrayList of job entries)
                                │
                                ▼
                    jobCleanup loop (separate runspace, Wuu.Core)
                        ├─ completion → EndInvoke, release OpState, clear deadline
                        ├─ failure    → mark Error, release OpState
                        └─ deadline   → Stop, mark Timeout, release OpState
                                │
                                ▼
                    Audit (Wuu.Audit) — intent before, outcome after; fail-closed
```

Per-computer state lives in the `Wuu.State` store (`Rows`/`ByName`); the console renders it.

### Execution entry points found

| Site | Kind | Gated by `MaxConcurrentJobs`? |
| --- | --- | --- |
| `Wuu.WindowsUpdate.psm1:472` | per-computer op submission (`Start-UpdateCheckJob`) | **No — see Phase 3** |
| `Wuu.Core.psm1:2472` | job-cleanup loop (one, started at wiring) | n/a (singleton) |
| `Wuu.Core.psm1:1687` | WUA search sub-pipeline **inside** the Check payload | n/a (bounded, sequential) |
| `Wuu.Core.psm1:1761` | reboot-probe sub-pipeline **inside** the Install payload | n/a (bounded, sequential) |
| `Wuu.Workers.psm1:134,211` | bounded remote probes on the worker pool | bounded by pool size, not the job cap |

The two `Wuu.Core` `BeginInvoke` sites are **bounded sub-pipelines inside a payload**, not job
submissions, and a validator gate already asserts no per-computer submission exists outside
`Start-UpdateCheckJob`.

### Two defects identified during Phase 0

Recorded here so they are not lost; each is fixed in its own phase.

1. **Credential fallback (Phase 1).** `Wuu.Credentials.psm1:86` — *"Custom credentials failed **or
   not configured**, try default credentials."* If custom credentials are enabled and fail
   authentication, the resolver silently probes with the default credential and returns it on
   success. The operation then runs as a different identity than the one configured, and the caller
   cannot tell.
2. **Global concurrency cap bypass (Phase 3).** `MaxConcurrentJobs` appears inside
   `Start-UpdateCheckJob` **only within a comment**; the single real check
   (`if ($jobs.Count -ge $MaxConcurrentJobs) { break }`) lives in the scheduler tick
   (`Start-PendingUpdateCheck`). Every console handler calls `Start-UpdateCheckJob` **directly**, in a
   loop, so the cap never applies and the comment's claim ("it counts toward the global cap") is
   untrue. A `-All` operation over a large estate can therefore start an unbounded number of
   pipelines.

### Also noted (not yet actioned)

- `Wuu.Core.psm1:1152` defines a **third** credential resolver, inside the per-computer runspace
  body, wrapping `$GetRemoteCredentialsScript`.
- `Get-RemoteCredentials` returns `$null` for **both** "use the default credential" and "no
  credential works", so every call site must re-probe to tell them apart.
- **No operation identity exists** (`OperationId`/`CurrentOperationId` appear nowhere), so a stale
  worker cannot be distinguished from the current one by anything other than timing.

---

## Phase 1 — Credential determinism

*(in progress — findings and changes recorded below as they are made)*
