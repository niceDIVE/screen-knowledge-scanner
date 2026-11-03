<#
  run-umi-bench.ps1 — 直接打 Umi-OCR 的 HTTP 接口算 CER，并区分两种拼接方式：

    raw     ：按接口返回顺序直接拼接（= 当前产品 V1/V2 的行为）
    sorted  ：按每行 box 坐标重排（先按 y 聚行，行内按 x）后再拼接

  为什么要分开算：表格、多栏、键值对齐的截图，Paddle/Rapid 返回的 box 常常是**列优先**的，
  按返回顺序拼会得到乱序文本 —— 那不是识别错误，是阅读顺序问题。把两者混在一起算 CER
  会把「集成侧的排序缺陷」误算成「引擎精度差」。

  用法：
    powershell -File tests\ocr-bench\run-umi-bench.ps1 -Url http://127.0.0.1:1224/api/ocr -Tag umi-paddle -ImgDir matrix -Csv matrix\umi.csv
#>
[CmdletBinding()]
param(
    [string]$Url = 'http://127.0.0.1:1224/api/ocr',
    [string]$ImgDir,
    [string]$Csv,
    [string]$Tag = 'umi',
    [string]$OutMd
)

$ErrorActionPreference = 'Stop'
if (-not $ImgDir) { $ImgDir = Join-Path $PSScriptRoot 'output' }
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

# 把 [{box,text}] 按坐标重排成行：y 中心聚行（容差 = 中位高度 * 0.6），行内按 x 升序
function Sort-ByPosition($items) {
    $list = @()
    foreach ($it in $items) {
        $xs = @(); $ys = @()
        foreach ($p in $it.box) { $xs += [int]$p[0]; $ys += [int]$p[1] }
        $minY = ($ys | Measure-Object -Minimum).Minimum
        $maxY = ($ys | Measure-Object -Maximum).Maximum
        $list += [pscustomobject]@{
            Text    = [string]$it.text
            MinX    = ($xs | Measure-Object -Minimum).Minimum
            CenterY = [int](($minY + $maxY) / 2)
            Height  = [Math]::Max(1, [int]($maxY - $minY))
        }
    }
    if ($list.Count -eq 0) { return '' }

    $heights = @($list | ForEach-Object { $_.Height } | Sort-Object)
    $median = $heights[[int]($heights.Count / 2)]
    $tol = [Math]::Max(4, [int]($median * 0.6))

    $lines = @()
    foreach ($box in ($list | Sort-Object CenterY, MinX)) {
        $placed = $false
        foreach ($line in $lines) {
            if ([Math]::Abs($line.Y - $box.CenterY) -le $tol) {
                $line.Items += $box
                $placed = $true
                break
            }
        }
        if (-not $placed) {
            $lines += [pscustomobject]@{ Y = $box.CenterY; Items = @($box) }
        }
    }

    $out = @()
    foreach ($line in ($lines | Sort-Object Y)) {
        $out += (($line.Items | Sort-Object MinX | ForEach-Object { $_.Text }) -join '')
    }
    return ($out -join "`n")
}

$rows = @()
foreach ($png in (Get-ChildItem $ImgDir -Filter *.png | Sort-Object Name)) {
    $name = [IO.Path]::GetFileNameWithoutExtension($png.Name)
    $gtPath = Join-Path $ImgDir ($name + '.txt')
    if (-not (Test-Path $gtPath)) { Write-Warning "跳过 $name：缺 ground truth"; continue }
    $gt = [IO.File]::ReadAllText($gtPath, [Text.Encoding]::UTF8)

    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($png.FullName))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $resp = Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json' -Body (@{ base64 = $b64 } | ConvertTo-Json -Compress) -TimeoutSec 180
    $sw.Stop()

    $items = @($resp.data | Where-Object { $_.text })
    $raw = (($items | ForEach-Object { $_.text }) -join "`n")
    $sorted = Sort-ByPosition $items

    $normGt = Normalize-Text $gt
    $cerRaw = if ($normGt.Length) { [Math]::Round((Get-Levenshtein $normGt (Normalize-Text $raw)) / $normGt.Length * 100, 1) } else { 100 }
    $cerSorted = if ($normGt.Length) { [Math]::Round((Get-Levenshtein $normGt (Normalize-Text $sorted)) / $normGt.Length * 100, 1) } else { 100 }
    $elapsed = [Math]::Round($sw.Elapsed.TotalSeconds, 2)

    $rows += [pscustomobject]@{
        标签          = $Tag
        用例          = $name
        参考字数      = $normGt.Length
        'CER_raw%'    = $cerRaw
        'CER_sorted%' = $cerSorted
        '耗时s'       = $elapsed
        块数          = $items.Count
    }
    Write-Host ("{0,-22} raw={1,5}%  sorted={2,5}%  {3,5}s  块数={4}" -f $name, $cerRaw, $cerSorted, $elapsed, $items.Count)
}

$tr = ($rows | Measure-Object -Property 'CER_raw%' -Average).Average
$ts = ($rows | Measure-Object -Property 'CER_sorted%' -Average).Average
Write-Host ''
$rows | Format-Table -AutoSize | Out-String | Write-Host
Write-Host ("平均：raw {0}%   sorted {1}%   （{2} 张，{3}）" -f [Math]::Round($tr, 1), [Math]::Round($ts, 1), $rows.Count, $Url)

if ($Csv) {
    $csvPath = if ([IO.Path]::IsPathRooted($Csv)) { $Csv } else { Join-Path $PSScriptRoot $Csv }
    $dir0 = Split-Path -Parent $csvPath
    if ($dir0 -and -not (Test-Path $dir0)) { New-Item -ItemType Directory -Path $dir0 -Force | Out-Null }
    $exists = Test-Path $csvPath
    $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Append:$exists
    Write-Host "CSV 已追加：$csvPath"
}
