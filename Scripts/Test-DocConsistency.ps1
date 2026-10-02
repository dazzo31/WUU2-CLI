# DOC CONSISTENCY (instructions SS40/SS45). The release gate validates the TREE; until this block
# existed, nothing validated the DOCUMENT'S claims about the tree. That tax was paid twice: the SS9
# direct-write breakdown said "34 in Wuu.Core / 7 in Wuu.WindowsUpdate" when the measured split was
# 23/10/8, and three SS45 priority statuses said NOT IMPLEMENTED for work that was finished.
#
# The rules below are deliberately MEASURED, not textual. This block never parses the document's prose
# to decide what it means - it counts reality and checks that the document agrees. That is what makes
# it non-brittle: rewording a paragraph cannot break it, but letting a module go undocumented can.
#
# WHY NOT MORE RULES. The obvious extra ones are noisy by construction and were rejected with
# evidence: matching `Test-*` backticked names finds FUNCTIONS as well as suites (7 of 24 were
# functions), and matching `X.psm1` literals fails because the prose writes module names without the
# extension. A rule that cries wolf is worse than no rule, so only these three are enforced.

$docPathDC = Join-Path $root '.github\copilot-instructions.md'
if (-not (Test-Path $docPathDC)) {
    Fail 'the LLM development instructions file is missing - the document the whole workflow depends on is not in the tree (SS40)'
} else {
    $docTextDC = [System.IO.File]::ReadAllText($docPathDC)
    # The inventory table is delimited by markers, so the parse does not depend on table formatting.
    $invStartDC = $docTextDC.IndexOf('<!-- module-inventory:start -->')
    $invEndDC = $docTextDC.IndexOf('<!-- module-inventory:end -->')
    if ($invStartDC -lt 0 -or $invEndDC -le $invStartDC) {
        Fail 'the module inventory is missing its markers - the documented module set cannot be read, so nothing can be checked against it (SS40)'
    } else {
        $invTextDC = $docTextDC.Substring($invStartDC, $invEndDC - $invStartDC)
        # | `Wuu.X` | owns |
        $docModsDC = @([regex]::Matches($invTextDC, '\|\s*`(Wuu\.[\w\.]+)`\s*\|') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $shipModsDC = @(Get-ChildItem -Path (Join-Path $root 'src') -Filter '*.psm1' -File |
            ForEach-Object { $_.BaseName } | Sort-Object)

        $undocumentedDC = @($shipModsDC | Where-Object { $docModsDC -notcontains $_ })
        $phantomDC = @($docModsDC | Where-Object { $shipModsDC -notcontains $_ })

        if ($docModsDC.Count -eq 0) {
            Fail 'the module inventory lists no modules at all - an empty inventory would vacuously agree with any tree (SS40)'
        } elseif ($undocumentedDC.Count -gt 0) {
            Fail ("module(s) shipped but NOT in the documented inventory: {0} - add the row to SS7 before adding the module (SS40)" -f ($undocumentedDC -join ', '))
        } elseif ($phantomDC.Count -gt 0) {
            Fail ("the documented inventory names module(s) that do not exist: {0} - a reader would go looking for them (SS40)" -f ($phantomDC -join ', '))
        } else {
            Pass "every shipped module is in the documented inventory and every documented module exists ($($docModsDC.Count) modules) (SS40)"
        }

        # SS45 prioritises work. A status word that contradicts the tree is the drift this block exists
        # for, so the MEASURABLE ones are checked. `NOT IMPLEMENTED` next to a module that is demonstrably
        # present and wired is the exact shape of all three drifts that were corrected by hand.
        $prioStartDC = $docTextDC.IndexOf('# 45. Current architectural priorities')
        if ($prioStartDC -lt 0) {
            Fail 'the SS45 priorities section is missing - the workflow has no stated priorities (SS45)'
        } else {
            $prioTextDC = $docTextDC.Substring($prioStartDC)
            # P1#1 is satisfied by Wuu.Result.psm1 existing AND Core consuming it; P1#2 by a schema
            # version being emitted. Each claim is checked against the artifact that satisfies it.
            $p1ModelDC = [regex]::Match($prioTextDC, '(?s)1\.\s*Formalise command result model\.\s*[-\u2014]+\s*\*\*([^*]+)\*\*')
            $resultWiredDC = (Test-Path (Join-Path $root 'src\Wuu.Result.psm1')) -and
                ([System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Core.psm1')) -match 'New-WuuCommandResult')
            if ($p1ModelDC.Success -and $p1ModelDC.Groups[1].Value -match 'NOT IMPLEMENTED' -and $resultWiredDC) {
                Fail 'SS45 says the command result model is NOT IMPLEMENTED, but Wuu.Result.psm1 exists and Core builds a result through it - the priorities understate finished work (SS45)'
            } elseif ($resultWiredDC -and $p1ModelDC.Success -and $p1ModelDC.Groups[1].Value -notmatch 'NOT IMPLEMENTED') {
                Pass 'SS45 agrees with the tree on the command result model (SS45)'
            } elseif (-not $resultWiredDC) {
                Fail 'the command result model is claimed but Wuu.Result.psm1 or its use in Core is missing - the priorities overstate finished work (SS45)'
            } else {
                Warn 'the SS45 entry for the command result model could not be read; the status-check pattern needs updating (SS45)'
            }

            # The document is the interface for a workflow that spans sessions, so a claim of a specific
            # line count is a claim that rots the moment code moves. Measured: only two such claims exist,
            # and both are historical (a before -> after), which is legitimate and is why this only
            # rejects a line count stated as a CURRENT size.
            if ($prioTextDC -match '(?m)^\s*\d+\.\s.*\bis\s+\d{3,}\s+lines\b') {
                Fail 'SS45 states a module''s CURRENT line count - that number rots on the next edit; state the direction of travel instead (SS40/SS45)'
            } else {
                Pass 'SS45 states no current line counts that would rot (SS40)'
            }
        }
    }
}
