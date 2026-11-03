<#
  run-ocr-bench.ps1 — 对 make-bench-images.ps1 生成的图跑 OCR，算字符错误率（CER）。

  做法：起一个**隔离实例**（独立端口 + 独立数据目录，默认在 %TEMP% 下），
  走产品真实链路（POST /api/runs → 上传图 → 后台 OCR → 读回 ocrText），
  再与同名 .txt 的 ground truth 做去标点/空白后的 Levenshtein 比对。
  跑完自动停掉实例；不触碰用户既有数据目录与既有进程。

  用法：
    powershell -File tests\ocr-bench\run-ocr-bench.ps1
    powershell -File tests\ocr-bench\run-ocr-bench.ps1 -Port 8802 -Engines windows
  参数：
    -Port     隔离实例端口，默认 8801
    -TimeoutSec 单张等待 OCR 的上限，默认 30
    -KeepData 保留临时数据目录（默认删除）
    -OutMd    把结果表写成 Markdown 文件
#>
[CmdletBinding()]
param(
    [int]$Port = 8801,
    [int]$TimeoutSec = 30,
    [switch]$KeepData,
    [string]$OutMd,
    # auto | windows | umi | tesseract —— 对应 Scanner:OcrEngine，用于同一条链路做引擎 A/B
    [string]$Engine = 'auto',
    # 图片目录（绝对路径或 output/matrix 这样的相对名），默认 output（T0 核心集）
    [string]$ImgDir,
    # 追加写 CSV（一行一图），便于多轮对比合并
    [string]$Csv,
    # 结果标签，写进 CSV 与 Markdown，用于区分引擎/配置
    [string]$Tag = '',
    # 覆盖 Scanner:UmiUrl（多实例对比时用，例如 Rapid 版跑在 1225）
    [string]$UmiUrl
)

$ErrorActionPreference = 'Stop'
$benchRoot = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $benchRoot)
$imgDir = if ($ImgDir) { if ([IO.Path]::IsPathRooted($ImgDir)) { $ImgDir } else { Join-Path $benchRoot $ImgDir } } else { Join-Path $benchRoot 'output' }
$dll = Join-Path $repoRoot 'screen-v2\src\Screen.App\bin\Debug\net10.0-windows10.0.19041.0\Screen.App.dll'

if (-not (Test-Path $dll)) { throw "找不到已构建的 V2 程序集：$dll（先跑 screen-v2\scripts\run-windows.ps1 或 dotnet build）" }
if (-not (Test-Path $imgDir)) { throw "找不到测试图目录：$imgDir（先跑 make-bench-images.ps1）" }

# ---------- 归一化与编辑距离 ----------
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

# ---------- 隔离实例 ----------
$base = "http://127.0.0.1:$Port"
$dataDir = Join-Path $env:TEMP ("ocr-bench-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

$proc = Start-Process -FilePath 'dotnet' -PassThru -WindowStyle Hidden -ArgumentList $(
    @($dll, '--urls', $base, "--Scanner:DataDirectory=$dataDir", '--Scanner:OpenBrowser=false', "--Scanner:OcrEngine=$Engine") +
    $(if ($UmiUrl) { @("--Scanner:UmiUrl=$UmiUrl") } else { @() })
)
Write-Host "隔离实例 PID=$($proc.Id) 数据目录=$dataDir 引擎=$Engine" + $(if ($UmiUrl) { " UmiUrl=$UmiUrl" } else { '' })

$ready = $false
for ($k = 0; $k -lt 40; $k++) {
    try { Invoke-RestMethod -Uri "$base/api/status" -TimeoutSec 3 | Out-Null; $ready = $true; break } catch { Start-Sleep -Milliseconds 500 }
}
if (-not $ready) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw "隔离实例未能在 $base 就绪"
}

