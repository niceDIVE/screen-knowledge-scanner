#requires -Version 5.1
<#
  web-server.ps1 — 屏幕扫描机器人 本地 Web 控制台后端
  传输层：TcpListener + 手写 HTTP/1.1 子集（本机环境裁掉了 HttpListener，实测 TcpListener 可用）
  安全：只绑定 127.0.0.1、Host 头校验（防 DNS rebinding）、路径穿越防护、静态文件白名单。
  由 start-web.ps1 启动；不要手动把端口暴露到局域网。
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [int]$Port = 0
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
$webCfg = if ($cfg.Web) { $cfg.Web } else { @{} }
if ($Port -le 0) { $Port = if ($webCfg.Port) { [int]$webCfg.Port } else { 8787 } }

$logsDir = Join-Path $Root 'logs'
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
function Write-WebLog([string]$m) {
    Add-Content -Path (Join-Path $logsDir 'web.log') -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
}

# ---------- 基础 ----------
$Utf8 = [System.Text.Encoding]::UTF8
$Ascii = [System.Text.Encoding]::ASCII

function Resolve-InRoot([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $Root $p }
    $full = [IO.Path]::GetFullPath($p)
    if ($full.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) { $full } else { $null }
}
function Get-PidStatus([string]$pidFile) {
    if (Test-Path $pidFile) {
        $p = Get-Content $pidFile -ErrorAction SilentlyContinue
        $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -match '^powershell$') {
            return @{ running = $true; pid = [int]$p }
        }
    }
    @{ running = $false; pid = $null }
}

