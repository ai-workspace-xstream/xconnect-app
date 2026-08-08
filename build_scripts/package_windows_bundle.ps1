#!/usr/bin/env pwsh
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "windows_bundle_utils.ps1")

$releaseDir = Get-XConnectWindowsReleaseDir
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

Copy-XConnectBridgeDll -ReleaseDir $releaseDir
Copy-XConnectVcRuntime -ReleaseDir $releaseDir
Copy-XConnectWintunDll -ReleaseDir $releaseDir

# Package the release bundle.
$zipPath = Join-Path $releaseDir "xconnect-windows.zip"
if (Test-Path $zipPath) {
    Remove-Item -Force $zipPath
}
Compress-Archive -Path "$releaseDir/*" -DestinationPath $zipPath -Force

# Verify the package was created.
if (!(Test-Path $zipPath)) {
    Write-Error "Error: Zip package not created!"
    exit 1
}

Write-Host "Package created successfully: $zipPath"