try {
    $status = Invoke-RestMethod -Uri "$base/api/status"
    Write-Host "引擎：$($status.ocrEngine)"

    $run = Invoke-RestMethod -Uri "$base/api/runs" -Method Post -ContentType 'application/json' -Body (@{ title = 'ocr-bench' } | ConvertTo-Json)

    function Send-Frame([string]$runId, [string]$path) {
        $b = [Guid]::NewGuid().ToString('N')
        $name = [IO.Path]::GetFileName($path)
        $head = "--$b`r`nContent-Disposition: form-data; name=`"file`"; filename=`"$name`"`r`nContent-Type: image/png`r`n`r`n"
        $ms = New-Object IO.MemoryStream
        $hb = [Text.Encoding]::UTF8.GetBytes($head); $ms.Write($hb, 0, $hb.Length)
        $fb = [IO.File]::ReadAllBytes($path); $ms.Write($fb, 0, $fb.Length)
        $tb = [Text.Encoding]::UTF8.GetBytes("`r`n--$b--`r`n"); $ms.Write($tb, 0, $tb.Length)
        Invoke-RestMethod -Uri "$base/api/runs/$runId/frames" -Method Post -ContentType "multipart/form-data; boundary=$b" -Body $ms.ToArray()
    }

    $rows = @()
    foreach ($png in (Get-ChildItem $imgDir -Filter *.png | Sort-Object Name)) {
        $name = [IO.Path]::GetFileNameWithoutExtension($png.Name)
        $gtPath = Join-Path $imgDir ($name + '.txt')
        if (-not (Test-Path $gtPath)) { Write-Warning "跳过 $name：缺 ground truth"; continue }
        $gt = [IO.File]::ReadAllText($gtPath, [Text.Encoding]::UTF8)

        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $frame = Send-Frame $run.id $png.FullName
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        do {
            Start-Sleep -Milliseconds 400
            $cur = Invoke-RestMethod -Uri "$base/api/frames/$($frame.id)"
        } while ($cur.ocrState -in @('pending', 'processing') -and (Get-Date) -lt $deadline)
        $stopwatch.Stop()
        $elapsed = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)

        $got = if ($cur.ocrState -eq 'succeeded') { $cur.ocrText } else { '' }
        $normGt = Normalize-Text $gt
        $normGot = Normalize-Text $got
        $edits = Get-Levenshtein $normGt $normGot
        $cer = if ($normGt.Length -gt 0) { [Math]::Round($edits / $normGt.Length * 100, 1) } else { 100 }
        $rows += [pscustomobject]@{
            标签   = $Tag
            用例   = $name
            状态   = $cur.ocrState
            参考字数 = $normGt.Length
            识别字数 = $normGot.Length
            编辑距离 = $edits
            'CER%' = $cer
            '耗时s' = $elapsed
        }
        Write-Host ("{0,-22} {1,-10} CER={2,5}%  {3,6}s  (edits={4}/{5})" -f $name, $cur.ocrState, $cer, $elapsed, $edits, $normGt.Length)
    }

    $totalEdits = ($rows | Measure-Object -Property 编辑距离 -Sum).Sum
    $totalChars = ($rows | Measure-Object -Property 参考字数 -Sum).Sum
    $overall = if ($totalChars -gt 0) { [Math]::Round($totalEdits / $totalChars * 100, 1) } else { 100 }

    Write-Host ''
    $rows | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "总体 CER = $overall%  (edits=$totalEdits / chars=$totalChars)"

    if ($Csv) {
        $csvPath = if ([IO.Path]::IsPathRooted($Csv)) { $Csv } else { Join-Path $benchRoot $Csv }
        $dir0 = Split-Path -Parent $csvPath
        if ($dir0 -and -not (Test-Path $dir0)) { New-Item -ItemType Directory -Path $dir0 -Force | Out-Null }
        $exists = Test-Path $csvPath
        $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Append:$exists
        Write-Host "CSV 已追加：$csvPath"
    }

    if ($OutMd) {
        $sb = New-Object Text.StringBuilder
        [void]$sb.AppendLine("# OCR 基线结果（$(Get-Date -Format 'yyyy-MM-dd HH:mm') ，引擎：$($status.ocrEngine)）")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('| 用例 | 状态 | 参考字数 | 识别字数 | 编辑距离 | CER% |')
        [void]$sb.AppendLine('|---|---|---|---|---|---|')
        foreach ($r in $rows) {
            [void]$sb.AppendLine("| $($r.用例) | $($r.状态) | $($r.参考字数) | $($r.识别字数) | $($r.编辑距离) | $($r.'CER%') |")
        }
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("**总体 CER = $overall%**（edits=$totalEdits / chars=$totalChars）")
        [IO.File]::WriteAllText($OutMd, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
        Write-Host "结果已写入：$OutMd"
    }
}
finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    if (-not $KeepData) { Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "已清理临时数据目录" }
    else { Write-Host "保留临时数据目录：$dataDir" }
}
