<#
  run-reorder-proto.ps1 — 版式感知重排的算法原型（先在这里验证，通过后再落进 C# 适配层）。

  背景（2026-11-04 实测）：
    · 同一套 Umi 引擎，表格必须用 single_* 解析（0%），用 multi_* 会按列读（80.6%）
    · 双栏正文必须用 multi_* 解析（0.8%），用 single_* 会横穿两栏（77.3%）
    · 因此「无条件坐标重排」是错的：它对表格有效（0%），但会把双栏拆成 77.3%
    → 结论：必须先判定版式（单栏/表格 vs 多栏正文），再决定排序策略

  本原型只用一次 OCR（parser=none，拿原始 box），在本地做版式判定 + 排序：
    1) 把所有 box 的 x 区间投影到 x 轴，找出「宽度 > 阈值 且 无任何 box 覆盖」的空白带
    2) 空白带把画面切成 N 个列带
       N == 1 → 单栏/表格：y 聚行 + 行内 x（表格逐行读正是这个）
       N >= 2 → 再判「表格 or 双栏正文」：
                列带内 box 宽度 / 列宽 的中位数 < 0.6 → 表格（单元格短）→ 逐行读
                否则 → 双栏正文 → 列带内排序，按列左→右拼接
    3) 以 CER 与 ground truth 比对

  用法：
    powershell -File tests\ocr-bench\run-reorder-proto.ps1 -Url http://127.0.0.1:1225/api/ocr
#>
[CmdletBinding()]
param(
    [string]$Url = 'http://127.0.0.1:1225/api/ocr',
    [string]$ImgDir,
    [string]$Csv,
    # 列带内 box 宽度/列宽 的中位数低于此值判为表格
    [double]$TableWidthRatio = 0.6,
    # 空白带最小宽度（像素）
    [int]$GapPx = 24
)

$ErrorActionPreference = 'Stop'
if (-not $ImgDir) { $ImgDir = Join-Path $PSScriptRoot 'layout' }
elseif (-not [IO.Path]::IsPathRooted($ImgDir)) { $ImgDir = Join-Path $PSScriptRoot $ImgDir }

