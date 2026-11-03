#requires -Version 5.1
<#
  scan-daemon.ps1 — 热键守护进程（RegisterHotKey 消息循环，不轮询、不劫持、不注入）
  热键（可在 config.psd1 改）:
    Ctrl+Alt+S  扫描当前屏幕
    Ctrl+Alt+W  半自动滚动段扫（人速节奏 + 稳定即拍 + 缺漏校验）
    Ctrl+Alt+Q  中止滚动扫描
    Ctrl+Alt+R  框选采集区域
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [switch]$SmokeTest,
    [switch]$SelfTest,     # 行剖面互相关自检（无 UI、无网络）
    [switch]$ScanOnce,     # 单发截屏一次后退出（供 Web 控制台调用）
    [switch]$ScrollOnce    # 单发滚动段扫一次后退出（供 Web 控制台调用）
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
public static class U32D {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, int dwData, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT pt);
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] public static extern int GetMessage(out MSG msg, IntPtr hWnd, uint min, uint max);
    [DllImport("user32.dll")] public static extern bool PeekMessage(out MSG msg, IntPtr hWnd, uint min, uint max, uint remove);
}
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
public struct POINT { public int X; public int Y; }
public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }
"@
[void][U32D]::SetProcessDPIAware()

function Get-ScanConfig([string]$root) {
    $p = Join-Path $root 'config.psd1'
    if (Test-Path $p) { Import-PowerShellDataFile $p } else { @{} }
}
$cfg = Get-ScanConfig $Root
$logsDir = Join-Path $Root 'logs'
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
function Write-Log([string]$m) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path (Join-Path $logsDir 'daemon.log') -Value $line
    Write-Host $line
}

# ---------- 采集区域（选区优先，否则全虚拟屏） ----------
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

# ---------- 帧灰度与像素差 ----------
function Get-FrameGray {
    $rc = Get-CaptureRect
    $w = 96
    $h = [Math]::Max(8, [int][Math]::Round($w * $rc.H / [Math]::Max($rc.W, 1)))
    $bmp = New-Object System.Drawing.Bitmap $rc.W, $rc.H
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($rc.L, $rc.T, 0, 0, $bmp.Size)
    $g.Dispose()
    $small = New-Object System.Drawing.Bitmap $bmp, $w, $h
    $bmp.Dispose()
    $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
    $data = $small.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $stride = [Math]::Abs($data.Stride)
    $raw = New-Object byte[] ($stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $raw, 0, $raw.Length)
    $small.UnlockBits($data)
    $small.Dispose()
    $gray = New-Object byte[] ($w * $h)
    for ($y = 0; $y -lt $h; $y++) {
        $rowOff = $y * $stride
        $outOff = $y * $w
        for ($x = 0; $x -lt $w; $x++) {
            $i = $rowOff + $x * 3   # 24bpp BGR
            $gray[$outOff + $x] = [byte]((($raw[$i + 2] * 299) + ($raw[$i + 1] * 587) + ($raw[$i] * 114)) / 1000)
        }
    }
    @{ W = $w; H = $h; Gray = $gray }
}
function Get-GrayDiff([hashtable]$a, [hashtable]$b) {
    if (-not $a -or -not $b -or $a.W -ne $b.W -or $a.H -ne $b.H) { return 1.0 }
    $diff = 0; $total = $a.W * $a.H
    for ($i = 0; $i -lt $total; $i++) {
        if ([Math]::Abs([int]$a.Gray[$i] - [int]$b.Gray[$i]) -gt 12) { $diff++ }
    }
    ($diff / $total)
}

# ---------- 行剖面互相关（单格位移校准用） ----------
function Get-RowProfile([hashtable]$g, [int]$block) {
    $rows = [int][Math]::Floor($g.H / $block)
    $prof = New-Object int[] $rows
    for ($r = 0; $r -lt $rows; $r++) {
        $acc = 0L; $n = 0
        for ($y = ($r * $block); $y -lt (($r + 1) * $block); $y++) {
            for ($x = 0; $x -lt $g.W; $x += 4) {
                $acc += $g.Gray[($y * $g.W) + $x]; $n++
            }
        }
        if ($n -gt 0) { $prof[$r] = [int]($acc / $n) }
    }
    ,$prof
}
function Find-RowOffset([int[]]$a, [int[]]$b, [int]$maxDy) {
    # b 相对 a 的垂直位移：b[i] ≈ a[i-dy]（向下滚动 dy 行内容）
    $best = @{ Dy = -1; Matches = 0; Total = 0 }
    for ($dy = 0; $dy -le $maxDy; $dy++) {
        $m = 0; $t = 0
        for ($i = $dy; $i -lt $b.Count; $i++) {
            $j = $i - $dy
            if ($j -ge $a.Count) { break }
            $t++
            if ([Math]::Abs($b[$i] - $a[$j]) -le 3) { $m++ }
        }
        if ($m -gt $best.Matches) { $best = @{ Dy = $dy; Matches = $m; Total = $t } }
    }
    $best
}

