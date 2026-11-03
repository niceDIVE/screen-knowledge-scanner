<#
  ask.ps1 — 向知识库提问（V1：多关键词 ranked 检索；RAG 见 README 路线图）
  用法: powershell -File ask.ps1 -Question "世界书 分批 触发"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Question,
    [int]$Top = 5,
    [string]$Root = ''
)
if (-not $Root) {
    $self = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Root = Split-Path -Parent $self
}
if ([IO.Path]::IsPathRooted($Root)) { $Root = [IO.Path]::GetFullPath($Root) }
else { $Root = [IO.Path]::GetFullPath((Join-Path (Get-Location) $Root)) }
$vault = Join-Path $Root 'vault'
$files = @(Get-ChildItem $vault -Recurse -Filter '*.md' -File -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) { '知识库为空，先采集并处理。'; return }

# 中文按 2 字滑窗切词 + 英文按词切
$keywords = @()
foreach ($raw in ($Question -split '\s+')) {
    if ($raw -match '^[a-zA-Z0-9_-]+$') { if ($raw) { $keywords += $raw } }
    else {
        $t = $raw -replace '[，。？！、：""''（）]', ''
        for ($i = 0; $i -lt $t.Length - 1; $i++) { $keywords += $t.Substring($i, 2) }
    }
}
$keywords = @($keywords | Select-Object -Unique)
if ($keywords.Count -eq 0) { '没有可用关键词'; return }

$score = @{}
$best  = @{}
foreach ($kw in $keywords) {
    $hits = @($files | Select-String -Pattern $kw -SimpleMatch)
    foreach ($h in $hits) {
        if (-not $score.ContainsKey($h.Path)) { $score[$h.Path] = 0; $best[$h.Path] = @() }
        $score[$h.Path]++
        if ($best[$h.Path].Count -lt 3) { $best[$h.Path] += "  L$($h.LineNumber): $($h.Line.Trim())" }
    }
}
if ($score.Count -eq 0) { "没有命中。试过关键词: $($keywords -join ' / ')"; return }

"按匹配密度排序（关键词: $($keywords -join '、')）"
''
$score.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Top | ForEach-Object {
    $rel = $_.Key.Substring([Math]::Min($Root.Length + 1, $_.Key.Length))
    "=== $rel  （密度 $($_.Value)）"
    $best[$_.Key]
    ''
}
