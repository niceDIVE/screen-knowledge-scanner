#requires -Version 5.1
<#
  select-region.ps1 — 全屏半透明覆盖层，拖拽框选采集区域 → logs\region.json
  触发方式：守护进程热键 Ctrl+Alt+R，或 Web 控制台「框选区域」按钮。
  ESC 取消；拖拽距离太小视为取消。坐标为物理像素（进程 DPI 感知）。
#>
[CmdletBinding()]
param(
    [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    $self = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Root = Split-Path -Parent $self
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class U32R {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[void][U32R]::SetProcessDPIAware()

$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$regionFile = Join-Path $Root 'logs\region.json'

$form = New-Object System.Windows.Forms.Form
$form.Text = 'screen-region-select'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point($vs.X, $vs.Y)
$form.Size = New-Object System.Drawing.Size($vs.Width, $vs.Height)
$form.BackColor = [System.Drawing.Color]::Black
$form.Opacity = 0.30
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.KeyPreview = $true
$form.Cursor = [System.Windows.Forms.Cursors]::Cross

$script:dragStart = $null
$script:cur = [System.Drawing.Rectangle]::Empty

$form.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:dragStart = $e.Location
        $script:cur = [System.Drawing.Rectangle]::Empty
        $s.Invalidate()
    }
})
$form.Add_MouseMove({
    param($s, $e)
    if ($script:dragStart) {
        $x = [Math]::Min($script:dragStart.X, $e.X)
        $y = [Math]::Min($script:dragStart.Y, $e.Y)
        $w = [Math]::Abs($e.X - $script:dragStart.X)
        $h = [Math]::Abs($e.Y - $script:dragStart.Y)
        $script:cur = New-Object System.Drawing.Rectangle $x, $y, $w, $h
        $s.Invalidate()
    }
})
$form.Add_MouseUp({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    if ($script:cur.Width -ge 40 -and $script:cur.Height -ge 40) {
        # 覆盖层坐标 → 物理屏幕坐标（虚拟屏原点可能非 0）
        $rect = @{
            left   = $vs.X + $script:cur.X
            top    = $vs.Y + $script:cur.Y
            width  = $script:cur.Width
            height = $script:cur.Height
        }
        $json = $rect | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($regionFile, $json, (New-Object System.Text.UTF8Encoding $false))
        [System.Media.SystemSounds]::Asterisk.Play()
    }
    $s.Close()
})
$form.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $font = New-Object System.Drawing.Font('Microsoft YaHei', 13, [System.Drawing.FontStyle]::Bold)
    $g.DrawString('按住左键拖拽框选采集区域（滚轮扫描只拍这块），松开完成，ESC 取消', $font, [System.Drawing.Brushes]::Yellow, 24, 20)
    if (-not $script:cur.IsEmpty) {
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Yellow), 2
        $g.DrawRectangle($pen, $script:cur)
        $g.DrawRectangle($pen, ($script:cur.X + 2), ($script:cur.Y + 2), ($script:cur.Width - 4), ($script:cur.Height - 4))
        $pen.Dispose()
    }
})
$form.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $s.Close() }
})

[void]$form.ShowDialog()
