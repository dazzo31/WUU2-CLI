# Release validation, COMMAND BEHAVIOUR CONTRACT (SS39). Extracted from Validate-Release.ps1.
#
# WHAT IS IN HERE, so the name does not have to carry it all:
#   (aa) exit codes - asserted by NUMBER and by the ORDER of the branches that produce them
#   (ab) operation-specific timeouts - the budget is per op, not one flat stop for everything
#   (ac) workflow state is not a display string - Test-PhaseCompletion decides on state, not text
#   (ad) credential propagation and persistence - the configured identity is the one used
#   (ae) -WhatIf reports a per-computer plan, and writes no audit record
#
# DOT-SOURCED FRAGMENT - not a standalone script. Validate-Release.ps1 dot-sources it into its own
# scope AT THE POSITION THESE BLOCKS OCCUPIED, which is what gives this file $root, the verdict
# helpers, and the shared harness helpers hoisted above the dot-sources. It also keeps the verdict
# order unchanged - the report is what CI reads.

# (aa) EXIT CODES (brief SS10). Asserted by NUMBER and by the ORDER of the branches that produce
#      them, because the contract is the number a script branches on. The defect SS10 names is that a
#      scripted `wuu install` could exit 0 while the install was merely QUEUED - "accepted" read as
#      "done", silently, in every CI job that used it.
#
#      Static, like the neighbouring Core gates: driving the shell for real needs elevation, a live
#      WSUS target and minutes per run, so it cannot be a per-build gate. Literal .IndexOf is used
#      instead of -match for the patterns containing '$', because a bare '$busy' in a regex is an
#      end-of-line anchor - that produced a false failure while writing the accompanying test.
$cmdRawE = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Command.psm1') -Raw

# 1. The vocabulary itself: every name must map to its documented number.
$codeMap = @{ 'Success' = 0; 'OperationFailed' = 1; 'UsageError' = 2; 'Timeout' = 3; 'PartialSuccess' = 4; 'AuditFailure' = 5; 'Queued' = 6; 'Refused' = 7 }
$exitBody = Get-WuuFunctionBody $cmdRawE 'Get-WuuExitCode'
if (-not $exitBody) {
    Fail 'Get-WuuExitCode is not defined - SS10 has no vocabulary and every exit is folklore'
} else {
    foreach ($n in ($codeMap.Keys | Sort-Object)) {
        if ($exitBody -notmatch ("'" + $n + "'\s*\{\s*" + $codeMap[$n] + "\s*\}")) {
            Fail "exit code '$n' is not mapped to $($codeMap[$n])"
        }
    }
    # A name that reaches the default arm silently becomes 1, i.e. a usage error reported as an
    # operation failure. The ValidateSet is what makes that impossible.
    if ($exitBody -notmatch 'ValidateSet') {
        Fail 'Get-WuuExitCode has no ValidateSet - an unknown name would silently become 1'
    }
    if (-not $failed) { Pass 'the exit-code vocabulary maps all eight names to their documented numbers (SS10)' }
}

if ($cmdRawE -notmatch "'Get-WuuExitCode'") { Fail 'Get-WuuExitCode is not exported (the caller cannot resolve it)' }
if ($cmdRawE -notmatch 'function Get-WuuExitCodeMeaning') { Fail 'Get-WuuExitCodeMeaning is missing - a non-zero exit would be unexplained' }

# 2. -Async must be parsed AND forwarded. Either one alone makes the flag a silent no-op: parsed
#    but not forwarded and Core still calls an async command a timeout; forwarded but not parsed
#    and the option is reported as a typo before it ever reaches Core.
$coreRawE = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
if ($cmdRawE -notmatch "'-async'\s*=\s*'Async'") { Fail 'the command parser does not recognise -Async' }
if ($coreRawE.IndexOf('-Async:$parsed.Options[''Async'']') -lt 0) { Fail 'Core does not forward -Async from the parsed options' }