# ---------- 行归一化（与 process-inbox 保持一致） ----------
# 注意：映射表用码位构造，禁止在源码里写弯引号字面量（写盘管线会把 U+2018/2019 规范化成 ASCII 单引号，'‘' 会变成 ''' 直接炸语法）
function ConvertTo-NormLine([string]$s) {
    $t = $s -replace '\s+', ''
    $pairs = @(
        @(0xFF0C, 0x002C), @(0x3002, 0x002E), @(0xFF1A, 0x003A), @(0xFF1B, 0x003B),
        @(0xFF1F, 0x003F), @(0xFF01, 0x0021), @(0xFF08, 0x0028), @(0xFF09, 0x0029),
        @(0x201C, 0x0022), @(0x201D, 0x0022), @(0x2018, 0x0027), @(0x2019, 0x0027),
        @(0x3010, 0x005B), @(0x3011, 0x005D), @(0x300A, 0x003C), @(0x300B, 0x003E),
        @(0x2014, 0x002D), @(0xFF5E, 0x007E)
    )
    foreach ($p in $pairs) {
        $t = $t.Replace([string][char]$p[0], [string][char]$p[1])
    }
    $t.ToLower()
}

# ---------- 热键（RegisterHotKey + 消息循环） ----------
$WM_HOTKEY = 0x0312
$modMap = @{ ctrl = 0x2; alt = 0x1; shift = 0x4; win = 0x8 }
function ConvertTo-HotKey([string]$combo) {
    $mods = 0x4000   # MOD_NOREPEAT
    $vk = 0
    foreach ($p in ($combo -split '\+')) {
        $t = $p.Trim().ToLower()
        if ($modMap.ContainsKey($t)) { $mods = $mods -bor $modMap[$t] }
        elseif ($t.Length -eq 1)     { $vk = [int][char]$t.ToUpper() }
        elseif ($t -match '^f(\d+)$') { $vk = 0x70 + [int]$Matches[1] - 1 }
        else                         { $vk = [int]$p.Trim() }
    }
    @{ Mods = [uint32]$mods; Vk = [uint32]$vk }
}
$hotDefs = @(
    @{ Id = 1; Name = 'ScanScreen';   Combo = $(if ($hkScan) { $hkScan } else { '' }) },
    @{ Id = 2; Name = 'ScanScroll';   Combo = '' },
    @{ Id = 3; Name = 'StopScroll';   Combo = '' },
    @{ Id = 4; Name = 'SelectRegion'; Combo = '' }
)
$hk = if ($cfg.Hotkeys) { $cfg.Hotkeys } else { @{} }
$hotDefs[0].Combo = $(if ($hk.ScanScreen)   { $hk.ScanScreen }   else { 'Ctrl+Alt+S' })
$hotDefs[1].Combo = $(if ($hk.ScanScroll)   { $hk.ScanScroll }   else { 'Ctrl+Alt+W' })
$hotDefs[2].Combo = $(if ($hk.StopScroll)   { $hk.StopScroll }   else { 'Ctrl+Alt+Q' })
$hotDefs[3].Combo = $(if ($hk.SelectRegion) { $hk.SelectRegion } else { 'Ctrl+Alt+R' })

function Register-AllHotKeys {
    $ok = @{}
    foreach ($h in $hotDefs) {
        $hk2 = ConvertTo-HotKey $h.Combo
        if ([U32D]::RegisterHotKey([IntPtr]::Zero, $h.Id, $hk2.Mods, $hk2.Vk)) { $ok[$h.Id] = $true }
        else { Write-Log "热键注册失败（可能被其他程序占用）: $($h.Combo)" }
    }
    $ok
}
function Unregister-AllHotKeys {
    foreach ($h in $hotDefs) { [void][U32D]::UnregisterHotKey([IntPtr]::Zero, $h.Id) }
}
$script:stopRequested = $false
function Pump-Messages {
    # 非阻塞泵：滚动扫描期间响应中止热键，丢弃排队的其他热键
    $m = New-Object 'U32D+MSG'
    while ([U32D]::PeekMessage([ref]$m, [IntPtr]::Zero, 0, 0, 1)) {
        if ($m.message -eq $WM_HOTKEY) {
            $id = [int]$m.wParam
            if ($id -eq 3) { $script:stopRequested = $true; Write-Log '收到中止热键' }
            else { Write-Log "滚动扫描期间忽略排队热键 id=$id" }
        }
    }
}

