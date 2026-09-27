# Dev-only transformer (not shipped: Scripts/_*.ps1 is excluded from the release zip).
#
# CONSERVATIVE by design. Only rewrites blocks whose opening line CLOSES its own argument
# list, i.e. the exact shape:
#     $uiHash.ListView.Dispatcher.Invoke('Normal'|'Background',[action]{
#         ...row property writes...
#     })
# and only when the body contains an EditItem call and the closing line is exactly "})".
# Anything else is reported for manual handling - no guessing.
#
# History: a first attempt transformed every dispatcher block and corrupted the file two
# ways - (a) the appended "if ($stateStore) {...}" line was double-quoted so $stateStore
# interpolated to EMPTY inside the transformer, emitting "if ( ) { ... }" into the module;
# (b) single-line blocks swallowed the statement that followed them. Both fixed here.
# The single-quote rule is the one to remember for any future generator like this.
param([switch]$Apply)

$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Wuu.Core.psm1'
$lines = Get-Content -LiteralPath $path
$out = New-Object System.Collections.Generic.List[string]
$transformed = 0
$skipped = New-Object System.Collections.Generic.List[string]

$openRe = "^(\s*)\`$uiHash\.ListView\.Dispatcher\.Invoke\('(Normal|Background)',\[action\]\{\s*$"
$statusRe = "^(\s*)\`$uiHash\.StatusTextBox\.Dispatcher\.Invoke\('(Normal|Background)',\s*\[action\]\{\s*$"
$dropRe = @(
    '^\s*\$uiHash\.Listview\.Items\.EditItem\(.*\)\s*$',
    '^\s*\$uiHash\.Listview\.Items\.CommitEdit\(\)\s*$',
    '^\s*\$uiHash\.Listview\.Items\.Refresh\(\)\s*$'
)

$i = 0
while ($i -lt $lines.Count) {
    $line = $lines[$i]
    $isStatus = $line -match $statusRe
    $isRow = (-not $isStatus) -and ($line -match $openRe)

    if ($isStatus) {
        $indent = $Matches[1]
        if ($line -match "\[action\]\{\s*(.+?)\s*\}\s*\)\s*\|?\s*(Out-Null)?\s*$") {
            $inner = $Matches[1]
            if ($inner -match '\$uiHash\.StatusTextBox\.Text\s*=\s*(.+?)\s*$') {
                $out.Add(("{0}`$stateStore.SetStatus({1})" -f $indent, $Matches[1]))
                $transformed++
            } else {
                $out.Add($line); $skipped.Add("line $($i+1): status single-line unrecognised")
            }
        } else {
            $out.Add($line); $skipped.Add("line $($i+1): multiline status invoke needs manual care")
        }
        $i++; continue
    }

    if ($isRow) {
        $indent = $Matches[1]
        $depth = 1
        $j = $i + 1
        $body = New-Object System.Collections.Generic.List[string]
        $editVar = $null
        $found = $false
        while ($j -lt $lines.Count) {
            $l = $lines[$j]
            $depth += ([regex]::Matches($l, '\{')).Count - ([regex]::Matches($l, '\}')).Count
            if ($depth -le 0) { $found = $true; break }
            $body.Add($l)
            if ($l -match '\$uiHash\.Listview\.Items\.EditItem\(\s*\$?([A-Za-z_][A-Za-z0-9_]*)\s*\)') { $editVar = $Matches[1] }
            $j++
        }
        if (-not $found -or $lines[$j].Trim() -ne '})' -or -not $editVar) {
            $out.Add($line)
            $skipped.Add("line $($i+1): shape not matched")
            $i++; continue
        }

        $newBody = New-Object System.Collections.Generic.List[string]
        foreach ($b in $body) {
            $drop = $false
            foreach ($r in $dropRe) { if ($b -match $r) { $drop = $true; break } }
            if ($drop) { continue }
            if ($b -match 'Brushes\]::(LightGray|LightYellow|LightGreen)') {
                $colour = switch ($Matches[1]) { 'LightGray' { 'Error' } 'LightYellow' { 'Timeout' } 'LightGreen' { 'Success' } default { 'Default' } }
                $newBody.Add(("{0}`$$editVar.Color = '{1}'" -f $indent, $colour))
                continue
            }
            $b = $b -replace '\$uiHash\.AutoDownloadCheckBox\.IsChecked', '$stateStore.Settings.AutoDownload'
            $b = $b -replace '\$uiHash\.AutoInstallCheckBox\.IsChecked', '$stateStore.Settings.AutoInstall'
            $b = $b -replace '\$uiHash\.AutoRebootCheckBox\.IsChecked', '$stateStore.Settings.AutoReboot'
            $newBody.Add($b)
        }
        # SINGLE-quoted format string - double quotes interpolate $stateStore to empty HERE.
        $newBody.Add(('{0}if ($stateStore) {{ $stateStore.Touch() }}' -f $indent))

        foreach ($nl in $newBody) { $out.Add($nl) }
        $transformed++
        $i = $j + 1
        continue
    }

    $out.Add($line)
    $i++
}

Write-Host "Transformed blocks: $transformed"
Write-Host "Remaining Dispatcher lines: $((($out | Select-String -Pattern 'Dispatcher').Count))"
if ($skipped.Count) { Write-Host "Skipped for manual review ($($skipped.Count)):"; foreach ($s in $skipped) { Write-Host "  $s" } }

if ($Apply) {
    Set-Content -LiteralPath $path -Value $out -Encoding UTF8
    Write-Host "APPLIED to $path"
} else {
    Write-Host '(dry run - pass -Apply to write)'
}
