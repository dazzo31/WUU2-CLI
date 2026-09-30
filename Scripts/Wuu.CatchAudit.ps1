# Wuu.CatchAudit.ps1 - the silent-catch policy, shared by the release gate and its test suite.
#
# WHY THIS IS A SHARED FILE AND NOT TWO COPIES. The gate and the suite must agree on exactly which
# silences are permitted; if each carried its own rule they would drift and the gate would pass while
# the suite failed, or the reverse. Dot-sourcing one file makes disagreement impossible.
#
# WHAT A SILENT CATCH IS, AND WHY IT NEEDS A POLICY. A catch whose body performs no statement converts
# a fault into apparent success - the caller cannot tell "nothing to do" from "the work failed". That
# is the shape that hides real failures, and the reviewer's suggestion is that a release gate should
# reject it outside a small allowlist. The allowlist exists because some silences are CORRECT: a
# disposal failure must not mask the original error, and a logging failure cannot be logged.
#
# THE PRECEDING COMMENT COUNTS. A catch whose body is a comment stating why nothing can be done HAS
# made a decision, and written it down. It is permitted - the defect is an IMPLICIT silence, not a
# short one.

function Get-WuuSilentCatchAllowlist {
    <#
    .SYNOPSIS The permitted reasons for a silent catch, each with its justification.
    .DESCRIPTION
    Deliberately SMALL and keyed on the SHAPE of the guarded statement, not on a list of file/line
    exemptions. A line-number allowlist would silently approve an unrelated catch that later moved
    onto the same line; a shape match keeps approving the same KIND of silence and nothing else.

    Each entry is @{ Name; Pattern; Why }. The Why is required: an allowlist entry without a stated
    justification is indistinguishable from "we stopped looking", which is the thing this policy
    exists to prevent. tests\Test-SilentCatchPolicy.ps1 asserts every entry has one.
    #>
    return @(
        @{
            Name    = 'best-effort logging'
            Pattern = 'Write-[A-Za-z]*Log|WriteDebugLogScript|WriteLogFileScript|Write-WarningLog|Write-Warning\b|Write-ErrorLog|Write-InfoLog'
            Why     = 'the call IS the reporting; a failure to report cannot itself be reported without recursion, and the operation continues regardless'
        }
        @{
            Name    = 'audit / denial recording'
            Pattern = 'DenialHook|Write-WuuAuditRecord'
            Why     = 'the operation is already blocked or already recorded; failing to ADD a record must not replace a clean refusal with an exception'
        }
        @{
            Name    = 'resource release'
            Pattern = '\.Dispose\(|\.Close\(|\.Stop\(|\.EndStop\(|\.EndInvoke\(|\.Kill\('
            Why     = 'a release failure must never replace the original error that caused the release, and the object is being discarded either way'
        }
        @{
            Name    = 'lock release'
            Pattern = '\[System\.Threading\.Monitor\]::(Exit|TryEnter)'
            Why     = 'a lock release runs from a finally; a throw there would replace the real exception with a lock-release error'
        }
        @{
            Name    = 'redraw signal'
            Pattern = '\.Touch\(\)'
            Why     = 'presentation only; a failed redraw cannot affect the operation, and the next write signals again'
        }
        @{
            Name    = 'best-effort read / probe'
            Pattern = '^\s*\$[A-Za-z_][\w:]*\s*=\s*[^=]'
            Why     = 'assigns a probe result to a variable; the ABSENCE of a value is handled by the caller, so a failed probe is a normal branch'
        }
    )
}

function Test-WuuSilentCatchAllowed {
    <#
    .SYNOPSIS Whether a silent catch is permitted because of what it guards (or what it says).
    .DESCRIPTION
    Returns @{ Allowed; Reason }. Two ways to be allowed, in this order:
      1. DOCUMENTED - the catch body is a comment. The body is inspected, not the guarded statement,
         because the justification is what matters and it lives in the body.
      2. ALLOWLISTED - the guarded statement is one of the shapes in Get-WuuSilentCatchAllowlist.

    Order matters for the message: a commented catch is reported as documented even if its guarded
    statement would also match an allowlist entry, because the comment is the stronger evidence.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()][string]$Guarded = '',
        [Parameter(Mandatory = $false)][AllowNull()][string]$Body = ''
    )

    if ($Body -and $Body.Trim() -ne '') {
        # The body has content. If it is only comments, that is a documented decision.
        $bodyText = $Body.Trim()
        if ($bodyText.StartsWith('#') -or $bodyText.StartsWith('<#')) {
            return @{ Allowed = $true; Reason = 'documented: the catch states why it is silent' }
        }
    }

    foreach ($entry in (Get-WuuSilentCatchAllowlist)) {
        if ($Guarded -match $entry.Pattern) {
            return @{ Allowed = $true; Reason = "allowlisted: $($entry.Name)" }
        }
    }

    return @{ Allowed = $false; Reason = "no allowlist entry matches the guarded statement, and the catch says nothing: $($Guarded.Trim())" }
}

