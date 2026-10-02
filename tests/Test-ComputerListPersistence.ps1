#Requires -Version 5.1
<#
.SYNOPSIS Saved computer list: the plain-text round trip and the interoperability boundary (instruction SS14).
.DESCRIPTION
The saved computer list is a long-term interoperability boundary: an operator writes one by hand and
another build reads it. This suite tests the EXISTING contract. It does not introduce a format.

PROVEN HERE
  1. export -> file -> import returns the same SET of computers
  2. ordering is the store's append order on both sides (pinned, not assumed)
  3. duplicates collapse case-insensitively, first spelling wins
  4. blank lines and surrounding whitespace are skipped, never imported as empty names
  5. an empty file imports nothing and does not throw
  6. a 500-computer list round-trips intact and in order
  7. the file carries MEMBERSHIP ONLY - nothing but names, and no transient runtime state
  8. the format is version-independent (no version marker), so an old build and a new build agree
  9. both input doors apply ONE policy: the same text yields the same computers and the same verdict

WHY 7 AND 9 ARE THE POINT
-------------------------
The row holds 35 properties, including OperationId, OpState, PendingOp and Revision. Only the
export's SELECT keeps them out of the file, so this suite asserts the select rather than the
absence alone: a file that happens to contain no operation state today is not a guarantee.

Assertion 9 pins a real divergence found while writing this suite. The guided workflow imports a
.txt by splitting each line on whitespace, comma, semicolon or tab and validating each name. The
flat console menu imported a .txt as one name per line with no validation. So the SAME file read
differently through the two doors:

  "SRV01 SRV02"  -> guided path: two computers (SRV01, SRV02)
                 -> flat path:   ONE computer literally called "SRV01 SRV02"

The second is added successfully, appears in the list, and can never connect. The guided path also
reports what it rejected; the flat path discarded nothing and reported nothing.

Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-ComputerListPersistence.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$fail = 0
function Ok($m)  { Write-Host "PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail++ }

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force -DisableNameChecking
Import-WuuModules -WuuRoot $root
$global:EnableDebugLogging = $false

# --- expression extraction -----------------------------------------------------------------
# The export pipeline and the .txt reader are taken from the PARSED source, not re-typed here: a
# copy would keep passing after the product started serialising something else. The AST is used
# rather than a regex because a `(?m)^...$` pattern does not match a trailing `\r` in this
# worktree (autocrlf=true), which silently matched nothing when this suite was first written.
$coreAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'src\Wuu.Core.psm1'), [ref]$null, [ref]$null)

function Get-LeafCommand($pipelineElement) {
    # PipelineElements[-1] is a CommandAst for a plain command, and a CommandExpressionAst when the
    # expression IS the command. Only the first kind has GetCommandName().
    if ($null -eq $pipelineElement) { return '' }
    if ($pipelineElement -is [System.Management.Automation.Language.CommandAst]) { return $pipelineElement.GetCommandName() }
    if ($pipelineElement -is [System.Management.Automation.Language.CommandExpressionAst]) { return $pipelineElement.Expression.Extent.Text }
    return ''
}

function Get-ExportExpression {
    $pipes = $coreAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.PipelineAst] }, $true)
    foreach ($p in $pipes) {
        if ((Get-LeafCommand $p.PipelineElements[-1]) -ne 'Out-File') { continue }
        if ($p.Extent.Text -notmatch 'Get-WuuComputerRow') { continue }
        return $p.Extent.Text
    }
    return ''
}

$exportExpr = Get-ExportExpression
# The two text doors: the manual-entry prompt (reads $ans) and the file import (reads Get-Content).
$entryReaderExpr = ''
$fileReaderExpr  = ''
$assigns = $coreAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
foreach ($a in $assigns) {
    if ($a.Left.Extent.Text -ne '$names') { continue }
    if ($a.Right.Extent.Text -match 'Get-Content') { if (-not $fileReaderExpr) { $fileReaderExpr = $a.Right.Extent.Text } }
    if ($a.Right.Extent.Text -match '\$ans')       { if (-not $entryReaderExpr) { $entryReaderExpr = $a.Right.Extent.Text } }
}
$readerExpr = $fileReaderExpr

