<#
  start-scanner.ps1 — 热键守护进程的启动/停止
    powershell -File start-scanner.ps1            # 后台启动（隐藏窗口）
    powershell -File start-scanner.ps1 -Foreground # 前台运行（调试用）
    powershell -File start-scanner.ps1 -Stop       # 停止
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [switch]$Stop,
    [switch]$Foreground
)
if (-not $Root) {
    $self = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Root = Split-Path -Parent $self
}
$daemon  = Join-Path $Root 'bin\scan-daemon.ps1'
$logsDir = Join-Path $Root 'logs'
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
$pidFile = Join-Path $logsDir 'daemon.pid'

if ($Stop) {
    if (Test-Path $pidFile) {
        $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue
        $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -match '^powershell$') {
            Stop-Process -Id $oldPid -Force
            "守护进程 (pid=$oldPid) 已停止"
        } else {
            "pid=$oldPid 的进程不存在或已易主，仅清除记录"
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    } else {
        '没有 daemon.pid 记录（守护进程可能没在运行）'
    }
    return
}

if ($Foreground) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $daemon -Root $Root
    return
}

$p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $daemon, '-Root', $Root
)
Set-Content -Path $pidFile -Value $p.Id
"守护进程已启动 pid=$($p.Id)"
"查看日志: Get-Content '$logsDir\daemon.log' -Tail 20 -Wait"
"停止: powershell -File start-scanner.ps1 -Stop"
