# Test: the scheduler/worker-runspace module and the deduplicated log appender (reviewer P2).
#
# WHY THIS SUITE EXISTS
# ---------------------
# Worker runspaces are isolated, so every helper a payload needs is built as a STRING and injected. That
# caused two problems:
#
#   1. the fault-tolerant log appender was written TWICE - once in Wuu.Core for the cleanup runspace and
#      once in Wuu.WindowsUpdate for each per-computer runspace - with a comment in each copy telling the
#      reader to keep them in sync. Two independent copies of a retry loop is exactly the arrangement
#      that drifts. They are now built by one factory.
#   2. the set of helpers a worker receives IS the worker's capability surface, and it was only
#      discoverable by searching call sites in two modules.
#
# This suite asserts:
#   1. the appender is defined ONCE in src/ (the dedupe is real, not a rename)
#   2. the appender WORKS - driven in a real runspace against a real file, with the lock retry actually
#      exercised, because "it was injected" is not the same as "it can log"
#   3. both worker kinds CALL the factory and carry no private copy
#   4. the helper surface is wired and INSPECTABLE, and a Busy runspace is reported as busy rather than
#      as missing helpers (conflating the two makes an in-flight worker look broken)
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-SchedulerModule.ps1
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

Import-Module (Join-Path $root 'src\Wuu.Logging.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $root 'src\Wuu.Scheduler.psm1') -Force -ErrorAction Stop

'=== 1. the module exists, loads, and exports its surface ==='
foreach ($fn in 'Get-WuuWorkerLogAppender', 'Add-WuuWorkerHelper', 'Test-WuuWorkerHelperSurface', 'Test-WuuWorkerVariableDefined', 'Test-WuuWorkerVariableState') {
    Assert-True ($null -ne (Get-Command $fn -ErrorAction SilentlyContinue)) "$fn is resolvable"
}
# The appender belongs to LOGGING, not to the scheduler: Write-WuuLogEntry delegates to it, and three
# suites import Wuu.Logging on its own. Putting it in Wuu.Scheduler made logging depend on the scheduler,
# which broke those imports - a backwards dependency this suite was right to expose.
$loggingAlone = & powershell.exe -NoProfile -Command "Import-Module '$root\src\Wuu.Logging.psm1' -Global -ErrorAction Stop; if (Get-Command Get-WuuWorkerLogAppender -ErrorAction SilentlyContinue) { 'OK' } else { 'MISSING' }"
Assert-Equal (($loggingAlone -join '').Trim()) 'OK' 'Wuu.Logging alone provides the appender (logging must not depend on the scheduler)'

# Wuu.Scheduler must be WIRED INTO THE APPLICATION, not merely present on disk and importable here.
# This suite imports it directly, so it would pass whether or not the app ever loads it - which is a gap
# the tautology harness exposed: removing it from Import-WuuModules left this suite green. The real
# import path is therefore DRIVEN here, because "the module exists" and "the app loads it" are different
# claims and only the second one means the helper set is wired.
$appWiring = & powershell.exe -NoProfile -Command "Import-Module '$root\src\Wuu.Core.psm1' -Force -ErrorAction Stop; Import-WuuModules -WuuRoot '$root'; `$s = Get-Command Add-WuuWorkerHelper -ErrorAction SilentlyContinue; `$a = Get-Command Get-WuuWorkerLogAppender -ErrorAction SilentlyContinue; if (`$s -and `$a) { 'OK' } else { 'MISSING: scheduler=' + [bool]`$s + ' appender=' + [bool]`$a }"
Assert-Equal (($appWiring -join '').Trim()) 'OK' 'the REAL import path (Import-WuuModules) wires Wuu.Scheduler and the appender into the app'

'=== 2. the retry loop exists ONCE in src/ (the dedupe is real) ==='
# FOUR copies became one. The assertion is not "one" but "no copy OUTSIDE the factory", because the
# factory itself must contain the loop - and asserting exactly one would break the moment the factory
# legitimately grew a second loop.
$distinctive = 'Start-Sleep -Milliseconds (100 * $attempt)'
$outside = @()
$insideFactory = @()
foreach ($f in Get-ChildItem (Join-Path $root 'src\*.psm1') | Sort-Object Name) {
    $lines = [System.IO.File]::ReadAllLines($f.FullName)
    $inFactory = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^function\s+Get-WuuWorkerLogAppender') { $inFactory = $true }
        elseif ($lines[$i] -match '^function\s+') { $inFactory = $false }
        if ($lines[$i].Contains($distinctive)) {
            if ($inFactory) { $insideFactory += "$($f.Name):L$($i+1)" } else { $outside += "$($f.Name):L$($i+1)" }
        }
    }
}
Assert-True ($insideFactory.Count -ge 1) "the factory contains the retry loop ($($insideFactory.Count) occurrence(s))"
Assert-Equal $outside.Count 0 "NO module carries its own copy of the retry loop (found outside the factory: $($outside -join ', '))"

