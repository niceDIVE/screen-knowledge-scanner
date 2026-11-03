#requires -Version 5.1
<#
  process-inbox.ps1 — inbox 清洗 → vault 知识库
    1. 相邻截图行级拼接：锚点对齐（上一帧末尾"长且唯一"行在新帧全行中定位），归一化比较
       —— 大重叠（≥35 行）是常态，前后缀小窗口匹配会整帧重复，故不再使用
    2. 疑似代码/JSON 的截图 → "手动复制清单"（OCR 对代码不可靠，人工兜底）
    3. 视觉 LLM 钩子（config.psd1 VisionLLM.Enabled = $true 时启用）
    4. 幂等：批次内容哈希已入库则跳过，重复扫描不产生重复文档
  默认只复制进 vault，不删 inbox；确认无误后可加 -CleanInbox 清理
  -StateFile / -ReportFile：供 Web 控制台异步调用（运行状态与结果报告落盘）
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [switch]$CleanInbox,
    [string]$StateFile = '',
    [string]$ReportFile = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Root) {
    $self = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Root = Split-Path -Parent $self
}
if ([IO.Path]::IsPathRooted($Root)) { $Root = [IO.Path]::GetFullPath($Root) }
else { $Root = [IO.Path]::GetFullPath((Join-Path (Get-Location) $Root)) }

