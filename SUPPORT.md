# Support

Thanks for using WUU2-CLI. Here is where to go for each kind of help.

## I found a bug

Open an issue using the **Bug report** template:
<https://github.com/dazzo31/WUU2-CLI/issues/new/choose>

Please include your Windows and PowerShell versions, whether the run was elevated, the exact command
(pass `-Reason`), and relevant log output with credentials and host names redacted.

## I want a feature

Open an issue using the **Feature request** template, and describe the problem to solve rather than
only the solution.

## I found a security vulnerability

**Do not open a public issue.** Follow [SECURITY.md](SECURITY.md) and use
[private vulnerability reporting](https://github.com/dazzo31/WUU2-CLI/security/advisories/new).

## I want to contribute code

Read [CONTRIBUTING.md](CONTRIBUTING.md). It covers the PowerShell 5.1 constraint, the release gate and
test runner, the coding standards, and the pull-request checklist.

## Before asking — quick self-checks

- **Run it elevated and with `-STA`.** Most "it did nothing" reports are a non-elevated or non-STA host.
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WUU.ps1`
- **Read the exit code.** `0` means *completed*, `3` means *timed out with work outstanding*, `6` means
  *queued with `-Async`*, `7` means *refused* (often a missing `-Reason`). See
  [`docs/EXIT_CODES.md`](docs/EXIT_CODES.md) — a blanket "non-zero means retry" is wrong here.
- **Try a dry run.** `wuu install -Computer <name> -WhatIf` prints a per-computer plan and changes
  nothing.
- **Check the audit chain.** `wuu audit verify`.

## Documentation

| Topic | Document |
| --- | --- |
| Overview, commands, exit codes | [README.md](README.md) |
| Architecture and modules | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Workflow and terminal states | [docs/STATE-MACHINE.md](docs/STATE-MACHINE.md) |
| Exit-code contract | [docs/EXIT_CODES.md](docs/EXIT_CODES.md) |
| Audit trail and retention | [docs/AUDIT_RETENTION.md](docs/AUDIT_RETENTION.md) |
| Development and testing | [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md), [docs/TESTING.md](docs/TESTING.md) |
| Known limitations | [docs/PHASE4_PROGRESS.md](docs/PHASE4_PROGRESS.md), [docs/ISO_27001_A815_MAPPING.md](docs/ISO_27001_A815_MAPPING.md) |

## Code of Conduct

Participation in this project is covered by the [Code of Conduct](CODE_OF_CONDUCT.md).
