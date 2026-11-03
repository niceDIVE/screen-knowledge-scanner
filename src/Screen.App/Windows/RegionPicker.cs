using System.Diagnostics;
using System.Text;

namespace Screen.App.Windows;

/// <summary>
/// 框选区域：在独立 PowerShell 进程中显示全屏覆盖层。
/// 进程内（ASP.NET Core 宿主）直接创建 WinForms 全屏窗口在本机实测不渲染，
/// 独立进程方式与 V1 实现一致且已实机验证可用。
/// </summary>
public sealed class RegionPicker(ILogger<RegionPicker> log) : IRegionPicker
{
    private readonly SemaphoreSlim gate = new(1, 1);

    public async Task<Region?> PickAsync()
    {
        await gate.WaitAsync();
        try
        {
            var scriptPath = Path.Combine(Path.GetTempPath(), "screen-region-" + Guid.NewGuid().ToString("N") + ".ps1");
            await File.WriteAllTextAsync(scriptPath, Script, new UTF8Encoding(true));
            try
            {
                var psi = new ProcessStartInfo("powershell.exe")
                {
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8
                };
                foreach (var arg in new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPath })
                    psi.ArgumentList.Add(arg);

                using var process = Process.Start(psi) ?? throw new InvalidOperationException("无法启动框选进程。");
                var stdout = process.StandardOutput.ReadToEndAsync();
                var stderr = process.StandardError.ReadToEndAsync();
                await process.WaitForExitAsync();
                var output = (await stdout).Trim();
                var error = (await stderr).Trim();

                if (process.ExitCode != 0)
                {
                    log.LogWarning("框选进程退出码 {Code}：{Error}", process.ExitCode, error);
                    return null;
                }
                if (output.Length == 0) { log.LogInformation("框选已取消"); return null; }
                var parts = output.Split(',');
                if (parts.Length != 4 ||
                    !int.TryParse(parts[0], out var x) || !int.TryParse(parts[1], out var y) ||
                    !int.TryParse(parts[2], out var w) || !int.TryParse(parts[3], out var h) ||
                    w < 40 || h < 40)
                {
                    log.LogWarning("框选输出无法解析：{Output}", output);
                    return null;
                }
                log.LogInformation("框选完成：{Region}", output);
                return new Region(x, y, w, h);
            }
            finally
            {
                try { File.Delete(scriptPath); } catch { }
            }
        }
        finally { gate.Release(); }
    }

    private const string Script = """
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        Add-Type -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;
        public static class U32Picker { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
        "@
        [void][U32Picker]::SetProcessDPIAware()
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $form = New-Object System.Windows.Forms.Form
        $form.FormBorderStyle = 'None'
        $form.StartPosition = 'Manual'
        $form.Location = New-Object System.Drawing.Point($vs.X, $vs.Y)
        $form.Size = New-Object System.Drawing.Size($vs.Width, $vs.Height)
        $form.BackColor = [System.Drawing.Color]::Black
        $form.Opacity = 0.55
        $form.TopMost = $true
        $form.ShowInTaskbar = $false
        $form.KeyPreview = $true
        $form.Cursor = [System.Windows.Forms.Cursors]::Cross
        $script:start = $null
        $script:rect = [System.Drawing.Rectangle]::Empty
        $script:done = $false
        $form.Add_Shown({ $form.Activate(); $form.Focus() })
        $form.Add_MouseDown({ param($s,$e) if ($e.Button -eq 'Left') { $script:start = $e.Location; $script:rect = [System.Drawing.Rectangle]::Empty; $s.Invalidate() } })
        $form.Add_MouseMove({ param($s,$e) if ($script:start) { $px=$script:start.X; $py=$script:start.Y; $x=[Math]::Min($px,$e.X); $y=[Math]::Min($py,$e.Y); $w=[Math]::Abs($e.X-$px); $h=[Math]::Abs($e.Y-$py); $script:rect = New-Object System.Drawing.Rectangle $x,$y,$w,$h; $s.Invalidate() } })
        $form.Add_MouseUp({ param($s,$e) if ($e.Button -eq 'Left') { if ($script:rect.Width -ge 40 -and $script:rect.Height -ge 40) { $script:done = $true }; $s.Close() } })
        $form.Add_Paint({ param($s,$e) $font = New-Object System.Drawing.Font('Microsoft YaHei',13,[System.Drawing.FontStyle]::Bold); $e.Graphics.DrawString('拖拽框选阅读区域 · 松开保存 · Esc 取消', $font, [System.Drawing.Brushes]::White, 28, 28); if ($script:rect.Width -gt 0) { $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(93,224,176)),3; $e.Graphics.DrawRectangle($pen, $script:rect); $pen.Dispose() } })
        $form.Add_KeyDown({ param($s,$e) if ($e.KeyCode -eq 'Escape') { $s.Close() } })
        [void]$form.ShowDialog()
        if ($script:done -and $script:rect.Width -ge 40 -and $script:rect.Height -ge 40) {
            Write-Output ("{0},{1},{2},{3}" -f ($vs.X + $script:rect.X), ($vs.Y + $script:rect.Y), $script:rect.Width, $script:rect.Height)
        }
        """;
}
