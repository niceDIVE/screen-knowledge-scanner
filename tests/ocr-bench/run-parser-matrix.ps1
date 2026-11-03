<#
  run-parser-matrix.ps1 — 版式验收：同一个 Umi 引擎，比较不同「排版解析方案」（tbpu.parser）
  与「按坐标重排」在表格 / 双栏正文 / 代码 / JSON 上的阅读顺序效果。

  为什么要这项实验：Umi 的 OCR 接口本身就带排版解析（默认 multi_para），返回的 data 顺序
  已经是解析后的顺序，另有 end 字段表达行尾。所以「阅读顺序错了」到底是
  「解析方案选错」还是「我们的适配层丢了顺序」，必须先用参数矩阵分清楚，
  再决定适配层要不要自己写坐标重排。

  用法：
    powershell -File tests\ocr-bench\run-parser-matrix.ps1 -Url http://127.0.0.1:1225/api/ocr
#>
[CmdletBinding()]
param(
    [string]$Url = 'http://127.0.0.1:1225/api/ocr',
    [string]$ImgDir,
    [string]$Csv
)

$ErrorActionPreference = 'Stop'
if (-not $ImgDir) { $ImgDir = Join-Path $PSScriptRoot 'layout' }
elseif (-not [IO.Path]::IsPathRooted($ImgDir)) { $ImgDir = Join-Path $PSScriptRoot $ImgDir }
if (-not (Test-Path $ImgDir)) { throw "找不到测试图目录：$ImgDir" }

function Normalize-Text([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s.Normalize([Text.NormalizationForm]::FormKC) -replace '[\s\p{P}\p{S}]', '').ToLowerInvariant()
}
function Get-Levenshtein([string]$a, [string]$b) {
    [int]$n = $a.Length; [int]$m = $b.Length
    $d = New-Object 'int[,]' ($n + 1), ($m + 1)
    [int]$i = 0
    while ($i -le $n) { $d.SetValue($i, $i, 0); $i++ }
    [int]$j = 0
    while ($j -le $m) { $d.SetValue($j, 0, $j); $j++ }
    $i = 1
    while ($i -le $n) {
        $im = $i - 1
        $j = 1
        while ($j -le $m) {
            $jm = $j - 1
            $cost = 1
            if ($a[$im] -eq $b[$jm]) { $cost = 0 }
            $up = $d.GetValue($im, $j) + 1
            $left = $d.GetValue($i, $jm) + 1
            $diag = $d.GetValue($im, $jm) + $cost
            $best = $up
            if ($left -lt $best) { $best = $left }
            if ($diag -lt $best) { $best = $diag }
            $d.SetValue($best, $i, $j)
            $j++
        }
        $i++
    }
    return $d.GetValue($n, $m)
}
function Cer([string]$gt, [string]$got) {
    $a = Normalize-Text $gt; $b = Normalize-Text $got
    if ($a.Length -eq 0) { return 100 }
    return [Math]::Round((Get-Levenshtein $a $b) / $a.Length * 100, 1)
}
# 单栏坐标重排：y 聚行、行内按 x
function Sort-ByPosition($items) {
    $list = @()
    foreach ($it in $items) {
        $xs = @(); $ys = @()
        foreach ($p in $it.box) { $xs += [int]$p[0]; $ys += [int]$p[1] }
        $minY = ($ys | Measure-Object -Minimum).Minimum; $maxY = ($ys | Measure-Object -Maximum).Maximum
        $list += [pscustomobject]@{ Text = [string]$it.text; MinX = ($xs | Measure-Object -Minimum).Minimum
            CenterY = [int](($minY + $maxY) / 2); Height = [Math]::Max(1, [int]($maxY - $minY)) }
    }
    if ($list.Count -eq 0) { return '' }
    $hs = @($list | ForEach-Object { $_.Height } | Sort-Object)
    $tol = [Math]::Max(4, [int]($hs[[int]($hs.Count / 2)] * 0.6))
    $lines = @()
    foreach ($box in ($list | Sort-Object CenterY, MinX)) {
        $placed = $false
        foreach ($line in $lines) { if ([Math]::Abs($line.Y - $box.CenterY) -le $tol) { $line.Items += $box; $placed = $true; break } }
        if (-not $placed) { $lines += [pscustomobject]@{ Y = $box.CenterY; Items = @($box) } }
    }
    return ((($lines | Sort-Object Y | ForEach-Object { ($_.Items | Sort-Object MinX | ForEach-Object { $_.Text }) -join '' }) -join "`n"))
}
function Invoke-Ocr([string]$imagePath, $options) {
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($imagePath))
    $payload = @{ base64 = $b64 }
    if ($options) { $payload['options'] = $options }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json' -Body ($payload | ConvertTo-Json -Depth 6 -Compress) -TimeoutSec 180
    $sw.Stop()
    return [pscustomobject]@{ Response = $r; Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 2) }
}