# ---------- 工具调用 ----------
$binDir = Join-Path $Root 'bin'
function Invoke-Tool([string]$file, [string[]]$toolArgs) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $binDir $file) @toolArgs 2>&1
    ,@($out | ForEach-Object { $_.ToString() })
}
function Start-Detached([string]$file, [string[]]$toolArgs, [string]$pidFile) {
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $binDir $file)) + $toolArgs
    $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList $all
    Set-Content -Path $pidFile -Value $p.Id
    $p.Id
}
function Stop-Detached([string]$pidFile) {
    $st = Get-PidStatus $pidFile
    if ($st.running) {
        Stop-Process -Id $st.pid -Force
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        return @{ stopped = $true; pid = $st.pid }
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    @{ stopped = $false; note = '进程不在运行或已退出' }
}
function Get-RegionObj {
    $rf = Join-Path $Root 'logs\region.json'
    if (Test-Path $rf) {
        try {
            $r = Get-Content $rf -Raw -Encoding UTF8 | ConvertFrom-Json
            return @{ left = [int]$r.left; top = [int]$r.top; width = [int]$r.width; height = [int]$r.height }
        } catch { }
    }
    return $null
}
function Get-StatusObj {
    $inboxText = @(Get-ChildItem (Join-Path $Root 'inbox\text') -Filter '*.md' -File -ErrorAction SilentlyContinue)
    $inboxShots = @(Get-ChildItem (Join-Path $Root 'inbox\shots') -Filter '*.png' -File -ErrorAction SilentlyContinue)
    $scans = @(Get-ChildItem (Join-Path $Root 'vault\scans') -Filter '*.md' -File -ErrorAction SilentlyContinue)
    $llm = $cfg.VisionLLM
    $sr = if ($cfg.Scroll -and $cfg.Scroll.NotchRange) { $cfg.Scroll.NotchRange } else { @(2, 4) }
    $pr = if ($cfg.Scroll -and $cfg.Scroll.NotchMs) { $cfg.Scroll.NotchMs } else { @(250, 750) }
    $rc = if ($cfg.Scroll -and $cfg.Scroll.ExtraReadChance) { $cfg.Scroll.ExtraReadChance } else { 10 }
    @{
        daemon = Get-PidStatus (Join-Path $logsDir 'daemon.pid')
        scroll = Get-PidStatus (Join-Path $logsDir 'scroll.pid')
        counts = @{ inboxText = $inboxText.Count; inboxShots = $inboxShots.Count; vaultScans = $scans.Count }
        ocr    = @{ mode = $(if ($cfg.Ocr -and $cfg.Ocr.Mode) { $cfg.Ocr.Mode } else { 'auto' }) }
        vision = @{ enabled = [bool]($llm -and $llm.Enabled) }
        region = Get-RegionObj
        rhythm = @{ notch = "$($sr[0])-$($sr[1])格"; pause = "$($pr[0])-$($pr[1])ms"; extraRead = "1/$rc" }
        port   = $chosenPort
    }
}

# ---------- 响应构造 ----------
function New-Resp { @{ Code = 200; Type = 'text/plain; charset=utf-8'; Bytes = $Ascii.GetBytes('') } }
function Set-Json([hashtable]$resp, $obj, [int]$code = 200) {
    $resp.Code = $code
    $resp.Type = 'application/json; charset=utf-8'
    $resp.Bytes = $Utf8.GetBytes(($obj | ConvertTo-Json -Depth 6 -Compress))
}
function Set-Bytes([hashtable]$resp, [byte[]]$bytes, [string]$ctype, [int]$code = 200) {
    $resp.Code = $code; $resp.Type = $ctype; $resp.Bytes = $bytes
}
function Set-Text([hashtable]$resp, [string]$text, [string]$ctype, [int]$code = 200) {
    Set-Bytes $resp $Utf8.GetBytes($text) $ctype $code
}

# ---------- API 路由 ----------
function Handle-Api($req, [hashtable]$resp) {
    $path = $req.Path
    $q = $req.Query
    switch -Regex ($path) {
        '^/api/status$' {
            Set-Json $resp (Get-StatusObj)
        }
        '^/api/region-select$' {
            Write-WebLog 'API: 框选采集区域'
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'bin\select-region.ps1'), '-Root', $Root
            ) | Out-Null
            Set-Json $resp @{ ok = $true; note = '请在屏幕上拖拽框选区域，ESC 取消' }
        }
        '^/api/region-clear$' {
            Write-WebLog 'API: 清除选区'
            Remove-Item (Join-Path $Root 'logs\region.json') -Force -ErrorAction SilentlyContinue
            Set-Json $resp @{ ok = $true; region = $null }
        }
        '^/api/region$' {
            Set-Json $resp @{ region = Get-RegionObj }
        }
        '^/api/capture$' {
            Write-WebLog 'API: 扫描屏幕'
            $out = Invoke-Tool 'capture-ocr.ps1' @('-Root', $Root)
            $last = ($out | Select-Object -Last 1)
            if ($last -match 'OK shot=(\S+) lines=(\d+) ocr=(\S+)') {
                Set-Json $resp @{ ok = $true; shot = $Matches[1]; lines = [int]$Matches[2]; ocr = $Matches[3] }
            } else {
                Set-Json $resp @{ ok = $false; error = ($out -join ' | ') } 500
            }
        }
        '^/api/scroll-start$' {
            Write-WebLog 'API: 滚动扫描开始'
            $pid = Start-Detached 'scan-daemon.ps1' @('-Root', $Root, '-ScrollOnce') (Join-Path $logsDir 'scroll.pid')
            Start-Sleep -Milliseconds 600
            Set-Json $resp @{ ok = $true; pid = $pid; note = '请确保 Discord 窗口已聚焦' }
        }
        '^/api/scroll-stop$' {
            Write-WebLog 'API: 滚动扫描中止'
            Set-Json $resp (Stop-Detached (Join-Path $logsDir 'scroll.pid'))
        }
        '^/api/daemon-start$' {
            Write-WebLog 'API: 启动守护进程'
            Start-Detached 'start-scanner.ps1' @('-Root', $Root) (Join-Path $logsDir 'web-daemon-starter.pid')
            Start-Sleep -Milliseconds 1200
            Set-Json $resp @{ ok = $true; status = Get-PidStatus (Join-Path $logsDir 'daemon.pid') }
        }
        '^/api/daemon-stop$' {
            Write-WebLog 'API: 停止守护进程'
            $out = Invoke-Tool 'start-scanner.ps1' @('-Root', $Root, '-Stop')
            Set-Json $resp @{ ok = $true; output = $out }
        }
        '^/api/process$' {
            Write-WebLog 'API: 处理 inbox（异步）'
            $stateFile = Join-Path $logsDir 'process.state'
            $busy = $false
            if (Test-Path $stateFile) {
                $stLine = (Get-Content $stateFile -Raw -ErrorAction SilentlyContinue)
                if ($stLine -match '^running\s+(.+)$') {
                    try {
                        if (((Get-Date) - [datetime]$Matches[1]).TotalMinutes -lt 15) { $busy = $true }
                    } catch { }
                }
            }
            if ($busy) { Set-Json $resp @{ started = $false; busy = $true } }
            else {
                Set-Content -Path $stateFile -Value ("running " + (Get-Date -Format s)) -Encoding UTF8
                Start-Detached 'process-inbox.ps1' @('-Root', $Root, '-StateFile', $stateFile, '-ReportFile', (Join-Path $logsDir 'process.report.txt')) (Join-Path $logsDir 'process.pid')
                Set-Json $resp @{ started = $true }
            }
        }
        '^/api/process-status$' {
            $stateFile = Join-Path $logsDir 'process.state'
            $st = if (Test-Path $stateFile) { (Get-Content $stateFile -Raw -ErrorAction SilentlyContinue).Trim() } else { 'idle' }
            $rpFile = Join-Path $logsDir 'process.report.txt'
            $rp = if (Test-Path $rpFile) { [IO.File]::ReadAllText($rpFile, $Utf8) } else { '' }
            Set-Json $resp @{ state = $st; report = $rp }
        }
        '^/api/search$' {
            $term = [uri]::UnescapeDataString([string]$q['q'])
            if ([string]::IsNullOrWhiteSpace($term)) { Set-Json $resp @{ error = '缺少 q' } 400; break }
            $files = @(Get-ChildItem (Join-Path $Root 'vault') -Recurse -Filter '*.md' -File -ErrorAction SilentlyContinue)
            $hits = @($files | Select-String -Pattern $term -SimpleMatch)
            $groups = @($hits | Group-Object Path | Sort-Object Count -Descending | Select-Object -First 10)
            $results = @($groups | ForEach-Object {
                @{
                    path  = $_.Name
                    count = $_.Count
                    hits  = @($_.Group | Select-Object -First 3 | ForEach-Object {
                        @{ line = $_.LineNumber; text = $_.Line.Trim() }
                    })
                }
            })
            Set-Json $resp @{ q = $term; total = $hits.Count; results = $results }
        }
        '^/api/ask$' {
            $term = [uri]::UnescapeDataString([string]$q['q'])
            if ([string]::IsNullOrWhiteSpace($term)) { Set-Json $resp @{ error = '缺少 q' } 400; break }
            Write-WebLog "API: 问一问 $term"
            $out = Invoke-Tool 'ask.ps1' @('-Root', $Root, '-Question', $term)
            Set-Json $resp @{ q = $term; text = ($out -join "`n") }
        }
        '^/api/list$' {
            $dir = [string]$q['dir']
            $map = @{
                'inbox-text'  = @('inbox\text', '*.md')
                'inbox-shots' = @('inbox\shots', '*.png')
                'vault'       = @('vault\scans', '*.md')
                'vault-shots' = @('vault\_shots', '*.png')
            }
            if (-not $map.ContainsKey($dir)) { Set-Json $resp @{ error = '未知 dir' } 400; break }
            $d = Resolve-InRoot (Join-Path $Root $map[$dir][0])
            $items = @()
            if ($d -and (Test-Path $d)) {
                $items = @(Get-ChildItem $d -Filter $map[$dir][1] -File -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending | Select-Object -First 200 | ForEach-Object {
                        @{ name = $_.Name; size = $_.Length; mtime = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
                    })
            }
            Set-Json $resp @{ dir = $dir; items = $items }
        }
        '^/api/file$' {
            $p = Resolve-InRoot ([uri]::UnescapeDataString([string]$q['p']))
            if (-not $p -or -not (Test-Path $p -PathType Leaf)) { Set-Json $resp @{ error = '路径无效' } 403; break }
            if ([IO.Path]::GetExtension($p) -ne '.md') { Set-Json $resp @{ error = '只允许 .md' } 400; break }
            $raw = [IO.File]::ReadAllText($p, $Utf8)
            # 关联截图：inbox md 的 png 字段 / scan md 的 ![截图](../_shots/x.png)
            $png = $null
            if ($raw -match '(?m)^png:\s*(.+)$') {
                $rel = $Matches[1].Trim()
                if ([IO.Path]::IsPathRooted($rel)) { if (Test-Path $rel) { $png = $rel } }
                else {
                    $cand = Resolve-InRoot (Join-Path (Join-Path $Root 'inbox') $rel)
                    if ($cand -and (Test-Path $cand)) { $png = $cand }
                }
            }
            if (-not $png -and $raw -match '!\[截图\]\(\.\./_shots/([^)]+)\)') {
                $cand = Resolve-InRoot (Join-Path (Join-Path $Root 'vault') ('_shots\' + $Matches[1].Trim()))
                if ($cand -and (Test-Path $cand)) { $png = $cand }
            }
            Set-Json $resp @{ path = $p; content = $raw; png = $png }
        }
        '^/api/log$' {
            $n = 60
            if ($q['n']) { $n = [Math]::Max(5, [Math]::Min(500, [int]$q['n'])) }
            $lines = @()
            foreach ($f in @('daemon.log', 'web.log')) {
                $fp = Join-Path $logsDir $f
                if (Test-Path $fp) {
                    $lines += @("===== $f =====")
                    $lines += @(Get-Content $fp -Tail $n -Encoding UTF8 -ErrorAction SilentlyContinue)
                }
            }
            Set-Json $resp @{ lines = $lines }
        }
        default { Set-Json $resp @{ error = "未知 API: $path" } 404 }
    }
}

# ---------- 静态文件 / 媒体 ----------
$staticTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
}
function Handle-Static($req, [hashtable]$resp) {
    $path = $req.Path
    $webDir = Join-Path $Root 'web'
    if ($path -eq '/') { $path = '/index.html' }
    $rel = $path.TrimStart('/')
    # 白名单：只允许纯文件名，杜绝目录穿越
    if ($rel -match '[\\/]') { Set-Text $resp 'not found' 'text/plain' 404; return }
    $full = Join-Path $webDir $rel
    if (-not (Test-Path $full -PathType Leaf)) { Set-Text $resp 'not found' 'text/plain' 404; return }
    $ext = [IO.Path]::GetExtension($full).ToLower()
    if (-not $staticTypes.ContainsKey($ext)) { Set-Text $resp 'not found' 'text/plain' 404; return }
    Set-Bytes $resp ([IO.File]::ReadAllBytes($full)) $staticTypes[$ext]
}
function Handle-Media($req, [hashtable]$resp) {
    $imgTypes = @{ '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.webp' = 'image/webp'; '.gif' = 'image/gif' }
    $p = Resolve-InRoot ([uri]::UnescapeDataString([string]$req.Query['p']))
    $ext = if ($p) { [IO.Path]::GetExtension($p).ToLower() } else { '' }
    if (-not $p -or -not (Test-Path $p -PathType Leaf) -or -not $imgTypes.ContainsKey($ext)) {
        Set-Text $resp 'not found' 'text/plain' 404
    } else {
        Set-Bytes $resp ([IO.File]::ReadAllBytes($p)) $imgTypes[$ext]
    }
}

# ---------- 请求准入（CSRF 防护） ----------
# Host 校验防 DNS rebinding，但防不了 CSRF：任意网页可向 127.0.0.1 发 POST 且 Host 合法。
# 浏览器跨站 POST 必带 Origin（非本源）→ 拒绝；Sec-Fetch-Site 亦校验。
# 本机 curl 等无 Origin 的客户端放行。GET 全部只读，无状态变更。
function Test-RequestAllowed($req) {
    if ($req.Method -ne 'POST') { return $true }
    $origin = [string]$req.Headers['origin']
    if ($origin) {
        if (($origin -ne "http://127.0.0.1:$chosenPort") -and ($origin -ne "http://localhost:$chosenPort")) { return $false }
    }
    $sfs = [string]$req.Headers['sec-fetch-site']
    if ($sfs -and ($sfs -ne 'same-origin') -and ($sfs -ne 'none')) { return $false }
    return $true
}

# ---------- TCP HTTP 子集 ----------
function Find-HeaderEnd([byte[]]$b) {
    for ($i = 0; $i -le $b.Length - 4; $i++) {
        if ($b[$i] -eq 13 -and $b[$i+1] -eq 10 -and $b[$i+2] -eq 13 -and $b[$i+3] -eq 10) { return $i }
    }
    return -1
}
function Read-Request($stream) {
    $ms = New-Object IO.MemoryStream
    $buf = New-Object byte[] 8192
    $headEnd = -1
    while ($true) {
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
        $headEnd = Find-HeaderEnd $ms.ToArray()
        if ($headEnd -ge 0) { break }
        if ($ms.Length -gt 8KB) { return @{ Error = 'headers-too-large' } }   # 头部上限 8KB
    }
    if ($headEnd -lt 0) { return $null }
    if ($headEnd -gt 8KB) { return @{ Error = 'headers-too-large' } }   # 已终止但头部超 8KB 同样拒绝
    $all = $ms.ToArray()
    $headStr = $Ascii.GetString($all, 0, $headEnd)
    $lines = @($headStr -split "`r`n")
    if ($lines.Count -lt 1) { return $null }
    $parts = $lines[0] -split ' '
    if ($parts.Count -lt 2) { return $null }
    $headers = @{}
    foreach ($h in ($lines | Select-Object -Skip 1)) {
        $idx = $h.IndexOf(':')
        if ($idx -gt 0) { $headers[$h.Substring(0, $idx).Trim().ToLower()] = $h.Substring($idx + 1).Trim() }
    }
    if ($headers.ContainsKey('transfer-encoding')) { return @{ Error = 'chunked-not-supported' } }
    # body（本控制台 POST 均无 body；按字节循环读满 Content-Length，拒绝非法值）
    $cl = 0
    if ($headers['content-length']) {
        if ($headers['content-length'] -notmatch '^\d{1,7}$') { return @{ Error = 'bad-content-length' } }
        $cl = [Math]::Min(1MB, [int]$headers['content-length'])
    }
    $bodyMs = New-Object IO.MemoryStream
    if ($all.Length -gt ($headEnd + 4)) { $bodyMs.Write($all, $headEnd + 4, $all.Length - $headEnd - 4) }
    while ($bodyMs.Length -lt $cl) {
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $bodyMs.Write($buf, 0, $n)
    }
    $bodyArr = $bodyMs.ToArray()
    if ($bodyArr.Length -gt $cl) { $bodyArr = $bodyArr[0..($cl - 1)] }
    # 解析 URL 与 query（单次解码 + 根目录白化 + 前缀校验，双重编码残留只会 404/403）
    $rawUrl = $parts[1]
    $path = $rawUrl; $query = @{}
    if ($rawUrl -match '^([^?]*)\?(.*)$') {
        $path = $Matches[1]
        foreach ($kv in ($Matches[2] -split '&')) {
            $i2 = $kv.IndexOf('=')
            if ($i2 -gt 0) { $query[$kv.Substring(0, $i2)] = $kv.Substring($i2 + 1) }
        }
    }
    @{ Method = $parts[0].ToUpper(); Path = $path; Query = $query; Headers = $headers; Body = $Utf8.GetString($bodyArr) }
}
$reasons = @{ 200 = 'OK'; 400 = 'Bad Request'; 403 = 'Forbidden'; 404 = 'Not Found'; 500 = 'Internal Server Error' }
function Write-Response($stream, [hashtable]$resp) {
    $head = "HTTP/1.1 $($resp.Code) $($reasons[$resp.Code])`r`n" +
            "Content-Type: $($resp.Type)`r`n" +
            "Content-Length: $($resp.Bytes.Length)`r`n" +
            "Cache-Control: no-cache`r`n" +
            "X-Content-Type-Options: nosniff`r`n" +
            "Content-Security-Policy: default-src 'self'; img-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'`r`n" +
            "Connection: close`r`n`r`n"
    $headBytes = $Ascii.GetBytes($head)
    $stream.Write($headBytes, 0, $headBytes.Length)
    $stream.Write($resp.Bytes, 0, $resp.Bytes.Length)
    $stream.Flush()
}

# ---------- 监听 ----------
$listener = $null
$chosenPort = $null
foreach ($tryPort in $Port..($Port + 10)) {
    try {
        $l2 = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), $tryPort
        $l2.Start()
        $listener = $l2; $chosenPort = $tryPort; break
    } catch { }
}
if (-not $chosenPort) { throw "端口 $Port~$($Port+10) 全部被占用，请在 config.psd1 Web.Port 换端口" }

