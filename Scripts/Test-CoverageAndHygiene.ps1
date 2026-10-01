# Release validation, BEHAVIOUR COVERAGE AND RELEASE HYGIENE (SS39). Extracted from Validate-Release.ps1.
#
# WHAT IS IN HERE:
#   (ag) reboot and cancellation coverage - the behaviours where a bug is expensive: a reboot that
#        never happens, one wrongly reported as failed, or a cancellation that runs anyway
#   (al) migration debris - a name left over from the GUI edition that described a view no longer here
#   (am) release hygiene - debug logging OFF by default, and no interactive prompt on a fatal path
#
# DOT-SOURCED FRAGMENT - not a standalone script. Validate-Release.ps1 dot-sources it into its own
# scope AT THE POSITION THESE BLOCKS OCCUPIED, which is what gives this file $root, the verdict
# helpers, and the shared harness helpers hoisted above the dot-sources. It also keeps the verdict
# order unchanged - the report is what CI reads.

# (ag) REBOOT AND CANCELLATION COVERAGE (brief SS16). The brief lists these as the untested behaviours,
#      and they are the ones where a bug is expensive: a reboot that never happens, a reboot wrongly
#      reported as failed, or a cancellation that runs anyway.
#
#      The BEHAVIOUR is covered by tests\Test-RebootAndCancellation.ps1, which extracts the shipped
#      $RestartComputer payload and drives it in a real runspace with stubbed remote calls (the only way
#      to exercise it without a second machine). This gate asserts the pieces that make that coverage
#      meaningful, so deleting the payload's structure cannot silently turn the tests into no-ops.
$coreRawR = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$restartBody = [regex]::Match($coreRawR, '\$RestartComputer = \{[\s\S]*?\r?\n# Note: the old duplicate').Value
if (-not $restartBody) {
    Fail 'could not locate the $RestartComputer payload'
} else {
    # Comments stripped: the payload explains the ICMP removal by naming Test-Connection.
    $restartCode = Get-WuuTextWithoutComments -Text $restartBody
    if ($restartCode -match 'Test-Connection') {
        Fail 'the reboot payload decides with ICMP again - it cannot terminate on a host that blocks echo (SS7/SS16)'
    }
    if ($restartCode -notmatch 'Restart-Computer \$Computer\.computer -Force') {
        Fail 'the reboot payload does not issue Restart-Computer (the reboot would never be requested) (SS16)'
    }
    if ($restartCode -notmatch 'Test-WuuManagementEndpoint') {
        Fail 'the reboot payload does not use the management-endpoint probe (SS7/SS16)'
    }
    # The offline wait must give up and CONTINUE rather than fail - a slow shutdown is not a stuck one.
    if ($restartCode -notmatch 'assuming a very fast reboot') {
        Fail 'the offline wait no longer tolerates "never observed down" - a healthy fast reboot would be reported as failed (SS16)'
    }
    if ($restartCode -notmatch 'may still be booting') {
        Fail 'the online-wait timeout no longer says the host may still be booting - it would blame the restart (SS16)'
    }
    if (-not $failed) { Pass 'the reboot payload waits on the management endpoint and reports honestly (SS16)' }
}
# The cancellation surfaces, asserted structurally because they are reachability properties.
$navRawR = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Navigate.psm1') -Raw
$consoleRawR = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Console.psm1') -Raw
$denialSites = ([regex]::Matches($navRawR + $consoleRawR, 'DenialHook')).Count
if ($denialSites -lt 3) {
    Fail "only $denialSites denial-hook site(s) - a cancellation would leave no trace (A.8.15) (SS16)"
}
if ($navRawR -notmatch "Proceed = \`$false; Reason = ''") {
    Fail 'a blank change reason no longer cancels the operation (it would run unaudited) (SS16)'
}
$emptyGuards = ([regex]::Matches($coreRawR, "if \(\`$rows\.Count -eq 0\) \{ Write-Host '  Cancelled\.'")).Count
if ($emptyGuards -lt 5) {
    Fail "only $emptyGuards empty-selection guard(s) - a cancelled selection could widen to every computer (SS16)"
}
# An unreachable computer must cancel queued work but KEEP the row below the threshold (SS12/SS16).
$stateRawR = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw
if ($stateRawR -notmatch "\`$Row\.Pending = \`$false") {
    Fail 'an unreachable computer no longer has its queued work cancelled - the scheduler would spin against a host that is not there (SS16)'
}
# ...and the probe-shape handling must not have the unguarded Contains that made its own branch dead.
#
# The invariant is ORDER, not the absence of .Contains: the guarded branch legitimately calls
# $ProbeResult.Contains('Resolves') on a hashtable. What broke was calling it BEFORE the shape test, on
# an object that has no such method. So: the first shape test must precede the first .Contains call.
$connBody = Get-WuuFunctionBody $stateRawR 'Update-WuuConnectivityState'
$connCode = Get-WuuTextWithoutComments -Text $connBody
$containsAt = $connCode.IndexOf('.Contains(')
$shapeAt = $connCode.IndexOf('-is [hashtable]')
if ($connCode -notmatch 'PSObject\.Properties\[''Resolves''\]') {
    Fail 'the connectivity decision no longer handles a PSCustomObject probe result'
} elseif ($containsAt -ge 0 -and ($shapeAt -lt 0 -or $containsAt -lt $shapeAt)) {
    Fail "the connectivity decision calls .Contains on the probe result BEFORE testing its shape - a PSCustomObject throws and the PSCustomObject branch is unreachable (SS16)"
} elseif (-not $failed) {
    Pass 'the connectivity decision tests the probe shape before calling a shape-specific method (SS16)'
}
if (-not $failed) { Pass 'cancellation surfaces, and both probe-result shapes, are intact (SS16)' }

