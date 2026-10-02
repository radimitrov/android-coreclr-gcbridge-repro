<#
.SYNOPSIS
    Installs the latest .NET 11 preview SDK and the android workload into .dotnet11\ next to this
    script, for the CoreCLR-net11 variant. Nothing system-wide is touched; delete .dotnet11\ to undo.
    run-ab.ps1 picks it up automatically.
#>
$ErrorActionPreference = 'Stop'
$installDir = Join-Path $PSScriptRoot '.dotnet11'
$installScript = Join-Path $env:TEMP "dotnet-install-$([guid]::NewGuid()).ps1"
try {
    Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installScript
    & $installScript -Channel 11.0 -Quality preview -InstallDir $installDir
}
finally {
    if (Test-Path -LiteralPath $installScript) { Remove-Item -LiteralPath $installScript -Force }
}
$dotnet = Join-Path $installDir 'dotnet.exe'
# Workload commands must use the local dotnet, or the metadata lands in the system install.
& $dotnet workload install android
& $dotnet workload update
& $dotnet --version
& $dotnet workload list
