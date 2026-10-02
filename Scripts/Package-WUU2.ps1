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
#
# ComputerList.config is DELIBERATELY absent. It is .gitignore'd operator data - an encrypted computer
# list plus its credential block - and the application creates and loads it at runtime. Listing it here
# meant a build made on a working machine would ship that operator's estate and its encrypted
# credentials inside a release zip. It was never present in CI, where the name simply matched nothing.
$include = @(
    "WUU.ps1",
    "Exempt.txt",
    "README.md",
    "LICENSE",
    "NOTICE",
    "Kill-WUU-Processes.ps1"
)

# Report a missing include rather than skipping it in silence. The old loop's Test-Path guard treated
# "renamed or removed" exactly like "intentionally optional", so an entry could stop shipping and the
# only evidence was a smaller zip. Nothing is fatal here - the packager's job is to report, and a name
# that matches nothing is a defect in this list.
foreach ($rel in $include) {
    $src = Join-Path $repoRoot $rel
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $staging $rel) -Force
    } else {
        Write-Warning "Included file not found, so it will NOT be packaged: $rel"
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

# Include docs\ recursively. The top-level copy above misses everything under docs\ (it is not
# -Recurse), which meant a release zip shipped NO compliance documentation at all - the ISO 27001
# control mapping and the audit retention policy were silently absent from the package. A
# release that cannot answer "what are these audit records, and how long are they kept?" is not
# usable for the purpose it exists. Preserve the docs\ subfolder so the references inside the
# documents (docs\..., docs/...) still resolve.
#
# GUI-edition documents are EXCLUDED: the history was inherited from the GUI repo, so docs\ still
# contains WPF/ListView/column-resize material that describes an interface this edition does not
# have. Shipping it in a console package would misdirect a tester in the same way the GUI README
# does. They remain in the repo as history; they are just not part of a CLI release.
$docsSrc = Join-Path $repoRoot "docs"
if (Test-Path $docsSrc) {
    $docsDst = Join-Path $staging "docs"
    New-Item -ItemType Directory -Path $docsDst -Force | Out-Null
    $guiOnlyDocs = @(
        'GUI_FUNCTIONALITY_ANALYSIS.md'
        'GUI_HANG_FIX_COMPREHENSIVE.md'
        'SUGGESTIONS_FOR_GUI.md'
        'PASSWORD_LAG_FIX.md'
        'COMPUTER_LIST_CRASH_FIX.md'
        'TIMEOUT_STATE_MACHINE_PLAN.md'
    )
    Get-ChildItem -Path $docsSrc -Filter "*.md" -File |
        Where-Object { $guiOnlyDocs -notcontains $_.Name } |
        ForEach-Object { Copy-Item -Path $_.FullName -Destination (Join-Path $docsDst $_.Name) -Force }
}

$zipPath = Join-Path $OutputDirectory $ZipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

# Compress-Archive's constructor intermittently throws (ConstructorInvokedThrowException)
# when the destination is in the OneDrive-synced dist/ and leaves NO zip behind while
# still reaching the success message below. Use the ZipFile API instead and verify the archive
# actually exists with a real entry count.
#
# ENTRIES ARE BUILT ONE AT A TIME, with "/" separators. [ZipFile]::CreateFromDirectory on Windows
# writes the platform separator, so the archive contained entries like "docs\ARCHITECTURE.md" -
# 85 of 91 entries in a measured build. The ZIP spec (APPNOTE 4.4.17) requires "/", and extractors
# on Linux and macOS take the name literally, creating a file CALLED "docs\ARCHITECTURE.md" in the
# extraction root instead of a docs/ folder. The documents an ISO 27001 review needs would then be
# present but unfindable. Deriving the name from the relative path is what keeps it portable.
# BOTH assemblies are required: ZipFile lives in System.IO.Compression.FileSystem, while the
# ZipArchiveMode enum and CreateEntryFromFile live in System.IO.Compression. Loading only the former
# gave "Unable to find type [IO.Compression.ZipArchiveMode]" - measured, not assumed.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    $stagingFull = (Resolve-Path $staging).Path.TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
    foreach ($f in @(Get-ChildItem -Path $staging -Recurse -File)) {
        $entryName = $f.FullName.Substring($stagingFull.Length).Replace([char]92, [char]47)
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $f.FullName, $entryName, [IO.Compression.CompressionLevel]::Optimal)
    }
} finally {
    $zip.Dispose()
}

if (-not (Test-Path $zipPath)) {
    throw "Packaging failed: zip was not created at $zipPath"
}
$verify = [IO.Compression.ZipFile]::OpenRead($zipPath)
$entryCount = $verify.Entries.Count
# SELF-CHECK: no entry may carry a backslash, or the archive is not portable.
$badSeparators = @($verify.Entries | Where-Object { $_.FullName -match '\\' })
$verify.Dispose()
if ($entryCount -lt 1) { throw "Packaging failed: zip at $zipPath has 0 entries" }
if ($badSeparators.Count -gt 0) {
    throw "Packaging failed: $($badSeparators.Count) entry(ies) use a backslash separator (first: '$($badSeparators[0].FullName)') - the ZIP spec requires '/' and non-Windows extractors take the name literally"
}

Write-Host "Created package: $zipPath ($entryCount entries)" -ForegroundColor Green
Write-Host "Staging folder: $staging" -ForegroundColor DarkGray