# (ah)-(ak) ENGINE INVARIANTS - extracted to Scripts\Test-EngineInvariants.ps1 (instructions SS39).
#      Dot-sourced HERE, where the blocks were, so their verdicts keep their position in the list.
#      A fragment may be dot-sourced ONCE.
. (Join-Path $PSScriptRoot 'Test-EngineInvariants.ps1')
# (al) MIGRATION DEBRIS: the misleading name (brief SS14). `SafeUpdateListViewItem` described the GUI
#      edition, where the helper wrote into a WPF ListView. In this repository it writes a computer ROW
#      into the state store and there is no ListView at all - so the name pointed a reader at a view
#      dependency that does not exist, and a new operation could reasonably have been routed around it
#      on that basis. It was defined under that name TWICE (a module-scope copy and the
#      runspace-injected copy the payloads actually use), which is how it survived a GUI-removal pass:
#      renaming one would have left the other.
#
#      The gate asserts the name is GONE from shipped code and that the accurate name is what both
#      copies now carry. Comments are excluded, so the rename's own explanation does not satisfy it.
$debrisFiles = @('src\Wuu.Core.psm1', 'src\Wuu.WindowsUpdate.psm1', 'src\Wuu.State.psm1')
$debrisHits = @()
foreach ($df in $debrisFiles) {
    $dCode = Get-WuuTextWithoutComments -Text (Get-Content -LiteralPath (Join-Path $root $df) -Raw)
    if ($dCode -match 'SafeUpdateListViewItem') { $debrisHits += $df }
}
if ($debrisHits.Count) {
    Fail ('the misleading GUI-era name survives in shipped code: ' + ($debrisHits -join ', ') + ' - it describes a WPF ListView this edition does not have')
} else {
    Pass 'the GUI-era name `SafeUpdateListViewItem` is gone from shipped code (SS14)'
}
# Both copies must exist under the accurate name, or the payload and the main session would differ.
$coreDebris = Get-WuuTextWithoutComments -Text (Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw)
$wupdDebris = Get-WuuTextWithoutComments -Text (Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw)
if ($coreDebris -notmatch 'function Update-WuuComputerRow') {
    Fail 'the module-scope row writer is not named Update-WuuComputerRow (SS14)'
} elseif ($wupdDebris -notmatch "SetVariable\('UpdateWuuComputerRowScript'") {
    Fail 'the runspace-injected row writer is not named UpdateWuuComputerRowScript (SS14)'
} else {
    Pass 'both row-writer copies carry the accurate name (SS14)'
}

# (am) RELEASE HYGIENE: debug logging OFF by default, and no interactive prompt on a fatal path
#      (brief SS17 / SS15). Two defects that are cheap to reintroduce and expensive to notice.
#
#      WHY A GATE AND NOT A COMMENT. Both were wrong in the shipped tree at the same time: the
#      comment above the assignment said "$false by default" while the assignment said $true, and
#      four startup failure paths ended in `Read-Host "Press Enter to exit"` followed by a bare
#      `exit` that reports SUCCESS. Neither is caught by any behavioural test, because a test can
#      start the application successfully without ever exercising either.
$coreRawM = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$consoleRawM = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Console.psm1') -Raw
# The $global:* SETTINGS moved to src\Wuu.Configuration.psm1 (SS8), so the checks about those settings
# read THAT file. $coreRawM still serves the checks about Core's own code (the fatal prompt, the input
# choke point below): only orchestration stayed behind, so a reader can tell which file each check owns.
$configRawM = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Configuration.psm1'))

# 1. Debug logging must default to OFF. Verbose-by-default is wrong for an unattended patch tool:
#    large logs, I/O on every run, operational detail written by default, and diagnostic records
#    interleaved with the audit trail.
if ($configRawM -notmatch '\$global:EnableDebugLogging\s*=\s*\$false') {
    Fail 'debug logging does not default to $false - verbose-by-default is wrong for an unattended patch tool (large logs, extra I/O, operational detail on disk) (SS17)'
} elseif ($configRawM -match '\$global:EnableDebugLogging\s*=\s*\$true') {
    # The override path legitimately assigns $true inside the WUU_DEBUG branch, so its presence is
    # only a failure if it is NOT guarded by that branch.
    if ($configRawM -notmatch 'WUU_DEBUG') {
        Fail 'debug logging is set to $true with no documented override - production behaviour would depend on editing source (SS17)'
    } else {
        Pass 'debug logging defaults to $false and is enabled by the WUU_DEBUG override (SS17)'
    }
} else {
    Pass 'debug logging defaults to $false (SS17)'
}
# The override must exist, so an operator can diagnose without editing a shipped file.
if ($configRawM -notmatch 'WUU_DEBUG') {
    Fail 'there is no way to enable debug logging without editing source - a shipped file edit is reverted by the next install and invisible in the configuration (SS17)'
}

