<#
  make-layout-images.ps1 — A 轮验收用的「版式」测试集（4 张）。

  与其它两个出图脚本的分工：
    - make-bench-images.ps1 ：T0 核心集 5 张（回归判据）
    - make-matrix-images.ps1：恶劣条件矩阵 10 张（选型取舍）
    - 本脚本               ：版式专项 4 张 —— 表格、双栏正文、代码、JSON，
                             专门用来验收「阅读顺序」这一项，顺序对了才算过

  每张图同时给出「理想阅读顺序」的 ground truth：
    - table     ：逐行读（左→右，每行一条）
    - two-column：读完左栏再读右栏（不是逐行左右穿插）
    - code      ：逐行读
    - json      ：逐行读

  输出：tests\ocr-bench\layout\<name>.png + <name>.txt

  用法：powershell -File tests\ocr-bench\make-layout-images.ps1
#>
[CmdletBinding()]
param([string]$OutDir)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not $OutDir) {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $OutDir = Join-Path $root 'tests\ocr-bench\layout'
}
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

function New-Canvas([int]$w, [int]$h, [int[]]$bg) {
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.Color]::FromArgb(255, $bg[0], $bg[1], $bg[2]))
    return @($bmp, $g)
}

# ---------------- 1. 表格：5 行 × 4 列，理想顺序 = 逐行 ----------------
$table = @(
    @('项目', '端口', '状态', '说明'),
    @('V1 控制台', '8788', '在线', '零依赖脚本版'),
    @('V2 工作台', '8800', '在线', 'C# 桌面版'),
    @('OCR 服务', '1225', '在线', 'Rapid 引擎'),
    @('知识库', '—', '正常', '三个文件')
)
$cols = @(24, 240, 400, 560)
$c = New-Canvas 900 210 @(255, 255, 255)
$bmp = $c[0]; $g = $c[1]
$font = New-Object System.Drawing.Font('Microsoft YaHei', 11)
$brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(31, 35, 40))
$y = 24
foreach ($row in $table) {
    for ($i = 0; $i -lt $row.Count; $i++) { $g.DrawString($row[$i], $font, $brush, [float]$cols[$i], [float]$y) }
    $y += 34
}
$g.Dispose(); $brush.Dispose(); $font.Dispose()
$bmp.Save((Join-Path $OutDir 'table.png'), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
[IO.File]::WriteAllText((Join-Path $OutDir 'table.txt'), (($table | ForEach-Object { $_ -join "`t" }) -join "`n"), (New-Object Text.UTF8Encoding $false))

# ---------------- 2. 双栏正文：理想顺序 = 左栏读完再读右栏 ----------------
$left = @(
    '左栏第一段：滚动采集时',
    '屏幕会一屏一屏往下走，',
    '每一帧都要先落盘再识别。',
    '左栏第四段：如果首帧丢',
    '了，顶部内容就再也补不',
    '回来，所以写入要抢在',
    '滚动动作之前。'
)
$right = @(
    '右栏第一段：识别环节是',
    '整条链路的瓶颈，错一个字',
    '就可能让检索失效。',
    '右栏第四段：所以引擎选',
    '型比界面美化重要得多，',
    '界面可以慢慢改，数据脏',
    '了就很难洗干净。'
)
$c = New-Canvas 900 320 @(255, 255, 255)
$bmp = $c[0]; $g = $c[1]
$font = New-Object System.Drawing.Font('Microsoft YaHei', 10)
$brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(31, 35, 40))
$y = 20
foreach ($line in $left) { $g.DrawString($line, $font, $brush, [float]24, [float]$y); $y += 30 }
$y = 20
foreach ($line in $right) { $g.DrawString($line, $font, $brush, [float]470, [float]$y); $y += 30 }
$g.Dispose(); $brush.Dispose(); $font.Dispose()
$bmp.Save((Join-Path $OutDir 'two-column.png'), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
[IO.File]::WriteAllText((Join-Path $OutDir 'two-column.txt'), ((@($left) + @($right)) -join "`n"), (New-Object Text.UTF8Encoding $false))

# ---------------- 3. 代码块：逐行 ----------------
$code = @(
    'var engine = new UmiOcr(options, clients);',
    'if (options.OcrEngine == "umi") Use(engine);',
    'SELECT bm25(search) FROM search WHERE search MATCH ?',
    'throw new InvalidOperationException("识别失败");',
    'curl -X POST http://127.0.0.1:1225/api/ocr -d @body.json'
)
$c = New-Canvas 900 200 @(30, 30, 30)
$bmp = $c[0]; $g = $c[1]
$font = New-Object System.Drawing.Font('Consolas', 11)
$brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(212, 212, 212))
$y = 22
foreach ($line in $code) { $g.DrawString($line, $font, $brush, [float]20, [float]$y); $y += 32 }
$g.Dispose(); $brush.Dispose(); $font.Dispose()
$bmp.Save((Join-Path $OutDir 'code.png'), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
[IO.File]::WriteAllText((Join-Path $OutDir 'code.txt'), ($code -join "`n"), (New-Object Text.UTF8Encoding $false))

# ---------------- 4. JSON：逐行 ----------------
$json = @(
    '{',
    '  "preset_name": "深度润色",',
    '  "temperature": 0.7,',
    '  "prompt_order": [100, 191, 192],',
    '  "enabled": true',
    '}'
)
$c = New-Canvas 900 220 @(255, 255, 255)
$bmp = $c[0]; $g = $c[1]
$font = New-Object System.Drawing.Font('Consolas', 11)
$brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(31, 35, 40))
$y = 22
foreach ($line in $json) { $g.DrawString($line, $font, $brush, [float]20, [float]$y); $y += 30 }
$g.Dispose(); $brush.Dispose(); $font.Dispose()
$bmp.Save((Join-Path $OutDir 'json.png'), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
[IO.File]::WriteAllText((Join-Path $OutDir 'json.txt'), ($json -join "`n"), (New-Object Text.UTF8Encoding $false))

"版式集 4 张已生成 -> $OutDir"
