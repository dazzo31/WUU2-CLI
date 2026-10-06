# Security Policy

WUU2-CLI remotely checks, downloads, installs and reboots Windows Updates across a fleet, runs with
Administrator rights, and writes a hash-chained audit trail intended for ISO/IEC 27001:2022 A.8.15
review. Security reports are taken seriously.

## Supported Versions

Security fixes are provided for the **current release line** only. This project is pre-1.0 in the
release-candidate sense: `v1.5.0-rc.1-cli` is the current line.

| Version | Supported |
| --- | --- |
| `1.5.x` (`v1.5.0-rc.*-cli` and later `1.5.x`) | :white_check_mark: |
| Earlier `1.4.x` and below | :x: |
| Unreleased forks or local modifications | :x: |

If you are running an older version, reproduce the issue on the latest release before reporting where
you can.

## Reporting a Vulnerability

**Do not open a public issue, pull request or discussion for a security problem.**

Report privately using GitHub's **private vulnerability reporting**:

1. Go to the repository's **Security** tab → **Advisories** → **Report a vulnerability**
   (direct link: <https://github.com/dazzo31/WUU2-CLI/security/advisories/new>).
2. Describe the issue with enough detail to reproduce it.

Please include, where applicable:

- the affected version (`src/Wuu.Configuration.psm1` records `$global:WuuVersion`), and the exact
  command or menu path;
- the Windows and PowerShell versions, and whether the run was elevated;
- what an attacker gains, and the prerequisites (local admin? network position? a crafted input?);
- a minimal reproduction, and any logs **with credentials, host names and audit content redacted**.

**Never include live credentials, private keys, tokens, or unredacted audit logs** in a report.

### What to expect

- **Acknowledgement** of your report as soon as reasonably possible, normally within a few days.
- An initial **assessment** (accepted, needs more information, or out of scope) after triage.
- **Updates** when the status changes, and again when a fix is released.
- **Credit** in the release notes for a valid report, if you would like it. This project offers no bug
  bounty — it is a volunteer, MIT-licensed project.

Please allow a reasonable window for a fix to be prepared and released before any public disclosure.
Coordinated disclosure is appreciated.

## Scope

**In scope** — defects in WUU2-CLI's own code, for example:

- remote code execution, privilege escalation, or command/path injection through tool inputs
  (computer names, list files, CSV imports, `-Reason`, `-Path`, credentials, WSUS audit input);
- bypass of the audit trail's fail-closed behaviour, or a way to alter the audit chain so that
  `audit verify` still reports success;
- credential handling: disclosure of a `SecureString`/`[pscredential]`, DPAPI protection bypass, or a
  credential being sent to the wrong target;
- bypass of the admission gates (one-operation-per-computer, global concurrency cap), the timeout
  enforcement, or the state-machine / operation-identity guards in a way that causes operations to run
  on, or be attributed to, the wrong host.

**Out of scope** — and please do not report these as vulnerabilities:

- **The design requirement to run as Administrator.** This tool patches remote machines; elevation is
  intended, not a flaw.
- **Hash-chain limitations that are already documented.** A hash chain makes silent edits *detectable*,
  not *impossible*; anyone who can rewrite the log *and* the code can recompute a chain over their own
  edits. Real non-repudiation requires the chain head to be anchored externally, which is not
  implemented. This is stated in `docs/PHASE4_PROGRESS.md`, the code, and CLI output — it is a known
  limitation, not a vulnerability.
- **Local administrators reading or clearing the local log or the Windows Event Log.** Local admin can
  do both by design.
- Vulnerabilities in **Windows, the Windows Update Agent (WUA) COM API, or a target host's
  configuration** — report those to Microsoft.
- Issues that require the attacker to already have Administrator rights on the machine running
  WUU2-CLI, unless the issue grants *additional* privilege or escapes WUU2-CLI's own boundaries.

## Security-relevant areas of this project

If you are auditing, these are the areas that carry the most weight:

| Area | Where |
| --- | --- |
| Audit trail: canonical JSON, SHA-256 chaining, verify, external anchor, fail-closed writes | `src/Wuu.Audit.psm1`, `docs/AUDIT_RETENTION.md`, `docs/ISO_27001_A815_MAPPING.md` |
| Credential resolution and DPAPI protection | `src/Wuu.Credentials.psm1` |
| Remote execution and bounded invocation | `src/Wuu.Remote.psm1`, `src/Wuu.Network.psm1` |
| State mutation funnel, operation identity, terminal-state guard | `src/Wuu.State.psm1` |
| Admission, concurrency and deadlines | `src/Wuu.Scheduler.psm1`, `src/Wuu.WindowsUpdate.psm1` |
| Command parsing, exit codes, JSON output | `src/Wuu.Command.psm1`, `docs/EXIT_CODES.md` |

## Hardening guidance for operators

- Run WUU2-CLI only from a trusted, patched administrative host.
- The audit trail is written to `%PROGRAMDATA%\WUU2\audit` (LocalAppData fallback). Keep it off synced
  folders, restrict who can write it, and verify it with `wuu audit verify`.
- Review the documented **known limitations** before relying on the trail for compliance evidence:
  `docs/PHASE4_PROGRESS.md` and `docs/ISO_27001_A815_MAPPING.md`.
