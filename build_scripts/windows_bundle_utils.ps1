Set-Variable -Name XConnectWintunVersion -Option ReadOnly -Value "0.14.1"
Set-Variable -Name XConnectWintunSha256 -Option ReadOnly -Value "07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51"
Set-Variable -Name XConnectWintunZipUrl -Option ReadOnly -Value "https://www.wintun.net/builds/wintun-0.14.1.zip"

function Get-XConnectWindowsReleaseDir {
    return Join-Path $PSScriptRoot "..\build\windows\x64\runner\Release"
}

function Copy-XConnectBridgeDll {
    param(
        [Parameter(Mandatory = $true)][string]$ReleaseDir
    )

    $source = Join-Path $PSScriptRoot "..\bindings\libgo_native_bridge.dll"
    if (-not (Test-Path $source)) {
        throw "libgo_native_bridge.dll not found at $source"
    }

    Copy-Item $source -Destination $ReleaseDir -Force
    Write-Host "Copied bridge DLL: $source"
}

function Get-XConnectVcRedistDir {
    $candidates = @()

    if ($env:VCToolsRedistDir) {
        $candidates += (Join-Path $env:VCToolsRedistDir "x64\Microsoft.VC143.CRT")
        $candidates += (Join-Path $env:VCToolsRedistDir "x64\Microsoft.VC145.CRT")
    }

    $globbed = Get-ChildItem `
        "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Redist\MSVC" `
        -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending

    foreach ($entry in $globbed) {
        $candidates += (Join-Path $entry.FullName "x64\Microsoft.VC145.CRT")
        $candidates += (Join-Path $entry.FullName "x64\Microsoft.VC143.CRT")
    }

    foreach ($dir in $candidates) {
        if (Test-Path (Join-Path $dir "vcruntime140.dll")) {
            return $dir
        }
    }

    return $null
}

function Copy-XConnectVcRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$ReleaseDir
    )

    $redistDir = Get-XConnectVcRedistDir
    if (-not $redistDir) {
        Write-Warning "Visual C++ redistributable directory not found. Portable package may require the VC runtime to be installed on the target machine."
        return
    }

    foreach ($name in @("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")) {
        $source = Join-Path $redistDir $name
        if (Test-Path $source) {
            Copy-Item $source -Destination $ReleaseDir -Force
            Write-Host "Copied VC runtime: $source"
        }
    }
}

function Get-XConnectWintunCacheDir {
    return Join-Path $env:LOCALAPPDATA "XConnect\cache\wintun\$XConnectWintunVersion"
}

function Resolve-XConnectWintunDll {
    $cacheDir = Get-XConnectWintunCacheDir
    $dllPath = Join-Path $cacheDir "wintun\bin\amd64\wintun.dll"
    if (Test-Path $dllPath) {
        return $dllPath
    }

    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

    $zipPath = Join-Path $cacheDir "wintun-$XConnectWintunVersion.zip"
    Invoke-WebRequest -Uri $XConnectWintunZipUrl -OutFile $zipPath

    $actualHash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $XConnectWintunSha256) {
        throw "Downloaded wintun.zip hash mismatch. Expected $XConnectWintunSha256, got $actualHash"
    }

    Expand-Archive -Path $zipPath -DestinationPath $cacheDir -Force

    if (-not (Test-Path $dllPath)) {
        throw "wintun.dll not found in downloaded archive: $dllPath"
    }

    return $dllPath
}

function Copy-XConnectWintunDll {
    param(
        [Parameter(Mandatory = $true)][string]$ReleaseDir
    )

    $source = Resolve-XConnectWintunDll
    Copy-Item $source -Destination (Join-Path $ReleaseDir "wintun.dll") -Force
    Write-Host "Copied Wintun DLL: $source"
}