function Get-ScanConfig([string]$root) {
    $p = Join-Path $root 'config.psd1'
    if (Test-Path $p) { Import-PowerShellDataFile $p } else { @{} }
}
$cfg = Get-ScanConfig $Root
$inbox   = Join-Path $Root 'inbox'
$shotsIn = Join-Path $inbox 'shots'
$textIn  = Join-Path $inbox 'text'
$vault   = Join-Path $Root 'vault'
foreach ($d in @((Join-Path $vault 'scans'), (Join-Path $vault '_shots'), (Join-Path $vault '_meta'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$Utf8 = [System.Text.Encoding]::UTF8

# ---------- 行归一化（全半角/空白/大小写；与 scan-daemon 保持一致） ----------
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

# ---------- 前置元数据解析 ----------
function Split-FrontMatter([string]$raw) {
    $fm = @{}; $body = $raw
    if ($raw -match '(?s)^---\r?\n(.*?)\r?\n---\r?\n?(.*)$') {
        # 立刻保存分组：下面逐行 -match 会覆盖 $Matches
        $fmText = $Matches[1]; $body = $Matches[2]
        foreach ($ln in ($fmText -split '\r?\n')) {
            if ($ln -match '^([\w-]+):\s*(.*)$') { $fm[$Matches[1].ToLower()] = $Matches[2].Trim() }
        }
    }
    [pscustomobject]@{ Fm = $fm; Lines = @($body -split '\r?\n' | Where-Object { $_.Trim() }) }
}

# ---------- 锚点对齐拼接 ----------
# 步长(≤500px) ≪ 视口高度 ⇒ 相邻帧重叠可达 35+ 行，是常态而非边缘：
# 前后缀小窗口匹配必然失配 → 整帧重复。锚点法：取上一帧末尾"长且唯一"的行，
# 在新帧全部行中定位（与缺漏校验的全帧查找一致），按位置切割。
# 找不到锚点 → 保守全部保留（宁重复不丢失）。首末行可能被边缘截断成乱码，
# 但它们只会导致匹配失败（保守回退），不会导致丢内容。
function Merge-ShotLines([string[]]$prev, [string[]]$next) {
    $prevArr = @($prev); $nextArr = @($next)
    if ($prevArr.Count -eq 0) { return $nextArr }
    if ($nextArr.Count -eq 0) { return @() }
    $prevN = @($prevArr | ForEach-Object { ConvertTo-NormLine $_ })
    $nextN = @($nextArr | ForEach-Object { ConvertTo-NormLine $_ })
    # 锚点候选：上一帧末尾 15 行，归一化后长度 ≥8 且在上一帧内唯一（自底向上取）
    $anchors = New-Object System.Collections.ArrayList
    $start = [Math]::Max(0, $prevN.Count - 15)
    for ($i = $prevN.Count - 1; $i -ge $start; $i--) {
        $t = $prevN[$i]
        if ($t.Length -ge 8) {
            $c = 0
            foreach ($x in $prevN) { if ($x -eq $t) { $c++ } }
            if ($c -eq 1) { [void]$anchors.Add(@{ I = $i; T = $t }) }
        }
    }
    foreach ($a in $anchors) {
        # 在新帧中必须唯一命中
        $p = -1; $pc = 0
        for ($j = 0; $j -lt $nextN.Count; $j++) {
            if ($nextN[$j] -eq $a.T) { $pc++; if ($p -lt 0) { $p = $j }; if ($pc -gt 1) { break } }
        }
        if ($pc -ne 1) { continue }
        # 从锚点向后延长连续匹配段，最大限度吃掉重复区
        $k = 1
        while ((($a.I + $k) -lt $prevN.Count) -and (($p + $k) -lt $nextN.Count) -and ($prevN[$a.I + $k] -eq $nextN[$p + $k])) { $k++ }
        $cut = $p + $k
        if ($cut -ge $nextN.Count) { return @() }   # 锚点之后无新内容
        return @($nextArr[$cut..($nextArr.Count - 1)])
    }
    return $nextArr
}

# ---------- 代码/JSON 疑似检测 ----------
# OCR 常把花括号/引号吃掉或转成全角，按"任一强信号行"判定而非行数占比
function Test-CodeLike([string[]]$lines) {
    if (@($lines).Count -lt 3) { return $false }
    $strong = @($lines | Where-Object {
        ($_.Split('"').Count -ge 4) -or
        ($_ -match '"[\w-]+"\s*[：:]') -or
        ($_ -match '(^|\s)[{]\s*"')
    })
    return (@($strong).Count -ge 1)
}

# ---------- 视觉 LLM（OpenAI 兼容接口） ----------
function Invoke-VisionLLM([string]$pngPath, $v) {
    $key = [Environment]::GetEnvironmentVariable([string]$v.ApiKeyEnv)
    if (-not $key) { throw "环境变量 $($v.ApiKeyEnv) 未设置，无法调用视觉 LLM" }
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($pngPath))
    $prompt = @'
把这张 Discord/聊天窗口截图转写成结构化 Markdown：
1. 每条消息一行：`[时间] **作者**: 正文`（时间从消息元数据辨认，认不出就写 [?]）
2. 引用/回复关系用 `>` 缩进表示
3. 代码/JSON 块用 ``` 包裹，逐字符小心转写（注意 0/O、1/l/I、引号方向）
4. 表情、图片、附件用 `[图片]` `[附件: 文件名]` 占位
5. 只输出转写结果，不要任何解释
'@
    $body = @{
        model    = $v.Model
        messages = @(@{
            role    = 'user'
            content = @(
                @{ type = 'text'; text = $prompt },
                @{ type = 'image_url'; image_url = @{ url = "data:image/png;base64,$b64" } }
            )
        })
    } | ConvertTo-Json -Depth 8
    $r = Invoke-RestMethod -Uri (([string]$v.BaseUrl).TrimEnd('/') + '/chat/completions') `
        -Method Post -Headers @{ Authorization = "Bearer $key" } `
        -ContentType 'application/json' -Body $body -TimeoutSec 180
    return $r.choices[0].message.content
}

# ---------- 主流程（StateFile/ReportFile 兜底写状态） ----------
$report = @()
try {
    if ($StateFile) { Set-Content -Path $StateFile -Value ("running " + (Get-Date -Format s)) -Encoding UTF8 }

    $mdFiles = @(Get-ChildItem $textIn -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($mdFiles.Count -eq 0) {
        $report += 'inbox 里没有待处理文本。先用热键或 capture-ocr.ps1 采集。'
        return
    }

    $shots = @{}
    foreach ($f in $mdFiles) {
        $parsed = Split-FrontMatter (Get-Content $f.FullName -Raw -Encoding UTF8)
        $run = if ($parsed.Fm['run']) { $parsed.Fm['run'] } else { $f.BaseName }
        if (-not $shots.ContainsKey($run)) { $shots[$run] = @() }
        $shots[$run] += [pscustomobject]@{
            Id    = $f.BaseName
            Run   = $run
            Png   = $parsed.Fm['png']
            Lines = $parsed.Lines
            Note  = [string]$parsed.Fm['note']
            File  = $f.FullName
        }
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hashFile = Join-Path $vault '_meta\ingested-hashes.txt'
    $processed = 0

    foreach ($run in ($shots.Keys | Sort-Object)) {
        $list = @($shots[$run] | Sort-Object Id)
        $merged = @()
        $flagged = @()
        foreach ($s in $list) {
            # Merge-ShotLines 返回"新帧独有段"（增量），必须与已累积历史拼接，不能直接覆盖
            $delta = Merge-ShotLines $merged $s.Lines
            $merged = @($merged) + @($delta)
            if (Test-CodeLike $s.Lines) { $flagged += $s }
        }

        # 幂等：内容哈希已入库 → 跳过（重复扫描不产生重复文档）
        $mergedN = @($merged | ForEach-Object { ConvertTo-NormLine $_ })
        $contentHash = [BitConverter]::ToString($sha.ComputeHash($Utf8.GetBytes(($mergedN -join "`n")))) -replace '-', ''
        if ((Test-Path $hashFile) -and (@(Get-Content $hashFile -ErrorAction SilentlyContinue) -contains $contentHash)) {
            $report += "run=$run  内容与已入库批次重复 → 跳过"
            continue
        }

        # 视觉 LLM 二级处理
        $llmBlocks = @{}
        $v = if ($cfg.VisionLLM) { $cfg.VisionLLM } else { @{ Enabled = $false; Trigger = 'never' } }
        if ($v.Enabled -and $v.Trigger -ne 'never' -and $flagged.Count -gt 0) {
            foreach ($s in $flagged) {
                $pngSrc = if ([IO.Path]::IsPathRooted($s.Png)) { $s.Png } else { Join-Path $inbox $s.Png }
                if (-not (Test-Path $pngSrc)) { continue }
                try {
                    $out = Invoke-VisionLLM $pngSrc $v
                    $llmBlocks[$s.Id] = $out
                    Set-Content -Path (Join-Path $vault ('_shots\' + $s.Id + '.llm.md')) -Value $out -Encoding UTF8
                    Write-Host "视觉 LLM 结构化完成: $($s.Id)"
                } catch {
                    Write-Host "视觉 LLM 调用失败（$($s.Id)）: $($_.Exception.Message)"
                }
            }
        }

        # 组装 scan 文档
        $timeStr = Get-Date -Format 'yyyy-MM-dd HH:mm'
        $fm = @(
            '---', 'type: scan', "run: $run",
            "shots: $(($list | ForEach-Object Id) -join ',')",
            "flagged: $(($flagged | ForEach-Object Id) -join ',')",
            "created: $(Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')", '---'
        )
        $doc = @($fm) + @('', "# 屏幕扫描 $timeStr", '')
        # 合并全文（去重后）：锚点拼接出的连续内容，供阅读与检索；各帧原始行留作证据
        if ($merged.Count -gt 0) {
            $doc += @('## 合并全文（去重后）', '')
            $doc += $merged
            $doc += ''
        }
        foreach ($s in $list) {
            $doc += @("## 截屏 $($s.Id)", '')
            if ($s.Note -match 'gapfix:1') {
                $doc += @('> ⚠️ **补扫帧**：程序检测到此帧与上一帧无重叠（异常跳变），已自动回滚补拍。请核对此处与上下文的衔接是否缺漏。', '')
            }
            $pngTarget = Join-Path $vault ('_shots\' + $s.Id + '.png')
            # png 前置元数据相对 inbox 目录（或为绝对路径）
            $pngSrc = if ([IO.Path]::IsPathRooted($s.Png)) { $s.Png } else { Join-Path $inbox $s.Png }
            if (Test-Path $pngSrc) {
                Copy-Item $pngSrc $pngTarget -Force
                $doc += @('![截图](../_shots/' + $s.Id + '.png)', '')
            }
            if ($llmBlocks.ContainsKey($s.Id)) {
                $doc += @('### 视觉 LLM 结构化', '', $llmBlocks[$s.Id], '', '### OCR 原始行（供比对）', '')
            }
            $doc += $s.Lines
            $doc += ''
        }
        $scanPath = Join-Path $vault ('scans\scan-' + $run + '.md')
        Set-Content -Path $scanPath -Value $doc -Encoding UTF8
        Add-Content -Path $hashFile -Value $contentHash -Encoding UTF8
        $processed++

        # 手动复制清单（按截图 id 去重）
        $clPath = Join-Path $vault '_meta\手动复制清单.md'
        $clNow = if (Test-Path $clPath) { Get-Content $clPath -Raw -Encoding UTF8 } else { '' }
        foreach ($s in $flagged) {
            if ($clNow -and $clNow.Contains($s.Id)) { continue }
            $entry = "- $(Get-Date -Format 'yyyy-MM-dd HH:mm') [$($s.Id)](../_shots/$($s.Id).png) — 疑似代码/JSON，OCR 不可靠，请对照截图手动复制原文"
            Add-Content -Path $clPath -Value $entry -Encoding UTF8
        }
        $report += "run=$run  截图=$($list.Count)  合并行=$($merged.Count)  疑似代码=$($flagged.Count)  → $scanPath"
    }

    # 可选：清理 inbox（显式开关才执行）
    if ($CleanInbox -and $processed -gt 0) {
        foreach ($f in $mdFiles) { Remove-Item $f.FullName -Force }
        Get-ChildItem $shotsIn -Filter '*.png' -File -ErrorAction SilentlyContinue | Remove-Item -Force
        $report += 'inbox 已清理'
    }

    $report += "入库完成：$processed 个批次。检索：bin\search.ps1 -Query 关键词"
} finally {
    if ($ReportFile) { Set-Content -Path $ReportFile -Value ($report -join "`r`n") -Encoding UTF8 }
    if ($StateFile)  { Set-Content -Path $StateFile  -Value ("done " + (Get-Date -Format s)) -Encoding UTF8 }
}

''
$report
