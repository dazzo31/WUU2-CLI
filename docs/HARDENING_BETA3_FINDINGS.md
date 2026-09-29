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

## Phase 1 — Credential determinism (PASS)

### The rule

> If custom credentials are configured and enabled, the operation uses that identity **or fails**.
> It never falls back to the process identity.

### The defect (three parts, all silent)

| Part | Location | What it did |
| --- | --- | --- |
| Resolver fallback | `Wuu.Credentials.psm1` | *"Custom credentials failed **or not configured**, try default credentials"* — a configured-but-rejected credential produced a **successful operation under the wrong account** |
| Call-site swallow | both remote-task paths | `catch { $remoteCred = $null }`. `$null` legitimately means "use the process identity", so a credential **refusal** was converted into an **identity substitution** |
| Ambiguous return | `Get-RemoteCredentials` | `$null` meant **both** "use the default" and "nothing works", so no caller could tell them apart |

### What changed

* **`Resolve-WuuOperationCredential`** — reports `Mode` / `Credential` / `Username` / `Verified` /
  `Reason` as one self-describing value, with the mode decided **before any probe runs**. The answer to
  *"which identity was intended?"* never requires reading mutable global state afterwards.
  `-Verify` is optional so identity can be fixed at submission without a network round trip.
* **`Get-RemoteCredentials`** keeps its contract (`[pscredential]` or `$null` = process identity) but
  now **throws** when configured custom credentials are unusable. It also no longer probes on the
  default path — its own documentation claimed that round trip was pointless, and the first version of
  the fix reintroduced it.
* **Runspace-side resolver rewritten** to match, with no fallback, and a cache that can only hold the
  configured credential itself (so a cached entry cannot contradict the configured mode).
* **Call sites made unconditional** — the resolver owns the mode *and* the local-machine rule, so the
  duplicated `-ne 'localhost'` guard is gone. Identity is decided in **one** place.

### A determinism hole the brief asks about (case 7)

A runspace captures the credential configuration **at creation** and is then **reused**
(`if (-not $ComputerItem.Runspace)`). So a credential change left every existing row running the next
operation under the **previous** identity — silently and deterministically wrong.

Fixed with a **credential epoch**: bumped whenever the configuration changes, stamped on the row when
its runspace is built, and compared at submission. A mismatch disposes the stale runspace and builds a
fresh one. One integer comparison when nothing has changed.

### Verification

* `tests\Test-CredentialDeterminism.ps1` — **30 assertions**. Includes the core assertion on **both**
  resolvers (a failed custom credential probes **no** default identity) and a **differential** that
  drives the module-side and runspace-side implementations on identical inputs and compares verdicts.
* `tests\Test-CredentialPropagation.ps1` — the `(b)`/`(c)`/`(d)` blocks were **rewritten, not
  deleted**: they *asserted the fallback as a requirement* ("falls back to default credentials",
  "caches the default-credentials outcome"), i.e. the suite encoded the defect. Regex-pair agreement
  was replaced with the real differential.
* Validator gates **(ad)/(SS6)** updated for the same reason — one gate **demanded** the fallback and
  now **forbids** it.
* Tautology check: reintroduced the fallback and confirmed **both** the validator and the suite fail.
* Full suite **27 pass, 0 fail** (1 elevation-gated skip). Validator: all gates pass.

### Mistake made during this phase (recorded, not hidden)

I ran the tautology experiment with `git checkout --` as the **restore** step while Phase 1 was still
**uncommitted**. That discarded the two `Wuu.WindowsUpdate.psm1` changes. I detected it via
`git status` (the file no longer appeared as modified), verified exactly what was lost, and re-applied
both. The pattern is fixed: **copy to a temp file and restore from the copy**, or commit first —
never `git checkout` on uncommitted work.

---

## Phase 2 — Stale-worker / race correctness

*(in progress)*