# ---------- 采集动作 ----------
$capScript = Join-Path $Root 'bin\capture-ocr.ps1'
function Invoke-Capture([string]$note) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $capScript -Root $Root -Note $note 2>&1
    $last = ($out | Select-Object -Last 1 | Out-String).Trim()
    Write-Log $last
    $last
}
function Read-NewestShotLines([string]$textDir, [string]$afterId) {
    $f = Get-ChildItem $textDir -Filter '*.md' | Where-Object { $_.BaseName -gt $afterId } |
        Sort-Object Name | Select-Object -Last 1
    if (-not $f) { return $null }
    $raw = Get-Content $f.FullName -Raw -Encoding UTF8
    if ($raw -match '(?s)^---\r?\n.*?\r?\n---\r?\n?(.*)$') { return @($Matches[1] -split '\r?\n' | Where-Object { $_.Trim() }) }
    return $null
}

# ---------- 节奏参数 ----------
$sc = if ($cfg.Scroll) { $cfg.Scroll } else { @{} }
$notchRange = if ($sc.NotchRange) { @([int]$sc.NotchRange[0], [int]$sc.NotchRange[1]) } else { @(2, 4) }
$pauseRange = if ($sc.NotchMs)          { @([int]$sc.NotchMs[0], [int]$sc.NotchMs[1]) } else { @(250, 750) }
$readChance = if ($sc.ExtraReadChance)  { [int]$sc.ExtraReadChance }  else { 10 }
$readRange  = if ($sc.ExtraReadMs)      { @([int]$sc.ExtraReadMs[0], [int]$sc.ExtraReadMs[1]) } else { @(1500, 3000) }
$maxSteps   = if ($sc.ScreenCount)      { [int]$sc.ScreenCount }      else { 12 }
$stabGap    = if ($sc.StabilityIntervalMs) { [int]$sc.StabilityIntervalMs } else { 500 }
$diffThr    = if ($sc.DiffThresholdPct) { [double]$sc.DiffThresholdPct / 100 } else { 0.005 }
$maxWaitMs  = if ($sc.MaxWaitMs)        { [int]$sc.MaxWaitMs }        else { 4000 }
$gapMax     = if ($sc.GapMaxRetries)    { [int]$sc.GapMaxRetries }    else { 3 }
$maxDurSec  = if ($sc.MaxDurationSec)   { [int]$sc.MaxDurationSec }   else { 180 }

function Invoke-Wheel([int]$delta, [int]$times, [int]$gapMin = 60, [int]$gapMax = 140) {
    for ($i = 0; $i -lt $times; $i++) {
        [U32D]::mouse_event(0x0800, 0, 0, $delta, [UIntPtr]::Zero)   # -120 下滚 / +120 上滚
        Start-Sleep -Milliseconds (Get-Random -Minimum $gapMin -Maximum $gapMax)
    }
}
function Invoke-ScrollStep([int]$forcedNotch = 0) {
    $notch = $forcedNotch
    if ($notch -le 0) { $notch = Get-Random -Minimum $notchRange[0] -Maximum ($notchRange[1] + 1) }
    Invoke-Wheel (-120) $notch
    # 停顿取对数正态形态（阅读时间右偏），比均匀分布更自然
    $pause = [int][Math]::Exp((Get-Random -Minimum ([Math]::Log($pauseRange[0])) -Maximum ([Math]::Log($pauseRange[1]))))
    if ((Get-Random -Maximum $readChance) -eq 0) {
        $pause += Get-Random -Minimum $readRange[0] -Maximum $readRange[1]   # 模拟"读一条"
    }
    Start-Sleep -Milliseconds $pause
    # 人味小动作：偶尔回滚一格再看一眼（个别平滑滚动应用中净位移可能非零，由缺漏校验兜底）
    if ((Get-Random -Maximum 6) -eq 0) {
        Invoke-Wheel 120 1 100 200
        Start-Sleep -Milliseconds (Get-Random -Minimum 300 -Maximum 900)
        Invoke-Wheel (-120) 1 100 200
        Start-Sleep -Milliseconds (Get-Random -Minimum 200 -Maximum 500)
    }
}

