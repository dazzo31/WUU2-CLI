#Requires -Version 5.1
<#
.SYNOPSIS
    SS11: -WhatIf reports a per-computer plan, not one sentence.

.DESCRIPTION
    `-WhatIf` used to print "would run 'install' against all computers" and stop there. That is not
    reviewable before a production change, and it is WRONG in the most expensive direction for a
    restart: a busy computer is not deferred for `restart` (the operator explicitly confirmed it) or
    for `service` - the request is dropped - so "would restart 10 servers" can be false for three of
    them.

    Asserted here:
      1. every computer is listed, with the action it would take;
      2. a busy computer is 'queue' for the deferring verbs and 'skip' for the refusing ones;
      3. a download with nothing to fetch is 'noop', matching the handler's own no-op test;
      4. an install with nothing downloaded is 'noop';
      5. names that resolve to nothing are REPORTED, not silently dropped;
      6. resolution mirrors Read-WuuSelection (exact, then unique prefix; ambiguous is unresolved);
      7. the totals add up and the plan reflects the real policy per verb;
      8. -WhatIf still changes NOTHING and still classifies as Success (SS10);
      9. -Json and -Async interact correctly with the dry run.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:fail++ }

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force -DisableNameChecking
Import-WuuModules -WuuRoot $root

$cmdRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Command.psm1') -Raw
$coreRaw = Get-Content -LiteralPath (Join-Path $root 'src\Wuu.Core.psm1') -Raw

function New-PlanStore {
    $s = New-WuuStateStore
    return $s
}
function Add-Row {
    param($Store, [string]$Name, [hashtable]$Props)
    $r = New-WuuComputerRow -Computer $Name
    $r.Pending = $false
    if ($Props) { foreach ($k in $Props.Keys) { $r.$k = $Props[$k] } }
    Add-WuuComputerRow -Store $Store -Row $r | Out-Null
    return $r
}

# --- 1. every computer is listed with its action -------------------------------------
$store = New-PlanStore
Add-Row $store 'SRV01' @{ Available = 3; Downloaded = 0; State = 'UpdatesFound' } | Out-Null
Add-Row $store 'SRV02' @{ Available = 0; Downloaded = 0; State = 'Complete' } | Out-Null
$plan = Get-WuuCommandPlan -Verb 'install' -Store $store -All
if ($plan.Targets.Count -eq 2) { Ok 'the plan lists every selected computer' }
else { Bad "the plan listed $($plan.Targets.Count) of 2 computers" }
if ($plan.Selected -eq 2 -and $plan.Targets.Count -eq $plan.Selected) {
    Ok 'the Selected count matches the listed targets'
} else {
    Bad "Selected=$($plan.Selected) but Targets=$($plan.Targets.Count)"
}

# --- 2. busy policy per verb ----------------------------------------------------------
# SRV01 is downloading; SRV02 is idle and has nothing downloaded.
$store = New-PlanStore
Add-Row $store 'SRV01' @{ OpState = 'Running'; Downloaded = 2; Available = 3 } | Out-Null
Add-Row $store 'SRV02' @{ OpState = 'Idle'; Downloaded = 0; Available = 0; State = 'Complete' } | Out-Null

$checkPlan = Get-WuuCommandPlan -Verb 'check' -Store $store -All
$t1 = @($checkPlan.Targets | Where-Object { $_.Computer -eq 'SRV01' })[0]
if ($t1.Action -eq 'queue' -and $checkPlan.Policy -eq 'defer') {
    Ok 'a busy computer is QUEUED for a deferring verb (check) - the request is honoured, later'
} else {
    Bad "check on a busy computer gave Action='$($t1.Action)' Policy='$($checkPlan.Policy)'"
}
if ($checkPlan.WouldQueue -eq 1 -and $checkPlan.WouldRun -eq 1) {
    Ok 'the totals separate queued from would-run'
} else {
    Bad "totals wrong: run=$($checkPlan.WouldRun) queue=$($checkPlan.WouldQueue)"
}

