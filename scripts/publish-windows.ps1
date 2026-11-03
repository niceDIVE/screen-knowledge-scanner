[CmdletBinding()]
param([ValidateSet('win-x64','win-arm64')][string]$Runtime='win-x64')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$staging=Join-Path ([IO.Path]::GetTempPath()) ("screen-publish-" + [guid]::NewGuid().ToString('N'))
Push-Location $root
try {
    New-Item -ItemType Directory -Force artifacts | Out-Null
    & dotnet publish src/Screen.App/Screen.App.csproj -c Release -r $Runtime --self-contained true `
        -p:WindowsDesktop=true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o $staging
    if($LASTEXITCODE -ne 0){throw 'Publish failed'}
    Copy-Item scripts/start-published.cmd (Join-Path $staging 'start.cmd')
    Copy-Item docs/使用说明.md $staging
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath "artifacts/screen-$Runtime.zip" -Force
    "Ready: artifacts/screen-$Runtime.zip"
} finally {
    Pop-Location
    if(Test-Path -LiteralPath $staging){Remove-Item -LiteralPath $staging -Recurse -Force}
}
