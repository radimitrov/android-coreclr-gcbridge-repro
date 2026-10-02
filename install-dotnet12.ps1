<#
.SYNOPSIS
    Installs the latest .NET 12 daily SDK and a .NET 12 Android workload into .dotnet12\ next to this
    script, for the CoreCLR-net12 variant - the first runtime with dotnet/runtime#131952. Nothing
    system-wide is touched; delete .dotnet12\ to undo. run-repro.ps1 runs this on first use.

.NOTES
    `dotnet workload install android` alone gives the .NET 11 manifest, which has no .NET 12 targets,
    and the .NET 12 manifest on the dotnet12 feed cannot go through the workload installer: it also
    lists a .NET 10 Android pack (Microsoft.Android.Sdk.net10) at a version that is not published on
    any public feed. A .NET 12 build never uses that pack, so after the regular install this lays the
    .NET 12 manifest and its Android SDK pack out by hand; the framework and runtime packs are then
    restored from the dotnet12 feed (see NuGet.config) like any package.
#>
$ErrorActionPreference = 'Stop'
$installDir = Join-Path $PSScriptRoot '.dotnet12'
$feed = 'https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet12/nuget/v3'

$installScript = Join-Path $env:TEMP "dotnet-install-$([guid]::NewGuid()).ps1"
try {
    Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installScript
    & $installScript -Channel 12.0 -Quality daily -InstallDir $installDir
}
finally {
    if (Test-Path -LiteralPath $installScript) { Remove-Item -LiteralPath $installScript -Force }
}
$dotnet = Join-Path $installDir 'dotnet.exe'
$sdkVersion = (& $dotnet --version).Trim()
# Feature band: 12.0.100-alpha.1.26480.102 -> 12.0.100-alpha.1
$band = ($sdkVersion -split '\.')[0..3] -join '.'
if ($sdkVersion -notmatch '-') { $band = ($sdkVersion -split '\.')[0..2] -join '.' }

# The regular install first: it brings the mono tooling the Android targets import.
& $dotnet workload install android --source https://api.nuget.org/v3/index.json --source "$feed/index.json"

function Get-LatestVersion([string]$id) {
    $versions = (Invoke-RestMethod "$feed/flat2/$($id.ToLowerInvariant())/index.json").versions
    # 37.99.0-preview.1.81: order by the numeric version, then by the build number at the end.
    return $versions | Sort-Object { [version](($_ -split '-')[0]) }, { [int](($_ -split '\.')[-1]) } | Select-Object -Last 1
}
function Expand-Package([string]$id, [string]$version, [string]$destination) {
    $lower = $id.ToLowerInvariant()
    $nupkg = Join-Path $env:TEMP "$lower.$version.zip"
    Invoke-WebRequest "$feed/flat2/$lower/$version/$lower.$version.nupkg" -OutFile $nupkg
    if (Test-Path $destination) { Remove-Item -Recurse -Force $destination }
    Expand-Archive $nupkg -DestinationPath $destination
    Remove-Item $nupkg
}

$manifestId = "Microsoft.NET.Sdk.Android.Manifest-$band"
$androidVersion = Get-LatestVersion $manifestId
Write-Host "Android workload manifest $androidVersion for band $band"

$staging = Join-Path $env:TEMP "android-manifest-$([guid]::NewGuid())"
Expand-Package $manifestId $androidVersion $staging
$manifestDir = Join-Path $installDir "sdk-manifests\$band\microsoft.net.sdk.android\$androidVersion"
New-Item -ItemType Directory -Force $manifestDir | Out-Null
Copy-Item (Join-Path $staging 'data\*') $manifestDir -Recurse -Force
Remove-Item -Recurse -Force $staging

Expand-Package 'Microsoft.Android.Sdk.Windows' $androidVersion (Join-Path $installDir "packs\Microsoft.Android.Sdk.Windows\$androidVersion")

& $dotnet --version
& $dotnet workload list