'=== 3. both worker kinds CALL the factory and carry no private copy ==='
$coreCode = Get-Content (Join-Path $root 'src\Wuu.Core.psm1') -Raw
$wupdCode = Get-Content (Join-Path $root 'src\Wuu.WindowsUpdate.psm1') -Raw
Assert-True ($coreCode.Contains('(Get-WuuWorkerLogAppender)')) 'the cleanup runspace uses the factory'
Assert-True ($wupdCode.Contains('(Get-WuuWorkerLogAppender)')) 'the per-computer runspace uses the factory'
Assert-False ($coreCode.Contains($distinctive)) 'the cleanup runspace no longer carries its own appender copy'
Assert-False ($wupdCode.Contains($distinctive)) 'the per-computer runspace no longer carries its own appender copy'
# WriteDebugLogScript inlined the loop a FOURTH time; it now calls the injected appender.
Assert-True ($wupdCode.Contains('& $WriteLogFileScript -LogEntry $logEntry')) 'WriteDebugLogScript delegates to the injected appender'
# And Write-WuuLogEntry delegates too, rather than keeping its own loop.
$logCode = Get-Content (Join-Path $root 'src\Wuu.Logging.psm1') -Raw
$wuStart = $logCode.IndexOf('function Write-WuuLogEntry')
$wuEnd = $logCode.IndexOf('function Get-WuuWorkerLogAppender')
Assert-True ($wuStart -ge 0 -and $wuEnd -gt $wuStart) 'Write-WuuLogEntry was located before the factory'
if ($wuStart -ge 0 -and $wuEnd -gt $wuStart) {
    $wuBody = $logCode.Substring($wuStart, $wuEnd - $wuStart)
    Assert-True ($wuBody.Contains('Get-WuuWorkerLogAppender')) 'Write-WuuLogEntry delegates to the factory'
    Assert-False ($wuBody.Contains($distinctive)) 'Write-WuuLogEntry no longer carries its own retry loop'
}

'=== 4. the appender WORKS in a real runspace, proven by writing ==='
# "It was injected" is not the same as "it can log". This drives it in a fresh runspace against a real
# file, so the SetVariable binding, the lock, and the retry loop are all exercised.
#
# The file is removed at the END, but the earlier version ALSO wrote its two lines before asserting, so
# it inherited whatever a PREVIOUS interrupted run had left behind - which is why it once reported 3
# lines for 2 writes. A fresh, uniquely-named file removes the possibility entirely.
$logFile = Join-Path ([System.IO.Path]::GetTempPath()) ("wuu-appender-" + [guid]::NewGuid().ToString('N') + '.log')
Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
$logLock = New-Object System.Object
$appender = Get-WuuWorkerLogAppender
Assert-True ($appender -is [scriptblock]) 'the factory returns a scriptblock'

$rs = [runspacefactory]::CreateRunspace()
$rs.Open()
$rs.SessionStateProxy.SetVariable('LogPath', $logFile)
$rs.SessionStateProxy.SetVariable('LogLock', $logLock)
$rs.SessionStateProxy.SetVariable('WriteLogFileScript', $appender)

# A LITERAL scriptblock is installed FIRST and must write nothing: it captures the defining session
# state, so it sees neither $LogPath nor $LogLock. This is the documented failure mode the factory
# exists to avoid, and asserting it before the real writes keeps the count arithmetic simple.
$rs.SessionStateProxy.SetVariable('WriteLogFileScript', [scriptblock]{ param([string]$LogEntry) Add-Content -Path $LogPath -Value $LogEntry })
$psLit = [powershell]::Create()
$psLit.Runspace = $rs
$null = $psLit.AddScript('try { & $WriteLogFileScript "literal must not append" } catch { }')
$null = $psLit.Invoke()
$psLit.Dispose()
Assert-False (Test-Path -LiteralPath $logFile) 'a LITERAL scriptblock cannot bind session state and wrote nothing (the failure mode the factory avoids)'

