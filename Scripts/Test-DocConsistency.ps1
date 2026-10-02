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

        # GATE CITATIONS. Appendix A names a gate block per invariant, and a block is FOUND BY ITS
        # LETTER - so a citation to a letter that no block declares is a pointer to nothing, and the
        # reader cannot locate the evidence. This is not hypothetical: invariant 8.1 cited "(u)" while
        # the letters ran s t v w x y z and no (u) existed, so the check that enforces one-operation-
        # per-computer was unfindable from the table that claims it.
        #
        # Measured against the corpus, not against the gate alone: a letter belongs to whichever
        # Scripts file declares it, and fragments are where most of them now live.
        $citedDC = @([regex]::Matches($docTextDC, '\(([a-z]{1,2})\)') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $declaredDC = @()
        foreach ($fDC in @(Get-ChildItem -Path (Join-Path $root 'Scripts') -Filter '*.ps1' -File)) {
            $textDC = [System.IO.File]::ReadAllText($fDC.FullName)
            $declaredDC += @([regex]::Matches($textDC, '(?m)^# \(([a-z]{1,2})\)') |
                ForEach-Object { $_.Groups[1].Value })
        }
        $declaredDC = @($declaredDC | Sort-Object -Unique)
        $danglingDC = @($citedDC | Where-Object { $declaredDC -notcontains $_ })
        if ($citedDC.Count -eq 0) {
            Fail 'the document cites no gate blocks at all - either the citations were lost or this check has gone blind (SS40)'
        } elseif ($declaredDC.Count -lt 20) {
            Fail "only $($declaredDC.Count) gate block header(s) were found in Scripts - the corpus is not being read, so this check would pass vacuously (SS40)"
        } elseif ($danglingDC.Count -gt 0) {
            Fail ("the document cites gate block(s) that do not exist: {0} - a citation is how a reader finds the evidence, so a dangling one points at nothing (SS40)" -f (($danglingDC | ForEach-Object { "($_)" }) -join ', '))
        } else {
            Pass "every gate block cited by the document exists ($($citedDC.Count) cited, $($declaredDC.Count) declared) (SS40)"
        }

        # SS34: EVERY command document goes through ONE renderer, so it carries the same schema version
        # and cannot drift into a second shape. Before this, the read verbs hand-built their own JSON with
        # no version field at all. The check is deliberately narrow about WHERE it applies: Wuu.Command's
        # COMMAND OUTPUT must not call ConvertTo-Json directly. Wuu.Audit's canonical record rendering is a
        # different concern (a hash-chained line, never parsed as a command document) and Wuu.Credentials
        # writes an encrypted blob, so both are out of scope by module rather than by exception list.
        # A new direct ConvertTo-Json inside Wuu.Command is what this catches.
        $cmdTextDC = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Command.psm1'))
        $cmdCodeDC = Get-WuuTextWithoutComments -Text $cmdTextDC
        $rawJsonDC = @([regex]::Matches($cmdCodeDC, 'ConvertTo-Json'))
        if ($rawJsonDC.Count -gt 0) {
            Fail "Wuu.Command calls ConvertTo-Json directly ($($rawJsonDC.Count) time(s)) - every command document must go through Format-WuuJsonDocument so it carries the shared schema version (SS34)"
        } elseif ($cmdCodeDC -notmatch 'Format-WuuJsonDocument') {
            Fail 'Wuu.Command never calls Format-WuuJsonDocument - the versioned envelope is not being applied, or this check has gone blind (SS34)'
        } else {
            Pass 'every command document in Wuu.Command is rendered through the versioned envelope (SS34)'
        }

        # The renderer must exist, be exported, and be the ONE definition of the envelope.
        if (-not (Get-Command Format-WuuJsonDocument -ErrorAction SilentlyContinue)) {
            Fail 'Format-WuuJsonDocument is not resolvable - the shared JSON envelope has no implementation (SS34)'
        } else {
            try {
                $probeDC = Format-WuuJsonDocument -Command 'gate' -Fields ([ordered]@{ A = 1 }) | ConvertFrom-Json
                if ($null -eq $probeDC.PSObject.Properties['SchemaVersion']) {
                    Fail 'Format-WuuJsonDocument does not stamp SchemaVersion - the versioned API is not versioned (SS34)'
                } elseif ($probeDC.Command -ne 'gate') {
                    Fail 'Format-WuuJsonDocument does not carry the command name - a document must be self-describing (SS34)'
                } else {
                    Pass 'the JSON envelope is versioned, self-describing, and used by every command document (SS34)'
                }
            } catch {
                Fail "driving the JSON envelope threw instead of reporting: $($_.Exception.Message) (SS34)"
            }
        }
    }
}