# THE assertion that matters most: a restart must NOT be reported as "would restart all of them".
$restartPlan = Get-WuuCommandPlan -Verb 'restart' -Store $store -All
$t1 = @($restartPlan.Targets | Where-Object { $_.Computer -eq 'SRV01' })[0]
if ($t1.Action -eq 'skip' -and $restartPlan.Policy -eq 'refuse') {
    Ok 'a busy computer is SKIPPED for restart - a confirmed reboot is never silently deferred'
} else {
    Bad "restart on a busy computer gave Action='$($t1.Action)' Policy='$($restartPlan.Policy)'"
}
if ($restartPlan.WouldSkip -eq 1 -and $restartPlan.WouldRun -eq 1) {
    Ok 'the restart plan reports 1 would-run and 1 would-be-SKIPPED (not "2 restarts")'
} else {
    Bad "restart totals wrong: run=$($restartPlan.WouldRun) skip=$($restartPlan.WouldSkip)"
}
if ($t1.Reason -match 'never silently deferred') {
    Ok 'the skip reason explains why a restart is not deferred'
} else {
    Bad "the restart skip reason is uninformative: '$($t1.Reason)'"
}
# ...and service refuses too, with its own wording.
$svcPlan = Get-WuuCommandPlan -Verb 'service' -Store $store -All -ServiceAction 'restart'
$t1 = @($svcPlan.Targets | Where-Object { $_.Computer -eq 'SRV01' })[0]
if ($t1.Action -eq 'skip' -and $svcPlan.Policy -eq 'refuse') {
    Ok 'a busy computer is SKIPPED for a service action (matching the handler)'
} else {
    Bad "service on a busy computer gave Action='$($t1.Action)' Policy='$($svcPlan.Policy)'"
}
# A Pending row counts as busy, not just OpState=Running.
$store2 = New-PlanStore
Add-Row $store2 'SRV03' @{ OpState = 'Idle'; Pending = $true } | Out-Null
$p = Get-WuuCommandPlan -Verb 'check' -Store $store2 -All
if ($p.Targets[0].Action -eq 'queue' -and $p.Targets[0].Busy) {
    Ok 'a Pending row is treated as busy (the scheduler queue is not idle capacity)'
} else {
    Bad "a Pending row gave Action='$($p.Targets[0].Action)' Busy=$($p.Targets[0].Busy)"
}

# --- 3. download no-op ---------------------------------------------------------------
$store = New-PlanStore
$null = Add-Row $store 'SRV10' @{ Available = 0; Downloaded = 0 }
$null = Add-Row $store 'SRV11' @{ Available = 4; Downloaded = 4 }
$null = Add-Row $store 'SRV12' @{ Available = 4; Downloaded = 1 }
$p = Get-WuuCommandPlan -Verb 'download' -Store $store -All
$a10 = @($p.Targets | Where-Object { $_.Computer -eq 'SRV10' })[0]
$a11 = @($p.Targets | Where-Object { $_.Computer -eq 'SRV11' })[0]
$a12 = @($p.Targets | Where-Object { $_.Computer -eq 'SRV12' })[0]
if ($a10.Action -eq 'noop' -and $a10.Reason -match 'no updates available') {
    Ok 'a download with no updates available is a noop, with the reason stated'
} else {
    Bad "SRV10 (0 available) gave '$($a10.Action)': $($a10.Reason)"
}
if ($a11.Action -eq 'noop' -and $a11.Reason -match 'already downloaded') {
    Ok 'a download where everything is already downloaded is a noop'
} else {
    Bad "SRV11 (4/4) gave '$($a11.Action)': $($a11.Reason)"
}
if ($a12.Action -eq 'run') {
    Ok 'a download with work remaining is a real run'
} else {
    Bad "SRV12 (4 available, 1 downloaded) gave '$($a12.Action)' - it has work to do"
}
if ($p.WouldNoOp -eq 2 -and $p.WouldRun -eq 1) {
    Ok "the totals report 2 pointless downloads out of 3 (would-run=$($p.WouldRun), noop=$($p.WouldNoOp))"
} else {
    Bad "download totals wrong: run=$($p.WouldRun) noop=$($p.WouldNoOp)"
}
# The no-op test must match the HANDLER's own condition, or the dry run lies in the other direction.
if ($coreRaw -match 'if \(\$r\.Available -eq \$r\.Downloaded\)') {
    Ok "the plan's no-op test matches the handler's own condition (\$r.Available -eq \$r.Downloaded)"
} else {
    Bad 'the handler no longer tests Available -eq Downloaded - the plan and the handler have diverged'
}