# 3. The four properties that make the exit code honest. Each can fail alone.
if ($coreRawE.IndexOf('OpState -eq ''Running''') -lt 0 -or $coreRawE.IndexOf('$_.Pending') -lt 0) {
    Fail 'outstanding work is not measured from the store rows (OpState/Pending) - the exit code would reflect a queue, not a result'
}
if ($coreRawE.IndexOf("Get-WuuExitCode -Result 'Timeout'") -lt 0) {
    Fail 'unfinished work does not produce the Timeout code - a queued install could still exit 0'
}
if ($coreRawE.IndexOf("Get-WuuExitCode -Result 'Queued'") -lt 0) {
    Fail 'queued work does not produce the Queued code (-Async has no distinct outcome)'
}
$timeoutAt = $coreRawE.IndexOf("Get-WuuExitCode -Result 'Timeout'")
$notOkAt = $coreRawE.IndexOf('elseif (-not $result')
if ($timeoutAt -gt 0 -and $notOkAt -gt 0 -and $timeoutAt -gt $notOkAt) {
    Fail 'the timeout branch is evaluated AFTER the result-object branch - a command that reported Ok but left work running would be classified as success'
}
if ($coreRawE.IndexOf('$script:CommandExitCode = $exitCode') -lt 0) {
    Fail 'the exit code is not assigned unconditionally - a stale non-zero code could persist into a later run'
}

# 4. Audit integrity is a DIFFERENT failure from a failed operation, so it gets its own code. The
#    old code set $script:CommandExitCode from inside Wuu.Command.psm1, which is that module's
#    script scope - not the caller's - so `audit verify` on a broken chain exited 0. Classification
#    travels on the result object instead, which crosses the scope boundary correctly.
if ($cmdRawE -notmatch "'AuditFailure'") { Fail 'audit-integrity failures carry no classification' }
if ($cmdRawE -match '\$script:CommandExitCode\s*=') {
    Fail 'Wuu.Command sets $script:CommandExitCode in the wrong scope - the value never reaches the exit path (audit verify would exit 0 on a broken chain)'
}
if (-not $failed) { Pass 'exit codes distinguish completion, timeout, queueing, usage, refusal and audit integrity (SS10)' }

# (ab) OPERATION-SPECIFIC TIMEOUTS (brief SS5). The defect was ONE flat 10-minute stop for every
#      operation, which is wrong in both directions: it killed healthy long operations (a reboot's own
#      offline+online waits total 40 minutes!) and let a hung 5-minute service action hold a runspace
#      for ten minutes. Five properties, because each can fail alone:
#
#        1. a per-op budget table exists, keyed by the ops actually accepted, with a default;
#        2. the budget is recorded on the row AT SUBMISSION (one source of truth);
#        3. the row carries the op name - without it the cleanup loop cannot know WHICH budget applies,
#           which is exactly why the old code needed one number for everything;
#        4. the loop decides from that deadline, retains a bounded fallback, and records a heartbeat;
#        5. every OpState release CLEARS the deadline. This one is a trap: the deadline is READ, not
#           recomputed, so a finished row that kept a past deadline would make the NEXT operation look
#           expired on its first loop pass - every operation after the first killed instantly.
#
#      The loop cannot call module functions, so the decision logic exists twice. tests\
#      Test-OperationTimeouts.ps1 runs both copies on identical inputs and compares verdicts; that
#      differential is the guard against drift, and this gate asserts the pieces both copies need.
$coreRawT = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$stateRawT = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw
$wupdRawT = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw
# The timeout settings moved to Wuu.Configuration.psm1 (SS8); the deadline USES stay in Core.
$configRawT = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Configuration.psm1'))

