# Runs on the target as SYSTEM via a WUU2 scheduled task; $RunId is prepended by Invoke-WuuRemoteTask.
if (-not $RunId) { $RunId = 'manual' }
$regPath = "HKLM:\SOFTWARE\WUU2\Jobs\$RunId"
function Write-WuuProgress([hashtable]$Data) {
    try {
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        Set-ItemProperty -Path $regPath -Name 'State' -Value ($Data | ConvertTo-Json -Compress)
    } catch { }
}

try {
    Write-WuuProgress @{ Phase = 'Searching' }
    $updateSession = New-Object -ComObject 'Microsoft.Update.Session'
    $searchResult = $updateSession.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0")

    $toInstall = @(foreach ($update in $searchResult.Updates) {
        if ($update.InstallationBehavior.CanRequestUserInput) { continue }
        if (-not $update.IsDownloaded) { continue }
        if (-not $update.EulaAccepted) { $update.AcceptEula() }
        $update
    })

    # One update per Install() call so progress can be reported between updates
    $numErrors = 0
    $rebootRequired = $false
    $i = 0
    foreach ($update in $toInstall) {
        $i++
        Write-WuuProgress @{ Phase = 'Installing'; Current = $i; Total = $toInstall.Count; Title = $update.Title }
        $coll = New-Object -ComObject 'Microsoft.Update.UpdateColl'
        [void]$coll.Add($update)
        $installer = $updateSession.CreateUpdateInstaller()
        $installer.Updates = $coll
        $installResult = $installer.Install()
        if ($installResult.GetUpdateResult(0).ResultCode -ge 4) { $numErrors++ }
        if ($installResult.RebootRequired) { $rebootRequired = $true }
    }

    try {
        if ((New-Object -ComObject 'Microsoft.Update.SystemInfo').RebootRequired) { $rebootRequired = $true }
    } catch { }

    $resultStr = if ($numErrors -gt 0) { 'Failed' } else { 'Success' }
    $errMsg = if ($numErrors -gt 0) { "$numErrors update(s) failed to install" } else { $null }
    Write-WuuProgress @{ Phase = 'Done'; Result = $resultStr; Count = $numErrors; Total = $toInstall.Count; RebootRequired = $rebootRequired; ErrorMessage = $errMsg }
    exit $numErrors
} catch {
    Write-WuuProgress @{ Phase = 'Done'; Result = 'Error'; ErrorMessage = $_.Exception.Message }
    exit 9999
}