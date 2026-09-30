# Decisive probe: can a payload runspace (InitialSessionState::CreateDefault, created the way
# Wuu.WindowsUpdate and the job-cleanup loop create theirs) call a MODULE function, or only the
# scriptblocks and plain objects injected via SessionStateProxy.SetVariable?
#
# This decides whether the P3 budget cap can be a CALL to Get-WuuEffectiveInnerTimeout or must be
# inlined arithmetic. Getting it wrong means the cap throws on every production probe.
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force -DisableNameChecking
Import-WuuModules -WuuRoot $root

'Get-WuuEffectiveInnerTimeout resolvable in THIS session: ' + [bool](Get-Command Get-WuuEffectiveInnerTimeout -ErrorAction SilentlyContinue)
''

# The exact shape Wuu.WindowsUpdate uses.
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$iss.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
$rs = [runspacefactory]::CreateRunspace($iss)
$rs.ApartmentState = 'STA'
$rs.Open()

# Inject a ROW the way production injects stateStore: a plain object via SetVariable.
$row = [pscustomobject]@{ OpName = 'Check'; TimeoutExpiresAt = (Get-Date).AddSeconds(7) }
$rs.SessionStateProxy.SetVariable('Row', $row)

# Inject a scriptblock the PRODUCTION way - [scriptblock]::Create(<string>) - and have it (a) report
# whether the module function resolves, (b) attempt the call.
$probe = @'
$fn = Get-Command Get-WuuEffectiveInnerTimeout -ErrorAction SilentlyContinue
$callable = [bool]$fn
if ($callable) {
    $plan = Get-WuuEffectiveInnerTimeout -InnerTimeoutSeconds 30 -Row $Row
    $seconds = $plan.Seconds
} else {
    $seconds = -1
}
$type = $Row.GetType().Name
$expiry = $Row.PSObject.Properties['TimeoutExpiresAt']
[pscustomobject]@{ ModuleFunctionCallable = $callable; Seconds = $seconds; RowType = $type; RowReadable = [bool]$expiry }
'@

$ps = [PowerShell]::Create()
$ps.Runspace = $rs
[void]$ps.AddScript([scriptblock]::Create($probe))
$out = $ps.Invoke()
if ($ps.Streams.Error.Count) { 'ERRORS from payload:'; $ps.Streams.Error | Select-Object -First 3 | ForEach-Object { '  ' + $_.ToString() } }
''
'--- RESULT ---'
if ($out -and $out.Count) {
    $r = $out[0]
    "  module function callable in payload : $($r.ModuleFunctionCallable)"
    "  Get-WuuEffectiveInnerTimeout returned: $($r.Seconds)   (5-7 expected if callable)"
    "  row type visible to payload          : $($r.RowType)"
    "  row property readable by payload     : $($r.RowReadable)"
} else { '  NO OUTPUT' }

$ps.Dispose(); $rs.Close(); $rs.Dispose()

''
'--- VERDICT ---'
if ($out -and $out[0].ModuleFunctionCallable) {
    'A module function IS callable from a payload runspace. A call is safe.'
} else {
    'A module function is NOT callable from a payload runspace. The P3 cap MUST be inlined,'
    'because a call would throw (or silently no-op under -ErrorAction SilentlyContinue) on every'
    'production probe.'
}