function Get-WuuSilentCatch {
    <#
    .SYNOPSIS Finds every catch whose body performs no statement, and what it guards.
    .DESCRIPTION
    Takes TEXT, not a path, so a test can DRIVE it with synthetic input. That matters: a checker that
    only ever runs against the real tree cannot be shown to detect anything, so its passing result is
    evidence of nothing. tests\Test-SilentCatchPolicy.ps1 feeds it a hand-written unjustified silence
    and requires a finding, and a hand-written documented silence and requires none.

    THE BRACE ARITHMETIC IS THE WHOLE RISK HERE, and an earlier attempt got it wrong: the catch line
    `    } catch {` contains BOTH a closing brace (ending the try) and an opening brace (starting the
    catch), so counting braces from the start of that line computes depth 0 and never collects the
    body - which reported 194 "silent" catches that all had real bodies. The catch's own brace is
    therefore found explicitly (the LAST '{' on the line) and the scan starts after it.

    A catch counts as SILENT when its body contains no statement. Comments are not statements, but a
    comment-only body is reported with Kind='comment-only' so the policy can accept it as documented.
    An inline `catch { }` is reported as Kind='inline-empty'.

    Returns @( @{ Line; Kind; Guarded; Body } ). Side-effect free.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()][string]$Text = ''
    )

    $results = @()
    if (-not $Text) { return $results }
    $lines = $Text -split "`r?`n"

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $m = [regex]::Match($line, 'catch\s*(\([^)]*\))?\s*\{')
        if (-not $m.Success) { continue }
        # Everything after the catch's OWN brace. This is EMPTY for the ordinary multi-line form
        # (`} catch {` with the body below), so it must NOT be treated as "nothing to do" - an earlier
        # version of this function `continue`d on empty and therefore only ever inspected one-line
        # catches, which is the opposite of what the check is for.
        $afterBrace = $line.Substring($m.Index + $m.Length)

        # --- collect the body, starting at depth 1 from the catch's OWN brace ---
        $depth = 1
        $kind = ''
        $bodyLines = @()
        if ($afterBrace.Trim() -eq '}') {
            $kind = 'inline-empty'          # `catch { }`
            $depth = 0
        } else {
            if ($afterBrace.Trim() -ne '') {
                # Inline body fragment on the catch line itself: `catch { Write-Log ... }`.
                $bodyLines += $afterBrace
                $depth += ([regex]::Matches($afterBrace, '\{')).Count - ([regex]::Matches($afterBrace, '\}')).Count
            }
            $k = $i + 1
            while ($k -lt $lines.Count -and $depth -gt 0) {
                $bodyLines += $lines[$k]
                $depth += ([regex]::Matches($lines[$k], '\{')).Count - ([regex]::Matches($lines[$k], '\}')).Count
                $k++
            }
        }

        if ($kind -ne 'inline-empty') {
            # Decide whether the body is a silent one: no statement anywhere in it.
            $code = @()
            $comments = @()
            foreach ($b in $bodyLines) {
                $t = $b.Trim()
                if ($t -eq '' -or $t -eq '}') { continue }
                if ($t.StartsWith('#') -or $t.StartsWith('<#')) { $comments += $t; continue }
                $code += $t
            }
            if ($code.Count -gt 0) { continue }              # a real body: not silent
            $kind = if ($comments.Count -gt 0) { 'comment-only' } else { 'empty' }
        }

        # --- what does this catch guard? ---
        # The text BETWEEN the try's brace and the catch's brace, which is what the allowlist matches on.
        # Two shapes, and an earlier version handled only the second:
        #   inline   `try { Write-Log "x" } catch { }`   -> the try is on the SAME line
        #   block    `try {` / body / `} catch {`        -> the try is on an EARLIER line
        # Walking back for `try {` unconditionally found an UNRELATED earlier try for the inline shape
        # (or nothing at all), so every inline catch was judged against the wrong statement and the whole
        # policy reported 33 false findings. Same class as the brace-arithmetic bug: the construct's own
        # syntax has to be respected.
        $guarded = ''
        $sameLineTry = [regex]::Match($line.Substring(0, $m.Index), 'try\s*\{')
        if ($sameLineTry.Success) {
            $from = $sameLineTry.Index + $sameLineTry.Length
            $guarded = $line.Substring($from, $m.Index - $from)
        } else {
            # Block form: find the nearest preceding `try {` and take everything after its brace, across
            # the intervening lines, up to the catch.
            $tryLine = -1
            for ($j = $i - 1; $j -ge 0; $j--) {
                if ($lines[$j] -match 'try\s*\{') { $tryLine = $j; break }
                if ($lines[$j] -match '^\s*function\s') { break }
                if ($lines[$j] -match '\}\s*catch') { break }   # another catch: stop, do not borrow its try
            }
            if ($tryLine -ge 0) {
                $tm = [regex]::Match($lines[$tryLine], 'try\s*\{')
                $frag = @()
                $first = $lines[$tryLine].Substring($tm.Index + $tm.Length)
                if ($first.Trim() -ne '') { $frag += $first }
                # BOUNDED WALK. The span is capped because a mis-parse (an unbalanced brace earlier in
                # the file) can otherwise make this capture thousands of lines PER CATCH, which turns the
                # whole scan into an apparent hang - observed when the brace depth was deliberately
                # broken: the suite stopped returning. A cap keeps a mis-parse cheap and visible.
                $spanStart = $tryLine + 1
                $spanEnd = [Math]::Min($i, $spanStart + 40)
                for ($j = $spanStart; $j -le $spanEnd; $j++) {
                    $piece = if ($j -eq $i) { $lines[$j].Substring(0, $m.Index) } else { $lines[$j] }
                    if ($piece.Trim() -ne '') { $frag += $piece }
                }
                $guarded = ($frag -join ' ')
            }
        }
        # Drop the try's closing brace, which sits immediately before `catch`.
        $guarded = $guarded.TrimEnd()
        while ($guarded.EndsWith('}')) { $guarded = $guarded.Substring(0, $guarded.Length - 1).TrimEnd() }
        $guarded = ($guarded -split "`r?`n" | ForEach-Object { $_.Trim() }) -join ' '
        $guarded = $guarded.Trim()

        $bodyText = if ($kind -eq 'comment-only') { (($comments | Where-Object { $_ -ne '' }) -join ' ') } else { '' }
        $results += @{ Line = $i + 1; Kind = $kind; Guarded = $guarded; Body = $bodyText }
    }

    return $results
}
