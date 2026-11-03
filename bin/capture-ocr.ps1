#requires -Version 5.1
<#
  capture-ocr.ps1 — 截图 → 本地 OCR → inbox（原始证据链第一环）
  用法:
    powershell -File capture-ocr.ps1                    # 截全屏并 OCR
    powershell -File capture-ocr.ps1 -ImageFile x.png   # 对已有图片 OCR
    powershell -File capture-ocr.ps1 -Probe             # 探测 OCR 可用性
    -Note 'run:20260101-120000'   # 由守护进程传入的扫描批次号
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$OutRoot,
    [string]$ImageFile,
    [string]$Note = '',
    [switch]$Probe
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    $self = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Root = Split-Path -Parent $self
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.FileAccessMode, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.DataWriter, Windows.Foundation, ContentType = WindowsRuntime]

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class U32Cap {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[void][U32Cap]::SetProcessDPIAware()   # 高 DPI 屏（当前 1707x1067 = 缩放后）必须，否则截不全

# ---------- 配置 ----------
function Get-ScanConfig([string]$root) {
    $p = Join-Path $root 'config.psd1'
    if (Test-Path $p) { Import-PowerShellDataFile $p } else { @{} }
}
$cfg = Get-ScanConfig $Root
$ocrCfg  = if ($cfg.Ocr)  { $cfg.Ocr }  else { @{} }
$ocrMode = if ($ocrCfg.Mode) { $ocrCfg.Mode } else { 'auto' }
$prefer  = if ($ocrCfg.PreferLanguages) { @($ocrCfg.PreferLanguages) } else { @('zh-Hans-CN') }
$umiUrl  = if ($ocrCfg.UmiUrl) { $ocrCfg.UmiUrl } else { 'http://127.0.0.1:1224/api/ocr' }

# ---------- WinRT IAsyncOperation → 同步等待 ----------
$script:asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
                   $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function AwaitOp([object]$WinRtOp, [type]$ResultType) {
    $asTask  = $script:asTaskGeneric.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($WinRtOp))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}

# ---------- OCR 喂图增强 ----------
# 小字号截图放大 2 倍可明显降低错字率；受 OcrEngine.MaxImageDimension 上限约束，
# 超限则等比缩到上限。只影响喂给 OCR 的图，证据截图保持原始分辨率。
function Get-OcrFeedBytes([string]$imagePath) {
    $src = [System.Drawing.Image]::FromFile($imagePath)
    try {
        $maxDim = [int][Windows.Media.Ocr.OcrEngine]::MaxImageDimension
        $scale = 2.0
        $longest = [Math]::Max($src.Width, $src.Height)
        if (($longest * $scale) -gt $maxDim) { $scale = $maxDim / $longest }
        if ($scale -le 1.0) { return [IO.File]::ReadAllBytes($imagePath) }
        $nw = [int]($src.Width * $scale)
        $nh = [int]($src.Height * $scale)
        $bmp = New-Object System.Drawing.Bitmap $nw, $nh
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($src, 0, 0, $nw, $nh)
        $g.Dispose()
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        return $ms.ToArray()
    } finally {
        $src.Dispose()
    }
}

# ---------- OCR 后端 1：Windows 内置 ----------
function Invoke-WindowsOcr([byte[]]$pngBytes, [string[]]$preferTags) {
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    foreach ($tag in $preferTags) {
        try {
            $lang = New-Object Windows.Globalization.Language $tag
            if ($lang -and [Windows.Media.Ocr.OcrEngine]::IsLanguageSupported($lang)) {
                $e2 = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
                if ($e2) { $engine = $e2; break }
            }
        } catch { }
    }
    if (-not $engine) { throw 'NO_OCR_ENGINE' }
    # 不走 StorageFile.GetFileFromPathAsync：UWP 文件代理会拒绝无包身份进程（0x80070005）。
    # 改用内存流（字节已由调用方准备好，可能含 2x 放大增强）。
    $mem    = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
    $writer = New-Object Windows.Storage.Streams.DataWriter($mem)
    $writer.WriteBytes([byte[]]$pngBytes)
    [void](AwaitOp ($writer.StoreAsync()) ([UInt32]))
    [void](AwaitOp ($writer.FlushAsync()) ([Boolean]))
    $null = $writer.DetachStream(); $writer.Dispose()
    [void]$mem.Seek(0)
    $dec    = AwaitOp ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($mem)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $sbmp   = AwaitOp ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $result = AwaitOp ($engine.RecognizeAsync($sbmp)) ([Windows.Media.Ocr.OcrResult])
    $mem.Dispose()
    # Windows OCR 引擎原生按阅读顺序（上→下、左→右）输出 Lines；
    # 不要对 WinRT 对象再 Sort-Object：PS 5.1 投影下 .BoundingRect 取值会静默失败（实测），键全空反而打乱顺序
    $lines = @($result.Lines | ForEach-Object { $_.Text })
    # Windows OCR 会在汉字间插空格（"世 界 书"），归一化掉，否则全文检索搜不到
    $lines = @($lines | ForEach-Object { $_ -replace '(?<=[\p{IsCJKUnifiedIdeographs}])\s+(?=[\p{IsCJKUnifiedIdeographs}])', '' })
    [pscustomobject]@{ Lines = @($lines | Where-Object { $_.Trim() }); Engine = 'windows:' + $engine.RecognizerLanguage.LanguageTag }
}

