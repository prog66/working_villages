[CmdletBinding()]
param(
    [string]$VersionFile = "",
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ContainedRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$ChildPath
    )
    $basePrefix = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
    $childFullPath = [System.IO.Path]::GetFullPath($ChildPath)
    if (-not $childFullPath.StartsWith($basePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes expected root: $childFullPath"
    }
    return $childFullPath.Substring($basePrefix.Length).Replace('\', '/')
}

$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $toolsRoot ".."))
$sourceRoot = Join-Path $repositoryRoot "working_villagers"
if ($VersionFile -eq "") {
    $VersionFile = Join-Path $sourceRoot "VERSION"
}
if ($OutputRoot -eq "") {
    $OutputRoot = Join-Path $repositoryRoot "dist"
}
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)

$version = (Get-Content -LiteralPath $VersionFile -Raw).Trim()
if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+-(alpha|beta|rc)\.[0-9]+$') {
    throw "Unsupported release label: $version"
}

$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
    throw "Unable to resolve a valid Git source commit"
}
$sourceCommitShort = $sourceCommit.Substring(0, [Math]::Min(8, $sourceCommit.Length))
$buildDate = Get-Date -Format "yyyyMMdd"
$packageLabel = "working_villages-$version-local-$buildDate-s$sourceCommitShort"
$archivePath = Join-Path $OutputRoot "$packageLabel.zip"
$archivePartialPath = "$archivePath.partial.zip"
$archiveHashPath = "$archivePath.sha256"
$stageRoot = Join-Path $OutputRoot ".$packageLabel.stage"
$packageRoot = Join-Path $stageRoot "working_villages"

if (Test-Path -LiteralPath $archivePath) {
    throw "Release archive already exists: $archivePath"
}
if (Test-Path -LiteralPath $archivePartialPath) {
    throw "Partial release archive already exists: $archivePartialPath"
}
if (Test-Path -LiteralPath $archiveHashPath) {
    throw "Release checksum already exists: $archiveHashPath"
}
if (Test-Path -LiteralPath $stageRoot) {
    throw "Release staging directory already exists: $stageRoot"
}

$releaseCompleted = $false
try {
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

function Copy-ReleaseFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$RelativeDestination
    )
    $destination = Join-Path $packageRoot $RelativeDestination
    $destinationDirectory = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $destination
}

# Runtime allowlist. This intentionally does not use git archive: the audited
# snapshot contains required untracked runtime files and intentional deletions.
Get-ChildItem -LiteralPath $sourceRoot -File -Filter "*.lua" | Where-Object {
    $_.Name -ne "building_sign.lua"
} | Sort-Object Name | ForEach-Object {
    Copy-ReleaseFile -Source $_.FullName -RelativeDestination $_.Name
}

foreach ($directory in @("compat", "jobs")) {
    $directoryRoot = Join-Path $sourceRoot $directory
    Get-ChildItem -LiteralPath $directoryRoot -File -Filter "*.lua" | Where-Object {
        $_.Name -notlike "EXAMPLE_*"
    } | Sort-Object Name | ForEach-Object {
        Copy-ReleaseFile -Source $_.FullName -RelativeDestination (Join-Path $directory $_.Name)
    }
}

Get-ChildItem -LiteralPath (Join-Path $sourceRoot "schems") -File -Filter "*.we" |
    Sort-Object Name | ForEach-Object {
        Copy-ReleaseFile -Source $_.FullName -RelativeDestination (Join-Path "schems" $_.Name)
    }
Get-ChildItem -LiteralPath (Join-Path $sourceRoot "textures") -File -Filter "*.png" |
    Where-Object { $_.Name -ne "working_villages_pixel.png" } |
    Sort-Object Name | ForEach-Object {
        Copy-ReleaseFile -Source $_.FullName -RelativeDestination (Join-Path "textures" $_.Name)
    }

foreach ($metadata in @("mod.conf", "depends.txt", "settingtypes.txt", "VERSION")) {
    Copy-ReleaseFile -Source (Join-Path $sourceRoot $metadata) -RelativeDestination $metadata
}
foreach ($document in @(
    "LICENSE",
    "README.MD",
    "INSTALLATION.md",
    "DEPLOYMENT.md",
    "AUDIT_STATUS.md",
    "VALIDATION_CHECKLIST.md",
    "CHANGELOG.md",
    "ARCHITECTURE.md",
    "API_REFERENCE.md",
    "ROADMAP.md",
    "CONTRIBUTING.md",
    "BLUEPRINTS.md",
    "JOBS.md"
)) {
    Copy-ReleaseFile -Source (Join-Path $repositoryRoot $document) -RelativeDestination $document
}
foreach ($screenshot in @(
    "screenshot.png",
    "screenshot.2.png",
    "screenshot.3.png",
    "screenshot.4.png"
)) {
    Copy-ReleaseFile -Source (Join-Path $repositoryRoot $screenshot) -RelativeDestination $screenshot
}

# README links use repository-relative paths for these two developer resources.
# Preserve those paths inside the package so every local documentation link
# remains usable without shipping the full test/source tree.
Copy-ReleaseFile -Source (Join-Path $sourceRoot "api.MD") `
    -RelativeDestination "working_villagers/api.MD"
Copy-ReleaseFile -Source (Join-Path $sourceRoot "jobs\EXAMPLE_enhanced_plant_collector.lua") `
    -RelativeDestination "working_villagers/jobs/EXAMPLE_enhanced_plant_collector.lua"

