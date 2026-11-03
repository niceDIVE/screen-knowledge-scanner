<#
  search.ps1 — 知识库全文检索
  用法: powershell -File search.ps1 -Query 世界书 [-Regex] [-Top 10]
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Query,
    [switch]$Regex,
    [int]$Top = 10,
    [int]$PerFile = 3,
    [string]$Root = ''
)
if (-not $Root) {
    $self = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Root = Split-Path -Parent $self
}
if ([IO.Path]::IsPathRooted($Root)) { $Root = [IO.Path]::GetFullPath($Root) }
else { $Root = [IO.Path]::GetFullPath((Join-Path (Get-Location) $Root)) }   # 绝对化，避免后续 Substring 切错
$vault = Join-Path $Root 'vault'
if (-not (Test-Path $vault)) { 'vault 目录不存在'; return }
$files = @(Get-ChildItem $vault -Recurse -Filter '*.md' -File)
if ($files.Count -eq 0) { '知识库为空'; return }

$hits = @($files | Select-String -Pattern $Query -SimpleMatch:(-not $Regex))
if ($hits.Count -eq 0) { "没有命中: $Query"; return }

"命中 $($hits.Count) 处 / $($hits | Group-Object Path | Measure-Object | Select-Object -ExpandProperty Count) 个文件"
''
$hits | Group-Object Path | Sort-Object Count -Descending | Select-Object -First $Top | ForEach-Object {
    $rel = $_.Name.Substring([Math]::Min($Root.Length + 1, $_.Name.Length))
    "=== $rel  （$($_.Count) 处）"
    $_.Group | Select-Object -First $PerFile | ForEach-Object {
        "  L$($_.LineNumber): $($_.Line.Trim())"
    }
    ''
}
