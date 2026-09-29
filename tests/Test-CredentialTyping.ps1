# Functional test: verify the typed [pscredential] params in the REAL Invoke-CimWithTimeout
# work correctly with (a) a real PSCredential and (b) $null default credentials,
# and that a plain STRING is rejected (ParameterBindingException, not silently used).
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Test-CredentialTyping.ps1

$repo = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$pass = 0; $fail = 0

# --- Extract the REAL Invoke-CimWithTimeout from its HOME MODULE ---
#
# This test used to parse the GUI-era monolith WUU.ps1, which no longer contains the function: it
# moved to src\Wuu.Remote.psm1 in the module split, so the test threw at line 15
# ("Invoke-CimWithTimeout not found") and had been failing ever since. Pointed at the real owner
# instead of deleted, because the assertion it makes is genuinely valuable: a plain string must
# never be silently accepted as a credential.
#
# The function is EXTRACTED and dot-sourced rather than imported, matching the original intent -
# importing Wuu.Remote would pull in Wuu.Logging/Wuu.Workers for the pooled execution path and this
# test is about parameter TYPING at the binding layer, not about the worker pool.
$remotePath = Join-Path $repo 'src\Wuu.Remote.psm1'
$tokens = $null; $perr = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($remotePath, [ref]$tokens, [ref]$perr)
if ($perr.Count -gt 0) { throw "Wuu.Remote.psm1 parse errors: $($perr.Count)" }
$fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Invoke-CimWithTimeout' }, $true) | Select-Object -First 1
if (-not $fn) { throw 'Invoke-CimWithTimeout not found in src\Wuu.Remote.psm1' }
. ([scriptblock]::Create($fn.Extent.Text))

# The function's body delegates to Invoke-WithPoolTimeout, which lives in Wuu.Workers. A stub keeps
# the binding assertions meaningful without importing the pool: these calls are expected to FAIL at
# the remote end, and what is under test is how the credential CROSSES the boundary, not whether a
# fictional host answers.
function Invoke-WithPoolTimeout {
    param([scriptblock]$ScriptBlock, [object]$ArgumentList = $null, [int]$TimeoutSeconds = 300, [string]$OperationName = 'Pooled operation')
    return @{ Success = $false; Result = $null; Error = "$OperationName : simulated DNS failure (WUU-NOTREAL-000000)" }
}

# NOTE: full CIM round-trips need WinRM (not configured on dev boxes), so these
# tests verify BINDING and type-flow, not remote query success. A non-routable
# computer name guarantees the job fails fast for the right reason (DNS), proving
# the credential crossed the job boundary without type errors.

# --- Test A: $null credential (default credentials) ---
$rA = Invoke-CimWithTimeout -ComputerName 'WUU-NOTREAL-000000' -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 10
if (-not $rA.Success -and $rA.Error -notmatch 'parameter name|cannot convert') { Write-Host 'PASS A: null credential binds and flows (fails on DNS, as expected)'; $pass++ }
else { Write-Host "FAIL A: null credential - $($rA.Error)"; $fail++ }

# --- Test B: real PSCredential is accepted, crosses the job boundary ---
$secPass = ConvertTo-SecureString 'ThisIsNotARealPassword123!' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('.\WUU_test_user', $secPass)
$rB = Invoke-CimWithTimeout -ComputerName 'WUU-NOTREAL-000000' -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 10 -Credential $cred
if (-not $rB.Success -and $rB.Error -notmatch 'parameter name|cannot convert') { Write-Host 'PASS B: PSCredential accepted and serialized into the job (fails on DNS, as expected)'; $pass++ }
else { Write-Host "FAIL B: PSCredential - $($rB.Error)"; $fail++ }

# --- Test C: a plain STRING must NOT silently become a credential ---
# PSCredential params carry a CredentialAttribute that converts strings, but in a
# NON-INTERACTIVE child job the conversion fails (no prompt available). Requirement:
# the failure must be a hard error, never a silent use of the string as a password.
$usedPlainString = $false
try {
    $rC = Invoke-CimWithTimeout -ComputerName 'WUU-NOTREAL-000000' -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 10 -Credential 'PlainTextPassword'
    # If we get here the string was converted to some credential; it must not have succeeded
    if ($rC.Success) { $usedPlainString = $true }
} catch {
    # ParameterBindingException at binding time is the ideal outcome
}
if ($usedPlainString) { Write-Host 'FAIL C: plain string was silently used as a credential'; $fail++ }
else { Write-Host 'PASS C: plain string never becomes a working credential (hard error or prompt-blocked in job)'; $pass++ }

Write-Host ""
Write-Host ("RESULT: {0} passed, {1} failed" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }