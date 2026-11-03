<#
  make-matrix-images.ps1 — 选型用的「真实感」测试矩阵（在 T0 的 5 张核心图之外）。

  与 make-bench-images.ps1 的分工：
    - make-bench-images.ps1：固定 5 张核心集，作为 T0 回归判据（口径不许改）
    - 本脚本：覆盖真实使用中的恶劣条件——细字重、低对比度、小字、大图、代码块、
      密集符号、对齐表格、渐变背景、长文本，用于技术选型取舍

  输出：tests\ocr-bench\matrix\<name>.png + <name>.txt（UTF-8 无 BOM）

  用法：
    powershell -File tests\ocr-bench\make-matrix-images.ps1
    # 真实感对照：用 ClearType 次像素抗锯齿重画一套（更接近真实截屏，而非 GDI+ 灰度抗锯齿）
    powershell -File tests\ocr-bench\make-matrix-images.ps1 -OutDir matrix-ct -TextHint ClearTypeGridFit
#>
[CmdletBinding()]
param(
    [string]$OutDir,
    # AntiAliasGridFit（默认，灰度抗锯齿）/ ClearTypeGridFit（次像素抗锯齿，更接近真实屏幕渲染）
    [string]$TextHint = 'AntiAliasGridFit'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not $OutDir) {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $OutDir = Join-Path $root 'tests\ocr-bench\matrix'
}
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$cases = @(
    @{
        Name = 'thin-dark-10pt'; Width = 750; Pt = 10; Family = 'Microsoft YaHei Light'
        Bg = @(49, 51, 56); Fg = @(219, 222, 225); LineFactor = 1.6
        Lines = @(
            '细字重是最容易翻车的情况，抗锯齿会把笔画糊在一起',
            '世界书、提示词、预设这三样要分开管理，不然改一个坏三个',
            '滚动采集的缺漏校验靠帧间位移估计'
        )
    },
    @{
        Name = 'lowcontrast-11pt'; Width = 750; Pt = 11; Family = 'Microsoft YaHei'
        Bg = @(43, 45, 49); Fg = @(110, 114, 120); LineFactor = 1.6
        Lines = @(
            '低对比度文字在深色主题里很常见，尤其是次要信息',
            '这类文字的识别率通常比正文低得多，要靠预处理兜底',
            '如果知识库里全是这类文本，检索基本等于没用'
        )
    },
    @{
        Name = 'small-9pt'; Width = 750; Pt = 9; Family = 'Microsoft YaHei'
        Bg = @(255, 255, 255); Fg = @(40, 44, 52); LineFactor = 1.5
        Lines = @(
            '九号字在网页正文里不算罕见，尤其是侧栏和注释',
            '这个尺寸下中文字形笔画密度已经接近识别下限',
            '帧数、延迟、队列积压都要在这个尺寸下看'
        )
    },
    @{
        Name = 'dpi125-12pt'; Width = 950; Pt = 12; Family = 'Microsoft YaHei'
        Bg = @(255, 255, 255); Fg = @(31, 35, 40); LineFactor = 1.6
        Lines = @(
            '一百二十五百分比缩放下，同样的字号会渲染成更大的像素',
            '这时选区坐标要乘缩放比，否则截出来的范围是错的',
            '识别率一般会随字号变大而上升，但截图文件也更大'
        )
    },
    @{
        Name = 'longtext-30lines'; Width = 900; Pt = 10; Family = 'Microsoft YaHei'
        Bg = @(49, 51, 56); Fg = @(219, 222, 225); LineFactor = 1.55
        Lines = @(
            '第一行：这屏模拟滚动采集的一次取景，共三十行正文',
            '第二行：长文本下识别耗时会线性增长，要关注单帧延迟',
            '第三行：如果一帧要超过两秒，滚动节奏就得跟着调慢',
            '第四行：否则会出现上一帧还没识别完、下一帧已经拍好的情况',
            '第五行：排队积压会体现在待处理计数上',
            '第六行：用户可以点处理收件箱来手动触发',
            '第七行：但真正的瓶颈是引擎的吞吐，不是队列本身',
            '第八行：所以选型时要优先看每秒能处理多少帧',
            '第九行：其次才是单帧绝对精度',
            '第十行：两者冲突时，优先保证精度',
            '第十一行：因为错字会污染知识库，慢只会让人等',
            '第十二行：知识库一旦被污染，后续检索全是噪声',
            '第十三行：清理噪声的成本远高于等待',
            '第十四行：这是本项目最重要的取舍原则',
            '第十五行：因此在本地跑的情况下，宁可慢一倍',
            '第十六行：也不要让中文正文错误率超过百分之五',
            '第十七行：百分之五是可检索的下限',
            '第十八行：低于百分之三才算舒服',
            '第十九行：代码和数字要单独看，它们容错更低',
            '第二十行：一个下划线认错，路径就失效了',
            '第二十一行：一个引号认错，JSON 就解析失败',
            '第二十二行：所以代码块建议人工校对',
            '第二十三行：界面上要能把这类帧标出来',
            '第二十四行：需要核对的帧不应该直接进正文',
            '第二十五行：应该先挂起，等人确认',
            '第二十六行：这就是需要核对状态的意义',
            '第二十七行：目前前端还没把这个状态显示出来',
            '第二十八行：用户看不到，就会以为采集成功了',
            '第二十九行：这是下一步要补的界面工作',
            '第三十行：以上为长文本测试用例'
        )
    },
    @{
        Name = 'code-consolas'; Width = 900; Pt = 10; Family = 'Consolas'
        Bg = @(30, 30, 30); Fg = @(212, 212, 212); LineFactor = 1.5
        Lines = @(
            '$cfg = @{ Port = 8788; Ocr = ''umi''; DataDir = ''F:\screen\data'' }',
            'Invoke-RestMethod -Uri "$base/api/search?q=世界书" -Method Get',
            'SELECT f.id, bm25(search) FROM search JOIN frames f ON f.id = search.frame_id',
            'if (options.OcrEngine -eq ''auto'') { Use-WindowsOcr } else { Use-Umi }',
            'ERROR: Win32Exception(5) at SetParentProcessExitCallback'
        )
    },
    @{
        Name = 'dense-symbols'; Width = 900; Pt = 10; Family = 'Microsoft YaHei'
        Bg = @(255, 255, 255); Fg = @(31, 35, 40); LineFactor = 1.6
        Lines = @(
            '路径：D:\work\screen-v2\src\Screen.App\bin\Debug\net10.0-windows10.0.19041.0',
            '接口：POST /api/runs/{id}/frames?source=import&text=世界书',
            '配置：Scanner:HotkeyKeys:Region = Ctrl+Alt+R（被占用时改键）',
            '数值：CER 3.6% / 17.5%，耗时 1.2s / 0.4s，内存 320MB / 75MB',
            '标识符：_backup、snake_case、kebab-case、CamelCase 全都要认对'
        )
    },
    @{
        Name = 'table-kv'; Width = 750; Pt = 10; Family = 'Microsoft YaHei'
        Bg = @(255, 255, 255); Fg = @(31, 35, 40); LineFactor = 1.7
        Lines = @(
            '项目      端口    状态      说明',
            'V1        8788    在线      零依赖脚本版',
            'V2        8800    在线      C# 工作台',
            'Umi-OCR   1224    在线      Paddle 后端',
            '数据库    —       正常      知识库三文件'
        )
    },
    @{
        Name = 'gradient-bg'; Width = 750; Pt = 10; Family = 'Microsoft YaHei'
        Bg = @(24, 32, 54); Fg = @(240, 240, 240); LineFactor = 1.6; Gradient = $true
        Lines = @(
            '渐变背景加半透明遮罩是很多客户端的默认样式',
            '背景亮度变化会让固定阈值二值化失效',
            '这类图在分割阶段就容易断行'
        )
    },
    @{
        Name = 'wide-1600'; Width = 1600; Pt = 10; Family = 'Microsoft YaHei'
        Bg = @(255, 255, 255); Fg = @(31, 35, 40); LineFactor = 1.6
        Lines = @(
            '宽屏截图左右分栏，正文在左侧，右侧是目录和元信息',
            '这种情况下选区通常只框正文那一块，但误框进侧栏就麻烦了',
            '识别器对多栏排版的阅读顺序处理差异很大'
        )
    }
)

