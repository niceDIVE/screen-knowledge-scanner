using System.Diagnostics;
using System.Net.Http.Json;
using System.Text.Json;

namespace Screen.App;

public interface IOcrEngine
{
    string Name { get; }
    Task<OcrResult> RecognizeAsync(string imagePath, CancellationToken cancellationToken);
}

public sealed class TesseractOcr(ScannerOptions options) : IOcrEngine
{
    public string Name => $"Tesseract · {options.TesseractLanguages}";
    public async Task<OcrResult> RecognizeAsync(string path, CancellationToken token)
    {
        var start = new ProcessStartInfo(options.TesseractExecutable)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        foreach (var arg in new[] { path, "stdout", "-l", options.TesseractLanguages, "--psm", "6" }) start.ArgumentList.Add(arg);
        using var proc = new Process { StartInfo = start };
        try { proc.Start(); }
        catch (System.ComponentModel.Win32Exception ex) { throw new InvalidOperationException("未找到 Tesseract。请安装后重试，或配置 Umi-OCR；Windows 桌面版可使用系统 OCR。", ex); }
        try
        {
            var output = proc.StandardOutput.ReadToEndAsync(token);
            var error = proc.StandardError.ReadToEndAsync(token);
            await proc.WaitForExitAsync(token);
            var text = await output; var stderr = await error;
            if (proc.ExitCode != 0) throw new InvalidOperationException($"Tesseract 识别失败：{stderr.Trim()}");
            return new(text.Trim(), Name);
        }
        finally { if (!proc.HasExited) { proc.Kill(true); await proc.WaitForExitAsync(CancellationToken.None); } }
    }
}

public sealed class UmiOcr(ScannerOptions options, IHttpClientFactory clients) : IOcrEngine
{
    public string Name => "Umi-OCR";
    public async Task<OcrResult> RecognizeAsync(string path, CancellationToken token)
    {
        var body = new { base64 = Convert.ToBase64String(await File.ReadAllBytesAsync(path, token)), options = new { } };
        using var response = await clients.CreateClient("ocr").PostAsJsonAsync(options.UmiUrl, body, token);
        response.EnsureSuccessStatusCode();
        using var data = JsonDocument.Parse(await response.Content.ReadAsStringAsync(token));
        var code = data.RootElement.GetProperty("code").GetInt32();
        if (code == 101) return new("", Name);
        if (code != 100) throw new InvalidOperationException($"Umi-OCR 返回错误 {code}：{data.RootElement.GetProperty("data")}");
        var lines = data.RootElement.GetProperty("data").EnumerateArray().Select(x => x.GetProperty("text").GetString());
        return new(string.Join('\n', lines), Name);
    }
}

public sealed class OcrWorker(KnowledgeStore store, IOcrEngine engine, ILogger<OcrWorker> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            var job = store.ClaimJob();
            if (job is null) { await Task.Delay(400, stoppingToken); continue; }
            try
            {
                var frame = store.FrameById(job.FrameId)!;
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
                timeout.CancelAfter(TimeSpan.FromMinutes(2));
                var result = await engine.RecognizeAsync(store.ImagePath(frame.Sha256), timeout.Token);
                store.Complete(job, result);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                // Leave 'processing' persisted; Initialize requeues it at the next startup.
                return;
            }
            catch (Exception ex)
            {
                var message = ex is OperationCanceledException ? "识别超过两分钟，原图已保留，可以重试。" : ex.Message;
                store.Fail(job, message); log.LogWarning(ex, "OCR failed for frame {Frame}", job.FrameId);
            }
        }
    }
}
