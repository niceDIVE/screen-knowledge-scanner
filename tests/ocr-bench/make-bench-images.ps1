<#
  make-bench-images.ps1 — 生成 OCR 准确率基线（T0）用的 5 张中文测试图 + 对应 ground truth。

  设计原则：
  - 每张图只渲染该用例的正文行，不画名字/时间等装饰，保证 ground truth 与画面逐字对应。
  - 覆盖真实使用中的两种底色（深色聊天客户端 / 浅色文章页）、三种字号、以及中英数标点密排。
  - 输出：<OutDir>\<name>.png 与 <OutDir>\<name>.txt（UTF-8 无 BOM，逐行拼接）。

  用法：
    powershell -File tests\ocr-bench\make-bench-images.ps1
    powershell -File tests\ocr-bench\make-bench-images.ps1 -OutDir C:\temp\bench
#>
[CmdletBinding()]
param([string]$OutDir)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not $OutDir) {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $OutDir = Join-Path $root 'tests\ocr-bench\output'
}
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$cases = @(
    @{
        Name = 'dark-10pt'
        Theme = 'dark'
        FontPt = 10
        Lines = @(
            '预设的排版要控制 token 密度，别把正文挤掉了',
            '收到，我把世界书的插入点整体后移了一格，生成稳定多了',
            '上面这种 JSON 记得手动复制，OCR 会认错引号和花括号',
            '楼主整理的世界书分批触发写得很好，链接我收藏了'
        )
    },
    @{
        Name = 'light-10pt'
        Theme = 'light'
        FontPt = 10
        Lines = @(
            '知识库的检索质量取决于识别环节，错一个字就可能搜不到',
            '把截图变成可检索的文本，是这条链路里最容易低估的一步',
            '滚动采集遇到图片或动画时，帧间差异会被判成未移动'
        )
    },
    @{
        Name = 'light-13pt'
        Theme = 'light'
        FontPt = 13
        Lines = @(
            '角色卡预设的维护成本主要来自版本漂移',
            '每改一次模板，历史对话的复现结果都会跟着变',
            '所以要把预设和提示词分开版本管理'
        )
    },
    @{
        Name = 'dark-16px'
        Theme = 'dark'
        FontPt = 12
        Lines = @(
            '这种情况应该标记为需要核对，而不是直接丢弃',
            '停止滚动采集之后，帧数不应该再继续增长',
            '首帧要优先落盘，否则会漏掉顶部内容'
        )
    },
    @{
        Name = 'mixed-10pt'
        Theme = 'dark'
        FontPt = 10
        Lines = @(
            '{"preset_name":"深度润色","temperature":0.7,"top_p":0.95}',
            '调用 /api/search?q=世界书 返回 2 条命中，bm25 分数 2.75e-06',
            '注意：OCR 会认错引号、花括号和下划线'
        )
    }
)

foreach ($case in $cases) {
    if ($case.Theme -eq 'dark') {
        $back = [System.Drawing.Color]::FromArgb(49, 51, 56)
        $fore = [System.Drawing.Color]::FromArgb(219, 222, 225)
    } else {
        $back = [System.Drawing.Color]::FromArgb(255, 255, 255)
        $fore = [System.Drawing.Color]::FromArgb(31, 35, 40)
    }

    $font = New-Object System.Drawing.Font('Microsoft YaHei', [float]$case.FontPt)
    $pad = 16
    $lineHeight = [int][Math]::Ceiling($font.GetHeight(96) * 1.55)
    $width = 900
    $height = [Math]::Max(200, ($case.Lines.Count * $lineHeight) + ($pad * 2))

    $bmp = New-Object System.Drawing.Bitmap $width, $height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear($back)
    $brush = New-Object System.Drawing.SolidBrush $fore

    $y = $pad
    foreach ($line in $case.Lines) {
        $g.DrawString($line, $font, $brush, [float]$pad, [float]$y)
        $y += $lineHeight
    }

    $g.Dispose()
    $pngPath = Join-Path $OutDir ($case.Name + '.png')
    $txtPath = Join-Path $OutDir ($case.Name + '.txt')
    $bmp.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    [IO.File]::WriteAllText($txtPath, ($case.Lines -join "`n"), (New-Object Text.UTF8Encoding $false))

    "生成 $($case.Name): $pngPath ($width x $height, $($case.FontPt)pt, $($case.Theme))"
}

"共 $($cases.Count) 张，输出目录：$OutDir"
