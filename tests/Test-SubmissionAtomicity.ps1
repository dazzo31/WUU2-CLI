# Test: atomic concurrency-slot reservation (hardening brief SS4).
#
# WHY THIS SUITE EXISTS
# ---------------------
# The global cap was ENFORCED at the top of Start-UpdateCheckJob but CONSUMED 141 lines later, at
# `$jobs.Add`. Two submissions that overlapped that span both read the same `$jobs.Count` and both
# admitted, so a cap of 10 could run 12 and the overshoot grew with the work in between (runspace
# creation, pipeline composition, the identity claim). The invariant is not "the cap is checked" but
# "the cap is checked in the same indivisible step that consumes a slot".
#
# This suite asserts:
#   1. the primitive really does exclude across THREADS (not just that a function is called)
#   2. the lock is re-entrant on one thread, so a nested submission cannot deadlock against itself
#   3. a failed acquisition is reported and releases nothing (no double-release, no leak)
#   4. the cap holds under a FORCED race: N threads race to reserve the last slots and the admitted
#      count never exceeds the cap, with the refused threads being told so rather than left waiting
#   5. the submission point reserves under the lock, tests the cap THERE, and rolls back a claim it
#      could not turn into a reservation
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-SubmissionAtomicity.ps1
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$failures = @()
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -eq "$Expected") { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host ("FAIL: {0} - expected '{1}', got '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red; $script:failures += $Name }
}
function Assert-True($Condition, $Name) {
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host ("FAIL: {0}" -f $Name) -ForegroundColor Red; $script:failures += $Name }
}
function Assert-False($Condition, $Name) { Assert-True (-not $Condition) $Name }

Import-Module (Join-Path $root 'src\Wuu.State.psm1') -Force -ErrorAction Stop

'=== 1. the primitive excludes across REAL THREADS ==='
# $script: state is per MODULE INSTANCE, so importing into two runspaces would give two gate objects
# and prove nothing. One object is created here and shared with real threads - which is what
# production has, because the modules are imported -Global exactly once.
#
# The event queue is passed as an ARGUMENT rather than injected with SessionStateProxy.SetVariable:
# an earlier version injected it and collected 0 events, so the measurement silently observed nothing
# and reported "peak depth 0" - a passing-shaped result from a test that never ran.
$gate = New-Object System.Object
$modulePath = Join-Path $root 'src\Wuu.State.psm1'

$events = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$overlapScript = {
    param($Gate, $ModulePath, $Events, $Tag)
    Import-Module $ModulePath -Force -ErrorAction Stop
    $got = Enter-WuuSubmissionLock -Gate $Gate -TimeoutMs 20000
    if (-not $got) { $Events.Enqueue("$Tag`:REFUSED"); return }
    try {
        $Events.Enqueue("$Tag`:IN")
        Start-Sleep -Milliseconds 120
        $Events.Enqueue("$Tag`:OUT")
    } finally {
        Exit-WuuSubmissionLock -Gate $Gate
    }
}

$threads = @()
foreach ($i in 1..6) {
    $ps = [powershell]::Create()
    $tag = "T$i"
    $null = $ps.AddScript($overlapScript).AddArgument($gate).AddArgument($modulePath).AddArgument($events).AddArgument($tag)
    $ps.Runspace = [runspacefactory]::CreateRunspace()
    $ps.Runspace.Open()
    $threads += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
}
foreach ($t in $threads) { try { $t.PS.EndInvoke($t.Handle) | Out-Null } catch { } ; try { $t.PS.Dispose() } catch { } }

$seq = @($events.ToArray())
$order = @($seq | Where-Object { $_ -like '*:IN' -or $_ -like '*:OUT' })
# Walk the sequence: the section depth must never exceed 1, i.e. no IN may appear while an IN is open.
$depth = 0
$maxDepth = 0
foreach ($e in $order) {
    if ($e -like '*:IN') { $depth++; if ($depth -gt $maxDepth) { $maxDepth = $depth } }
    elseif ($e -like '*:OUT') { $depth-- }
}
Assert-Equal $order.Count 12 "all 6 threads entered and left the section (got $($order.Count) of 12 events)"
Assert-Equal $maxDepth 1 "the critical section never holds two threads at once (peak depth $maxDepth, from $($order.Count) events)"
Assert-Equal $depth 0 'every acquisition was released (net section depth is 0)'
Assert-Equal @($seq | Where-Object { $_ -like '*:REFUSED' }).Count 0 'no thread was refused the lock under normal contention'

