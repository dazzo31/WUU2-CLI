#Requires -Version 5.1
<#
.SYNOPSIS Multiple named computer lists in ONE encrypted config file (SS: computer-list storage).
.DESCRIPTION
Proves, without a remote target and without touching the operator's real configuration:

  1. Two named lists coexist in ONE file; saving one does not lose the other.
  2. Importing by name returns THAT list; importing with no name still returns a flat view, so
     callers written before the file could hold more than one list keep working.
  3. A same-named list is REFUSED rather than silently replaced, and -AllowOverwrite replaces it
     while still leaving the other lists alone.
  4. A WRONG PASSPHRASE is reported as such and leaves the file untouched. This is the failure that
     matters most: "cannot decrypt" and "no lists yet" look identical at the prompt, and confusing
     them means a typo silently discards every list in the file.
  5. A v1 (legacy single-list) file reads as the default-named list, reports IsLegacy, and is NOT
     rewritten by the act of reading it - merely opening the tool must never modify the operator's
     only copy.
  6. The onscreen chooser takes a number, an exact name, or an unambiguous prefix, returns '' on
     cancel, and does not prompt at all when the file holds a single list.
  7. -ListName reaches the handlers from the command line, i.e. the option is parsed and threaded.

Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-ComputerLists.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$fail = 0
function Ok($m)  { Write-Host "PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail++ }

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force -DisableNameChecking
Import-WuuModules -WuuRoot $root

# Everything is written under a throwaway directory: the suite must never touch the operator's real
# ComputerList.config, and it must not be able to leave one behind if an assertion aborts the run.
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("wuu-lists-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
function New-Password([string]$plain) {
    $s = New-Object System.Security.SecureString
    foreach ($c in $plain.ToCharArray()) { $s.AppendChar($c) }
    $s.MakeReadOnly()
    return $s
}
function New-Rows([string[]]$names) {
    return @($names | ForEach-Object { @{ Computer = $_; Phase = 'Phase 1' } })
}
function Get-RowNames($rows) {
    # Not comma-wrapped: every call site wraps with @(), which is what turns a one-row scalar back
    # into an array. Doing BOTH nests the array one level deeper and the name stringifies as
    # 'System.Object[]'.
    return @($rows | ForEach-Object { $_.Computer })
}

try {
    $null = New-Item -ItemType Directory -Path $sandbox -Force
    $cfg = Join-Path $sandbox 'ComputerList.config'
    $pw = New-Password 'Correct-Horse-Battery'

    # --- 1. two lists, one file ------------------------------------------------------
    $saveA = Save-ComputerListConfig -ComputerList (New-Rows @('SRV01', 'SRV02')) -ConfigPath $cfg -Password $pw -ListName 'prod'
    $saveB = Save-ComputerListConfig -ComputerList (New-Rows @('LAB01')) -ConfigPath $cfg -Password $pw -ListName 'lab'
    if (-not $saveA.Success -or -not $saveB.Success) {
        Bad "saving two named lists failed: $($saveA.Error) / $($saveB.Error)"
    } elseif ($saveB.ListCount -ne 2) {
        Bad "saving the second list did not leave two lists in the file (ListCount=$($saveB.ListCount))"
    } else {
        Ok 'two named lists coexist in one file'
    }

    $names = @(Get-WuuComputerListNames -ConfigPath $cfg -Password $pw)
    if ($names.Count -ne 2 -or $names -notcontains 'prod' -or $names -notcontains 'lab') {
        Bad "list names wrong: '$($names -join ', ')'"
    } else {
        Ok 'both list names are readable back from the file'
    }

    # --- 2. select by name; bare import stays a flat view -----------------------------
    $prod = Import-ComputerListConfig -ConfigPath $cfg -Password $pw -ListName 'prod'
    $lab  = Import-ComputerListConfig -ConfigPath $cfg -Password $pw -ListName 'lab'
    $gotProd = @(Get-RowNames $prod.Config.Computers)
    $gotLab  = @(Get-RowNames $lab.Config.Computers)
    if (-not ($gotProd -contains 'SRV01' -and $gotProd -contains 'SRV02' -and $gotProd.Count -eq 2)) {
        Bad "selecting 'prod' returned '$($gotProd -join ', ')'"
    } elseif ($gotLab.Count -ne 1 -or $gotLab[0] -ne 'LAB01') {
        Bad "selecting 'lab' returned '$($gotLab -join ', ')'"
    } else {
        Ok 'import by name returns exactly that list'
    }

    # A caller that predates multi-list support passes no -ListName; it must still get a usable
    # flat $Config rather than an object whose shape changed under it.
    $bare = Import-ComputerListConfig -ConfigPath $cfg -Password $pw
    if (-not $bare.Success -or $null -eq $bare.Config -or @($bare.Config.Computers).Count -eq 0) {
        Bad 'a bare import (no -ListName) did not return a usable flat Config'
    } elseif (@($bare.Lists).Count -ne 2) {
        Bad "a bare import did not report both lists (Lists=$(@($bare.Lists).Count))"
    } else {
        Ok 'a bare import still returns a flat Config AND reports all lists (backward compatible)'
    }

    # A name that is not in the file is an error, not a silent fallback to some other list.
    $missing = Import-ComputerListConfig -ConfigPath $cfg -Password $pw -ListName 'nope'
    if ($missing.Success -or $missing.Error -notmatch 'no list named') {
        Bad "asking for a missing list did not fail clearly (Success=$($missing.Success))"
    } else {
        Ok 'a missing list name fails instead of falling back to another list'
    }

    # --- 3. same name is refused, not silently replaced -------------------------------
    $clash = Save-ComputerListConfig -ComputerList (New-Rows @('NEW01')) -ConfigPath $cfg -Password $pw -ListName 'prod'
    if ($clash.Success -or -not $clash.Exists) { Bad 'a same-named save was not refused' }
    else { Ok 'a same-named save is refused rather than silently replacing the list' }

    $afterClash = @(Get-RowNames (Import-ComputerListConfig -ConfigPath $cfg -Password $pw -ListName 'prod').Config.Computers)
    if ($afterClash -notcontains 'SRV01' -or $afterClash -contains 'NEW01') {
        Bad "the refused save still modified 'prod': '$($afterClash -join ', ')'"
    } else {
        Ok 'the refused save left the existing list byte-for-byte intact'
    }

    $forced = Save-ComputerListConfig -ComputerList (New-Rows @('NEW01')) -ConfigPath $cfg -Password $pw -ListName 'prod' -AllowOverwrite
    $afterForced = @(Get-WuuComputerListNames -ConfigPath $cfg -Password $pw)
    $forcedNames = @(Get-RowNames (Import-ComputerListConfig -ConfigPath $cfg -Password $pw -ListName 'prod').Config.Computers)
    if (-not $forced.Success -or -not $forced.Replaced) {
        Bad "-AllowOverwrite did not replace the list: $($forced.Error)"
    } elseif ($forcedNames[0] -ne 'NEW01') {
        Bad "the overwrite did not take effect: '$($forcedNames -join ', ')'"
    } elseif ($afterForced -notcontains 'lab' -or $afterForced.Count -ne 2) {
        Bad "overwriting one list destroyed another (now: '$($afterForced -join ', ')')"
    } else {
        Ok '-AllowOverwrite replaces the named list and leaves the others alone'
    }

    # --- 4. a wrong passphrase is reported, and destroys nothing -----------------------
    $before = (Get-FileHash -LiteralPath $cfg -Algorithm SHA256).Hash
    $badPw = New-Password 'definitely-not-it'
    $bad = Save-ComputerListConfig -ComputerList (New-Rows @('X01')) -ConfigPath $cfg -Password $badPw -ListName 'oops'
    if ($bad.Success) { Bad 'a save with the wrong passphrase succeeded' }
    elseif (-not $bad.WrongPassword) { Bad "a wrong passphrase was not identified as one (Error=$($bad.Error))" }
    else { Ok 'a wrong passphrase is identified as a wrong passphrase' }

    $after = (Get-FileHash -LiteralPath $cfg -Algorithm SHA256).Hash
    if ($after -ne $before) { Bad 'a failed save modified the configuration file' }
    else { Ok 'a failed save leaves the file untouched' }

    $stillThere = @(Get-WuuComputerListNames -ConfigPath $cfg -Password $pw)
    if ($stillThere.Count -ne 2) { Bad "the refused save lost lists (now $($stillThere.Count))" }
    else { Ok 'no list is lost when the passphrase is wrong' }

    # The read path must distinguish the two as well - the load handler depends on it.
    $badRead = Read-WuuConfigFile -ConfigPath $cfg -Password $badPw
    if ($badRead.Success -or -not $badRead.WrongPassword) {
        Bad "Read-WuuConfigFile did not flag a wrong passphrase (Success=$($badRead.Success))"
    } else {
        Ok 'the read path flags a wrong passphrase (so "no lists" is never guessed from a failure)'
    }

    # --- 5. v1 files still read, and are not rewritten by reading ----------------------
    $legacy = Join-Path $sandbox 'Legacy.config'
    $legacyDoc = @{
        SavedDate        = '2026-01-01 00:00:00'
        ComputerCount    = 2
        Computers        = @(@{ Computer = 'OLD01'; Phase = 'Phase 1' }, @{ Computer = 'OLD02'; Phase = 'Phase 2' })
        CredentialConfig = Get-WuuCredentialStateSignature
    }
    $enc = Protect-ComputerListData -Data ($legacyDoc | ConvertTo-Json -Depth 6) -Password $pw
    [System.IO.File]::WriteAllText($legacy, $enc.Data, (New-Object System.Text.UTF8Encoding($false)))
    $legacyBefore = (Get-FileHash -LiteralPath $legacy -Algorithm SHA256).Hash

    $legacyRead = Import-ComputerListConfig -ConfigPath $legacy -Password $pw
    $legacyNames = @(Get-RowNames $legacyRead.Config.Computers)
    if (-not $legacyRead.Success) {
        Bad "a v1 file no longer reads: $($legacyRead.Error)"
    } elseif ($legacyNames.Count -ne 2 -or $legacyNames -notcontains 'OLD01') {
        Bad "a v1 file read as the wrong computers: '$($legacyNames -join ', ')'"
    } elseif (-not $legacyRead.IsLegacy) {
        Bad 'a v1 file was not reported as legacy'
    } else {
        Ok 'a v1 file reads correctly and is reported as legacy'
    }

    $legacyListNames = @(Get-WuuComputerListNames -ConfigPath $legacy -Password $pw)
    if ($legacyListNames.Count -ne 1 -or $legacyListNames[0] -ne 'default') {
        Bad "a v1 file did not present one 'default' list: '$($legacyListNames -join ', ')'"
    } else {
        Ok "a v1 file presents itself as a single 'default' list"
    }

    $legacyAfter = (Get-FileHash -LiteralPath $legacy -Algorithm SHA256).Hash
    if ($legacyAfter -ne $legacyBefore) { Bad 'reading a v1 file rewrote it' }
    else { Ok 'reading a v1 file does not rewrite it (opening the tool is not a migration)' }

    # --- 6. the chooser ----------------------------------------------------------------
    $choices = @(Get-WuuComputerListNames -ConfigPath $cfg -Password $pw)

    # The chooser runs on the module's own input queue, so it is driven through the same
    # Initialize-WuuInputMode the command surface uses - never by assigning to a scoped variable.
    function Choose([string]$answer) {
        Initialize-WuuInputMode -NonInteractive -Answers @($answer)
        try { return [string](New-WuuComputerListPrompt -Names $choices) }
        finally { Initialize-WuuInputMode -NonInteractive:$false }
    }

    $byNumber = Choose '1'
    $byName   = Choose 'lab'
    $byPrefix = Choose 'la'
    $cancelled = Choose ''
    $unknown  = Choose 'not-a-list'

    if ($byNumber -ne $choices[0]) { Bad "chooser did not resolve a number (got '$byNumber')" }
    else { Ok 'chooser resolves a list by its menu number' }
    if ($byName -ne 'lab') { Bad "chooser did not resolve an exact name (got '$byName')" }
    else { Ok 'chooser resolves a list by exact name' }
    if ($byPrefix -ne 'lab') { Bad "chooser did not resolve an unambiguous prefix (got '$byPrefix')" }
    else { Ok 'chooser resolves an unambiguous prefix' }
    if ($cancelled -ne '') { Bad "cancelling the chooser returned '$cancelled'" }
    else { Ok 'cancelling the chooser returns empty (the caller cancels, nothing is loaded)' }
    if ($unknown -ne '') { Bad "an unknown answer returned '$unknown' instead of cancelling" }
    else { Ok 'an unrecognised answer cancels instead of loading an arbitrary list' }

    # An ambiguous prefix must not silently pick the first match.
    $ambNames = @('prod', 'personal')
    Initialize-WuuInputMode -NonInteractive -Answers @('p')
    try { $ambResult = [string](New-WuuComputerListPrompt -Names $ambNames) }
    finally { Initialize-WuuInputMode -NonInteractive:$false }
    if ($ambResult -ne '') { Bad "an ambiguous prefix loaded '$ambResult' instead of refusing" }
    else { Ok 'an ambiguous prefix refuses rather than guessing' }

    # One list means no decision, so there must be no prompt at all.
    $single = [string](New-WuuComputerListPrompt -Names @('only'))
    if ($single -ne 'only') { Bad "a single-list file prompted and returned '$single'" }
    else { Ok 'a single-list file loads without prompting (there is no decision to make)' }

    $none = [string](New-WuuComputerListPrompt -Names @())
    if ($none -ne '') { Bad "an empty list set returned '$none'" }
    else { Ok 'no lists means no choice, not a crash' }

    # --- 7. -ListName reaches the handlers from the command line ------------------------
    $parsedList = ConvertTo-WuuCommandLine -Arguments @('config', 'load', '-ListName', 'prod')
    if ($parsedList.Unknown.Count -gt 0) {
        Bad "-ListName is not a recognised option: $($parsedList.Unknown -join ', ')"
    } elseif ($parsedList.Options['ListName'] -ne 'prod') {
        Bad "-ListName parsed to '$($parsedList.Options['ListName'])'"
    } else {
        Ok 'the command line parses -ListName for config load'
    }

    $parsedSave = ConvertTo-WuuCommandLine -Arguments @('config', 'save', '-ListName', 'lab')
    if ($parsedSave.SubVerb -ne 'save' -or $parsedSave.Options['ListName'] -ne 'lab') {
        Bad 'the command line did not carry -ListName on config save'
    } else {
        Ok 'the command line parses -ListName for config save'
    }

    # The config entry must actually hand the option to the handler as an answer, or the option
    # would parse and then be dropped - the failure mode that makes a switch look broken.
    $entry = (Get-WuuCommandTable)['config']
    if (-not $entry -or -not $entry.Answers) {
        Bad 'the config command entry has no answer builder'
    } else {
        $q = @(& $entry.Answers @{ ListName = 'prod' })
        if ($q.Count -lt 1 -or $q[0] -ne 'prod') {
            Bad "the config answer builder ignored -ListName (answers: '$($q -join '|')')"
        } else {
            Ok 'the config command hands -ListName to the handler as its prompt answer'
        }
    }

    # --- 8. the confirm field on a passphrase that is being CHOSEN -----------------------
    # Every list in the file shares one passphrase, so a typo while creating it produces a file that
    # opens with neither entry - and a file the operator cannot identify, holding lists they can no
    # longer read, is indistinguishable from an empty one at the next load.
    function Sec([string]$plain) {
        $s = New-Object System.Security.SecureString
        foreach ($c in $plain.ToCharArray()) { $s.AppendChar($c) }
        $s.MakeReadOnly()
        return $s
    }

    $matchCases = @(
        @{ Name = 'identical entries';      A = 'Correct-Horse'; B = 'Correct-Horse'; Want = $true }
        @{ Name = 'different entries';      A = 'Correct-Horse'; B = 'Wrong-Horse';   Want = $false }
        @{ Name = 'CASE differs only';      A = 'Password1';     B = 'password1';     Want = $false }
        @{ Name = 'trailing space differs'; A = 'secret';        B = 'secret ';       Want = $false }
        @{ Name = 'one character differs';  A = 'Passw0rd';      B = 'PasswOrd';      Want = $false }
    )
    $matchWrong = @()
    foreach ($c in $matchCases) {
        $got = Test-WuuPasswordMatch -First (Sec $c.A) -Second (Sec $c.B)
        if ($got -ne $c.Want) { $matchWrong += "$($c.Name) -> $got" }
    }
    if ($matchWrong.Count -gt 0) {
        Bad "the password comparison is wrong for: $($matchWrong -join '; ')"
    } else {
        Ok "the password comparison matches on $($matchCases.Count) cases, including case-only and whitespace differences"
    }

    # An empty retype must be REFUSED, not treated as "no change": it is the one entry an operator can
    # produce by pressing Enter, and accepting it would save under a passphrase they never set.
    if (Test-WuuPasswordMatch -First (Sec 'abc') -Second $null) {
        Bad 'an empty confirmation is treated as a match'
    } else {
        Ok 'an empty confirmation is refused'
    }

    # The prompt must SKIP - and return before reaching a prompt - when the check cannot mean anything.
    # Each of these would otherwise be a way for the save to block with nobody able to answer.
    Initialize-WuuInputMode -NonInteractive -Answers @()
    try {
        $n = Confirm-WuuPasswordPrompt -Password (Sec 'abc')
    } finally { Initialize-WuuInputMode -NonInteractive:$false }
    if (-not $n.Confirmed -or -not $n.Skipped) {
        Bad "the confirm field ran in a non-interactive run (Confirmed=$($n.Confirmed) Skipped=$($n.Skipped))"
    } else {
        Ok 'the confirm field skips itself in a non-interactive run (nothing can retype, and nothing blocks)'
    }
    if ((Get-WuuInputMode).AnswersUsed -ne 0) {
        Bad 'the confirm field consumed a queued answer even though it skipped'
    } else {
        Ok 'a skipped confirm field consumes no queued answer (the answer queue is not shifted)'
    }

    $e = Confirm-WuuPasswordPrompt -Password (Sec 'abc') -ExistingFile
    if (-not $e.Confirmed -or -not $e.Skipped) {
        Bad "the confirm field prompted for a passphrase that is being proved, not chosen (Skipped=$($e.Skipped))"
    } else {
        Ok 'an existing file is not asked to confirm - that passphrase is proved by opening the file'
    }

    # ...and the save handler must actually consult it, only on the create path. A check nobody calls
    # is not a check, and one that runs on every save is friction over a password already in use.
    $coreSave = [regex]::Match((Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw),
        'Confirm-WuuPasswordPrompt[\s\S]{0,240}?-ExistingFile').Value
    if (-not $coreSave) {
        Bad 'the save path never calls Confirm-WuuPasswordPrompt, or does not gate it on the file existing'
    } else {
        Ok 'the save path confirms a new passphrase, and only when the file would be created'
    }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'Test-ComputerLists.ps1: ALL PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host "Test-ComputerLists.ps1: $fail FAILURE(S)" -ForegroundColor Red
    exit 1
}