# 1. the table, and that its numbers are per-op rather than one repeated value
$tableMatch = [regex]::Match($configRawT, '\$global:OperationTimeoutSeconds\s*=\s*@\{([\s\S]*?)\}')
if (-not $tableMatch.Success) {
    Fail 'the per-op operation timeout table is missing (SS5) - a flat stop would come back'
} else {
    $tableBody = $tableMatch.Groups[1].Value
    if ($tableBody -notmatch "'default'") {
        Fail 'the operation timeout table has no default entry - an unrecognised op would be unbounded'
    }
    $values = @([regex]::Matches($tableBody, '=\s*(\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
    if (($values | Sort-Object -Unique).Count -lt 3) {
        Fail "the operation timeout table has only $(($values | Sort-Object -Unique).Count) distinct value(s) - that is not per-op"
    }
    # The reboot chain's own waits must fit inside its budget, or the budget guarantees a false timeout.
    $autoFlow = [regex]::Match($tableBody, "'AutoFlow'\s*=\s*(\d+)")
    $offline = [regex]::Match($configRawT, '\$global:OfflineWaitSeconds\s*=\s*(\d+)')
    $online = [regex]::Match($configRawT, '\$global:OnlineWaitSeconds\s*=\s*(\d+)')
    if ($autoFlow.Success -and $offline.Success -and $online.Success) {
        $needed = [int]$offline.Groups[1].Value + [int]$online.Groups[1].Value
        if ([int]$autoFlow.Groups[1].Value -le $needed) {
            Fail "the AutoFlow budget ($($autoFlow.Groups[1].Value)s) is shorter than its own reboot waits ($needed) - every reboot would report a false timeout"
        }
    }
    # Every op Start-UpdateCheckJob accepts must have its own budget.
    $opSet = [regex]::Match($wupdRawT, "ValidateSet\(([^)]*)\)\]\s*\r?\n\s*\[string\]\`$Op")
    if ($opSet.Success) {
        $ops = @($opSet.Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim("'") })
        $missingOps = @($ops | Where-Object { $_ -and $tableBody -notmatch "['""]$_['""]" })
        if ($missingOps.Count -gt 0) {
            Fail "op(s) accepted by Start-UpdateCheckJob with no budget entry (they inherit default silently): $($missingOps -join ', ')"
        }
    }
    if (-not $failed) { Pass 'operation timeouts are per-op, complete, and fit inside the reboot waits (SS5)' }
}

# 2. the row contract must carry what the decision needs
foreach ($field in @('OpName', 'TimeoutExpiresAt', 'TimeoutSource', 'LastHeartbeatAt', 'Heartbeats')) {
    if ($stateRawT -notmatch [regex]::Escape($field)) {
        Fail "the row contract does not carry $field - the per-op deadline decision cannot work (SS5)"
    }
}
if ($stateRawT -notmatch 'function Test-WuuOperationExpired') {
    Fail 'Test-WuuOperationExpired is missing - the SS5 decision is not testable'
} elseif ($stateRawT -notmatch "'Test-WuuOperationExpired'") {
    Fail 'Test-WuuOperationExpired is not exported'
} elseif (-not $failed) { Pass 'the SS5 row contract and decision function exist (SS5)' }

# 3. the deadline is recorded at submission, and the op name travels with it
$supBodyT = Get-WuuFunctionBody $wupdRawT 'Start-UpdateCheckJob'
if (-not $supBodyT) { Fail 'could not locate Start-UpdateCheckJob' }
elseif ($supBodyT -notmatch 'Set-WuuOperationDeadline') {
    Fail 'the submission point does not record the operation deadline - the loop would have to guess the budget'
} elseif (-not $failed) { Pass 'the operation deadline is recorded at submission, with the op name (SS5)' }

# 4. the loop must decide on the deadline, not on a flat elapsed-time threshold
# The cleanup PAYLOAD moved to Wuu.Workers (Get-WuuJobCleanupPayload, SS8), so it is read from THAT file.
$workersRawT = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Workers.psm1'))
$loopIdx = $workersRawT.IndexOf('#Routine to handle completed runspaces')
$loopBodyT = if ($loopIdx -ge 0) { $workersRawT.Substring($loopIdx, [Math]::Min(60000, $workersRawT.Length - $loopIdx)) } else { '' }
if (-not $loopBodyT) {
    Fail 'could not locate the job cleanup loop (it should be the payload in src\Wuu.Workers.psm1)'
} else {
    if ($loopBodyT -match 'TotalMinutes -gt 10') {
        Fail 'the flat 10-minute stop is still present - healthy long operations would be killed (SS5)'
    }
    if ($loopBodyT -notmatch 'OperationTimeoutSeconds') {
        Fail 'the cleanup loop does not consult the per-op budget table'
    }
    if ($loopBodyT -notmatch 'TimeoutExpiresAt') {
        Fail 'the cleanup loop does not read the deadline recorded at submission'
    }
    if ($loopBodyT -notmatch 'StartTime\.AddSeconds\(\$budget\)') {
        Fail 'the cleanup loop has no start-time fallback - work not submitted through the single submission point would be unbounded'
    }
    if ($loopBodyT -notmatch 'Heartbeat') {
        Fail 'the cleanup loop records no heartbeat - slow and stuck would be indistinguishable'
    }
    if ($coreRawT -notmatch "SetVariable\('OperationTimeoutSeconds'") {
        Fail 'the per-op table is not injected into the cleanup runspace - the loop could not resolve any budget'
    }
    if (-not $failed) { Pass 'the cleanup loop enforces the per-op deadline with a bounded fallback and a heartbeat (SS5)' }
}

# 5. the trap: every OpState release must also clear the deadline
$idleSitesT = ([regex]::Matches($coreRawT, "OpState = 'Idle'")).Count
$clearSitesT = ([regex]::Matches($coreRawT, "TimeoutExpiresAt'\]\)\s*\{\s*\`$\w+\.TimeoutExpiresAt = \`$null")).Count
if ($idleSitesT -gt 0 -and $clearSitesT -lt $idleSitesT) {
    Fail "only $clearSitesT deadline clear site(s) for $idleSitesT OpState release site(s) - a stale deadline would make the NEXT operation expire immediately (SS5)"
} elseif ($idleSitesT -gt 0) {
    Pass "the operation deadline is cleared wherever the operation lock is released ($clearSitesT/$idleSitesT) (SS5)"
}

# (ac) WORKFLOW STATE IS NOT A DISPLAY STRING (brief SS8). Test-PhaseCompletion decided "is this row
#      settled?" from `UpdatesStatus -ne 'All updates installed'` - a DISPLAY string written from eight
#      sites with five different values. Two consequences, both real:
#
#        * re-wording a status message was a silent change to phase gating;
#        * 'Unknown' (set for a row LOADED FROM CONFIG in command mode, i.e. nothing has been checked
#          and there is nothing to report) was permanently "outstanding", so that row's phase could
#          never complete.
#
#      The check strips comments (including <# #> blocks) from the RAW text rather than using
#      Get-WuuCodeWithoutComments. Two reasons, both learned the hard way here: that tokenizer-based
#      helper joins every token with a space and DISCARDS newlines (so Get-WuuFunctionBody, which slices
#      to the next "\nfunction ", returned the whole file) and drops '$' (so a '\$state -in' pattern
#      could never match). Both produced false failures on correct code. Raw-minus-comments keeps both.
$wupdRawC = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw
$wupdBodyC = Get-WuuFunctionBody $wupdRawC 'Test-PhaseCompletion'
$wupdNoComments = Get-WuuTextWithoutComments -Text $wupdBodyC
if (-not $wupdNoComments) {
    Fail 'could not locate Test-PhaseCompletion'
} else {
    if ($wupdNoComments -match 'UpdatesStatus') {
        Fail 'the phase gate still reads UpdatesStatus - a display string is driving workflow gating (SS8)'
    }
    if ($wupdNoComments -notmatch 'CheckConcluded') {
        Fail 'the phase gate does not consult CheckConcluded - it has no workflow-state predicate (SS8)'
    }
    if ($wupdNoComments -notmatch '\$state -in') {
        Fail 'the phase gate does not distinguish mid-operation workflow states'
    }
    if (-not $failed) { Pass 'the phase gate decides from workflow state, not from a display string (SS8)' }
}

# The field must exist on the row, and must be THREE-state: $null has to stay distinguishable from
# $false, or "never checked" would be read as "checked and clean".
$stateRawW = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw
if ($stateRawW -notmatch 'CheckConcluded\s*=\s*\$null') {
    Fail 'CheckConcluded is not initialised to $null - "not established" must differ from "concluded clean" (SS8)'
} elseif (-not $failed) { Pass 'CheckConcluded is three-state ($null = not established) (SS8)' }

# The payload must SET it at every conclusion of a check, or the predicate never becomes non-null and
# the field is dead in the other direction.
$coreRawW = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$ccSets = ([regex]::Matches($coreRawW, "CheckConcluded'\]\)\s*\{\s*\`$\w+\.CheckConcluded\s*=\s*\`$(true|false)")).Count
if ($ccSets -lt 3) {
    Fail "only $ccSets CheckConcluded assignment(s) in the check payload - an outcome (updates available / reboot required / clean) would never be recorded (SS8)"
} elseif (-not $failed) { Pass "the check payload records CheckConcluded for all three outcomes ($ccSets sites) (SS8)" }

# (ad) CREDENTIAL PROPAGATION AND PERSISTENCE (brief SS6, which was marked NOT VERIFIED). Auditing it
#      found two real defects rather than a clean bill of health:
#
#        A. the saved credential block came from $global:CredentialConfig.Username/.Domain - a variable
#           assigned exactly ONCE in the codebase (its initialiser) - so every configuration recorded
#           Username='' while the real name sat in $global:CustomCredentials.UserName. Verified by
#           probe, not by reading.
#        B. nothing READ that block on load, so loading a list into a session with a different credential
#           mode silently changed which account remote operations would use.
#
#      The identity is now taken from the PSCredential and compared on load. What is persisted is
#      IDENTITY ONLY - never a password, or anything derived from one.
$credRawC = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Credentials.psm1') -Raw
# Comments are stripped - lines AND <# #> blocks - before the identity checks below, because the
# implementation explains the removal by quoting the old `$global:CredentialConfig.Username` read and
# its header says it "never handles a password". Matching raw text reported BOTH as defects (observed).
# This is the third time in this pass that a check matched its own explanatory comment, so the shared
# block-comment-aware helper is used rather than another ad-hoc line filter.
$credNoComments = Get-WuuTextWithoutComments -Text $credRawC

# 1. The signature must come from the PSCredential, not from the never-assigned CredentialConfig.
if ($credNoComments -notmatch 'function Get-WuuCredentialStateSignature') {
    Fail 'Get-WuuCredentialStateSignature is missing - SS6 has no single source for the credential identity'
} elseif ($credNoComments -notmatch 'CustomCredentials\.UserName') {
    Fail 'the credential signature does not read CustomCredentials.UserName - it would record an empty identity again (SS6)'
}
if ($credNoComments -match '\$global:CredentialConfig\.Username') {
    Fail 'the credential identity is still read from $global:CredentialConfig.Username, which is never assigned (SS6)'
}

# 2. Identity only. A password-shaped value must not be placed in the signature hashtable.
$sigBody = Get-WuuTextWithoutComments -Text (Get-WuuFunctionBody $credRawC 'Get-WuuCredentialStateSignature')
if ($sigBody) {
    if ($sigBody -match 'Password|SecureString|GetNetworkCredential|PtrToStringAuto') {
        Fail 'the credential signature handles password material - it must be identity only (SS6)'
    }
    if ($sigBody -notmatch 'Mode') {
        Fail 'the credential signature does not state the mode in words'
    }
}

# 3. The comparison must exist and be consulted by the load path, or the block stays write-only.
if ($credRawC -notmatch 'function Test-WuuCredentialStateMatches') {
    Fail 'Test-WuuCredentialStateMatches is missing - a saved credential mode could not be compared (SS6)'
}
if ($credRawC -notmatch "'Test-WuuCredentialStateMatches'") {
    Fail 'Test-WuuCredentialStateMatches is not exported'
}
if ($credRawC -notmatch "'Get-WuuCredentialStateSignature'") {
    Fail 'Get-WuuCredentialStateSignature is not exported (the save path could not reach it)'
}
if ($coreRawE -notmatch 'Test-WuuCredentialStateMatches') {
    Fail 'the config load path does not compare the saved credential mode - the saved block stays write-only (SS6)'
} elseif ($coreRawE -notmatch 'CREDENTIAL MODE DIFFERS') {
    Fail 'a credential-mode difference is not surfaced to the operator'
} else {
    if (-not $failed) { Pass 'credential identity is recorded from the PSCredential and compared on load (SS6)' }
}

# 4. The propagation matrix: the two remote task paths that CHANGE a machine must resolve and pass a
#    credential, and must skip resolution on the local machine (where the process token is already right
#    and passing credentials to local DCOM is rejected).
$passCount = ([regex]::Matches($coreRawE, "InvokeRemoteTaskScript[\s\S]{0,400}?Credential \`$remoteCred")).Count
if ($passCount -lt 2) {
    Fail "only $passCount remote-task call(s) pass the resolved credential - the download/install paths must both pass it (SS6)"
}
# PHASE 1 replaced the duplicated inline guard with a single rule in the resolver, so the gate now
# asserts the RULE EXISTS IN ONE PLACE rather than that it is repeated at the call sites. Both are
# acceptable; what is not acceptable is neither, or a fallback branch reappearing.
$guardCount = ([regex]::Matches($coreRawE, "UseCustomCredentials -and \`$Computer\.computer -ne 'localhost'")).Count
$wupdRawC = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw
$resolverHasLocalRule = [bool]($wupdRawC -match "\`$isLocal = \(\`$ComputerName -eq 'localhost' -or \`$ComputerName -eq \`$env:COMPUTERNAME\)")
if ($guardCount -eq 0 -and -not $resolverHasLocalRule) {
    Fail 'the local-machine rule is neither centralised in the resolver nor present at the call sites - custom credentials could be applied to the local host (SS6)'
}
if ($wupdRawC -notmatch '\[pscredential\]\$Cred') {
    Fail 'the credential probe is not typed [pscredential] - a plain-string password could be used as one (SS6)'
}
# PHASE 1 INVERSION. This gate used to REQUIRE a null cache entry ("caches the default-credentials
# outcome"), i.e. it demanded the very fallback that Phase 1 removes - a gate enforcing a defect. It
# now forbids the fallback on both sides, which is the property that actually matters.
$rsResolverC = [regex]::Match($wupdRawC, "SetVariable\('GetRemoteCredentialsScript', \[scriptblock\]::Create\(\{([\s\S]*?)\n        \}\.ToString\(\)\)\)").Groups[1].Value
$rsCodeC = Get-WuuTextWithoutComments -Text $rsResolverC
if ($rsCodeC -match "-ArgumentList @\(\`$ComputerName, \`$null\)") {
    Fail 'the runspace resolver probes the DEFAULT identity again - the silent credential fallback is back (Phase 1)'
}
if ($rsCodeC -match "CredentialCache\[\`$ComputerName\] = \`$null") {
    Fail "the resolver records a 'use default' cache entry again, so a silent fallback can occur (Phase 1)"
}
if ($rsCodeC -notmatch 'No fallback is attempted') {
    Fail 'the runspace resolver does not refuse explicitly when configured custom credentials are unusable (Phase 1)'
}
# ...and the module-side resolver must not fall back either: no default probe after a custom failure.
$credResolveBody = Get-WuuFunctionBody (Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Credentials.psm1') -Raw) 'Resolve-WuuOperationCredential'
$credResolveCode = Get-WuuTextWithoutComments -Text $credResolveBody
if ($credResolveCode -match 'Operation ''credential verification \(process identity\)''') {
    # A process-identity probe is legitimate ONLY on the Default path. It must be unreachable when the
    # mode is Custom, which is guaranteed by the mode being decided before any probe runs.
    $modeAt = $credResolveCode.IndexOf("`$mode = if (`$customConfigured")
    $probeAt = $credResolveCode.IndexOf("credential verification (process identity)")
    if ($modeAt -lt 0 -or $probeAt -lt 0 -or $modeAt -gt $probeAt) {
        Fail 'the module-side resolver can probe the process identity after deciding on custom credentials - the fallback shape (Phase 1)'
    }
}
if (-not $failed) {
    Pass 'credential identity is deterministic: no fallback on either side, and the local-machine rule in one place (Phase 1)'
}

# 5. No password in the logs or the audit trail. Matches password-shaped EXPRESSIONS, not the word
#    "password": four correct lines log that the secure PROMPT was unavailable and interpolate only the
#    exception text, and a word-match reported those as leaks (observed while writing the test).
$pwExpression = '\$(password|pass|pwd|plainPassword|plaintext|secret|sec)\b|\.Password\b|GetNetworkCredential|PtrToStringAuto|SecureStringToBSTR'
$leakFiles = @()
foreach ($candidate in @('Wuu.Core.psm1', 'Wuu.WindowsUpdate.psm1', 'Wuu.Credentials.psm1', 'Wuu.Remote.psm1')) {
    $text = Get-Content -LiteralPath (Join-Path $root "src\$candidate") -Raw
    $logLines = ($text -split "`r?`n") | Where-Object { $_ -match '(WriteWuuLog|Write-InfoLog|Write-DebugLog|Write-WarningLog|Write-ErrorLog)' }
    if (@($logLines | Where-Object { $_ -match $pwExpression }).Count -gt 0) { $leakFiles += $candidate }
}
if ($leakFiles.Count -gt 0) {
    Fail "password-shaped expression(s) interpolated into a log call in: $($leakFiles -join ', ') (SS6)"
} elseif (-not $failed) {
    Pass 'no log or audit call interpolates a password-shaped expression (SS6)'
}

# 6. The confirm field, for a passphrase that is being CHOSEN rather than proved. Every list in the
#    file shares one passphrase, so a typo while creating it produces a file that opens with NEITHER
#    entry - and a file the operator cannot identify, holding lists they can no longer read, is
#    indistinguishable from an empty one at the next load.
#
#    Two properties, because either alone is insufficient. The prompt must EXIST on the create path
#    (a rule nobody calls is not a rule), and it must be gated on the file NOT existing (a passphrase
#    already in use is proved by opening the file; asking again is friction, and in command mode it
#    is a prompt with nobody to answer it). The comparison itself must be case-SENSITIVE: PowerShell's
#    -eq is case-INSENSITIVE by default, so "Password1" and "password1" compare EQUAL and a real typo
#    passes the very check that exists to catch it.
$pwConfirmCode = Get-WuuTextWithoutComments -Text (Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Credentials.psm1') -Raw)
$saveConfirmCode = Get-WuuTextWithoutComments -Text $coreRawE
if ($pwConfirmCode -notmatch 'function Confirm-WuuPasswordPrompt') {
    Fail 'Confirm-WuuPasswordPrompt is missing - a passphrase could be saved with a typo in it (SS6)'
} elseif ($pwConfirmCode -notmatch "'Confirm-WuuPasswordPrompt'") {
    Fail 'Confirm-WuuPasswordPrompt is not exported, so the save path could not reach it (SS6)'
} elseif ($pwConfirmCode -notmatch 'plain1 -ceq \$plain2') {
    Fail 'the password comparison is not case-sensitive: -eq treats "Password1" and "password1" as EQUAL, so a real typo passes (SS6)'
} elseif ($saveConfirmCode -notmatch 'Confirm-WuuPasswordPrompt[\s\S]{0,240}?-ExistingFile') {
    Fail 'the save path does not confirm a passphrase being chosen, or does not gate it on the file existing (SS6)'
} elseif (-not $failed) {
    Pass 'a passphrase being chosen is confirmed, compared case-sensitively, and only when the file would be created (SS6)'
}

# (ae) -WHATIF REPORTS A PER-COMPUTER PLAN (brief SS11). `-WhatIf` printed one sentence ("would run
#      'install' against all computers"), which is not reviewable before a production change - and for
#      a RESTART it is wrong in the most expensive direction: a busy computer is NOT deferred for
#      restart/service (the request is dropped), so "would restart 10 servers" can be false for three
#      of them.
#
#      The plan states three facts per computer (what it would do, whether it is busy, and why), and the
#      policy must MATCH THE HANDLERS rather than be a second opinion: deferring verbs set Pending so
#      the request is honoured later, refusing verbs do not.
$cmdRawP = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Command.psm1') -Raw
$coreRawP = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw

if ($cmdRawP -notmatch 'function Get-WuuCommandPlan') {
    Fail 'Get-WuuCommandPlan is missing - -WhatIf cannot report a per-computer breakdown (SS11)'
} elseif ($cmdRawP -notmatch "'Get-WuuCommandPlan'") {
    Fail 'Get-WuuCommandPlan is not exported'
} elseif ($cmdRawP -notmatch 'function Write-WuuCommandPlan') {
    Fail 'Write-WuuCommandPlan is missing'
} elseif ($cmdRawP -notmatch 'Get-WuuCommandPlan -Verb \$Verb') {
    Fail 'the -WhatIf path does not call the planner - it still prints one sentence (SS11)'
} elseif (-not $failed) {
    Pass 'the -WhatIf path produces a per-computer plan (SS11)'
}

# The policy table, and its agreement with the handlers.
if ($cmdRawP -match "\`$Verb -in @\('restart', 'service'\)\)\s*\{\s*'refuse'") {
    Pass 'the plan refuses (rather than defers) for restart and service, matching the handlers (SS11)'
} else {
    Fail "the plan's busy policy is not refuse-for-restart/service - it could promise a reboot it will not perform (SS11)"
}
# Deferring handlers must actually set Pending, or the plan's 'queue' action is a lie.
#
# Two acceptable forms, and the SECOND one is why this check was widened: after the SS7 pending-policy
# work, a handler delegates to Set-WuuPendingOperation instead of assigning Pending itself. The
# invariant is unchanged - a deferred request must end up Pending - so it is now asserted in two
# halves: the handler routes through the policy, AND the policy sets Pending. Checking only for the
# literal assignment would have failed correct code (it did), and checking only for the function name
# would prove nothing at all.
#
# The state source is read HERE rather than reused from gate (aj), which is defined further down this
# file - referencing it would be $null at this point and the check would silently pass a broken
# invariant. (It failed loudly instead, which is how this was found.)
$stateRawP = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw
$handlerSetsPending = [bool]($coreRawP -match 'if \(Test-WuuComputerBusy -Row \$r\) \{[\s\S]{0,400}?\$r\.Pending = \$true')
$handlerUsesPolicy = [bool]($coreRawP -match "Set-WuuPendingOperation -Row \`$r -Op '(Download|InstallAndRecheck)'")
$policySetsPending = [bool]((Get-WuuFunctionBody $stateRawP 'Set-WuuPendingOperation') -match '\$Row\.Pending = \$true')
if ($handlerSetsPending -or ($handlerUsesPolicy -and $policySetsPending)) {
    Pass 'the deferring handlers really set Pending (directly or via the SS7 policy), so the plan''s queue action is truthful (SS11)'
} else {
    Fail "a deferring handler no longer sets Pending - the plan would claim a request is honoured later when it is dropped (SS11)"
}
# ...and the restart handler must NOT defer.
$restartHandlerP = [regex]::Match($coreRawP, '\$consoleActions\.EventRestartComputer = \{[\s\S]*?\n\}').Value
if ($restartHandlerP -and $restartHandlerP -notmatch '\$r\.Pending = \$true') {
    Pass 'the restart handler never defers a busy computer, matching the plan (SS11)'
} else {
    Fail 'the restart handler defers after all - the plan claims it refuses, and the operator is told the wrong thing (SS11)'
}
# The no-op test must be the handler's own condition, not an independent interpretation.
if ($cmdRawP -match '\$avail -eq \$dl' -and $coreRawP -match 'if \(\$r\.Available -eq \$r\.Downloaded\)') {
    Pass "the plan's no-op test matches the handler's own condition (SS11)"
} else {
    Fail "the plan and the download handler disagree about what 'nothing to do' means (SS11)"
}
# Unresolved names must be REPORTED, or a typo in a change ticket becomes a silent no-op.
if ($cmdRawP -match 'Unresolved = @\(\$unresolved\)' -and $cmdRawP -match 'NOT RESOLVED') {
    Pass 'names that resolve to nothing are reported rather than silently dropped (SS11)'
} else {
    Fail 'unmatched names are not reported - a typo in a change ticket would go unnoticed (SS11)'
}
# The resolution must mirror the real selection helper (exact, then UNIQUE prefix). An ambiguous prefix
# must resolve to nothing: guessing a computer during a dry run is worse than reporting the name.
if ($cmdRawP -match "\`$hits\.Count -eq 1\) \{ return \`$hits\[0\]") {
    Pass 'the plan resolves names the way the selection helper does (unique prefix only) (SS11)'
} else {
    Fail 'the plan resolves names differently from the real selection helper (SS11)'
}
# -WhatIf must stay a Success, and must not claim to have queued anything.
# Literal match (no regex): the pattern contains '$true', '.', and a ';' - as a regex the unescaped
# escape sequence '\T' is an ArgumentException, which is how this gate first reported itself.
if ($cmdRawP.Contains("WhatIf = `$true; Would = `$plan.Detail; Result = 'Success'")) {
    Pass '-WhatIf still classifies as Success and never as Queued (SS10/SS11)'
} else {
    Fail '-WhatIf no longer reports Result=Success'
}
# ...and it must write NO audit record. A simulation is not a denied attempt, and mixing plans into the
# trail would make 'refused to make this change' indistinguishable from 'asked what it would do'. This
# is also asserted by tests\Test-AuditTrail.ps1, so the contract has two guards.
$whatIfBody = [regex]::Match($cmdRawP, 'if \(\$WhatIf -and \$entry\.Mutating\) \{[\s\S]*?\n    \}').Value
if ($whatIfBody -and $whatIfBody -notmatch 'Write-WuuAuditRecord' -and $whatIfBody -notmatch 'Start-WuuAuditSession') {
    Pass '-WhatIf writes no audit record: the trail records changes, not simulations (SS11)'
} else {
    Fail '-WhatIf writes audit records - simulations must not enter the compliance trail (SS11)'
}
# The JSON must be RETURNED, not emitted on the output stream. Emitting it made the call return two
# objects (measured); the exit code survived only because PowerShell member-enumerates across arrays,
# which is luck rather than design.
if ($cmdRawP -match '\$jsonText = \$null' -and $cmdRawP -match 'Plan = \$plan; Json = \$jsonText') {
    Pass 'the -WhatIf -Json output is returned on the result object, not emitted as a second object (SS11)'
} else {
    Fail 'the -WhatIf -Json path emits the JSON on the output stream - callers would receive two objects (SS11)'
}