$parsers = @('multi_para', 'multi_line', 'multi_none', 'single_para', 'single_line', 'single_none', 'single_code', 'none')
$rows = @()

foreach ($png in (Get-ChildItem $ImgDir -Filter *.png | Sort-Object Name)) {
    $name = [IO.Path]::GetFileNameWithoutExtension($png.Name)
    $gtPath = Join-Path $ImgDir ($name + '.txt')
    if (-not (Test-Path $gtPath)) { Write-Warning "跳过 $name：缺 ground truth"; continue }
    $gt = [IO.File]::ReadAllText($gtPath, [Text.Encoding]::UTF8)

    Write-Host ""
    Write-Host "===== $name =====" -ForegroundColor Cyan

    foreach ($p in $parsers) {
        $res = Invoke-Ocr $png.FullName @{ 'tbpu.parser' = $p }
        $items = @($res.Response.data | Where-Object { $_.text })
        $joined = (($items | ForEach-Object { $_.text }) -join "`n")
        $cer = Cer $gt $joined
        $rows += [pscustomobject]@{ 用例 = $name; 方案 = "parser=$p"; 'CER%' = $cer; 块数 = $items.Count; 耗时s = $res.Seconds }
        Write-Host ("  {0,-14} CER={1,5}%  块数={2}" -f "parser=$p", $cer, $items.Count)
    }

    # 对照 A：默认参数（产品当前行为）的返回顺序
    $d = Invoke-Ocr $png.FullName $null
    $dItems = @($d.Response.data | Where-Object { $_.text })
    $cerDefault = Cer $gt (($dItems | ForEach-Object { $_.text }) -join "`n")
    $rows += [pscustomobject]@{ 用例 = $name; 方案 = '默认(产品现状)'; 'CER%' = $cerDefault; 块数 = $dItems.Count; 耗时s = $d.Seconds }
    Write-Host ("  {0,-14} CER={1,5}%  块数={2}" -f '默认(产品现状)', $cerDefault, $dItems.Count)

    # 对照 B：同一次结果的坐标重排
    $cerSorted = Cer $gt (Sort-ByPosition $dItems)
    $rows += [pscustomobject]@{ 用例 = $name; 方案 = '坐标重排'; 'CER%' = $cerSorted; 块数 = $dItems.Count; 耗时s = $d.Seconds }
    Write-Host ("  {0,-14} CER={1,5}%" -f '坐标重排', $cerSorted)

    # 对照 C：data.format=text（让 Umi 直接给拼好的文本）
    $t = Invoke-Ocr $png.FullName @{ 'data.format' = 'text' }
    $cerText = Cer $gt ([string]$t.Response.data)
    $rows += [pscustomobject]@{ 用例 = $name; 方案 = 'data.format=text'; 'CER%' = $cerText; 块数 = 1; 耗时s = $t.Seconds }
    Write-Host ("  {0,-14} CER={1,5}%" -f 'data.format=text', $cerText)
}

Write-Host ""
Write-Host "===== 汇总（每张图的最优方案）=====" -ForegroundColor Green
foreach ($g in ($rows | Group-Object 用例)) {
    $best = $g.Group | Sort-Object 'CER%' | Select-Object -First 1
    "{0,-12} 最优={1,-18} CER={2}%   最差={3} CER={4}%" -f $g.Name, $best.方案, $best.'CER%',
        (($g.Group | Sort-Object 'CER%' -Descending | Select-Object -First 1).方案),
        (($g.Group | Sort-Object 'CER%' -Descending | Select-Object -First 1).'CER%')
}

if ($Csv) {
    $csvPath = if ([IO.Path]::IsPathRooted($Csv)) { $Csv } else { Join-Path $PSScriptRoot $Csv }
    $dir0 = Split-Path -Parent $csvPath
    if ($dir0 -and -not (Test-Path $dir0)) { New-Item -ItemType Directory -Path $dir0 -Force | Out-Null }
    $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host "CSV：$csvPath"
}