# ---------- 稳定帧（像素差阈值 + 最长等待） ----------
function Wait-StableFrame {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $prev = $null
    while ($true) {
        $g = Get-FrameGray
        if ($prev -and ((Get-GrayDiff $prev $g) -lt $diffThr)) {
            return @{ Gray = $g; Stable = $true; TimedOut = $false; Stop = $false }
        }
        $prev = $g
        Pump-Messages
        if ($script:stopRequested) { return @{ Gray = $g; Stable = $false; TimedOut = $false; Stop = $true } }
        if ($sw.ElapsedMilliseconds -ge $maxWaitMs) {
            return @{ Gray = $g; Stable = $false; TimedOut = $true; Stop = $false }   # 超时照拍，交由标记与校验兜底
        }
        Start-Sleep -Milliseconds $stabGap
    }
}

# ---------- 环境预检（前台窗口 + 光标在选区内） ----------
function Test-EnvStable($hwnd0, $rect0, $capRect) {
    if ([U32D]::GetForegroundWindow() -ne $hwnd0) { return $false }
    $rc = New-Object 'U32D+RECT'
    [void][U32D]::GetWindowRect($hwnd0, [ref]$rc)
    if ($rc.Left -ne $rect0.Left -or $rc.Top -ne $rect0.Top -or $rc.Right -ne $rect0.Right -or $rc.Bottom -ne $rect0.Bottom) { return $false }
    $pt = New-Object 'U32D+POINT'
    [void][U32D]::GetCursorPos([ref]$pt)
    if ($pt.X -lt $capRect.L -or $pt.X -ge ($capRect.L + $capRect.W) -or $pt.Y -lt $capRect.T -or $pt.Y -ge ($capRect.T + $capRect.H)) { return $false }
    return $true
}
function Wait-EnvStable($hwnd0, $rect0, $capRect) {
    Write-Log '前台窗口或光标位置变化，暂停等待恢复…'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-EnvStable $hwnd0 $rect0 $capRect)) {
        Pump-Messages
        if ($script:stopRequested) { return $false }
        if ($sw.ElapsedMilliseconds -gt 60000) { Write-Log '环境 60s 未恢复，中止本次扫描'; return $false }
        Start-Sleep -Milliseconds 1500
    }
    Write-Log '环境已恢复，继续扫描'
    return $true
}