# A store in a throwaway directory: the suite must never touch the operator's real list.
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("wuu-list-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
$null = New-Item -ItemType Directory -Path $sandbox -Force

function New-TestStore {
    param([string[]]$Names)
    $s = New-WuuStateStore
    foreach ($n in $Names) { Add-WuuComputerRow -Store $s -Row (New-WuuComputerRow -Computer $n) | Out-Null }
    return $s
}
function Get-StoreNames {
    param($Store)
    return @(Get-WuuComputerRow -Store $Store | Select-Object -Expand Computer)
}
# Writes the list through the SHIPPED export expression, binding $stateStore and $filePath the way
# Core binds them. A local re-implementation would not be evidence about the product.
function Export-List {
    param($Store, [string]$Path)
    $stateStore = $Store
    $filePath = $Path
    Invoke-Expression $exportExpr | Out-Null
}
# Reads a list through the SHIPPED .txt reader.
function Import-List {
    param([string]$Path)
    $path = $Path
    return @(Invoke-Expression $readerExpr)
}
# Reads typed input through the SHIPPED manual-entry reader (the door a person types into).
function Add-Entry {
    param([string]$Answer)
    $ans = $Answer
    return @(Invoke-Expression $entryReaderExpr)
}
function Write-Lines {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

try {
    if (-not $exportExpr) { Bad 'no export expression found in Wuu.Core.psm1 - the list writer cannot be checked' }
    if (-not $readerExpr) { Bad 'no .txt reader expression found in Wuu.Core.psm1 - the list reader cannot be checked' }

    # --- 1. round trip -------------------------------------------------------------------
    $original = @('SRV01', 'SRV02', 'SRV03', 'APP04')
    $file = Join-Path $sandbox 'list.txt'
    Export-List (New-TestStore $original) $file
    if (-not (Test-Path $file)) { Bad 'the export wrote no file' }
    else {
        $back = Import-List $file
        $sorted = @($back | Sort-Object)
        $want = @($original | Sort-Object)
        if (($sorted -join ',') -ne ($want -join ',')) {
            Bad "round trip returned '$($back -join ', ')' instead of '$($original -join ', ')'"
        } else { Ok "$($original.Count) computers survive the round trip" }
    }

    # --- 2. ordering: append order, both sides -------------------------------------------
    $ordered = @('ZULU', 'ALPHA', 'MIKE')
    $f2 = Join-Path $sandbox 'order.txt'
    Export-List (New-TestStore $ordered) $f2
    $back2 = Import-List $f2
    if (($back2 -join ',') -ne ($ordered -join ',')) {
        Bad "order was not preserved: got '$($back2 -join ', ')' want '$($ordered -join ', ')'"
    } else { Ok 'ordering is the store append order and survives the round trip (deliberately not alphabetical)' }

    # --- 3. duplicates and case -----------------------------------------------------------
    # First-wins is observable only AFTER a store add: the file itself is just a list of lines, so
    # the rule is stated in terms of which spelling the store KEEPS.
    $f3 = Join-Path $sandbox 'dupes.txt'
    Write-Lines $f3 "SRV01`r`nsrv01`r`nSRV01`r`nSRV02`r`n"
    $dupes = Import-List $f3
    $names3 = Get-StoreNames (New-TestStore $dupes)
    if ($names3.Count -ne 2) { Bad "duplicates were not collapsed: the store holds $($names3.Count) ('$($names3 -join ', ')') " }
    elseif ($names3[0] -ne 'SRV01') { Bad "the first spelling did not win: the store holds '$($names3[0])'" }
    else { Ok 'duplicates collapse case-insensitively and the first spelling wins' }

    # --- 4. blank lines and surrounding whitespace ----------------------------------------
    $f4 = Join-Path $sandbox 'blanks.txt'
    Write-Lines $f4 "  SRV01  `r`n`r`n`r`n   `r`nSRV02`r`n"
    $trimmed = Import-List $f4
    if ($trimmed.Count -ne 2) { Bad "blank lines produced $($trimmed.Count) entries instead of 2 ('$($trimmed -join '|')')" }
    elseif ($trimmed -contains '') { Bad 'a blank line was imported as an empty computer name' }
    elseif ($trimmed[0] -ne 'SRV01' -or $trimmed[1] -ne 'SRV02') { Bad "whitespace was not trimmed: '$($trimmed -join '|')'" }
    else { Ok 'blank lines are skipped and surrounding whitespace is trimmed' }

    # --- 5. empty file --------------------------------------------------------------------
    $f5 = Join-Path $sandbox 'empty.txt'
    Write-Lines $f5 ''
    $none = Import-List $f5
    if ($none.Count -ne 0) { Bad "an empty file produced $($none.Count) entries" }
    else { Ok 'an empty file imports nothing and does not throw' }

    # --- 6. a large list ------------------------------------------------------------------
    $many = @(1..500 | ForEach-Object { 'HOST{0:d3}' -f $_ })
    $f6 = Join-Path $sandbox 'large.txt'
    Export-List (New-TestStore $many) $f6
    $back6 = Import-List $f6
    if ($back6.Count -ne 500) { Bad "a 500-computer list round-tripped as $($back6.Count)" }
    elseif (($back6 -join ',') -ne ($many -join ',')) { Bad 'the large list round-tripped out of order or with losses' }
    else { Ok 'a 500-computer list round-trips intact and in order' }

    # --- 7. NO TRANSIENT STATE ------------------------------------------------------------
    # The row holds all of these (measured), so this is a real risk rather than a theoretical one:
    # the ONLY thing keeping them out of the file is that the export selects the Computer property.
    $transient = @('OperationId', 'OpState', 'PendingOp', 'Revision', 'Pending', 'Runspace',
        'Available', 'Downloaded', 'RebootRequired', 'TimeoutExpiresAt', 'Heartbeats',
        'OpStartedAt', 'RefusedCount', 'RetryAt', 'CredentialEpoch', 'StateSource')
    $f7 = Join-Path $sandbox 'purity.txt'
    $richStore = New-TestStore @('SRV01', 'SRV02')
    # Give a row REAL transient values, so that serialising them would be visible in the file.
    $row = @(Get-WuuComputerRow -Store $richStore)[0]
    $row.OperationId = 'op-abcdef123456'
    $row.OpState = 'Running'
    $row.PendingOp = 'InstallAndRecheck'
    $row.Revision = 42
    $row.Available = 7
    $row.Downloaded = 3
    $row.RebootRequired = $true
    Export-List $richStore $f7

    $rawText = [System.IO.File]::ReadAllText($f7)
    $leaked = @($transient | Where-Object { $rawText -match [regex]::Escape($_) })
    if ($leaked.Count -gt 0) { Bad "the list carries transient state: $($leaked -join ', ')" }
    elseif ($rawText -match 'op-abcdef123456' -or $rawText -match 'InstallAndRecheck') {
        Bad 'the list carries an operation value (id or pending op) even though the FIELD NAME is absent'
    } else {
        # The strongest form: the file contains the names and NOTHING else.
        $lines = @([System.IO.File]::ReadAllText($f7) -split "`r?`n" | Where-Object { $_.Trim() })
        $onlyNames = ($lines.Count -eq 2) -and ($lines[0] -eq 'SRV01') -and ($lines[1] -eq 'SRV02')
        if ($onlyNames) { Ok 'the list carries membership only - no transient state, and nothing but names' }
        else { Bad "the list holds unexpected content: '$($lines -join '|')'" }
    }

    # ...and structurally, because the row DOES hold those 35 properties: without the select, the
    # purity above would be an accident of which properties happened to be blank at export time.
    if ($exportExpr -notmatch 'Select-Object -Expand Computer') {
        Bad "the export does not narrow to the Computer property, so it serialises whatever a row happens to hold: $exportExpr"
    } else { Ok 'the export selects the Computer property (purity by construction, not by coincidence)' }

    # --- 8. version independence ----------------------------------------------------------
    # Nothing in the file identifies a WUU2-CLI version, so an older build and a newer build read
    # the same file identically. Asserted on the ARTEFACT (the bytes), which is what a future
    # release has to keep true.
    $bytes8 = [System.IO.File]::ReadAllBytes($f2)
    $asUtf16 = [System.Text.Encoding]::Unicode.GetString($bytes8)
    $asUtf8 = [System.Text.Encoding]::UTF8.GetString($bytes8)
    $markers = @('v1.', 'v2.', 'wuuVersion', 'SchemaVersion', 'WUU2', 'schema')
    $foundMarker = @($markers | Where-Object { $asUtf16 -match [regex]::Escape($_) -or $asUtf8 -match [regex]::Escape($_) })
    if ($foundMarker.Count -gt 0) {
        Bad "the list carries a version marker ($($foundMarker -join ', ')), so an older or newer build would not read it identically"
    } else { Ok 'the list is version-independent: it carries no version marker, so any build reads it identically' }

    # --- 9. one policy behind every text door ---------------------------------------------
    # Spec 4.1 promises "multiple names separated by commas, spaces, or new lines". Three doors
    # accepted text: the manual-entry prompt, the flat console file import, and the guided file
    # import. The first two had their own rules and neither split on a space, so "SRV01 SRV02"
    # became ONE computer named "SRV01 SRV02" - added successfully, listed, and unable to connect.
    # The same text meant different things depending on which menu it came through.
    if ($fileReaderExpr -notmatch 'Split-WuuComputerNames') {
        Bad ("the flat console file import reads a list with its own inline rule, so it disagrees with " +
             "the guided workflow about the same file: $fileReaderExpr")
    } else { Ok 'the flat console file import uses the shared computer-name parser (one door, one rule)' }

    if ($entryReaderExpr -notmatch 'Split-WuuComputerNames') {
        Bad ("the manual-entry prompt parses with its own inline split, so it disagrees with the " +
             "guided workflow about the same text: $entryReaderExpr")
    } else { Ok 'the manual-entry prompt uses the shared computer-name parser (one door, one rule)' }

    # Behavioural proof for BOTH doors: a line holding several names must yield several computers,
    # and both doors must agree on exactly which ones.
    $shared = @(Split-WuuComputerNames -Text 'SRV01 SRV02 SRV03')
    $f8 = Join-Path $sandbox 'multiname.txt'
    Write-Lines $f8 "SRV01 SRV02 SRV03`r`nAPP04,APP05;APP06`r`n"
    $multi = Import-List $f8
    $typed = Add-Entry 'SRV01 SRV02 SRV03'

    if ($multi -contains 'SRV01 SRV02 SRV03') {
        Bad "the file import made ONE computer named '$(@($multi | Where-Object { $_ -match ' ' })[0])' - it is added successfully and can never connect"
    } elseif ($typed -contains 'SRV01 SRV02 SRV03') {
        Bad "the manual-entry prompt made ONE computer named '$(@($typed | Where-Object { $_ -match ' ' })[0])' - it is added successfully and can never connect"
    } elseif (($typed -join ',') -ne ($shared -join ',')) {
        Bad "typed input and a file disagree: '$($typed -join ', ')' vs '$($shared -join ', ')'"
    } elseif ($multi.Count -ne 6) {
        Bad "a file line holding several names yielded $($multi.Count) entr(ies) instead of 6 ('$($multi -join '|')')"
    } else {
        Ok 'a space, comma, semicolon or newline separates names at every door, and both doors agree'
    }

    # And an unusable name must be REJECTED AND REPORTED, never silently added. The guided door
    # already does this; the assertion says the flat door has to reach the same verdict.
    $f9 = Join-Path $sandbox 'invalid.txt'
    Write-Lines $f9 "SRV01`r`nbad_char!`r`n"
    $invalidNames = Import-List $f9
    if ($invalidNames -contains 'bad_char!') {
        # The reader may hand the name on; what matters is that the ADD reports it rather than
        # accepting it as a computer that will never answer.
        $set9 = New-WuuComputerSet -Store (New-TestStore @())
        $res9 = Add-WuuComputerSetNames -Set $set9 -Names $invalidNames -StateSource 'Import'
        if (@($res9.Invalid).Count -lt 1) {
            Bad "an unusable name reached the list and was NOT reported as invalid ('$($invalidNames -join ', ')')"
        } else { Ok 'an unusable name is reported as invalid rather than silently added' }
    } else {
        Ok 'an unusable name is filtered out before it reaches the list'
    }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'Test-ComputerListPersistence.ps1: ALL PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host "Test-ComputerListPersistence.ps1: $fail FAILURE(S)" -ForegroundColor Red
    exit 1
}
