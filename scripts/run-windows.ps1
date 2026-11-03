[CmdletBinding()]
param([int]$Port = 8800, [switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    & dotnet build src/Screen.App/Screen.App.csproj -p:WindowsDesktop=true
    if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
    $url = "http://127.0.0.1:$Port"
    & dotnet src/Screen.App/bin/Debug/net10.0-windows10.0.19041.0/Screen.App.dll --urls $url "--Scanner:DataDirectory=$root/data" "--Scanner:OpenBrowser=$(-not $NoBrowser)"
    if ($LASTEXITCODE -ne 0) { throw 'Application exited with an error' }
} finally { Pop-Location }
