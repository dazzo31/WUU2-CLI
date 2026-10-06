# Contributing to WUU2-CLI

Thanks for taking the time to contribute. WUU2-CLI is the console edition of the Windows Update
Utility — a tool that performs real, remote, change-controlled work (patch deployment, reboots and an
ISO/IEC 27001:2022 A.8.15 audit trail) across a fleet of Windows machines. That context shapes every
rule below: a small correctness regression here can patch the wrong machine, reboot the wrong host, or
corrupt the audit evidence an operator relies on.

- **Repository:** <https://github.com/dazzo31/WUU2-CLI>
- **Companion GUI edition:** <https://github.com/dazzo31/WUU2>
- **Current version:** `v1.5.0-rc.1-cli` (see `src/Wuu.Configuration.psm1`)
- **License:** MIT — see [LICENSE](LICENSE) and [NOTICE](NOTICE)

---

## 1. Before you start — read these first

| Document | Why |
| --- | --- |
| [`.github/copilot-instructions.md`](.github/copilot-instructions.md) | The authoritative rule set for this repository: invariants, module boundaries, state-mutation rules. |
| [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) | The development workflow, phase status, and the honesty rules about CURRENT vs TARGET behaviour. |
| [`docs/TESTING.md`](docs/TESTING.md) | How the tests work, what they prove, and what a `SKIP` does and does not mean. |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Module layout and the request lifecycle. |
| [`docs/STATE-MACHINE.md`](docs/STATE-MACHINE.md) | Workflow states, terminal states and precedence. |

**Source code and passing tests are the source of truth.** Documentation describes intent, history and
plans; it may lag reality. If documentation and code disagree, stop and raise it rather than "fixing"
the code to match a document, or the document to match a bug.

---

## 2. Ground rules

1. **PowerShell 5.1 first.** Windows PowerShell 5.1 is the supported host. PowerShell 7 is best-effort
   for the *remote worker* paths only. Do not use PS7-only syntax, operators or cmdlets.
2. **No new external dependencies.** This tool runs on air-gapped and standard Windows Server hosts.
   Do not add a PowerShell Gallery module (including Pester) as a runtime or test dependency. The test
   suite is deliberately plain `.ps1` with no framework.
3. **No GUI.** No WPF, no XAML, no `System.Windows.*`. This is the console edition; the GUI lives in a
   separate repository that must not be modified from here.
4. **Preserve the invariants.** Operation identity, the state-machine rules, concurrency limits,
   timeout semantics, audit integrity, `-WhatIf` and exit codes are contracts. See
   `.github/copilot-instructions.md`. Do not weaken one to make a feature easier.
5. **Prefer the smallest correct change.** Do not perform architectural rewrites, and do not refactor
   unrelated code in the same pull request.
6. **`-STA` is mandatory** when running the application, the gate or the suites. The Windows Update COM
   APIs and per-computer runspaces are apartment-affine.
7. **Never use destructive Git operations on uncommitted work** (`git checkout --`, `git restore`,
   `git reset --hard`, `git clean -fd`, `git stash drop`). See `docs/DEVELOPMENT.md` §12.

---

## 3. Repository layout

```text
WUU.ps1                 entry point (kept thin — no business logic)
src/Wuu.*.psm1          the modules (see the module-inventory table in copilot-instructions.md)
Scripts/                Validate-Release.ps1 (release gate), Invoke-TestSuites.ps1 (suite runner)
tests/                  Test-*.ps1 behavioural suites (no Pester)
docs/                   architecture, state machine, testing, release notes, provenance
.github/                CI workflow, instructions, agent configs
dist/                   build output — does not belong in a pull request
```

The canonical module list is the `module-inventory` table in `.github/copilot-instructions.md`.
`Scripts/Test-DocConsistency.ps1` fails if a module exists without a row or a row exists without a
module, so **add the row before you add a module**.

---

## 4. Development environment

- Windows with **Windows PowerShell 5.1** (`powershell.exe`).
- No admin rights are needed to run the gate or most suites. `Test-RemoteTask` requires elevation and
  registers a SYSTEM scheduled task, so it **skips** in an unelevated run and in CI.

---

## 5. Running the release gate and the tests

Run both. They check different things: the gate asserts **structure**, the suites assert **behaviour**.

```powershell
# Structural gate (stricter than the tests):
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Validate-Release.ps1

# Whole suite via the aggregate runner (captures exit codes, times out hung suites):
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Invoke-TestSuites.ps1

# A single suite while iterating:
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Invoke-TestSuites.ps1 -Suite Test-WuuOperationState.ps1
```

Notes:

- Use the runner, not a bare `Get-ChildItem | ForEach-Object { … }` loop. A bare loop discards exit
  codes and reports green on a failing tree — that was a real defect in this repository.
- The runner excludes the two stale GUI suites (`Test-ColumnResize`, `Test-DragResize`).
- A `SKIP` is **not** a failure and **not** coverage. Do not quote a skip as evidence.
- Do not document or invoke a `Run-AllTests.ps1`; no such file exists.

