[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [string]$TargetRoot = "",
    [switch]$Replace
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

$archivePath = (Resolve-Path -LiteralPath $PackagePath).Path
$hashPath = "$archivePath.sha256"
if (-not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
    throw "Missing package checksum: $hashPath"
}
if ($TargetRoot -eq "") {
    $TargetRoot = Join-Path $env:APPDATA "Minetest\mods"
}
$TargetRoot = [System.IO.Path]::GetFullPath($TargetRoot)
New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null

$expectedArchiveHashLine = (Get-Content -LiteralPath $hashPath -Raw).Trim()
if ($expectedArchiveHashLine -notmatch '^([0-9a-fA-F]{64})  [^\\/]+$') {
    throw "Malformed package checksum file: $hashPath"
}
$expectedArchiveHash = $Matches[1].ToLowerInvariant()
$actualArchiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualArchiveHash -ne $expectedArchiveHash) {
    throw "Package checksum mismatch"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
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
}
finally {
    $zip.Dispose()
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "working_villages_deploy_" + [guid]::NewGuid().ToString("N")
)
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
$extractedRoot = Join-Path $temporaryRoot "working_villages"

try {
    [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $temporaryRoot)
    $manifestPath = Join-Path $extractedRoot "PACKAGE_MANIFEST.sha256"
    $versionPath = Join-Path $extractedRoot "VERSION"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
        throw "Extracted package is missing its manifest or version"
    }

    $expectedFiles = @{}
    $extractedPrefix = [System.IO.Path]::GetFullPath($extractedRoot).TrimEnd('\') + '\'
    foreach ($line in Get-Content -LiteralPath $manifestPath) {
        if ($line -notmatch '^([0-9a-f]{64})  (.+)$') {
            throw "Malformed package manifest entry: $line"
        }
        $expectedHash = $Matches[1]
        $relative = $Matches[2].Replace('\', '/')
        if ($relative -eq "PACKAGE_MANIFEST.sha256") {
            throw "Reserved package manifest entry: $relative"
        }
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $extractedRoot $relative))
        if (-not $candidate.StartsWith($extractedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Manifest path escapes package root: $relative"
        }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Manifest file is missing: $relative"
        }
        $actualHash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "Manifest hash mismatch: $relative"
        }
        if ($expectedFiles.ContainsKey($relative)) {
            throw "Duplicate package manifest entry: $relative"
        }
        $expectedFiles[$relative] = $expectedHash
    }

    $extractedFiles = @(Get-ChildItem -LiteralPath $extractedRoot -File -Recurse)
    if ($extractedFiles.Count -ne ($expectedFiles.Count + 1)) {
        throw "Extracted file count does not match manifest"
    }
    foreach ($file in $extractedFiles) {
        $relative = Get-ContainedRelativePath -BasePath $extractedRoot -ChildPath $file.FullName
        if ($relative -ne "PACKAGE_MANIFEST.sha256" -and -not $expectedFiles.ContainsKey($relative)) {
            throw "Extracted file is absent from manifest: $relative"
        }
    }
    $expectedManifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $destination = [System.IO.Path]::GetFullPath((Join-Path $TargetRoot "working_villages"))
    $targetPrefix = $TargetRoot.TrimEnd('\') + '\'
    if (-not $destination.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Deployment destination escapes target root: $destination"
    }

    $backup = $null
    $destinationWasMoved = $false
    if (Test-Path -LiteralPath $destination) {
        if (-not $Replace) {
            throw "Deployment target already exists; use -Replace after reviewing it: $destination"
        }
        $backupName = "working_villages.backup-" + (Get-Date -Format "yyyyMMdd-HHmmss")
        $backup = [System.IO.Path]::GetFullPath((Join-Path $TargetRoot $backupName))
        if (-not $backup.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
                (Test-Path -LiteralPath $backup)) {
            throw "Unsafe or existing deployment backup: $backup"
        }
    }

    $copyStarted = $false
    try {
        if ($backup) {
            Move-Item -LiteralPath $destination -Destination $backup
            $destinationWasMoved = $true
        }
        $copyStarted = $true
        Copy-Item -LiteralPath $extractedRoot -Destination $destination -Recurse

        $deployedFiles = @(Get-ChildItem -LiteralPath $destination -File -Recurse)
        if ($deployedFiles.Count -ne ($expectedFiles.Count + 1)) {
            throw "Deployed file count does not match manifest"
        }
        foreach ($file in $deployedFiles) {
            $relative = Get-ContainedRelativePath -BasePath $destination -ChildPath $file.FullName
            if ($relative -eq "PACKAGE_MANIFEST.sha256") {
                $deployedManifestHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($deployedManifestHash -ne $expectedManifestHash) {
                    throw "Deployed package manifest hash mismatch"
                }
                continue
            }
            if (-not $expectedFiles.ContainsKey($relative)) {
                throw "Deployed file is absent from manifest: $relative"
            }
            $deployedHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($deployedHash -ne $expectedFiles[$relative]) {
                throw "Deployed file hash mismatch: $relative"
            }
        }
    }
    catch {
        $deploymentError = $_
        if ($copyStarted -and (Test-Path -LiteralPath $destination)) {
            Remove-Item -LiteralPath $destination -Recurse -Force
        }
        if ($destinationWasMoved -and (Test-Path -LiteralPath $backup) -and
                -not (Test-Path -LiteralPath $destination)) {
            try {
                Move-Item -LiteralPath $backup -Destination $destination
            }
            catch {
                throw "Deployment failed and automatic restore failed. Backup remains at $backup. Original error: $deploymentError"
            }
        }
        throw $deploymentError
    }

    Write-Output "DEPLOYED_PATH=$destination"
    Write-Output "DEPLOYED_VERSION=$((Get-Content -LiteralPath (Join-Path $destination 'VERSION') -Raw).Trim())"
    Write-Output "DEPLOYED_FILES=$($expectedFiles.Count)"
    if ($backup) {
        Write-Output "BACKUP_PATH=$backup"
    }
}
finally {
    $resolvedTemporary = [System.IO.Path]::GetFullPath($temporaryRoot)
    $systemTemporaryPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedTemporary.StartsWith($systemTemporaryPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedTemporary).StartsWith("working_villages_deploy_")) {
        Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
    }
}
