<#
  make-test-image.ps1 — 生成模拟 Discord 界面截图，用于验证 OCR 链路
#>
[CmdletBinding()]
param([string]$OutPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not $OutPath) {
    $root = Split-Path -Parent $PSScriptRoot
    $dir = Join-Path $root 'tests\output'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $OutPath = Join-Path $dir 'test-shot.png'
}
$bmp = New-Object System.Drawing.Bitmap 900, 560
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
$g.Clear([System.Drawing.Color]::FromArgb(49, 51, 56))   # Discord #313338

$fontId   = New-Object System.Drawing.Font('Microsoft YaHei', 10, [System.Drawing.FontStyle]::Bold)
$fontMsg  = New-Object System.Drawing.Font('Microsoft YaHei', 10)
$fontCode = New-Object System.Drawing.Font('Consolas', 9)
$wName = [System.Drawing.Brushes]::White
$wText = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(219, 222, 225))
$wDim  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(148, 155, 164))

$y = 18
function Draw-Name([string]$name, [string]$time, [int]$yy) {
    $script:g.DrawString($name, $script:fontId, $script:wName, 16, $yy)
    $script:g.DrawString($time, $script:fontMsg, $script:wDim, 90, $yy + 2)
}
function Draw-Msg([string]$msg, [int]$yy, [System.Drawing.Font]$f, [System.Drawing.Brush]$b) {
    $script:g.DrawString($msg, $f, $b, 16, $yy)
}

Draw-Name '星野' '今天 14:32' $y; $y += 24
Draw-Msg '预设的排版要控制 token 密度，别把正文挤掉了' $y $fontMsg $wText; $y += 40

Draw-Name 'Kagari' '今天 14:33' $y; $y += 24
Draw-Msg '收到，我把世界书的插入点整体后移了一格，生成稳定多了' $y $fontMsg $wText; $y += 40

Draw-Name '小夜' '今天 14:35' $y; $y += 24
Draw-Msg '{"preset_name":"深度润色","temperature":0.7,"prompt_order":[100,191,192]}' $y $fontCode $wText; $y += 26
Draw-Msg '上面这种 JSON 记得手动复制，OCR 会认错引号和花括号' $y $fontMsg $wText; $y += 40

Draw-Name '星野' '今天 14:36' $y; $y += 24
Draw-Msg '楼主整理的世界书分批触发写得很好，链接我收藏了' $y $fontMsg $wText; $y += 40

$g.Dispose()
$bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"测试图已生成: $OutPath"
