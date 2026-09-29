#Requires -Version 5.1
<#
.SYNOPSIS
    SS10: the exit-code contract.

.DESCRIPTION
    Three things are asserted, and they are asserted against the PRODUCTION paths rather than a
    re-implementation:

      1. Get-WuuExitCode returns the documented number for every documented name. A test that
         re-listed the numbers here would pass forever while the real function drifted.
      2. Invoke-WuuCommand CLASSIFIES outcomes, so a caller can map them to codes. The previous
         code collapsed five distinct situations into "Ok = false".
      3. The Core exit path maps "work still outstanding" to a TIMEOUT, not to success, and maps
         it to QUEUED only when -Async was asked for. This is the actual defect SS10 names:
         `wuu install` used to exit 0 while the install was merely queued.

    (3) is checked statically. Running the whole console shell in a test would need elevation,
    a live WSUS target and minutes - the static check is what a validator gate can enforce on
    every build, and it fails if the ordering or the -Async condition is removed.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail++ }

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force -DisableNameChecking
# Import-WuuModules (not a bare Import-Module) so the whole set is loaded with -Global the way
# the application does it. Importing Wuu.Command alone left the audit helpers absent, which
# turned a legitimate refusal into an unhandled CommandNotFound inside its best-effort logger.
Import-WuuModules -WuuRoot $root

# --- 1. the vocabulary --------------------------------------------------------------
$expected = @{
    Success         = 0
    OperationFailed = 1
    UsageError      = 2
    Timeout         = 3
    PartialSuccess  = 4
    AuditFailure    = 5
    Queued          = 6
    Refused         = 7
}
foreach ($name in $expected.Keys) {
    $got = Get-WuuExitCode -Result $name
    if ($got -eq $expected[$name]) {
        Ok "exit code $name = $($expected[$name])"
    } else {
        Bad "exit code $name = $got (expected $($expected[$name]))"
    }
}

$codesUsed = @($expected.Values | Sort-Object -Unique)
if ($codesUsed.Count -eq 8) {
    Ok 'all eight codes are distinct'
} else {
    Bad "codes are not distinct: $($codesUsed -join ',')"
}

# Every code must have a human-readable meaning, or a non-zero exit is unexplained.
$meaningless = @()
foreach ($c in 0..7) {
    $m = Get-WuuExitCodeMeaning -Code $c
    if (-not $m -or $m -match '^unknown') { $meaningless += $c }
}
if ($meaningless.Count -eq 0) {
    Ok 'every code 0-7 has a meaning'
} else {
    Bad "codes with no meaning: $($meaningless -join ',')"
}
if ((Get-WuuExitCodeMeaning -Code 999) -match '^unknown') {
    Ok 'an out-of-range code is reported as unknown, not silently mapped'
} else {
    Bad 'an out-of-range code was not reported as unknown'
}

# The names are the contract: renaming one silently changes what a script branches on.
$names = @(Get-Command Get-WuuExitCode).Parameters['Result'].Attributes |
    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
    ForEach-Object { $_.ValidValues }
$missing = @($expected.Keys | Where-Object { $_ -notin $names })
if ($missing.Count -eq 0) {
    Ok 'ValidateSet accepts exactly the documented names'
} else {
    Bad "ValidateSet is missing: $($missing -join ',')"
}

# --- 2. classification --------------------------------------------------------------
# A usage error must be distinguishable from a failed operation. Both used to be Ok=$false.
$r = Invoke-WuuCommand -Verb 'definitely-not-a-verb' -Actions @{} -Store @{}
if ($r.Result -eq 'UsageError' -and -not $r.Ok) {
    Ok 'unknown verb classifies as UsageError, not OperationFailed'
} else {
    Bad "unknown verb classified as '$($r.Result)'"
}

$r = Invoke-WuuCommand -Verb 'show' -Actions @{} -Store @{} -SubVerb 'nonsense'
if ($r.Result -eq 'UsageError') {
    Ok 'wuu show with a bad subverb classifies as UsageError'
} else {
    Bad "wuu show bad subverb classified as '$($r.Result)'"
}

$r = Invoke-WuuCommand -Verb 'audit' -Actions @{} -Store @{} -SubVerb 'nonsense'
if ($r.Result -eq 'UsageError') {
    Ok 'wuu audit with a bad subverb classifies as UsageError'
} else {
    Bad "wuu audit bad subverb classified as '$($r.Result)'"
}

$r = Invoke-WuuCommand -Verb 'config' -Actions @{} -Store @{} -SubVerb 'nonsense'
if ($r.Result -eq 'UsageError') {
    Ok 'wuu config with a bad subverb classifies as UsageError'
} else {
    Bad "wuu config bad subverb classified as '$($r.Result)'"
}

# Refusal (missing -Reason) is its own outcome: a policy decision, and nothing ran.
$actions = @{ EventInstallUpdates = { throw 'MUST NOT RUN - the refusal must come first' } }
$r = Invoke-WuuCommand -Verb 'install' -Actions $actions -Store @{} -Computer 'SRV01'
if ($r.Result -eq 'Refused' -and $r.NeedsReason) {
    Ok 'a mutating verb without -Reason classifies as Refused and does not run'
} else {
    Bad "missing -Reason classified as '$($r.Result)' (NeedsReason=$($r.NeedsReason))"
}

# -WhatIf must stay a SUCCESS: it correctly did what was asked (report intent).
$r = Invoke-WuuCommand -Verb 'install' -Actions $actions -Store @{} -Computer 'SRV01' -WhatIf
if ($r.Ok -and $r.WhatIf) {
    Ok '-WhatIf stays Ok (and reports its intent)'
} else {
    Bad '-WhatIf did not report success'
}