# Now the real appender. It is built from a STRING, so it binds the injected variables.
#
# A FRESH [powershell] INSTANCE PER CALL. AddScript APPENDS to a instance's command list, so calling
# AddScript twice on one instance and invoking twice runs BOTH scripts on the second invoke - which
# wrote the first line twice and made this assertion report 3 lines for 2 writes. (Caught by the
# assertion, not by reading it.)
$rs.SessionStateProxy.SetVariable('WriteLogFileScript', $appender)
foreach ($line in @('[probe] first line', '[probe] second line')) {
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript('param($l) & $WriteLogFileScript $l').AddArgument($line)
    $null = $ps.Invoke()
    $ps.Dispose()
}

Assert-True (Test-Path -LiteralPath $logFile) 'the appender created the log file'
$content = @(Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue)
Assert-Equal $content.Count 2 "both lines were appended (got $($content.Count))"
Assert-True ($content[0] -like '*first line*') 'the first line was written verbatim'
Assert-True ($content[1] -like '*second line*') 'the second line was written verbatim'

# The appender's own fallback path: driven with NO injected variables, it must still append using the
# explicitly-passed path, or a main-session caller silently writes nowhere.
$appender2 = Get-WuuWorkerLogAppender
$rsPlain = [runspacefactory]::CreateRunspace()
$rsPlain.Open()
$psPlain = [powershell]::Create()
$psPlain.Runspace = $rsPlain
$null = $psPlain.AddScript('param($sb, $p) & $sb -LogEntry "[probe] explicit path" -Path $p').AddArgument($appender2).AddArgument($logFile)
$null = $psPlain.Invoke()
$psPlain.Dispose()
$content2 = @(Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue)
Assert-Equal $content2.Count 3 "the explicit-path fallback appends without ANY injected variable (got $($content2.Count))"
try { $rsPlain.Close(); $rsPlain.Dispose() } catch { }

try { $rs.Close(); $rs.Dispose() } catch { }
Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue

'=== 5. Add-WuuWorkerHelper wires the standard surface ==='
$rs2 = [runspacefactory]::CreateRunspace()
$rs2.Open()
$wired = Add-WuuWorkerHelper -SessionState $rs2.SessionStateProxy -StateStore $null -LogPath $logFile -LogLock $logLock
Assert-True ($wired -ge 4) "the helper set is non-trivial ($wired wired)"
Assert-True ($null -ne $rs2.SessionStateProxy.GetVariable('WriteLogFileScript')) 'the appender was wired'
# A null store is legitimate (the cleanup runspace can start before a store exists) and must be wired
# rather than skipped, or a payload would fail on an undefined variable rather than on a null one.
Assert-True (Test-WuuWorkerVariableDefined -Runspace $rs2 -Name 'stateStore') 'a NULL state store is still DEFINED (wired but null is a valid state)'

'=== 6. the helper surface is INSPECTABLE, and Busy is not Missing ==='
$surface = Test-WuuWorkerHelperSurface -Runspace $rs2
Assert-False $surface.Busy 'an idle runspace is not reported busy'
Assert-True ($surface.Present -contains 'WriteLogFileScript') 'the inspector sees the appender'
Assert-True ($surface.Present -contains 'LogPath') 'the inspector sees the log path'
Assert-Equal $surface.Missing.Count 0 "nothing is missing on a properly wired runspace ($($surface.Missing -join ', '))"

# An unwired runspace must report Missing, or the inspector cannot detect a broken worker.
$rs3 = [runspacefactory]::CreateRunspace()
$rs3.Open()
$bare = Test-WuuWorkerHelperSurface -Runspace $rs3
Assert-True ($bare.Missing.Count -gt 0) "an UNWIRED runspace reports missing helpers ($($bare.Missing -join ', '))"
Assert-False $bare.Busy 'a bare idle runspace is not busy'

# A BUSY runspace must be reported as busy, not as missing: conflating them makes an in-flight worker
# look broken, which is exactly when an operator is most likely to be looking at it.
$busyPs = [powershell]::Create()
$busyPs.Runspace = $rs3
$null = $busyPs.AddScript('Start-Sleep -Seconds 20')
$busyHandle = $busyPs.BeginInvoke()
Start-Sleep -Milliseconds 700
$busySurface = Test-WuuWorkerHelperSurface -Runspace $rs3
Assert-True $busySurface.Busy 'a BUSY runspace is reported as busy'
try { $busyPs.Stop() } catch { }
try { $busyPs.Dispose() } catch { }

try { $rs2.Close(); $rs2.Dispose() } catch { }
try { $rs3.Close(); $rs3.Dispose() } catch { }

''
if ($failures.Count -eq 0) {
    Write-Host "ALL PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FAILURES: {0}" -f $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