Set-Content -Path (Join-Path $logsDir 'web.url') -Value "http://127.0.0.1:$chosenPort/"
Set-Content -Path (Join-Path $logsDir 'web.pid') -Value $PID
Write-WebLog "控制台后端启动: http://127.0.0.1:$chosenPort/  root=$Root"

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 5000
            $req = Read-Request $stream
            if ($req) {
                $resp = New-Resp
                if ($req.Error) {
                    # 畸形请求（头超限/chunked/非法 CL）：直接 400，Error 对象不含 Headers，勿再读其他字段
                    Set-Json $resp @{ error = $req.Error } 400
                } else {
                    $hostHdr = [string]$req.Headers['host']
                    if ($hostHdr -ne "127.0.0.1:$chosenPort" -and $hostHdr -ne "localhost:$chosenPort") {
                        Set-Json $resp @{ error = 'forbidden host' } 403
                    } elseif (-not (Test-RequestAllowed $req)) {
                        Write-WebLog "拒绝跨源 POST: Origin=$($req.Headers['origin'])"
                        Set-Json $resp @{ error = 'cross-origin request rejected' } 403
                    } else {
                        try {
                            if ($req.Path -like '/api/*') { Handle-Api $req $resp }
                            elseif ($req.Path -eq '/media') { Handle-Media $req $resp }
                            else { Handle-Static $req $resp }
                        } catch {
                            Write-WebLog "ERROR: $($_.Exception.Message)"
                            Set-Json $resp @{ error = $_.Exception.Message } 500
                        }
                    }
                }
                Write-Response $stream $resp
            }
        } catch {
            Write-WebLog "CONN: $($_.Exception.Message)"
        } finally {
            try { $client.Close() } catch { }
        }
    }
} finally {
    $listener.Stop()
    Remove-Item (Join-Path $logsDir 'web.pid') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $logsDir 'web.url') -Force -ErrorAction SilentlyContinue
    Write-WebLog '控制台后端退出'
}