# --- 4. install no-op ----------------------------------------------------------------
$store = New-PlanStore
$null = Add-Row $store 'SRV20' @{ Downloaded = 0; Available = 0 }
$null = Add-Row $store 'SRV21' @{ Downloaded = 2; Available = 2 }
$p = Get-WuuCommandPlan -Verb 'install' -Store $store -All
$a20 = @($p.Targets | Where-Object { $_.Computer -eq 'SRV20' })[0]
$a21 = @($p.Targets | Where-Object { $_.Computer -eq 'SRV21' })[0]
if ($a20.Action -eq 'noop' -and $a20.Reason -match 'nothing downloaded') {
    Ok 'an install with nothing downloaded is a noop'
} else {
    Bad "SRV20 gave '$($a20.Action)': $($a20.Reason)"
}
if ($a21.Action -eq 'run') { Ok 'an install with downloads pending is a real run' } else { Bad "SRV21 gave '$($a21.Action)'" }

# --- 5. unresolved names are reported, never silently dropped -------------------------
$store = New-PlanStore
Add-Row $store 'SRV30' @{ Available = 0; Downloaded = 0 } | Out-Null
$p = Get-WuuCommandPlan -Verb 'check' -Store $store -Computer 'SRV30,SRV99'
if ($p.Unresolved.Count -eq 1 -and $p.Unresolved[0] -eq 'SRV99') {
    Ok 'an unmatched name is listed in Unresolved (a typo in a change ticket is caught by the dry run)'
} else {
    Bad "Unresolved wrong: $($p.Unresolved -join ',')"
}
if ($p.Targets.Count -eq 1 -and $p.Targets[0].Computer -eq 'SRV30') {
    Ok 'the resolvable name is still planned alongside the unresolved one'
} else {
    Bad "Targets wrong: $(($p.Targets | ForEach-Object { $_.Computer }) -join ',')"
}

# --- 6. resolution mirrors Read-WuuSelection -----------------------------------------
$store = New-PlanStore
Add-Row $store 'WEB01' @{ Available = 0; Downloaded = 0 } | Out-Null
Add-Row $store 'WEB02' @{ Available = 0; Downloaded = 0 } | Out-Null
# case-insensitive exact
$p = Get-WuuCommandPlan -Verb 'check' -Store $store -Computer 'web01'
if ($p.Targets.Count -eq 1 -and $p.Targets[0].Computer -eq 'WEB01') { Ok 'exact match is case-insensitive (as Read-WuuSelection is)' }
else { Bad "case-insensitive exact match failed: $(($p.Targets | ForEach-Object { $_.Computer }) -join ',')" }
# ambiguous prefix -> unresolved, NOT a guess
$p = Get-WuuCommandPlan -Verb 'check' -Store $store -Computer 'WEB'
if ($p.Targets.Count -eq 0 -and $p.Unresolved.Count -eq 1) {
    Ok 'an AMBIGUOUS prefix resolves to nothing rather than guessing a computer (mirrors Read-WuuSelection)'
} else {
    Bad "ambiguous prefix planned $(($p.Targets | ForEach-Object { $_.Computer }) -join ',') - it must not guess"
}
# unique prefix -> resolves
$store3 = New-PlanStore
Add-Row $store3 'WEB01' @{ Available = 0; Downloaded = 0 } | Out-Null
Add-Row $store3 'DB01' @{ Available = 0; Downloaded = 0 } | Out-Null
$p = Get-WuuCommandPlan -Verb 'check' -Store $store3 -Computer 'WEB'
if ($p.Targets.Count -eq 1 -and $p.Targets[0].Computer -eq 'WEB01') { Ok 'a UNIQUE prefix resolves (as Read-WuuSelection does)' }
else { Bad "unique prefix did not resolve: $(($p.Targets | ForEach-Object { $_.Computer }) -join ',')" }
# "all"/"*" still select everything
$p = Get-WuuCommandPlan -Verb 'check' -Store $store3 -Computer '*'
if ($p.Targets.Count -eq 2) { Ok "'*' selects every computer, as the selection helper does" } else { Bad "'*' selected $($p.Targets.Count) of 2" }

# --- 7. the plan is honest about a verb it has no no-op rule for ----------------------
# 'phase' and 'prune' have no per-computer no-op condition: every target is a real action. The plan
# must not invent one.
$p = Get-WuuCommandPlan -Verb 'phase' -Store $store3 -All -Set 2
if ($p.WouldRun -eq 2 -and $p.WouldNoOp -eq 0) {
    Ok 'a verb with no no-op rule reports every target as a real run'
} else {
    Bad "phase plan invented a no-op: run=$($p.WouldRun) noop=$($p.WouldNoOp)"
}