# 2. No interactive prompt may block a FATAL path. A prompt there hangs every unattended caller; the
#    exit code must also be non-zero, because a bare `exit` reported success on a failed startup.
$fatalPrompts = ([regex]::Matches($coreRawM, 'Read-Host\s+[''"]?\s*Press Enter')).Count
if ($fatalPrompts -gt 0) {
    Fail "$fatalPrompts 'Read-Host ... Press Enter' prompt(s) remain - a startup error would hang a scheduled task, a CI job or an agent-driven test instead of failing (SS15)"
} else {
    Pass 'no interactive prompt blocks a fatal startup path (SS15)'
}
if ($consoleRawM -notmatch 'function Stop-WuuFatal') {
    # In Wuu.Console, not Wuu.Core: the presentation layer owns console interaction, so the helper
    # belongs beside Read-WuuAnswer. Asserted against the CONSOLE source - an earlier version of this
    # check looked in Wuu.Core and reported the function missing while it was present.
    Fail 'Stop-WuuFatal is missing - the fatal paths have no unattended-safe exit'
}
if ($consoleRawM -notmatch "'Stop-WuuFatal'") {
    Fail 'Stop-WuuFatal is not exported from Wuu.Console - the fatal paths in Wuu.Core could not call it'
}
# It must exit NON-ZERO and must not wait without checking for a real console.
$consoleCodeM = Get-WuuTextWithoutComments -Text $consoleRawM
$fatalBodyM = Get-WuuFunctionBody $consoleRawM 'Stop-WuuFatal'
if ($fatalBodyM -notmatch 'exit \$ExitCode') {
    Fail 'Stop-WuuFatal does not exit with a code - a fatal startup would report success (SS15)'
} elseif ($fatalBodyM -notmatch 'IsInputRedirected') {
    Fail 'Stop-WuuFatal waits without checking for a console - it would still hang a redirected/unattended run (SS15)'
} else {
    Pass 'fatal exits are non-zero and wait only for a real interactive console (SS15)'
}

# 3. The password prompt must route through the input choke point, or a command-mode run blocks at
#    the unlock prompt with no way to answer it.
#    The prompt moved to Wuu.Presentation.psm1 (SS8), so it is read THERE. The check names the
#    module rather than Core so a future move fails loudly here instead of silently passing on
#    absent text - the failure mode a "not in the old file" check always has.
$presRawM = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Presentation.psm1'))
if ($presRawM -notmatch 'Read-WuuAnswer -Prompt \$Prompt -Secure') {
    Fail 'the password prompt bypasses Read-WuuAnswer - a scripted or non-interactive run could not answer the unlock prompt (SS15)'
} elseif ($presRawM -notmatch 'function _WuuReadPassword') {
    Fail 'the choke-point-routed password prompt is missing from Wuu.Presentation - the SS15 check above matched something else (SS15)'
} else {
    Pass 'the password prompt routes through the input choke point (SS15)'
}

# 4. THE VERSION GUARD (the defect that started this). The embedded literal and a real git tag at HEAD
#    must agree, or audit records carry a version no release used. Checked by RUNNING the resolver -
#    a text comparison here would duplicate its logic instead of exercising it.
$embeddedVersionM = ''
$versionMatchM = [regex]::Match($configRawM, "\`$global:WuuVersion\s*=\s*'([^']+)'")
if ($versionMatchM.Success) { $embeddedVersionM = $versionMatchM.Groups[1].Value }
if (-not $embeddedVersionM) {
    Fail 'could not read the embedded $global:WuuVersion literal - the version is not single-sourced (SS18)'
} else {
    try {
        $versionCheck = Resolve-WuuVersion -Embedded $embeddedVersionM -RepoRoot $root
        if ($versionCheck -and $versionCheck.Mismatch) {
            Fail ("version mismatch: " + $versionCheck.Note + " - every audit record would carry a version that did not produce the evidence (SS18)")
        } elseif ($versionCheck -and $versionCheck.Source -eq 'tag') {
            Pass "the embedded version matches the git tag at HEAD ($($versionCheck.Version)) (SS18)"
        } else {
            # NOT ON A TAG (a commit between releases). This is legitimate, but the check did not
            # actually run - and reporting it as PASS would claim a verified property that was never
            # evaluated. SKIP says exactly that, which is why the kind exists.
            Skip "version provenance not evaluated: $($versionCheck.Note) - the tag comparison does not apply off a release tag (SS18)"
        }
    } catch {
        Fail "could not resolve the version for the mismatch check: $($_.Exception.Message)"
    }
}
