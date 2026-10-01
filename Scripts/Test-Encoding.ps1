# Release validation, SOURCE ENCODING group (af). Extracted from Validate-Release.ps1 (instructions SS39).
#
# DOT-SOURCED FRAGMENT - not a standalone script. Validate-Release.ps1 dot-sources it into its own
# scope, which is what gives this file $root and the verdict helpers (Pass/Fail/Warn/Skip/
# Not-Implemented), and what keeps this verdict in its ORIGINAL POSITION in the report - the order of
# the verdict list is part of what CI reads.

# (af) SOURCE ENCODING. A shipped file that contains non-ASCII BYTES must carry a UTF-8 BOM.
#
#      This gate exists because I broke it while working on SS11: I rewrote Wuu.Core.psm1 with
#      Set-Content, which under PS7 writes UTF8 WITHOUT a BOM, and the file (which contains 51
#      non-ASCII bytes - the '-' ellipsis and friends) was corrupted by the encoding change. git showed
#      the first line as '´╗┐#Requires' - the BOM bytes reinterpreted. Nothing in the test suite noticed,
#      because none of them check encoding.
#
#      The rule is verified against every shipped file, not assumed:
#        * 4 files contain non-ASCII and ALL FOUR have a BOM (Command, Core, Session, Package-WUU2);
#        * all 20 remaining files have zero non-ASCII bytes and no BOM.
#      So the invariant is 'non-ASCII implies BOM', and it is checked in that direction only - a BOM on
#      an ASCII-only file is harmless and is not treated as a failure.
$encodingFiles = @()
$encodingFiles += @(Get-ChildItem -Path (Join-Path $root 'src') -Filter '*.psm1' -File)
$encodingFiles += @(Get-ChildItem -Path $root -Filter '*.ps1' -File)
$encodingFiles += @(Get-ChildItem -Path (Join-Path $root 'Scripts') -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike '_*' })
$encodingOffenders = @()
foreach ($ef in $encodingFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($ef.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if ($hasBom) { continue }
    $nonAscii = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -ge 0x80) { $nonAscii++ } }
    if ($nonAscii -gt 0) { $encodingOffenders += "$($ef.Name) ($nonAscii non-ASCII byte(s), no BOM)" }
}
if ($encodingOffenders.Count -gt 0) {
    Fail ("shipped file(s) contain non-ASCII bytes WITHOUT a UTF-8 BOM - their text is encoding-dependent and a rewrite will corrupt it: " + ($encodingOffenders -join '; '))
} else {
    Pass "every shipped file with non-ASCII bytes carries a UTF-8 BOM ($($encodingFiles.Count) file(s) checked)"
}