'=== 2. the lock is RE-ENTRANT on one thread (a nested submission cannot deadlock) ==='
$nested = Enter-WuuSubmissionLock -Gate $gate -TimeoutMs 5000
Assert-True $nested 'the outer acquisition succeeds'
$inner = Enter-WuuSubmissionLock -Gate $gate -TimeoutMs 5000
Assert-True $inner 'a NESTED acquisition on the same thread also succeeds (Monitor is re-entrant)'
Assert-True (Test-WuuSubmissionLockHeld -Gate $gate) 'the lock reports held on the acquiring thread'
Exit-WuuSubmissionLock -Gate $gate
Exit-WuuSubmissionLock -Gate $gate
Assert-False (Test-WuuSubmissionLockHeld -Gate $gate) 'after both releases the lock is free'

'=== 3. a release without an acquisition is swallowed, not thrown ==='
# Called from a finally, so a throw here would replace the real exception with a lock-release error.
$threw = $false
try { Exit-WuuSubmissionLock -Gate $gate } catch { $threw = $true }
Assert-False $threw 'a spurious release does not throw (it would mask the original failure)'
Assert-False (Test-WuuSubmissionLockHeld -Gate $gate) 'and it does not leave the lock held'

'=== 4. the cap holds under a FORCED RACE for the last slots ==='
# The defect: N submissions check the cap concurrently, all see room, all append. The fix: the test
# and the append are one step. This drives 12 threads against a cap of 3 and asserts the number that
# actually got in is exactly 3 - not "about 3", and not more.
$raceGate = New-Object System.Object
$cap = 3
$slots = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$admitted = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$refusedCount = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

$raceScript = {
    param($Gate, $ModulePath, $Cap, $Slots, $Admitted, $Refused, $Tag)
    Import-Module $ModulePath -Force -ErrorAction Stop
    # Mirror the shipped reservation: acquire, re-test capacity, append only if there is room.
    $lockTaken = Enter-WuuSubmissionLock -Gate $Gate -TimeoutMs 20000
    if (-not $lockTaken) { $Refused.Enqueue($Tag); return }
    try {
        if (-not (Test-WuuConcurrencyAvailable -Jobs $Slots -MaxConcurrentJobs $Cap)) {
            $Refused.Enqueue($Tag)
            return
        }
        $Slots.Add($Tag) | Out-Null
        $Admitted.Enqueue($Tag)
    } finally {
        Exit-WuuSubmissionLock -Gate $Gate
    }
}

$racers = @()
foreach ($i in 1..12) {
    $ps = [powershell]::Create()
    $tag = "R$i"
    $null = $ps.AddScript($raceScript).AddArgument($raceGate).AddArgument($modulePath).AddArgument($cap).AddArgument($slots).AddArgument($admitted).AddArgument($refusedCount).AddArgument($tag)
    $ps.Runspace = [runspacefactory]::CreateRunspace()
    $ps.Runspace.Open()
    $racers += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
}
foreach ($r in $racers) { try { $r.PS.EndInvoke($r.Handle) | Out-Null } catch { } ; try { $r.PS.Dispose() } catch { } }

$admittedCount = @($admitted.ToArray()).Count
$refusedN = @($refusedCount.ToArray()).Count
Assert-Equal $admittedCount $cap "exactly $cap of 12 racing submissions were admitted (got $admittedCount)"
Assert-Equal $slots.Count $cap "the job list holds exactly $cap entries (cap and counter agree)"
Assert-Equal $refusedN (12 - $cap) "the other $((12 - $cap)) were told they were refused (got $refusedN)"
Assert-True (@($slots.ToArray() | Sort-Object -Unique).Count -eq $cap) 'no slot was double-filled (all admitted tags are distinct)'