foreach ($case in $cases) {
    $font = New-Object System.Drawing.Font($case.Family, [float]$case.Pt)
    $pad = 18
    $lineHeight = [int][Math]::Ceiling($font.GetHeight(96) * $case.LineFactor)
    $width = [int]$case.Width
    $height = [Math]::Max(120, ($case.Lines.Count * $lineHeight) + ($pad * 2))

    $bmp = New-Object System.Drawing.Bitmap $width, $height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::$TextHint

    if ($case.Gradient) {
        $rect = New-Object System.Drawing.Rectangle 0, 0, $width, $height
        $c1 = [System.Drawing.Color]::FromArgb(255, $case.Bg[0], $case.Bg[1], $case.Bg[2])
        $c2 = [System.Drawing.Color]::FromArgb(255, ($case.Bg[0] + 40), ($case.Bg[1] + 30), ($case.Bg[2] + 50))
        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, $c1, $c2, 30.0
        $g.FillRectangle($brush, $rect)
        $brush.Dispose()
    } else {
        $g.Clear([System.Drawing.Color]::FromArgb(255, $case.Bg[0], $case.Bg[1], $case.Bg[2]))
    }

    $textBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, $case.Fg[0], $case.Fg[1], $case.Fg[2]))
    $y = $pad
    foreach ($line in $case.Lines) {
        $g.DrawString($line, $font, $textBrush, [float]$pad, [float]$y)
        $y += $lineHeight
    }

    $g.Dispose(); $textBrush.Dispose(); $font.Dispose()
    $png = Join-Path $OutDir ($case.Name + '.png')
    $txt = Join-Path $OutDir ($case.Name + '.txt')
    $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    [IO.File]::WriteAllText($txt, ($case.Lines -join "`n"), (New-Object Text.UTF8Encoding $false))

    "{0,-22} {1,5} x{2,-5} {3,3}pt {4}" -f $case.Name, $width, $height, $case.Pt, $case.Family
}

"共 $($cases.Count) 张，输出目录：$OutDir"