# --- 8. -WhatIf changes nothing and is a Success -------------------------------------
$store = New-PlanStore
Add-Row $store 'SRV40' @{ Available = 5; Downloaded = 0 } | Out-Null
$actions = @{ EventInstallUpdates = { throw 'MUST NOT RUN - -WhatIf must not call the handler' } }
$r = Invoke-WuuCommand -Verb 'install' -Actions $actions -Store $store -Computer 'SRV40' -WhatIf
if ($r.Ok -and $r.WhatIf -and $r.Result -eq 'Success') {
    Ok '-WhatIf reports success, change nothing, and never calls the handler'
} else {
    Bad "-WhatIf returned Ok=$($r.Ok) WhatIf=$($r.WhatIf) Result='$($r.Result)'"
}
# Nothing in the store was touched.
$rowAfter = Get-WuuComputerRow -Store $store -Computer 'SRV40'
if ($rowAfter.Available -eq 5 -and $rowAfter.Downloaded -eq 0 -and -not $rowAfter.Pending -and $rowAfter.OpState -eq 'Idle') {
    Ok 'the store is untouched by a dry run (counts, Pending and OpState all unchanged)'
} else {
    Bad "the dry run mutated the row: Available=$($rowAfter.Available) Downloaded=$($rowAfter.Downloaded) Pending=$($rowAfter.Pending) OpState=$($rowAfter.OpState)"
}
if ($r.Plan -and $r.Plan.Targets.Count -eq 1) {
    Ok 'the result carries the plan object for a caller that wants it'
} else {
    Bad 'the result does not carry the plan object'
}
# A dry run writes NO audit record. This is asserted by tests\Test-AuditTrail.ps1 as well, and it is
# deliberate: a SIMULATION is not a denied attempt, and mixing plans into the trail degrades it as
# evidence (an auditor could not distinguish "refused to make this change" from "asked what it would
# do" - and 'declined' would be misleading, since nothing was declined).
# I briefly added an audit record here on the strength of the brief saying -WhatIf is "audited
# already"; the measurement says it is not, so that argument rested on a mistaken premise.
$auditDir = Get-WuuAuditDirectory
$todayLog = Join-Path $auditDir ("audit-{0}.jsonl" -f (Get-Date -Format 'yyyy-MM-dd'))
$beforeLines = if (Test-Path -LiteralPath $todayLog) { @(Get-Content -LiteralPath $todayLog).Count } else { 0 }
$null = Invoke-WuuCommand -Verb 'install' -Actions $actions -Store $store -Computer 'SRV40' -WhatIf
$afterLines = if (Test-Path -LiteralPath $todayLog) { @(Get-Content -LiteralPath $todayLog).Count } else { 0 }
if ($afterLines -eq $beforeLines) {
    Ok 'a dry run writes NO audit record - the trail stays a record of changes, not of simulations'
} else {
    Bad "a dry run wrote $($afterLines - $beforeLines) audit record(s) - simulations must not enter the trail"
}

# --- 9. -Json and -Async ---------------------------------------------------------------
# The JSON must come back on the OBJECT, not as a second pipeline element. Emitting it on the output
# stream made this call return TWO objects (measured). NOTE the exit-code symptom was MASKED, and the
# reason is worth knowing: Core reads `$result.Ok`, which on a bare string is $null (so -not $null =
# $true = failure) - but PowerShell member-enumerates across an ARRAY, so the psobject element's Ok was
# found and the code stayed 0. Luck, not design. Asserted here so it cannot regress to two objects.
$jsonResult = Invoke-WuuCommand -Verb 'install' -Actions $actions -Store $store -Computer 'SRV40' -WhatIf -Json
$obj = $null
if ($jsonResult.Json) { try { $obj = $jsonResult.Json | ConvertFrom-Json } catch { } }
if ($obj -and $obj.WhatIf -and $obj.PSObject.Properties['WouldSkip']) {
    Ok '-WhatIf -Json emits machine-readable plan fields (WouldRun/WouldQueue/WouldSkip/WouldNoOp)'
} else {
    Bad '-WhatIf -Json did not emit the plan fields'
}
if (@($jsonResult).Count -eq 1 -and $jsonResult.Ok) {
    Ok 'the -Json path returns exactly ONE object that still carries Ok (so the exit code stays correct)'
} else {
    Bad "the -Json path returned $(@($jsonResult).Count) object(s) - Core's exit-code logic needs a single Ok-bearing result"
}
# -Async must not change a dry run: nothing is accepted for later, so it stays Success (0),
# never Queued (6). A dry run that reported Queued would be a claim to have queued work.
$async = Invoke-WuuCommand -Verb 'install' -Actions $actions -Store $store -Computer 'SRV40' -WhatIf -Async
if ($async.Result -eq 'Success' -and -not $async.PSObject.Properties['Queued']) {
    Ok "-WhatIf -Async stays Success - nothing was accepted for later, so 'Queued' would be a false claim"
} else {
    Bad "-WhatIf -Async returned Result='$($async.Result)'"
}