# ---------- OCR 后端 2：Umi-OCR HTTP（备用） ----------
function Invoke-UmiOcr([string]$imagePath, [string]$url) {
    $b64  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($imagePath))
    $body = @{ base64 = $b64; options = @{} } | ConvertTo-Json -Depth 4 -Compress
    $resp = Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 90
    $lines = @()
    if ($resp.data) { $lines = @($resp.data | ForEach-Object { $_.text } | Where-Object { $_ }) }
    [pscustomobject]@{ Lines = @($lines); Engine = 'umi-http' }
}

function Invoke-Ocr([string]$imagePath) {
    if ($ocrMode -in @('auto', 'windows')) {
        try {
            $feed = Get-OcrFeedBytes $imagePath
            return Invoke-WindowsOcr ([byte[]]$feed) $prefer
        } catch {
            if ($ocrMode -eq 'windows') { throw }
            Write-Warning "Windows OCR 失败，回退 Umi-OCR：$($_.Exception.Message)"
        }
    }
    return Invoke-UmiOcr $imagePath $umiUrl
}

# ---------- 截屏 ----------
# 采集区域：logs\region.json 优先（框选），否则全虚拟屏；越界自动裁剪到屏幕内
function Get-CaptureRect {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $rf = Join-Path $Root 'logs\region.json'
    if (Test-Path $rf) {
        try {
            $r = Get-Content $rf -Raw -Encoding UTF8 | ConvertFrom-Json
            $l  = [Math]::Max($vs.X, [int]$r.left)
            $t  = [Math]::Max($vs.Y, [int]$r.top)
            $rr = [Math]::Min(($vs.X + $vs.Width),  ([int]$r.left + [int]$r.width))
            $bb = [Math]::Min(($vs.Y + $vs.Height), ([int]$r.top  + [int]$r.height))
            if ((($rr - $l) -ge 200) -and (($bb - $t) -ge 200)) {
                return @{ L = $l; T = $t; W = ($rr - $l); H = ($bb - $t) }
            }
        } catch { }
    }
    @{ L = $vs.X; T = $vs.Y; W = $vs.Width; H = $vs.Height }
}
function New-ScreenShot([hashtable]$rect, [string]$pngPath) {
    $bmp = New-Object System.Drawing.Bitmap $rect.W, $rect.H
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($rect.L, $rect.T, 0, 0, (New-Object System.Drawing.Size $rect.W, $rect.H))
    $g.Dispose()
    $bmp.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    "$($rect.W)x$($rect.H)"
}

# ---------- 主流程 ----------
if ($Probe) {
    $langs = [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag }
    $eng   = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    "OCR_LANGUAGES: $(($langs -join ', '))"
    "OCR_ENGINE: $(if ($eng) { 'OK:' + $eng.RecognizerLanguage.LanguageTag } else { 'NULL' })"
    "OCR_MODE: $ocrMode"
    "VIRTUAL_SCREEN: $([System.Windows.Forms.SystemInformation]::VirtualScreen)"
    return
}

$ts    = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$outBase = if ($OutRoot) { $OutRoot } else { Join-Path $Root 'inbox' }
$shotsDir = Join-Path $outBase 'shots'
$textDir  = Join-Path $outBase 'text'
foreach ($d in @($shotsDir, $textDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

$run = if ($Note -match 'run:(\S+)') { $Matches[1] } else { $ts }

if ($ImageFile) {
    $pngPath = [IO.Path]::GetFullPath($ImageFile)
    if (-not (Test-Path $pngPath)) { throw "图片不存在: $pngPath" }
    $shotId = [IO.Path]::GetFileNameWithoutExtension($pngPath)
    $pngRel = $pngPath
    $rect = $null
} else {
    $shotId = $ts
    $pngPath = Join-Path $shotsDir "$shotId.png"
    $pngRel  = "shots/$shotId.png"
    $rect = Get-CaptureRect
    [void](New-ScreenShot $rect $pngPath)
}

$ocr = Invoke-Ocr $pngPath

$fm = @(
    '---',
    "shot: $shotId",
    "time: $(Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')",
    "png: $pngRel",
    "ocr: $($ocr.Engine)",
    "run: $run",
    "note: $Note",
    "region: $(if ($rect) { '{0},{1},{2},{3}' -f $rect.L, $rect.T, $rect.W, $rect.H } else { 'n/a(image)' })",
    '---'
)
$mdPath = Join-Path $textDir "$shotId.md"
Set-Content -Path $mdPath -Value ($fm + $ocr.Lines) -Encoding UTF8

"OK shot=$shotId lines=$($ocr.Lines.Count) ocr=$($ocr.Engine) md=$mdPath"
