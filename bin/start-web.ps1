<#
  start-web.ps1 — 启动本地 Web 控制台并打开浏览器
    powershell -File start-web.ps1              # 后台启动 + 打开浏览器
    powershell -File start-web.ps1 -Foreground  # 前台运行（调试）
    powershell -File start-web.ps1 -Stop        # 停止
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [int]$Port = 0,
    [switch]$Stop,
    [switch]$Foreground
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    $self = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Root = Split-Path -Parent $self
}
if ([IO.Path]::IsPathRooted($Root)) { $Root = [IO.Path]::GetFullPath($Root) }
else { $Root = [IO.Path]::GetFullPath((Join-Path (Get-Location) $Root)) }
$logsDir = Join-Path $Root 'logs'
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
$pidFile = Join-Path $logsDir 'web.pid'
$urlFile = Join-Path $logsDir 'web.url'
$server  = Join-Path $Root 'bin\web-server.ps1'

function Test-Alive {
    if (-not (Test-Path $pidFile)) { return $null }
    $p = Get-Content $pidFile -ErrorAction SilentlyContinue
    $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -match '^powershell$') { return $p }
    return $null
}

if ($Stop) {
    $alive = Test-Alive
    if ($alive) {
        Stop-Process -Id $alive -Force
        "Web 控制台 (pid=$alive) 已停止"
    } else {
        'Web 控制台不在运行'
    }
    Remove-Item $pidFile, $urlFile -Force -ErrorAction SilentlyContinue
    return
}

if ($Foreground) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $server -Root $Root -Port $Port
    return
}

# 已在运行 → 直接开浏览器
$alive = Test-Alive
if ($alive -and (Test-Path $urlFile)) {
    $url = Get-Content $urlFile -ErrorAction SilentlyContinue
    if ($url) { Start-Process $url; "控制台已在运行: $url"; return }
}

# 启动
$srvArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $server, '-Root', $Root)
if ($Port -gt 0) { $srvArgs += @('-Port', "$Port") }
$null = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList $srvArgs

$url = $null
foreach ($i in 1..30) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $urlFile) { $url = Get-Content $urlFile -ErrorAction SilentlyContinue; if ($url) { break } }
}
if (-not $url) {
    '启动失败，请查看 logs\web.log'
    return
}

$cfgPath = Join-Path $Root 'config.psd1'
$openBrowser = $true
if (Test-Path $cfgPath) {
    try {
        $cfg = Import-PowerShellDataFile $cfgPath
        if ($cfg.Web -and ($cfg.Web.OpenBrowser -eq $false)) { $openBrowser = $false }
    } catch { }
}
if ($openBrowser) { Start-Process $url }
"Web 控制台: $url"
"停止: powershell -File start-web.ps1 -Stop"