# --- 10. the policy is data, and it matches the handlers -----------------------------
# The handlers are the source of truth for defer-vs-refuse; the planner must not invent a third policy.
foreach ($pair in @(
        @{ Verb = 'check';    Policy = 'defer' },
        @{ Verb = 'download'; Policy = 'defer' },
        @{ Verb = 'install';  Policy = 'defer' },
        @{ Verb = 'restart';  Policy = 'refuse' },
        @{ Verb = 'service';  Policy = 'refuse' })) {
    $p = Get-WuuCommandPlan -Verb $pair.Verb -Store $store3 -All
    if ($p.Policy -eq $pair.Policy) {
        Ok "$($pair.Verb) plans with policy '$($p.Policy)', matching the handler"
    } else {
        Bad "$($pair.Verb) planned policy '$($p.Policy)', handler uses '$($pair.Policy)'"
    }
}
# ...and the handlers really do defer/refuse as claimed. Deferring verbs set Pending; refusing verbs
# must NOT (a deferred request that sets no Pending is lost, and a refused restart that sets Pending
# would reboot a machine the operator was told was skipped).
$deferBody = [regex]::Match($coreRaw, '\$consoleActions\.EventDownloadUpdates = \{[\s\S]*?\n\}').Value
# SINGLE-quoted pattern. In a double-quoted string `$r` INTERPOLATES, and `$r` holds a command result
# object in this test - so the pattern became garbage and the check failed on correct code. PowerShell
# escapes with a backtick, not a backslash, so `\.` alone does not protect a `$`.
#
# TWO ACCEPTABLE FORMS, because the SS7 pending-policy work moved the assignment out of the handler:
# the handler may assign Pending/PendingOp itself, OR it may delegate to Set-WuuPendingOperation (which
# sets both). Asserting only the literal form failed CORRECT code; asserting only the function name
# would prove nothing. The invariant is unchanged: a deferred request must end up Pending.
$deferDirect = ($deferBody -match '\$r\.Pending = \$true' -and $deferBody -match "\`$r\.PendingOp = 'Download'")
# The policy lives in Wuu.State, so read it from there - this test only loads Wuu.Core.
$pendingPolicyBody = [regex]::Match((Get-Content -LiteralPath (Join-Path $root 'src\Wuu.State.psm1') -Raw), 'function Set-WuuPendingOperation[\s\S]*?\n\}').Value
$deferViaPolicy = ($deferBody -match "Set-WuuPendingOperation -Row \`$r -Op 'Download'") -and
                  ($pendingPolicyBody -match '\$Row\.PendingOp = \$Op') -and
                  ($pendingPolicyBody -match '\$Row\.Pending = \$true')
if ($deferDirect -or $deferViaPolicy) {
    Ok 'the download handler really defers (sets Pending + PendingOp, directly or via the SS7 policy) - the plan is truthful'
} else {
    Bad 'the download handler does not defer - the plan claims it does'
}
$restartBody = [regex]::Match($coreRaw, '\$consoleActions\.EventRestartComputer = \{[\s\S]*?\n\}').Value
if ($restartBody -notmatch '\$r\.Pending = \$true') {
    Ok 'the restart handler really refuses a busy computer (sets no Pending) - the plan is truthful'
} else {
    Bad 'the restart handler defers after all - the plan claims it refuses'
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'Test-WhatIfPlan.ps1: ALL PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host "Test-WhatIfPlan.ps1: $fail FAILURE(S)" -ForegroundColor Red
    exit 1
}
