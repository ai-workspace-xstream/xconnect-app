$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../build_scripts/windows_bundle_utils.ps1')

foreach ($case in @(
    @('1.0.0+2', '1.0.2'),
    @('1.0.1+3', '1.0.3'),
    @('255.255.999+65535', '255.255.65535')
)) {
    $actual = ConvertTo-XConnectMsiVersion -Version $case[0]
    if ($actual -ne $case[1]) { throw "Unexpected MSI version: $actual" }
}
$old = [version](ConvertTo-XConnectMsiVersion -Version '1.0.0+2')
$next = [version](ConvertTo-XConnectMsiVersion -Version '1.0.0+3')
if ($next -le $old) { throw 'Build-only upgrade must increase MSI ProductVersion.' }
if ($old -le [version]'1.0.0') { throw 'New scheme must upgrade the legacy 1.0.0.2 package.' }
foreach ($invalid in @('1.0.0', '1.0.0+65536', '256.0.0+1', '1.256.0+1', '1.0.0+-1', '01.0.0+2', '1.0.0+999999999999999999999999')) {
    $rejected = $false
    try { $null = ConvertTo-XConnectMsiVersion -Version $invalid } catch { $rejected = $true }
    if (-not $rejected) { throw "Expected invalid version to be rejected: $invalid" }
}
Write-Output 'Windows MSI upgrade version checks passed.'

$packager = Get-Content (Join-Path $PSScriptRoot '../../build_scripts/package_windows_msi.ps1') -Raw
foreach ($requiredUi in @('WixToolset.UI.wixext/5.0.2', 'WixUI_InstallDir', 'InstallDirectory="INSTALLFOLDER"', 'WixUILicenseRtf', 'WixUI_ErrorProgressText')) {
    if ($packager -notmatch [regex]::Escape($requiredUi)) {
        throw "Windows MSI standard installer UI is missing: $requiredUi"
    }
}
