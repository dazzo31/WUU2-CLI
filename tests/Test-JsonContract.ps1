# Test: EVERY -Json document is versioned and parses (P1#2 / SS34).
#
# WHY THIS SUITE EXISTS
# ---------------------
# The result model covered the mutating verbs, but the READ verbs published their own shapes with no
# version field at all - `audit verify`, `audit show` and `-WhatIf`. A consumer therefore had to know
# which command it had called before it could parse the answer, and could not detect a schema change.
# SS34 treats JSON as an API, so the contract is only real if every document carries the same envelope.
#
# TWO PROPERTIES ARE ASSERTED, AND THE SECOND IS THE ONE THAT BITES:
#   1. every document parses, and carries SchemaVersion + Command;
#   2. the function that produced it returns ONE object. Emitting the JSON string AND returning a result
#      object made `... | ConvertFrom-Json` receive an array of two unrelated values - a defect already
#      recorded once for -WhatIf, and present in BOTH audit branches when this suite was written. A
#      contract test that only parsed the text would have passed straight over it.
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-JsonContract.ps1
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force -DisableNameChecking
Import-WuuModules -WuuRoot $root

$failures = @()
function Ok($m) { Write-Host "PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "FAIL: $m" -ForegroundColor Red; $script:failures += $m }
function Assert-True($cond, $m) { if ($cond) { Ok $m } else { Bad $m } }
function Assert-Equal($a, $b, $m) { if ("$a" -ceq "$b") { Ok $m } else { Bad ("$m (expected '$b', got '$a')") } }

# ---------------------------------------------------------------------------------------
# 1. the envelope is one definition, not a literal repeated per command
# ---------------------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 1. one schema version, one envelope ===' -ForegroundColor Cyan

$v = Get-WuuResultSchemaVersion
Assert-True ($v -is [int] -and $v -ge 1) "the schema version is a positive integer ($v)"

# Drive the renderer directly: the envelope is prepended to whatever fields the command supplies.
$doc = Format-WuuJsonDocument -Command 'unit-test' -Fields ([ordered]@{ Ok = $true; Count = 3 })
$parsed = $null
try { $parsed = $doc | ConvertFrom-Json } catch { Bad "the rendered document does not parse: $($_.Exception.Message)" }
if ($parsed) {
    Assert-Equal $parsed.SchemaVersion $v 'the document carries the schema version'
    Assert-Equal $parsed.Command 'unit-test' 'the document names its command'
    Assert-Equal $parsed.Ok $true 'the caller''s own fields survive'
    Assert-Equal $parsed.Count 3 'a numeric field survives'
    # Order matters for a readable diff of two runs.
    $names = @($parsed.PSObject.Properties | ForEach-Object { $_.Name })
    Assert-Equal ($names[0]) 'SchemaVersion' 'SchemaVersion is the FIRST field, so it is visible at a glance'
    Assert-Equal ($names[1]) 'Command' 'Command is the second field'
}

# A caller cannot override the envelope's version, or a command could claim a revision it is not.
$spoof = Format-WuuJsonDocument -Command 'spoof' -Fields ([ordered]@{ SchemaVersion = 999; Ok = $true }) | ConvertFrom-Json
Assert-Equal $spoof.SchemaVersion $v 'a command cannot override the envelope schema version'

# An EMPTY field bag is still a valid, versioned document - a command with nothing to report must not
# emit nothing.
$emptyDoc = Format-WuuJsonDocument -Command 'empty' -Fields $null | ConvertFrom-Json
Assert-Equal $emptyDoc.SchemaVersion $v 'an envelope-only document is still versioned'
Assert-Equal $emptyDoc.Command 'empty' 'an envelope-only document still names its command'

# Depth: at the ConvertTo-Json default of 2 a nested record renders as a TYPE NAME, so a consumer
# silently receives a string where it expected an object. The default here must be deeper.
$deep = Format-WuuJsonDocument -Command 'deep' -Fields ([ordered]@{ Target = [pscustomobject]@{ A = [pscustomobject]@{ B = [pscustomobject]@{ C = 'leaf' } } } })
Assert-True ($deep -match '"C":\s*"leaf"') 'the default depth renders nested data as data, not as a type name'

# A collection stays a collection, even with one element or none: unwrapping to a scalar is what breaks
# a consumer's iteration.
$oneDoc = Format-WuuJsonDocument -Command 'one' -Fields ([ordered]@{ Items = @([pscustomobject]@{ X = 1 }) }) | ConvertFrom-Json
Assert-True (@($oneDoc.Items).Count -eq 1) 'a single-element collection renders as a collection'
$noDoc = Format-WuuJsonDocument -Command 'none' -Fields ([ordered]@{ Items = @() }) | ConvertFrom-Json
Assert-Equal (@($noDoc.Items).Count) 0 'an empty collection renders as an empty collection, not as $null'

# ---------------------------------------------------------------------------------------
# 2. the command-result rendering is unchanged and carries the same envelope
#    (Test-ResultModel owns the field contract; this asserts the SHARED envelope, so the two
#     renderers cannot drift apart.)
# ---------------------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 2. the command result carries the same envelope ===' -ForegroundColor Cyan

$counts = Get-WuuCommandCounts -Rows @()
$res = New-WuuCommandResult -Command 'check' -Ok $true -ExitCode 0 -Counts $counts -Computers @()
$resParsed = Format-WuuResultJson -Result $res | ConvertFrom-Json
Assert-Equal $resParsed.SchemaVersion $v 'the command result carries the same schema version'
Assert-Equal $resParsed.Command 'check' 'the command result names its command'
Assert-True ($resParsed.PSObject.Properties['Computers']) 'the command result still carries Computers'

# ---------------------------------------------------------------------------------------
# 3. the READ verbs emit a versioned document (the P1#2 gap)
# ---------------------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 3. audit verify / audit show emit versioned documents ===' -ForegroundColor Cyan

# Build a REAL two-record chain so verify has something genuine to check. The session writes a daily
# log into the directory it is given; there is no stop call - each record is appended independently.
$logDir = Join-Path $env:TEMP ("wuu-jsoncontract-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$session = Start-WuuAuditSession -Directory $logDir -Action 'test'
$null = Write-WuuAuditRecord -Session $session -Action 'check' -Result 'succeeded' -Targets @('SRV01')
$null = Write-WuuAuditRecord -Session $session -Action 'download' -Result 'succeeded' -Targets @('SRV01')
$logPath = @(Get-ChildItem -LiteralPath $logDir -Filter 'audit-*.jsonl' -File | Sort-Object LastWriteTime -Descending)[0].FullName

# Capture BOTH the host output and the return value, then separate them BY TYPE rather than by a
# sentinel string. `6>&1` merges the information stream (Write-Host) with the success stream, so the
# JSON the command prints arrives as an InformationRecord while the returned object stays a
# PSCustomObject. A sentinel marker was tried first and was brittle: the capture produced a single
# value, so `.IndexOf` threw, and the marker could also appear inside the JSON itself.
$capture = & { Invoke-WuuAuditCommand -SubVerb 'verify' -LogPath $logPath -Json } 6>&1
$jsonLine = @($capture | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
    ForEach-Object { [string]$_.Message }) -join "`n"
$returned = @($capture | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })

$verify = $null
try { $verify = ($jsonLine.Trim()) | ConvertFrom-Json } catch { Bad "audit verify -Json does not parse: $($_.Exception.Message)" }
if ($verify) {
    Assert-Equal $verify.SchemaVersion $v 'audit verify -Json carries the schema version'
    Assert-Equal $verify.Command 'audit verify' 'audit verify -Json names its command'
    Assert-True ($verify.PSObject.Properties['LogPath']) 'audit verify keeps its documented LogPath field'
    Assert-True ($verify.PSObject.Properties['Checked']) 'audit verify keeps its documented Checked field'
    Assert-True ($verify.PSObject.Properties['FirstBreak']) 'audit verify keeps its documented FirstBreak field'
    Assert-True ($verify.Ok) 'a genuine chain verifies'
    # An EMPTY collection must be an empty collection. It rendered as `{ }` until the renderer stopped
    # reading the field through an `if` used as an expression, which unrolls a collection to $null.
    Assert-Equal (@($verify.Problems).Count) 0 'an intact chain reports an EMPTY Problems array, not a null that renders as an object'
}
# The RETURN value must be a single object, not an array of (json string, result object).
Assert-Equal ($returned.Count) 1 "audit verify -Json RETURNS one object, not the JSON string plus a result (got $($returned.Count))"

$captureShow = & { Invoke-WuuAuditCommand -SubVerb 'show' -LogPath $logPath -Json } 6>&1
$showJson = @($captureShow | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
    ForEach-Object { [string]$_.Message }) -join "`n"
$showReturned = @($captureShow | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
$show = $null
try { $show = ($showJson.Trim()) | ConvertFrom-Json } catch { Bad "audit show -Json does not parse: $($_.Exception.Message)" }
if ($show) {
    Assert-Equal $show.SchemaVersion $v 'audit show -Json carries the schema version'
    Assert-Equal $show.Command 'audit show' 'audit show -Json names its command'
    Assert-True ($show.PSObject.Properties['Records']) 'audit show keeps its documented Records field'
    Assert-True (@($show.Records).Count -ge 2) "audit show returns the records ($(@($show.Records).Count))"
}
Assert-Equal ($showReturned.Count) 1 "audit show -Json RETURNS one object (got $($showReturned.Count))"

Remove-Item $logDir -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------------------
# 4. -WhatIf emits a versioned document, and parses at a usable depth
# ---------------------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 4. the -WhatIf plan is a versioned document ===' -ForegroundColor Cyan

$store = New-WuuStateStore
$row = New-WuuComputerRow -Computer 'JSON1'
$row.Pending = $true
Add-WuuComputerRow -Store $store -Row $row | Out-Null
# The action must be REGISTERED or Invoke-WuuCommand returns a usage error before it ever reaches the
# -WhatIf branch - the branch sits below the action lookup. The handler itself must never run.
$actions = @{ EventInstallUpdates = { throw 'MUST NOT RUN - -WhatIf must not call the handler' } }
$plan = Invoke-WuuCommand -Verb 'install' -Actions $actions -Store $store -Computer 'JSON1' -WhatIf -Json
Assert-True ([bool]$plan.Json) 'the -WhatIf command returns the JSON text as a property'
$planParsed = $null
try { $planParsed = $plan.Json | ConvertFrom-Json } catch { Bad "-WhatIf -Json does not parse: $($_.Exception.Message)" }
if ($planParsed) {
    Assert-Equal $planParsed.SchemaVersion $v '-WhatIf -Json carries the schema version'
    Assert-Equal $planParsed.Command 'install' '-WhatIf -Json names the verb'
    Assert-Equal $planParsed.WhatIf $true '-WhatIf -Json still declares itself a dry run'
    # The plan's own fields must survive at the depth this renderer uses - the reason the depth is 6.
    foreach ($f in @('Targets', 'WouldRun', 'WouldQueue', 'WouldSkip', 'WouldNoOp', 'Unresolved')) {
        Assert-True ($null -ne $planParsed.PSObject.Properties[$f]) "-WhatIf -Json carries '$f'"
    }
}

''
if ($failures.Count -eq 0) {
    Write-Host 'Test-JsonContract.ps1: ALL PASS - every -Json document is versioned and parses (SS34)' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("SOME CHECKS FAILED ({0}): {1}" -f $failures.Count, ($failures -join '; ')) -ForegroundColor Red
    exit 1
}
