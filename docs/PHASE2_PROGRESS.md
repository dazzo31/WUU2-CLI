# Phase 2 — Command Surface: Progress Log

**Started:** 2026-09-28
**Goal:** Scriptable verbs so WUU runs unattended, with no duplication of the operations the
interactive menu already implements.
**Full plan:** [CLI_AUDIT_PLAN.md](CLI_AUDIT_PLAN.md) §6 Phase 3 (verb table in §4)

---

## Status: DONE (core)

| Deliverable | State |
|---|---|
| `src/Wuu.Command.psm1` (verb table, arg parser, dispatcher, help) | **DONE** |
| Non-interactive input provider in `Wuu.Console.psm1` | **DONE** |
| Command mode in `Start-WuuApplication` + `WUU.ps1` arg forwarding | **DONE** |
| `-WhatIf` on every mutating verb | **DONE** |
| `-Json` machine-readable output | **DONE** |
| Exit codes (0/1) for CI | **DONE** |
| `tests/Test-CommandSurface.ps1` | **DONE — 12/12 PASS** |
| Validator coverage for verbs + BOM gate | **DONE — 9/9 PASS** |
| Deeper `-Json` coverage for every read verb | NOT STARTED (currently a roster snapshot) |
| Phase 4 audit (hash-chained JSONL, reason per mutating action) | NOT STARTED |

## Usage

```
WUU.ps1                                  interactive menu (default, unchanged)
WUU.ps1 -Help                            verb list
WUU.ps1 check -All
WUU.ps1 check -Computer SRV01,SRV02
WUU.ps1 show available -Computer SRV01 -Json
WUU.ps1 install -Computer SRV01 -WhatIf
WUU.ps1 service restart -Computer SRV01
WUU.ps1 add -Computer A,B                WUU.ps1 add-file -Path list.csv
WUU.ps1 phase -Set 2 -All                WUU.ps1 export -Path out.csv
WUU.ps1 config save | config load | credentials set
```

### Verbs
`check` `download` `install` `restart` `add` `add-file` `remove` `clear` `prune` `phase`
`show available|installed|history|errors|phases` `audit wsus` `logs`
`service start|stop|restart` `export` `config save|load` `credentials set`

Mutating verbs (guarded by `-WhatIf`): `download` `install` `restart` `service`.

## The design decision that made this small

**Dispatch, not duplicate.** The command layer reimplements no operation. Each verb resolves its
arguments into (a) an action name and (b) the *ordered answers the interactive helper would have
prompted for*, then calls the same `$consoleActions` handler the menu calls.

That works because `Wuu.Console.psm1` now has **one input choke point**:

```
Initialize-WuuInputMode -NonInteractive -Answers @(...)
        |
        v
Read-WuuAnswer    <--  Read-WuuSelection, Read-WuuYesNo, and handler prompts all route here
   interactive: Read-Host
   non-interactive: dequeue answer, else default, else THROW
```

The **throw** is the important part: a scripted run must never block on a prompt. It is also why
no handler needed changing to become scriptable — none of them knows it is being scripted.

`-WhatIf` short-circuits mutating verbs *before* any handler runs, so no payload is queued and no
remote state is touched.

Command mode also loads the saved computer list first when one exists (otherwise `-All` would run
against an empty store and silently do nothing), then drains the job scheduler for a bounded
period so the operation actually makes progress before reporting.

## Bugs found while building this

Each was caught by a check, none by inspection:

1. **The validator found a verb pointing at a handler that did not exist.**
   `logs -> EventViewUpdateLog` had no `$consoleActions` adapter — and the *menu* had the same
   gap (no key bound to it), so the operation was unreachable in both surfaces and nothing had
   noticed. Fixed by adding the adapter plus a `g` menu key. This is the validator earning its
   keep: it cross-checks two independent declarations (verb table and action layer).
2. **`Unknown = @()` in a hashtable literal is a fixed-size array.** The first unrecognised
   option threw *"Collection was of a fixed size"* — i.e. the unknown-option reporter crashed
   precisely on the input it exists to report. Now an `ArrayList`.
3. **`service restart` did not parse** — `'service'` was missing from the subverb-verb list, so
   `restart` was swallowed as a computer name.
4. **Two test-expectation errors**, not product bugs: a closure that rebound `$script:called`
   (fixed by capturing the list *by reference*), and a mutating-verb count asserted as `> 4`
   when the correct set is *exactly* four (fixed by asserting the SET, so a verb silently gaining
   or losing its `Mutating` flag now fails).
5. **The UTF-8 BOM bug recurred twice more** (`Wuu.Command.psm1`, `Package-WUU2.ps1`). Rather
   than rely on memory a fourth time, the validator now **gates** it: every file containing
   non-ASCII bytes must carry a BOM. It caught `Package-WUU2.ps1` immediately after being
   written. This is now the 8th release check.

## Verification

`Scripts\Validate-Release.ps1` — **9/9 PASS**:

```
PASS: all 19 shipped PowerShell files parse under the PS 5.1 engine
PASS: no WPF/XAML/ui references in shipped code
PASS: all src/ modules import via Import-WuuModules
PASS: importing the engine loads no WPF assembly
PASS: all 24 menu handlers are defined in the action layer
PASS: all 15 command verb handlers are defined in the action layer
PASS: sub-dispatched verb handlers resolved
PASS: all 17 verbs have Help text
PASS: every file with non-ASCII bytes carries the UTF-8 BOM
```

`tests\Test-CommandSurface.ps1` — **12/12 PASS**: 8 real argv shapes parsed, unknown options
reported, `-WhatIf` invokes no handler, missing input fails loudly instead of prompting, answers
consumed in order, input mode restored after success **and** after a throwing handler, unknown
verb and missing subverb handled, mutating-verb set exact.

All 7 suites green under PS 5.1, and `Test-HeadlessEngine` still proves the engine loads with no
WPF assembly.

## Next

Phase 4 (audit) is the substantive remaining work and is what "fully auditable" referred to:
append-only JSONL, hash-chained records, session transcript, operator identity, and a **required
reason** for every mutating action — with the non-repudiation boundary stated honestly (a hash
chain makes edits *detectable*, not impossible; it needs an append-only anchor).
See [CLI_AUDIT_PLAN.md](CLI_AUDIT_PLAN.md) §5, and decide §9's open questions first.