# A read verb that succeeds must report Success so the caller exits 0.
$actions = @{ EventGetUpdates = { 'ran' } }
$r = Invoke-WuuCommand -Verb 'check' -Actions $actions -Store @{} -Computer 'SRV01'
if ($r.Ok -and $r.Result -eq 'Success') {
    Ok 'a read verb reports Result=Success'
} else {
    Bad "read verb reported Result='$($r.Result)'"
}

# A handler that throws is an operation failure - NOT a usage error, and not an audit failure.
$actions = @{ EventGetUpdates = { throw 'boom' } }
$r = Invoke-WuuCommand -Verb 'check' -Actions $actions -Store @{} -Computer 'SRV01'
if (-not $r.Ok -and $r.Result -eq 'OperationFailed') {
    Ok 'a throwing handler classifies as OperationFailed'
} else {
    Bad "throwing handler classified as '$($r.Result)'"
}

# --- 3. the Core exit path (static) -------------------------------------------------
# Static because the alternative is driving the real shell. Each assertion is anchored on text
# that only exists for this behaviour, so deleting the behaviour fails the test.
function Get-WuuRaw([string]$name) {
    Get-Content -LiteralPath (Join-Path $root "src\$name") -Raw
}
$coreRaw = Get-WuuRaw 'Wuu.Core.psm1'

# `-Async` must be threaded through from the parsed options, or the flag quietly does nothing.
if ($coreRaw -match '-Async:\$parsed\.Options\[''Async''\]') {
    Ok 'Core forwards -Async from the parsed options'
} else {
    Bad 'Core does not forward -Async (the flag would be parsed and ignored)'
}

# Outstanding work must be measured from the STORE's rows (OpState/Pending), never from a
# presentation object - that substitution is the defect class this whole pass removes.
# NOTE: these patterns are SINGLE-quoted. In a double-quoted string `$busy` would interpolate to
# empty and a trailing backslash would be an illegal pattern - both produced false failures here.
if ($coreRaw -match '\.OpState -eq ''Running''' -and $coreRaw -match '\$_\.Pending') {
    Ok 'outstanding work is measured from row OpState/Pending'
} else {
    Bad 'outstanding work is not measured from the store rows'
}

# Timeout must be produced, and produced from the timeout code - not from a bare "1".
if ($coreRaw -match "Get-WuuExitCode -Result 'Timeout'") {
    Ok 'unfinished work produces the Timeout code'
} else {
    Bad 'unfinished work does not produce the Timeout code'
}

# Queued must require -Async. The guard is the whole point of SS10: without it, "accepted"
# would be reported as success again.
if ($coreRaw -match "Get-WuuExitCode -Result 'Queued'") {
    Ok 'queued work produces the Queued code'
} else {
    Bad 'queued work does not produce the Queued code'
}
$queuedGuard = [regex]::Matches($coreRaw, 'Async''\]\s*-and\s*\$busy')
if ($queuedGuard.Count -ge 1) {
    Ok 'the Queued code is gated on -Async'
} else {
    Bad 'the Queued code is not gated on -Async'
}

# A non-Ok result must be mapped through its classification, with OperationFailed as fallback.
if ($coreRaw -match 'Get-WuuExitCode -Result \$result\.Result' -and $coreRaw -match "Get-WuuExitCode -Result 'OperationFailed'") {
    Ok 'non-Ok results map through their classification with an OperationFailed fallback'
} else {
    Bad 'non-Ok results are not mapped through their classification'
}

# The timeout branch must come FIRST. If -not $result.Ok were tested first, a command that
# reported Ok but left work running would be classified by the result object alone.
$iTimeout = $coreRaw.IndexOf("Get-WuuExitCode -Result 'Timeout'")
$iNotOk   = $coreRaw.IndexOf('elseif (-not $result.Ok)')
if ($iTimeout -gt 0 -and $iNotOk -gt 0 -and $iTimeout -lt $iNotOk) {
    Ok 'the timeout branch is evaluated before the result-object branch'
} else {
    Bad "branch order is wrong (timeout at $iTimeout, not-ok at $iNotOk)"
}

# The code must be assigned unconditionally, so a success CLEARS any earlier value rather than
# leaving a stale non-zero code in place.
if ($coreRaw -match '\$script:CommandExitCode = \$exitCode') {
    Ok 'the exit code is assigned unconditionally'
} else {
    Bad 'the exit code is not assigned unconditionally (a stale code could persist)'
}

# The audit-chain check used to set $script:CommandExitCode from INSIDE Wuu.Command.psm1, which
# is that module's script scope - not the caller's - so it never reached the exit path.
$cmdRaw = Get-WuuRaw 'Wuu.Command.psm1'
if ($cmdRaw -notmatch '\$script:CommandExitCode\s*=') {
    Ok 'audit verify no longer sets a dead script-scope variable'
} else {
    Bad 'audit verify still sets $script:CommandExitCode in the wrong scope'
}
if ($cmdRaw -match "'AuditFailure'") {
    Ok 'audit-integrity failures carry their own classification'
} else {
    Bad 'audit-integrity failures are not classified'
}

# Every verb option the parser accepts must be consumed by somebody, or it is a silent no-op.
if ($cmdRaw -match "'-async'\s*=\s*'Async'") {
    Ok 'the parser recognises -Async'
} else {
    Bad 'the parser does not recognise -Async (it would be reported as a typo)'
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'Test-CommandExitCodes.ps1: ALL PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host "Test-CommandExitCodes.ps1: $fail FAILURE(S)" -ForegroundColor Red
    exit 1
}
