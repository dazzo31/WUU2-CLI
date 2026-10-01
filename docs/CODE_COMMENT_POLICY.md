# Code comment policy (P2-3 outcome)
#
# WHY THIS FILE EXISTS
# --------------------
# The review item for P2 was "move historical commentary to docs". Measured against `src/`, that item
# as written would DEGRADE this codebase, and this file records the measurement and the narrow exception
# so the same item is not re-raised and "fixed" destructively later.
#
# WHAT WAS MEASURED (2026-09-30, after the P3 work)
#
#   module                    lines   code   comment   comment %
#   Wuu.WindowsUpdate.psm1     1072    628       362      33.8%
#   Wuu.Core.psm1              4213   2731      1044      24.8%
#   Wuu.Scheduler.psm1          211    141        44      20.9%
#   Wuu.Command.psm1            918    712       150      16.3%
#   Wuu.State.psm1             1969   1493       252      12.8%
#   (all 14 modules: 4113 comment lines; 109 runs of 12+ consecutive comment lines, 2358 lines in them)
#
# The premise behind the item was that those lines are narrative. They are not, mostly. Classifying the
# 109 runs by reading them:
#
#   MODULE HEADERS (13 runs, 520 lines) - the row contract, the phase contract, the exit-code table,
#   "worker runspaces must not call these functions", "no pipeline cmdlets on a callback path". Every one
#   of those is a constraint that has ALREADY cost real debugging time, and one of them - "a module
#   function is not callable from a payload runspace" - was re-learned the hard way DURING the P3 work
#   even though it was documented here. Removing or relocating these makes the next occurrence certain.
#
#   COMMENT-BASED HELP (the majority of the long run-based help blocks) - `.SYNOPSIS`/`.DESCRIPTION`/
#   `.PARAMETER` blocks. `Get-Help` reads these out of the module. Moving them into docs/ breaks the one
#   discovery mechanism an operator is most likely to use, and the P3 suite asserts on several of them.
#
#   RATIONALE AT THE SITE - the *why* for a non-obvious choice, adjacent to the choice. This is the most
#   valuable category and the least relocatable: the reason "the floor exists because a 1-second CIM call
#   reports a timeout for a merely slow host" is worth nothing in a separate document, because the person
#   editing that line will not read it.
#
#   HISTORY (the narrow exception) - "the old code did X line by line", stale feature changelogs, and
#   author/date stamps. This is the only category that belongs in docs/.
#
# THE POLICY
#
#   1. Contracts, constraints, and the reason behind a non-obvious choice stay INLINE, at the site.
#      They are not narrative and must not be relocated to reduce a percentage.
#   2. Comment-based help stays INLINE. `Get-Help` is part of the interface.
#   3. PURE HISTORY moves to docs/, and the site keeps at most a one-line pointer.
#   4. Only ONE instance of category 3 was found worth moving, and it was also factually WRONG:
#      Wuu.Core's module header described this as a GUI script, carried the 2016 author/date of the GUI
#      edition, and listed a 40-line feature changelog - in a file whose tree the release gate asserts
#      contains no GUI, no WPF and no ui references. A header that misdescribes the file is worse than a
#      long one: it is read as current fact. It now states what the file is and points here.
#
#   See docs/CHANGELOG-history.md for that preserved material.
#
# WHAT A REVIEWER SHOULD CHECK INSTEAD
#
#   Comment VOLUME is not a defect. A stale comment, or one that contradicts the code beside it, is. If
#   this item is revisited, the useful check is whether a comment's claim is still true - which is what
#   the release gate does for the assertions that matter (it strips comments precisely so a claim in prose
#   cannot satisfy a structural check).