function Normalize-Text([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s.Normalize([Text.NormalizationForm]::FormKC) -replace '[\s\p{P}\p{S}]', '').ToLowerInvariant()
}
function Get-Levenshtein([string]$a, [string]$b) {
    [int]$n = $a.Length; [int]$m = $b.Length
    $d = New-Object 'int[,]' ($n + 1), ($m + 1)
    [int]$i = 0; while ($i -le $n) { $d.SetValue($i, $i, 0); $i++ }
    [int]$j = 0; while ($j -le $m) { $d.SetValue($j, 0, $j); $j++ }
    $i = 1
    while ($i -le $n) {
        $im = $i - 1; $j = 1
        while ($j -le $m) {
            $jm = $j - 1; $cost = 1
            if ($a[$im] -eq $b[$jm]) { $cost = 0 }
            $up = $d.GetValue($im, $j) + 1; $left = $d.GetValue($i, $jm) + 1; $diag = $d.GetValue($im, $jm) + $cost
            $best = $up; if ($left -lt $best) { $best = $left }; if ($diag -lt $best) { $best = $diag }
            $d.SetValue($best, $i, $j); $j++
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

function Get-Blocks($items) {
    $list = @()
    foreach ($it in $items) {
        $xs = @(); $ys = @()
        foreach ($p in $it.box) { $xs += [int]$p[0]; $ys += [int]$p[1] }
        $list += [pscustomobject]@{
            Text = [string]$it.text
            X0 = ($xs | Measure-Object -Minimum).Minimum
            X1 = ($xs | Measure-Object -Maximum).Maximum
            Y0 = ($ys | Measure-Object -Minimum).Minimum
            Y1 = ($ys | Measure-Object -Maximum).Maximum
        }
    }
    return $list
}

# 找出 x 轴上的空白带（无任何 box 覆盖），把画面切成列带
function Get-Columns($blocks, [int]$gapPx) {
    if ($blocks.Count -eq 0) { return @() }
    $minX = ($blocks | Measure-Object X0 -Minimum).Minimum
    $maxX = ($blocks | Measure-Object X1 -Maximum).Maximum

    # 用「覆盖区间」求并集，再找补集
    $segments = $blocks | Sort-Object X0 | ForEach-Object { , @([int]$_.X0, [int]$_.X1) }
    $merged = @()
    foreach ($s in $segments) {
        if ($merged.Count -eq 0) { $merged += , @($s[0], $s[1]); continue }
        $last = $merged[$merged.Count - 1]
        if ($s[0] -le $last[1] + 1) { if ($s[1] -gt $last[1]) { $last[1] = $s[1] } }
        else { $merged += , @($s[0], $s[1]) }
    }

    # 列带 = 合并后的覆盖区间；相邻覆盖之间的空隙若 >= gapPx 才算真分栏
    $columns = @()
    foreach ($m in $merged) { $columns += , @([int]$m[0], [int]$m[1]) }

    # 合并掉太窄的间隙（同一行文字内部空隙）
    $result = @()
    foreach ($col in $columns) {
        if ($result.Count -eq 0) { $result += , @($col[0], $col[1]); continue }
        $last = $result[$result.Count - 1]
        if ($col[0] - $last[1] -lt $gapPx) { if ($col[1] -gt $last[1]) { $last[1] = $col[1] } }
        else { $result += , @($col[0], $col[1]) }
    }
    return $result
}

# 列带内：y 聚行、行内按 x
function Sort-InColumn($blocks) {
    if ($blocks.Count -eq 0) { return '' }
    $hs = @($blocks | ForEach-Object { [Math]::Max(1, $_.Y1 - $_.Y0) } | Sort-Object)
    $tol = [Math]::Max(4, [int]($hs[[int]($hs.Count / 2)] * 0.6))
    $lines = @()
    foreach ($b in ($blocks | Sort-Object { ($_.Y0 + $_.Y1) / 2 }, X0)) {
        $cy = ($b.Y0 + $b.Y1) / 2
        $placed = $false
        foreach ($line in $lines) {
            if ([Math]::Abs($line.Y - $cy) -le $tol) { $line.Items += $b; $placed = $true; break }
        }
        if (-not $placed) { $lines += [pscustomobject]@{ Y = $cy; Items = @($b) } }
    }
    return ((($lines | Sort-Object Y | ForEach-Object { ($_.Items | Sort-Object X0 | ForEach-Object { $_.Text }) -join '' }) -join "`n"))
}

$rows = @()
foreach ($png in (Get-ChildItem $ImgDir -Filter *.png | Sort-Object Name)) {
    $name = [IO.Path]::GetFileNameWithoutExtension($png.Name)
    $gtPath = Join-Path $ImgDir ($name + '.txt')
    if (-not (Test-Path $gtPath)) { continue }
    $gt = [IO.File]::ReadAllText($gtPath, [Text.Encoding]::UTF8)

    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($png.FullName))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $resp = Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json' `
        -Body (@{ base64 = $b64; options = @{ 'tbpu.parser' = 'none' } } | ConvertTo-Json -Depth 6 -Compress) -TimeoutSec 180
    $sw.Stop()

    $blocks = Get-Blocks @($resp.data | Where-Object { $_.text })
    $cols = Get-Columns $blocks $GapPx

    $verdict = ''
    $reordered = ''
    if ($cols.Count -le 1) {
        $verdict = '1 列 → 单栏/表格 → 逐行读'
        $reordered = Sort-InColumn $blocks
    } else {
        # 列带内 box 宽度 / 列宽 的中位数
        $ratios = @()
        foreach ($col in $cols) {
            $cw = [Math]::Max(1, $col[1] - $col[0])
            $inCol = @($blocks | Where-Object { $_.X0 -ge ($col[0] - 2) -and $_.X1 -le ($col[1] + 2) })
            if ($inCol.Count -eq 0) { continue }
            $ratios += ((($inCol | ForEach-Object { ($_.X1 - $_.X0) / $cw }) | Measure-Object -Average).Average)
        }
        $ratio = if ($ratios.Count) { ($ratios | Measure-Object -Average).Average } else { 1 }
        if ($ratio -lt $TableWidthRatio) {
            $verdict = "$($cols.Count) 列 + 单元格窄（比 $([Math]::Round($ratio,2))）→ 表格 → 逐行读"
            $reordered = Sort-InColumn $blocks
        } else {
            $verdict = "$($cols.Count) 列 + 行占满列宽（比 $([Math]::Round($ratio,2))）→ 多栏正文 → 逐列读"
            $parts = @()
            foreach ($col in ($cols | Sort-Object { $_[0] })) {
                $inCol = @($blocks | Where-Object { $_.X0 -ge ($col[0] - 2) -and $_.X1 -le ($col[1] + 2) })
                $parts += (Sort-InColumn $inCol)
            }
            $reordered = ($parts | Where-Object { $_ }) -join "`n"
        }
    }

    $cerRaw = Cer $gt ((($resp.data | ForEach-Object { $_.text }) -join "`n"))
    $cerNew = Cer $gt $reordered
    $rows += [pscustomobject]@{ 用例 = $name; 判定 = $verdict; '原始顺序CER%' = $cerRaw; '重排后CER%' = $cerNew; 块数 = $blocks.Count; 耗时s = [Math]::Round($sw.Elapsed.TotalSeconds, 2) }
    Write-Host ("{0,-12} 原始={1,5}%  重排={2,5}%   {3}" -f $name, $cerRaw, $cerNew, $verdict)
}

Write-Host ''
$rows | Format-Table -AutoSize | Out-String | Write-Host
if ($Csv) {
    $csvPath = if ([IO.Path]::IsPathRooted($Csv)) { $Csv } else { Join-Path $PSScriptRoot $Csv }
    $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host "CSV：$csvPath"
}
