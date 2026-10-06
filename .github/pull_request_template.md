<!--
Thanks for contributing. Keep the description honest about scope and about anything you did not verify.
See CONTRIBUTING.md and docs/DEVELOPMENT.md for the rules behind the checklist below.
-->

## Summary

<!-- What does this change, and why? Link the issue it resolves, e.g. "Closes #123". -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Refactor (no behaviour change)
- [ ] Documentation
- [ ] Tests / CI only
- [ ] Other:

## How this was tested

<!--
Paste the commands you ran and their result. Do not claim a SKIP as coverage.
  powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Validate-Release.ps1
  powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Invoke-TestSuites.ps1
-->

- Release gate (`Validate-Release.ps1`): <!-- exit code / verdict -->
- Suite runner (`Invoke-TestSuites.ps1`): <!-- pass / skip / fail -->
- Suites added or changed: <!-- list them -->
- Not verified (state it honestly): <!-- e.g. remote path not exercised; Test-RemoteTask skipped -->

## Checklist

- [ ] Targets **Windows PowerShell 5.1**; no PS7-only syntax, operators or cmdlets.
- [ ] Adds **no** external dependency (including Pester) and no GUI/WPF/XAML code.
- [ ] The change is scoped; no unrelated refactoring is mixed in.
- [ ] State mutation goes through the approved funnel; no new module-scope state writes.
- [ ] Invariants preserved: operation identity, state machine, concurrency, timeouts, audit integrity, `-WhatIf`, exit codes.
- [ ] A test that **can fail** was added or updated for the behaviour change.
- [ ] Console output remains line-oriented; no `Read-Host` added to automated paths.
- [ ] Non-ASCII source files are saved **UTF-8 with BOM**; interchange/audit artefacts remain BOM-less.
- [ ] Documentation updated in this PR (README for released behaviour; matching doc for a changed contract/gate).
- [ ] If a module was added or removed, the module-inventory table was updated.
- [ ] Diff reviewed against `docs/DEVELOPMENT.md` §20 (no `dist/` changes, encoding changes, scheduler bypass, credential fallback, dead code, secrets).

## Related

<!-- Issues, prior PRs, or follow-up work. -->