**Baseline to compare against:** the gate passes, and the suite runner reports the documented pass /
skip figures with **zero failures**. If a suite fails *before* your change, stop and report it — do not
edit unrelated tests to hide it.

---

## 6. Making a change

1. **Open or find an issue** describing the problem or feature, so the intent is agreed before code.
2. **Fork** the repository and create a topic branch off `master`
   (e.g. `fix/install-error-classification`, `feat/heartbeat-indicator`).
3. **Inspect before editing.** Identify the entry point, the module that owns the behaviour, the state
   it mutates, the tests that cover it, and any gate that protects it. Search for a duplicate
   implementation instead of adding a second one.
4. **Capture a baseline** (gate + relevant suites) *before* changing behaviour.
5. **Change in bounded steps.** Run the smallest relevant test after each step, then the related
   suites, then the full runner and the gate.
6. **Review the whole diff.** Look for the hazards listed in `docs/DEVELOPMENT.md` §20 (`dist/` changes,
   WPF imports, `Read-Host`, PS7 syntax, encoding/BOM changes, scheduler bypass, credential fallback,
   state-machine violations, unrelated refactoring).
7. **Open a pull request** against `master` using the pull request template and fill in the checklist.

---

## 7. Coding standards

- Follow the surrounding style; this codebase is heavily commented **on purpose**.
- **Comment policy** (`docs/CODE_COMMENT_POLICY.md`): contracts, constraints and the *reason* for a
  non-obvious choice stay **inline at the site**. Comment-based help (`.SYNOPSIS`, etc.) stays inline so
  `Get-Help` keeps working. Only pure history moves to `docs/`.
- **Encoding:** a source file containing non-ASCII characters MUST be saved as **UTF-8 with BOM**
  (PS 5.1 misreads BOM-less non-ASCII). Interchange/audit artefacts stay BOM-less. The gate checks this.
- **No `Read-Host`** on automated paths, and keep console output **line-oriented** — no cursor
  repositioning — so session transcripts stay readable and diffable.
- **State mutation** must go through the approved funnel (`Update-WuuOperationState`). Do not add
  `$computer.State = …` style writes at module scope. See `.github/copilot-instructions.md` §9.
- **JSON serialization** in `Wuu.Command` goes through `Format-WuuJsonDocument` (gate SS34).
- Do not commit anything under `dist/`, and never commit credentials, keys or captured logs.

---

## 8. Tests

- Add or update a suite under `tests/` for any behaviour change. Match the existing plain-`.ps1` style:
  print `PASS:` / `FAIL:` and exit `0`/`1`.
- **A test must be able to fail.** A test that can never fail is worse than none, because it is counted
  as protection. Where practical, prove it by making the hazard and confirming the assertion trips.
- Prefer **assertion lines** over mentioning a symbol. "The name appears in `tests/`" is not coverage.
- For timing-sensitive code, exercise the race deliberately (forced timeout, completion near the
  deadline) — see `docs/DEVELOPMENT.md` §13.

---

## 9. Documentation

Update documentation in the **same pull request** as the behaviour change:

- `README.md` tracks the **released** version; update it, and add release notes under `docs/`, when a
  release changes documented behaviour.
- If you change a transition, exit code, gate or invariant, update the matching document
  (`docs/STATE-MACHINE.md`, `docs/EXIT_CODES.md`, `.github/copilot-instructions.md`) and the gate.
- If you add or remove a module, update the module-inventory table (see §3).

---

## 10. Commit and pull-request conventions

- Use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `refactor:`,
  `chore:`, `docs:`, `test:`, `ci:`. Example:
  `fix(install): classify failed updates as an error outcome`.
- Keep commits focused; do not mix an unrelated refactor into a fix.
- Keep the pull request description honest about scope, and about anything you did **not** verify
  (e.g. "the remote path was not exercised; `Test-RemoteTask` skipped locally").
- All required CI checks — the release gate and the suite runner — must pass before merge.

---

## 11. Reporting bugs and requesting features

- Use the [issue templates](.github/ISSUE_TEMPLATE) for bug reports and feature requests.
- Include your Windows and PowerShell versions, whether the run was elevated, the exact command, and the
  relevant, **redacted** log output.
- **Never paste credentials, tokens, or unredacted audit logs** into an issue.

---

## 12. Security

Do not report security vulnerabilities through public issues, pull requests or discussions. Follow
[SECURITY.md](SECURITY.md) and use GitHub's private vulnerability reporting.

---

## 13. Licensing of contributions

By contributing, you agree that your contribution is licensed under the **MIT License** used by this
project, and that you have the right to submit it. Because WUU2-CLI is a derivative work, upstream
attribution is maintained in [NOTICE](NOTICE) and [docs/PROVENANCE.md](docs/PROVENANCE.md); do not
remove or alter upstream copyright notices.

---

## Code of Conduct

All participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md). By taking part, you agree
to uphold it.