# ---------- 半自动滚动段扫 ----------
function Invoke-ScrollScan {
    $runId = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:stopRequested = $false
    $script:gapRetries = 0
    $runSw = [System.Diagnostics.Stopwatch]::StartNew()
    $capRect = Get-CaptureRect
    $hwnd0 = [U32D]::GetForegroundWindow()
    $rect0 = New-Object 'U32D+RECT'
    [void][U32D]::GetWindowRect($hwnd0, [ref]$rect0)
    Write-Log "滚动扫描开始 run=$runId（每步 $($notchRange[0])-$($notchRange[1]) 格，上限 $maxSteps 步 / ${maxDurSec}s）"
    $textDir = Join-Path $Root 'inbox\text'
    if (-not (Test-Path $textDir)) { New-Item -ItemType Directory -Path $textDir -Force | Out-Null }

    # ---- 单格位移校准（行剖面互相关；失败则用默认节奏，不影响正确性） ----
    $pxPerNotch = -1
    $g1 = Get-FrameGray
    Invoke-Wheel (-120) 1 90 180
    $stC = Wait-StableFrame
    if (-not $stC.Stop) {
        $g2 = Get-FrameGray
        $block = 4
        $off = Find-RowOffset (Get-RowProfile $g1 $block) (Get-RowProfile $g2 $block) ([Math]::Min([int]($capRect.H / $block / 2), 150))
        if (($off.Total -gt 0) -and ($off.Matches -ge ($off.Total * 0.25)) -and ($off.Dy -gt 0)) {
            $pxPerNotch = $off.Dy * $block
            Write-Log "校准：单格位移 ≈ ${pxPerNotch}px"
            if ($pxPerNotch -gt ($capRect.H * 0.4)) { Write-Log '警告：单格滚动位移偏大，本运行每步只滚 1 格' }
        } else {
            Write-Log '校准无结论（可能已在底部或单格整页滚动），使用默认节奏'
        }
    } else { return }
    Invoke-Wheel 120 1 90 180       # 回滚校准位移，从头覆盖
    [void](Wait-StableFrame)

    $framesSeen = 0
    $boring = @{}
    $prevLines = $null; $prevGray = $null; $noMoveStreak = 0
    $lastPt = New-Object 'U32D+POINT'; [void][U32D]::GetCursorPos([ref]$lastPt)

    for ($step = 1; $step -le $maxSteps; $step++) {
        Pump-Messages
        if ($script:stopRequested) { break }
        if ($runSw.ElapsedMilliseconds -gt ($maxDurSec * 1000)) { Write-Log "达到单次时长上限 ${maxDurSec}s，结束扫描"; break }
        if (-not (Test-EnvStable $hwnd0 $rect0 $capRect)) {
            if (-not (Wait-EnvStable $hwnd0 $rect0 $capRect)) { break }
        }
        # 人工输入启发：两次步进之间光标被移动过 → 附加停顿让出控制权
        $pt = New-Object 'U32D+POINT'
        [void][U32D]::GetCursorPos([ref]$pt)
        if (($pt.X -ne $lastPt.X) -or ($pt.Y -ne $lastPt.Y)) {
            Start-Sleep -Milliseconds (Get-Random -Minimum 800 -Maximum 2000)
        }
        $lastPt = $pt

        # 步长：随机区间 ∩ 几何上限（校准后单格过大则限 1 格）
        $notch = Get-Random -Minimum $notchRange[0] -Maximum ($notchRange[1] + 1)
        if ($pxPerNotch -gt ($capRect.H * 0.4)) { $notch = 1 }
        elseif ($pxPerNotch -gt 0) {
            $maxByGeom = [Math]::Max(1, [int][Math]::Floor(($capRect.H * 0.3) / $pxPerNotch))
            if ($notch -gt $maxByGeom) { $notch = $maxByGeom }
        }
        Invoke-ScrollStep $notch

        $st = Wait-StableFrame
        if ($st.Stop) { break }
        $gray = $st.Gray
        $note = "run:$runId step:$step"
        if ($st.TimedOut) { $note += ' unstable:1'; Write-Log '等待稳定超时，照拍并标记 unstable' }
        $beforeId = (Get-ChildItem $textDir -Filter '*.md' | Sort-Object Name | Select-Object -Last 1).BaseName
        Invoke-Capture $note
        $gray = Get-FrameGray    # 拍摄后即时取帧，用于像素级不动判定

        # ① 像素级不动判定（空帧/纯图/视频区域也成立）
        if ($prevGray) {
            $d = Get-GrayDiff $prevGray $gray
            if ($d -lt $diffThr) { $noMoveStreak++ } else { $noMoveStreak = 0 }
        }
        $prevGray = $gray
        if ($noMoveStreak -ge 2) { Write-Log '连续两次滚动后画面不变 → 已到底部，结束'; break }

        # ② 文本层校验
        $newLines = Read-NewestShotLines $textDir $beforeId
        if ($newLines) {
            $framesSeen++
            $newN = @($newLines | ForEach-Object { ConvertTo-NormLine $_ })
            $shared = -1
            if ($prevLines) {
                $prevN = @($prevLines | ForEach-Object { ConvertTo-NormLine $_ })
                $shared = 0
                foreach ($t in $newN) { if ($prevN -contains $t) { $shared++ } }
                # 可用行：排除首末行（边缘截断）、排除所有先前帧都出现的固定元素、长度≥4
                $usable = @()
                for ($i = 0; $i -lt $newN.Count; $i++) {
                    if ($i -eq 0 -or $i -eq ($newN.Count - 1)) { continue }
                    $t = $newN[$i]
                    if ($t.Length -lt 4) { continue }
                    $prior = 0; if ($boring.ContainsKey($t)) { $prior = $boring[$t] }
                    if (($framesSeen -gt 1) -and ($prior -ge ($framesSeen - 1))) { continue }
                    $usable += $t
                }
                # 缺漏校验：新帧顶部可用行必须能在上一帧找到
                if ($usable.Count -ge 2) {
                    $tailN = @($prevN | Select-Object -Last 60)
                    $evidence = 0
                    foreach ($t in ($usable | Select-Object -First 6)) { if ($tailN -contains $t) { $evidence++ } }
                    if ($evidence -eq 0) {
                        $script:gapRetries++
                        if ($script:gapRetries -gt $gapMax) {
                            Write-Log "GAP 重试超过上限（$gapMax），停止并告警：请人工检查衔接"
                            break
                        }
                        Write-Log "GAP：新帧与上一帧无重叠证据（第 $script:gapRetries 次），自动回滚补拍"
                        Invoke-Wheel 120 ($notchRange[1] * 2) 90 180
                        $stG = Wait-StableFrame
                        if ($stG.Stop) { break }
                        Invoke-Capture "run:$runId step:$step gapfix:1"
                        $gapLines = Read-NewestShotLines $textDir $beforeId
                        if ($gapLines) {
                            $framesSeen++
                            foreach ($t in @($gapLines | ForEach-Object { ConvertTo-NormLine $_ })) {
                                if ($boring.ContainsKey($t)) { $boring[$t]++ } else { $boring[$t] = 1 }
                            }
                            $prevLines = $gapLines
                        }
                        continue   # 下一步正常下滚，重新覆盖间隙
                    }
                }
                # 文本级到底辅助：新帧几乎全部行都在上一帧
                if (($newN.Count -ge 4) -and ($shared -ge ($newN.Count - 1))) { $noMoveStreak++ }
                # 自适应阅读停顿：新增内容多则多读一会儿
                if (($newN.Count - $shared) -ge 8) {
                    Start-Sleep -Milliseconds (Get-Random -Minimum 800 -Maximum 1800)
                }
            }
            foreach ($t in $newN) {
                if ($boring.ContainsKey($t)) { $boring[$t]++ } else { $boring[$t] = 1 }
            }
            $prevLines = $newLines
        }
    }
    Write-Log "滚动扫描结束 run=$runId"
}

