param(
    # Nested Join-Path keeps Windows PowerShell 5.1 compatibility (3-arg Join-Path is PS7+)
    [string]$OutputDirectory = (Join-Path (Join-Path $PSScriptRoot "..") "dist"),
    [string]$ZipName = ("WUU2_{0}.zip" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
)

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$OutputDirectory = (Resolve-Path (New-Item -ItemType Directory -Path $OutputDirectory -Force)).Path

$staging = Join-Path $OutputDirectory "staging"
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging -Force | Out-Null

# Core runnable files + docs
$include = @(
    "WUU.ps1",
    "ComputerList.config",
    "Exempt.txt",
    "README.md",
    "LICENSE",
    "Kill-WUU-Processes.ps1"
)

foreach ($rel in $include) {
    $src = Join-Path $repoRoot $rel
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $staging $rel) -Force
    }
}

# ui/ was removed in the console edition (Phase 1): the shell renders the state store instead
# of XAML. Do not re-add a ui/ copy here.

# src/ modules (WUU.ps1 imports them at startup)
$srcSrc = Join-Path $repoRoot "src"
if (Test-Path $srcSrc) {
    Copy-Item -Path $srcSrc -Destination (Join-Path $staging "src") -Recurse -Force
}

# Include helper scripts folder
$scriptsSrc = Join-Path $repoRoot "Scripts"
$scriptsDst = Join-Path $staging "Scripts"
if (Test-Path $scriptsSrc) {
    Copy-Item -Path $scriptsSrc -Destination $scriptsDst -Recurse -Force

    # Don’t include the packager itself inside the zip (optional, avoids nesting tooling)
    $selfInZip = Join-Path $scriptsDst "Package-WUU2.ps1"
    if (Test-Path $selfInZip) { Remove-Item $selfInZip -Force }

    # Exclude dev-only scratch/tooling (_*.ps1, e.g. _syntax-check, _pack-*). Nothing the
    # app runs at runtime references them - ConfigPaths only uses Download-Patches.ps1 and
    # Install-Patches.ps1 - so they must not ship in a release zip.
    Get-ChildItem -Path $scriptsDst -Filter "_*.ps1" -File -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Force }
}

# Include markdown docs (optional but useful)
Get-ChildItem -Path $repoRoot -Filter "*.md" -File | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $staging $_.Name) -Force
}

$zipPath = Join-Path $OutputDirectory $ZipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

# Compress-Archive's constructor intermittently throws (ConstructorInvokedThrowException)
# when the destination is in the OneDrive-synced dist/ and leaves NO zip behind while
# still reaching the success message below. Use the proven ZipFile API instead (matches
# the beta.3 helper) and verify the archive actually exists with a real entry count.
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($staging, $zipPath)

if (-not (Test-Path $zipPath)) {
    throw "Packaging failed: zip was not created at $zipPath"
}
$verify = [IO.Compression.ZipFile]::OpenRead($zipPath)
$entryCount = $verify.Entries.Count
$verify.Dispose()
if ($entryCount -lt 1) { throw "Packaging failed: zip at $zipPath has 0 entries" }

Write-Host "Created package: $zipPath ($entryCount entries)" -ForegroundColor Green
Write-Host "Staging folder: $staging" -ForegroundColor DarkGray
