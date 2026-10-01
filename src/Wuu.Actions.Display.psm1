#Requires -Version 5.1
<#
.DESCRIPTION
Console DISPLAY actions: "show available updates", "show installed updates", "show update history"
and "view update log". Extracted from Wuu.Core.psm1 (instructions SS8) - these are console output,
not engine logic, and Core should become a bootstrap/orchestration layer.

WHY A MODULE AND NOT Wuu.Console. Wuu.Console owns the renderers and the interactive loop; these are
ACTION HANDLERS of the same shape as the ones still in Core, and they need the state store to resolve
their targets. Each action therefore takes the store as a parameter, which is the same explicit-context
rule the rest of the codebase follows (never a module global for per-call state).

NOT EXTRACTED FROM THE SAME REGION, deliberately: $WUServiceAction is a RUNSPACE PAYLOAD passed to the
worker as `$ctx.WUServiceAction` (it may use only the injected `$WriteDebugLogScript` /
`$InvokePooledScript`, never a module function), and $GetErrors reads the ambient `$Error collection and
$performanceHash. Moving either here would break that contract, so they stay in Core.
#>

# The only state these actions need is the store whose rows they resolve targets from.
$script:WuuActionStore = $null

function Initialize-WuuDisplayActions {
    <#
    .SYNOPSIS Hands the display actions the state store they resolve targets from.
    .DESCRIPTION Called once during startup. Refuses $null, so a mis-ordered call cannot leave the
    actions silently operating on nothing.
    #>
    param([Parameter(Mandatory)][object]$StateStore)
    $script:WuuActionStore = $StateStore
}

function Show-WuuObjectTable {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][string]$Title,
        [int]$MaxWidth = 100
    )
    Write-Host ''
    Write-Host ("  $Title") -ForegroundColor White
    Write-Host ('  ' + ('-' * [Math]::Min($MaxWidth, 100))) -ForegroundColor DarkGray
    if (-not $Items -or $Items.Count -eq 0) {
        Write-Host '  (nothing to show)' -ForegroundColor DarkGray
        return
    }
    foreach ($item in $Items) {
        $props = @($item.PSObject.Properties | Where-Object { $_.Name -ne 'PSComputerName' })
        foreach ($p in $props) {
            $v = [string]$p.Value
            if ([string]::IsNullOrWhiteSpace($v)) { continue }
            if ($v.Length -gt $MaxWidth) { $v = $v.Substring(0, $MaxWidth - 1) + [char]0x2026 }
            Write-Host ("  {0,-24} {1}" -f ($p.Name + ':'), $v)
        }
        Write-Host ''
    }
}

function Invoke-WuuShowAvailableUpdates {
    param([Parameter(Mandatory)][object]$Store)
    $rows = @(Read-WuuSelection -Store $Store -Prompt 'Show available updates for which computers?')
    if ($rows.Count -eq 0) { Write-Host '  Cancelled.' -ForegroundColor Yellow; return }
    ForEach ($Computer in $rows) {
        $updates = @($updatesHash[$computer.computer])
        Show-WuuObjectTable -Items $updates -Title "$($Computer.computer): available updates ($($updates.Count))"
        foreach ($u in $updates) {
            Write-Host ("  - {0}" -f $u.Title)
        }
    }
}
function Invoke-WuuShowInstalledUpdates {
    param([Parameter(Mandatory)][object]$Store)
    $rows = @(Read-WuuSelection -Store $Store -Prompt 'Show installed updates for which computers?')
    if ($rows.Count -eq 0) { Write-Host '  Cancelled.' -ForegroundColor Yellow; return }
    ForEach ($Computer in $rows){
        $comResult = Invoke-RemoteComWithTimeout -ComputerName $Computer.computer -TimeoutSeconds 30 -ScriptBlock {
            param($ComputerName)
            try {
                $session = [activator]::CreateInstance([type]::GetTypeFromProgID('Microsoft.Update.Session', $ComputerName))
                $searcher = $session.CreateUpdateSearcher()
                $updates = @($searcher.Search('IsInstalled=1').Updates)
                $result = $updates | ForEach-Object {
                    [PSCustomObject]@{
                        Title = $_.Title
                        Description = $_.Description
                        IsUninstallable = $_.IsUninstallable
                        SupportUrl = $_.SupportUrl
                    }
                }
                return $result
            } catch {
                return @([PSCustomObject]@{ Error = $_.Exception.Message })
            }
        }
        if ($comResult.Success) {
            Show-WuuObjectTable -Items @($comResult.Output) -Title "$($Computer.computer): installed updates"
        } else {
            Update-Status "Failed to show installed updates for $($Computer.computer): $($comResult.Error)"
        }
    }
}
function Invoke-WuuShowUpdateHistory {
    param([Parameter(Mandatory)][object]$Store)
    Try{
        $rows = @(Read-WuuSelection -Store $Store -Prompt 'Show update history for which computers?')
        if ($rows.Count -eq 0) { Write-Host '  Cancelled.' -ForegroundColor Yellow; return }
        foreach ($computer in $rows) {
        $comResult = Invoke-RemoteComWithTimeout -ComputerName $computer.computer -TimeoutSeconds 30 -ScriptBlock {
            param($ComputerName)
            try {
                $session = [activator]::CreateInstance([type]::GetTypeFromProgID('Microsoft.Update.Session', $ComputerName))
                $searcher = $session.CreateUpdateSearcher()
                $history = @($searcher.QueryHistory(0, $searcher.GetTotalHistoryCount()))
                return $history | ForEach-Object {
                    [PSCustomObject]@{
                        Operation = switch($_.Operation){1 {"Installation"}; 2 {"Uninstallation"}; 3 {"Other"}; default {$_.Operation}}
                        Result = switch($_.ResultCode){1 {"Success"}; 2 {"Success (reboot required)"}; 4 {"Failure"}; default {$_.ResultCode}}
                        HResult = '0x' + [Convert]::ToString($_.HResult, 16)
                        Date = $_.Date
                        Title = $_.Title
                        Description = $_.Description
                        SupportUrl = $_.SupportUrl
                    }
                }
            } catch {
                return @([PSCustomObject]@{ Error = $_.Exception.Message })
            }
        }
        
        if ($comResult.Success) {
            Show-WuuObjectTable -Items @($comResult.Output) -Title "$($computer.computer): update history"
        } else {
            throw "Failed to retrieve update history: $($comResult.Error)"
        }
        }   # end foreach ($computer in $rows)
    } Catch{
            $computer.Status = "Error Occured: $($_.exception.Message)"
        if ($Store) { $Store.Touch() }
    }
}
function Invoke-WuuViewUpdateLog {
    param([Parameter(Mandatory)][object]$Store)
    # Console edition: print the local copy of the Windows Update log for each target.
    # (The GUI opened \\<computer>\c$\windows\windowsupdate.log with the default handler.)
    $rows = @(Read-WuuSelection -Store $Store -Prompt 'View Windows Update log for which computers?')
    if ($rows.Count -eq 0) { Write-Host '  Cancelled.' -ForegroundColor Yellow; return }
    foreach ($r in $rows) {
        $p = "\\$($r.computer)\c`$\windows\windowsupdate.log"
        if (Test-Path -LiteralPath $p) {
            Write-Host "  --- $($r.computer) ---" -ForegroundColor White
            Get-Content -LiteralPath $p -Tail 200 | Write-Host
        } else {
            Write-Host "  $($r.computer): log not reachable at $p" -ForegroundColor Yellow
        }
    }
}

Export-ModuleMember -Function @(
    'Initialize-WuuDisplayActions'
    'Show-WuuObjectTable'
    'Invoke-WuuShowAvailableUpdates'
    'Invoke-WuuShowInstalledUpdates'
    'Invoke-WuuShowUpdateHistory'
    'Invoke-WuuViewUpdateLog'
)