# ---------- 入口 ----------
if ($SelfTest) {
    $a = New-Object int[] 200
    for ($i = 0; $i -lt 200; $i++) { $a[$i] = (($i * 37) % 211) }
    $dyReal = 13
    $b = New-Object int[] 200
    for ($i = 0; $i -lt 200; $i++) { $j = $i - $dyReal; $b[$i] = if ($j -ge 0) { $a[$j] } else { (($i * 11) % 211) } }
    $off = Find-RowOffset $a $b 60
    if ($off.Dy -eq $dyReal -and $off.Matches -ge 150) { "SELFTEST PASS dy=$($off.Dy) matches=$($off.Matches)/$($off.Total)" }
    else { "SELFTEST FAIL dy=$($off.Dy) matches=$($off.Matches)/$($off.Total)" }
    exit 0
}
if ($SmokeTest) { Write-Log 'SMOKE_OK：热键守护进程加载成功'; exit 0 }
if ($ScanOnce)   { Invoke-Capture "run:$(Get-Date -Format 'yyyyMMdd-HHmmss')" | Out-Null; Write-Log '单发扫描完成'; exit 0 }
if ($ScrollOnce) {
    $reg = Register-AllHotKeys
    try { Invoke-ScrollScan } finally { Unregister-AllHotKeys }
    Write-Log '单发滚动扫描完成'
    exit 0
}

$capProbe = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $capScript -Root $Root -Probe 2>&1
Write-Log "OCR 探测: $($capProbe -join ' | ')"
$reg = Register-AllHotKeys
Write-Log "守护进程就绪 pid=$PID  扫屏=$(($hotDefs[0].Combo))  滚动扫=$(($hotDefs[1].Combo))  中止=$(($hotDefs[2].Combo))  选区=$(($hotDefs[3].Combo))"

$msg = New-Object 'U32D+MSG'
try {
    while ($true) {
        $r = [U32D]::GetMessage([ref]$msg, [IntPtr]::Zero, 0, 0)
        if ($r -le 0) { break }   # WM_QUIT 或错误
        if ($msg.message -eq $WM_HOTKEY) {
            try {
                switch ([int]$msg.wParam) {
                    1 { Write-Log '热键触发：扫描当前屏幕'; Invoke-Capture "run:$(Get-Date -Format 'yyyyMMdd-HHmmss')" | Out-Null }
                    2 { Invoke-ScrollScan }
                    4 {
                        Write-Log '热键触发：框选采集区域'
                        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
                            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'bin\select-region.ps1'), '-Root', $Root
                        ) | Out-Null
                    }
                    default { }
                }
            } catch {
                Write-Log "ERROR: $($_.Exception.Message)"
            }
        }
    }
} finally {
    Unregister-AllHotKeys
    Write-Log '守护进程退出'
}