'=== 5. the same race WITHOUT the lock overshoots (proves the test can detect the defect) ==='
# Without this control, the assertion above could pass for a reason unrelated to the lock. It drives
# the identical body with the critical section removed and requires the cap to be EXCEEDED - so if the
# lock were removed from the shipped code, this suite would notice.
$noLockSlots = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$noLockAdmitted = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$noLockScript = {
    param($ModulePath, $Cap, $Slots, $Admitted, $Tag)
    Import-Module $ModulePath -Force -ErrorAction Stop
    # NO LOCK - deliberately the broken shape.
    if (-not (Test-WuuConcurrencyAvailable -Jobs $Slots -MaxConcurrentJobs $Cap)) { return }
    Start-Sleep -Milliseconds 60   # widen the check-to-append window, as the real 141 lines did
    $Slots.Add($Tag) | Out-Null
    $Admitted.Enqueue($Tag)
}
$nl = @()
foreach ($i in 1..12) {
    $ps = [powershell]::Create()
    $null = $ps.AddScript($noLockScript).AddArgument($modulePath).AddArgument($cap).AddArgument($noLockSlots).AddArgument($noLockAdmitted).AddArgument("N$i")
    $ps.Runspace = [runspacefactory]::CreateRunspace()
    $ps.Runspace.Open()
    $nl += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
}
foreach ($r in $nl) { try { $r.PS.EndInvoke($r.Handle) | Out-Null } catch { } ; try { $r.PS.Dispose() } catch { } }
$noLockCount = @($noLockAdmitted.ToArray()).Count
Assert-True ($noLockCount -gt $cap) "the unlocked control OVERSHOOTS the cap as expected ($noLockCount > $cap), so this suite can detect the defect it guards against"

'=== 6. the submission point reserves under the lock and rolls back a failed claim ==='
$wupdRaw = Get-Content (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw
function Get-CodeNoComments([string]$Text) {
    if (-not $Text) { return '' }
    $noBlocks = [regex]::Replace($Text, '(?s)<#.*?#>', '')
    return (($noBlocks -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
}
$wupdCode = Get-CodeNoComments $wupdRaw

function Get-FunctionText([string]$Text, [string]$Name) {
    $lines = $Text -split "`r?`n"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*function\s+$([regex]::Escape($Name))\b") { $start = $i; break }
    }
    if ($start -lt 0) { return '' }
    $out = @(); $depth = 0; $seenBrace = $false
    for ($i = $start; $i -lt $lines.Count; $i++) {
        $out += $lines[$i]
        $depth += ([regex]::Matches($lines[$i], '\{')).Count
        $depth -= ([regex]::Matches($lines[$i], '\}')).Count
        if ($depth -gt 0) { $seenBrace = $true }
        if ($seenBrace -and $depth -le 0) { break }
    }
    return ($out -join "`n")
}

$sub = Get-FunctionText $wupdCode 'Start-UpdateCheckJob'
Assert-True ($sub -like '*Enter-WuuSubmissionLock*') 'the submission point acquires the submission lock'
Assert-True ($sub -like '*Exit-WuuSubmissionLock*') 'it releases it'

# The authoritative cap test must sit INSIDE the section, i.e. after the acquisition.
$acqAt = $sub.IndexOf('Enter-WuuSubmissionLock')
$exitAt = $sub.LastIndexOf('Exit-WuuSubmissionLock')
$capTestAt = $sub.LastIndexOf('Test-WuuConcurrencyAvailable')
$addAt = $sub.LastIndexOf('$jobs.Add')
Assert-True ($capTestAt -gt $acqAt) 'the authoritative capacity test happens AFTER the acquisition'
Assert-True ($capTestAt -lt $exitAt) 'the capacity test happens INSIDE the critical section'
Assert-True ($addAt -gt $capTestAt) 'the slot is consumed AFTER the capacity test'
Assert-True ($addAt -lt $exitAt) 'the reservation happens INSIDE the critical section - the test and the append are one step'

# A failed reservation must not leave the row claimed, or no cleanup pass will ever settle it.
Assert-True ($sub -like '*rollback*') 'a failed reservation rolls back the claim'
# Assert the rollback BODY, not the whole function: an earlier version checked the function text for
# 'ClearOperation', which the claim ABOVE the reservation also contains - so removing the rollback's
# own clear still passed. The body is what must carry it.
$rbStart = $sub.IndexOf('$rollback = {')
$rbBody = ''
if ($rbStart -ge 0) { $rbBody = $sub.Substring($rbStart, [Math]::Min(500, $sub.Length - $rbStart)) }
Assert-True ($rbBody -ne '') 'the rollback block was located'
Assert-True ($rbBody.Contains('Update-WuuOperationState')) 'the rollback goes through the funnel'
Assert-True ($rbBody.Contains('-ClearOperation')) 'the rollback uses ClearOperation, which also retires the identity'

''
if ($failures.Count -eq 0) {
    Write-Host "ALL PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FAILURES: {0}" -f $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
