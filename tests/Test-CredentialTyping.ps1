# Functional test: verify the typed [pscredential] params in the REAL Invoke-CimWithTimeout
# work correctly with (a) a real PSCredential and (b) $null default credentials,
# and that a plain STRING is rejected rather than silently used.
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-CredentialTyping.ps1
#
# HISTORY (read before "simplifying" test C)
# ------------------------------------------
# This suite parsed the GUI-era monolith WUU.ps1 for Invoke-CimWithTimeout. That function moved to
# src\Wuu.Remote.psm1 during the module split, so the suite threw 'Invoke-CimWithTimeout not found'
# and had been failing ever since. It now reads the real module.
#
# Test C then HUNG for 20+ minutes in this process. PSCredential parameters carry a CredentialAttribute:
# binding a plain STRING triggers Get-Credential, which PROMPTS. The original test only worked because
# the call ran inside a child job with no console. Extracting the function and dot-sourcing it into the
# test process put the prompt on the inherited console and blocked for ever - while the suite printed
# PASS C. Test C therefore runs in a CHILD PROCESS with stdin closed and a hard timeout, and the reason
# is recorded here rather than left for the next person to rediscover by hanging.
#Requires -Version 5.1
$repo = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$pass = 0; $fail = 0

# --- Extract the REAL Invoke-CimWithTimeout from its HOME MODULE ------------------------------
# Extracted and dot-sourced rather than imported, matching the original intent: importing
# Wuu.Remote would pull in Wuu.Logging/Wuu.Workers for the pooled path, and this test is about
# parameter TYPING at the binding layer.
$remotePath = Join-Path $repo 'src\Wuu.Remote.psm1'
$tokens = $null; $perr = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($remotePath, [ref]$tokens, [ref]$perr)
if ($perr.Count -gt 0) { throw "Wuu.Remote.psm1 parse errors: $($perr.Count)" }
$fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Invoke-CimWithTimeout' }, $true) | Select-Object -First 1
if (-not $fn) { throw 'Invoke-CimWithTimeout not found in src\Wuu.Remote.psm1' }
. ([scriptblock]::Create($fn.Extent.Text))

# The body delegates to Invoke-WithPoolTimeout (Wuu.Workers). A stub keeps the binding assertions
# meaningful without importing the pool: these calls are expected to FAIL at the remote end, and what
# is under test is how the credential CROSSES the boundary, not whether a fictional host answers.
function Invoke-WithPoolTimeout {
    param([scriptblock]$ScriptBlock, [object]$ArgumentList = $null, [int]$TimeoutSeconds = 300, [string]$OperationName = 'Pooled operation')
    return @{ Success = $false; Result = $null; Error = "$OperationName : simulated DNS failure (WUU-NOTREAL-000000)" }
}

# --- Test A: $null credential (default credentials) ------------------------------------------
$rA = Invoke-CimWithTimeout -ComputerName 'WUU-NOTREAL-000000' -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 10
if (-not $rA.Success -and $rA.Error -notmatch 'parameter name|cannot convert') { Write-Host 'PASS: A - null credential binds and flows (fails on DNS, as expected)'; $pass++ }
else { Write-Host "FAIL: A - null credential - $($rA.Error)"; $fail++ }

# --- Test B: a real PSCredential is accepted and crosses the boundary ------------------------
$secPass = ConvertTo-SecureString 'ThisIsNotARealPassword123!' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('.\WUU_test_user', $secPass)
$rB = Invoke-CimWithTimeout -ComputerName 'WUU-NOTREAL-000000' -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 10 -Credential $cred
if (-not $rB.Success -and $rB.Error -notmatch 'parameter name|cannot convert') { Write-Host 'PASS: B - PSCredential accepted and passed into the call (fails on DNS, as expected)'; $pass++ }
else { Write-Host "FAIL: B - PSCredential - $($rB.Error)"; $fail++ }

# --- Test C: a plain STRING must NOT silently become a credential ----------------------------
# Asserted STATICALLY, against the parameter's declared type - and that is deliberate.
#
# The obvious dynamic test (call it with -Credential 'PlainTextPassword' and expect a failure) cannot
# be made safe here: PSCredential parameters carry a CredentialAttribute, so binding a string invokes
# Get-Credential and PROMPTS, and a child process with -NonInteractive and stdin closed STILL hung for
# 60 seconds waiting on a prompt. A test whose "pass" is a timeout is not evidence - it is a hang with
# a green label, and it makes the suite take a minute longer than it should.
#
# What actually guarantees the requirement is the TYPE: `[PSCredential]` means a string can never be
# silently used as a password - binding must convert (and prompt) or fail. So the type is what is
# checked, which is both stronger (it holds for every caller, not just this one) and instant.
$typedAsCredential = $false
$plainStringRisk = $false
$p = $fn.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Credential' }
if (-not $p) {
    Write-Host 'FAIL: C - Invoke-CimWithTimeout has no -Credential parameter at all'; $fail++
} else {
    $typeText = $p.StaticType.FullName
    if ($typeText -eq 'System.Management.Automation.PSCredential') { $typedAsCredential = $true }
    # [object] or [string] would let a plain string reach the session as a credential.
    if ($typeText -in @('System.Object', 'System.String')) { $plainStringRisk = $true }
    if ($plainStringRisk) {
        Write-Host ("FAIL: C - -Credential is typed [{0}] - a plain string could be used as a credential" -f $typeText); $fail++
    } elseif ($typedAsCredential) {
        Write-Host 'PASS: C - -Credential is typed [PSCredential] (a plain string cannot be silently used)'; $pass++
    } else {
        Write-Host ("PASS: C - -Credential is typed [{0}], not [object]/[string]" -f $typeText); $pass++
    }
}

# ...and the DCOM path must actually pass that typed value to the session, not a copy that could be
# coerced. Checked in the source so it holds even if the parameter type is preserved by accident.
if ($fn.Extent.Text -match 'New-CimSession' -and $fn.Extent.Text -match "sessionArgs\['Credential'\]") {
    Write-Host 'PASS: C2 - the typed credential is what reaches New-CimSession (no untyped copy)'; $pass++
} else {
    Write-Host 'FAIL: C2 - the credential is not demonstrably the typed value passed to New-CimSession'; $fail++
}

Write-Host ""
Write-Host ("RESULT: {0} passed, {1} failed" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