$sourceDirty = ((& git -C $repositoryRoot status --porcelain=v1 --untracked-files=all) | Measure-Object).Count -gt 0
$packageInfo = @(
    "name=working_villages",
    "version=$version",
    "channel=local-alpha",
    "built_on=$buildDate",
    "source_commit=$sourceCommit",
    "source_worktree_dirty=$($sourceDirty.ToString().ToLowerInvariant())",
    "validated_engine=Luanti 5.10.0 (alpha.7); Luanti 5.17.0 (prior harnesses)",
    "manual_client_validation=false",
    "autonomous_economy_e2e=false"
)
[System.IO.File]::WriteAllLines(
    (Join-Path $packageRoot "PACKAGE_INFO.txt"),
    $packageInfo,
    [System.Text.UTF8Encoding]::new($false)
)

$manifestEntries = @(Get-ChildItem -LiteralPath $packageRoot -File -Recurse |
    Where-Object { $_.Name -ne "PACKAGE_MANIFEST.sha256" } |
    ForEach-Object {
        $relative = Get-ContainedRelativePath -BasePath $packageRoot -ChildPath $_.FullName
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $relative"
    } | Sort-Object)
[System.IO.File]::WriteAllLines(
    (Join-Path $packageRoot "PACKAGE_MANIFEST.sha256"),
    $manifestEntries,
    [System.Text.UTF8Encoding]::new($false)
)

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
Compress-Archive -LiteralPath $packageRoot -DestinationPath $archivePartialPath -CompressionLevel Optimal

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($archivePartialPath)
try {
    foreach ($entry in $zip.Entries) {
        $normalizedEntry = $entry.FullName.Replace('\', '/')
        if ($normalizedEntry.StartsWith('/') -or
                $normalizedEntry -match '(^|/)\.\.(/|$)' -or
                $normalizedEntry.Contains(':') -or
                -not $normalizedEntry.StartsWith('working_villages/')) {
            throw "Unsafe or unexpected archive entry: $normalizedEntry"
        }
    }
    $requiredEntries = @(
        "working_villages/mod.conf",
        "working_villages/init.lua",
        "working_villages/VERSION",
        "working_villages/PACKAGE_MANIFEST.sha256"
    )
    foreach ($required in $requiredEntries) {
        if (-not ($zip.Entries | Where-Object { $_.FullName.Replace('\', '/') -eq $required })) {
            throw "Archive is missing required entry: $required"
        }
    }
}
finally {
    $zip.Dispose()
}

$verificationRoot = Join-Path $stageRoot "_verify"
[System.IO.Compression.ZipFile]::ExtractToDirectory($archivePartialPath, $verificationRoot)
$verifiedPackageRoot = Join-Path $verificationRoot "working_villages"
$verifiedManifest = Join-Path $verifiedPackageRoot "PACKAGE_MANIFEST.sha256"
$expectedFiles = @{}
foreach ($line in Get-Content -LiteralPath $verifiedManifest) {
    if ($line -notmatch '^([0-9a-f]{64})  (.+)$') {
        throw "Malformed package manifest entry: $line"
    }
    $expectedHash = $Matches[1]
    $relative = $Matches[2].Replace('\', '/')
    if ($relative -eq "PACKAGE_MANIFEST.sha256" -or $expectedFiles.ContainsKey($relative)) {
        throw "Duplicate or reserved package manifest entry: $relative"
    }
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $verifiedPackageRoot $relative))
    $verifiedPrefix = [System.IO.Path]::GetFullPath($verifiedPackageRoot).TrimEnd('\') + '\'
    if (-not $candidate.StartsWith($verifiedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest path escapes package root: $relative"
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Manifest file is missing after extraction: $relative"
    }
    $actualHash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "Manifest hash mismatch after extraction: $relative"
    }
    $expectedFiles[$relative] = $true
}
$actualExtractedFiles = @(Get-ChildItem -LiteralPath $verifiedPackageRoot -File -Recurse)
if ($actualExtractedFiles.Count -ne ($expectedFiles.Count + 1)) {
    throw "Extracted file count does not match manifest"
}
foreach ($file in $actualExtractedFiles) {
    $relative = Get-ContainedRelativePath -BasePath $verifiedPackageRoot -ChildPath $file.FullName
    if ($relative -ne "PACKAGE_MANIFEST.sha256" -and -not $expectedFiles.ContainsKey($relative)) {
        throw "Extracted file is absent from manifest: $relative"
    }
}

Move-Item -LiteralPath $archivePartialPath -Destination $archivePath
$archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText(
    $archiveHashPath,
    "$archiveHash  $([System.IO.Path]::GetFileName($archivePath))`n",
    [System.Text.UTF8Encoding]::new($false)
)

$releaseCompleted = $true
Write-Output "PACKAGE_PATH=$archivePath"
Write-Output "PACKAGE_SHA256=$archiveHash"
Write-Output "PACKAGE_FILES=$($manifestEntries.Count)"
}
finally {
    $outputPrefix = $OutputRoot.TrimEnd('\') + '\'
    $resolvedStage = [System.IO.Path]::GetFullPath($stageRoot)
    if ($resolvedStage.StartsWith($outputPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedStage) -eq ".$packageLabel.stage" -and
            (Test-Path -LiteralPath $resolvedStage)) {
        Remove-Item -LiteralPath $resolvedStage -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $archivePartialPath) {
        Remove-Item -LiteralPath $archivePartialPath -Force -ErrorAction SilentlyContinue
    }
    if (-not $releaseCompleted) {
        if (Test-Path -LiteralPath $archivePath) {
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $archiveHashPath) {
            Remove-Item -LiteralPath $archiveHashPath -Force -ErrorAction SilentlyContinue
        }
    }
}
