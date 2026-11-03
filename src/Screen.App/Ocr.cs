using System.Diagnostics;
using System.Net.Http.Json;
using System.Text;
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
    /// <summary>Umi 支持的排版解析方案（见 Umi 文档 http/api_ocr.md 的 tbpu.parser）。</summary>
    private static readonly string[] Parsers =
    [
        "multi_para", "multi_line", "multi_none",
        "single_para", "single_line", "single_none", "single_code", "none"
    ];

    /// <summary>
    /// 排版解析方案。默认 single_para：单栏/表格/代码按「逐行」顺序取文本。
    /// 双栏正文必须切到 multi_para，否则会横穿两栏（实测 CER 77.3% → 0.8%）。
    /// </summary>
    public string Parser => Parsers.Contains(options.UmiParser) ? options.UmiParser : "single_para";

    public string Name => $"Umi-OCR · {Parser}";

    public async Task<OcrResult> RecognizeAsync(string path, CancellationToken token)
    {
        var body = new Dictionary<string, object>
        {
            ["base64"] = Convert.ToBase64String(await File.ReadAllBytesAsync(path, token)),
            ["options"] = new Dictionary<string, object>
            {
                // 交给 Umi 侧决定阅读顺序；键名带点，不能用匿名对象
                ["tbpu.parser"] = Parser,
                ["data.format"] = "dict"
            }
        };
        using var response = await clients.CreateClient("ocr").PostAsJsonAsync(options.UmiUrl, body, token);
        response.EnsureSuccessStatusCode();
        using var data = JsonDocument.Parse(await response.Content.ReadAsStringAsync(token));
        var code = data.RootElement.GetProperty("code").GetInt32();
        if (code == 101) return new("", Name);
        if (code != 100) throw new InvalidOperationException($"Umi-OCR 返回错误 {code}：{data.RootElement.GetProperty("data")}");
        var blocks = new List<UmiBlock>();
        foreach (var block in data.RootElement.GetProperty("data").EnumerateArray())
        {
            var text = block.TryGetProperty("text", out var t) ? t.GetString() : null;
            var end = block.TryGetProperty("end", out var e) ? e.GetString() : null;
            var top = double.MaxValue;
            var bottom = double.MinValue;
            if (block.TryGetProperty("box", out var box) && box.ValueKind == JsonValueKind.Array)
            {
                foreach (var point in box.EnumerateArray())
                {
                    if (point.ValueKind != JsonValueKind.Array || point.GetArrayLength() < 2) continue;
                    var y = point[1].GetDouble();
                    if (y < top) top = y;
                    if (y > bottom) bottom = y;
                }
            }
            var hasBox = bottom > double.MinValue;
            blocks.Add(new UmiBlock(text, end,
                hasBox ? (top + bottom) / 2 : double.NaN,
                hasBox ? bottom - top : 0));
        }
        return new(Compose(blocks), Name);
    }

    /// <summary>
    /// 把 Umi 返回的文本块拼回文本。两级规则：
    /// 1) 优先用 Umi 给的 <c>end</c> 结束符（它已经按排版解析方案算过，双栏时靠它换行）；
    /// 2) <c>end</c> 只是空格或空串时，再用矩形的 y 中心差判断是否真的换了行
    ///    —— 表格的单元格之间 end 常是空格，但纵向明显错行，必须补换行，否则整张表挤成一行。
    /// 纯静态函数，便于跨平台单测。
    /// </summary>
    public static string Compose(IEnumerable<UmiBlock> blocks)
    {
        var list = blocks.Where(b => !string.IsNullOrEmpty(b.Text)).ToList();
        if (list.Count == 0) return string.Empty;

        var heights = list.Where(b => b.Height > 0).Select(b => b.Height).OrderBy(h => h).ToList();
        var rowTolerance = heights.Count > 0 ? Math.Max(4, heights[heights.Count / 2] * 0.6) : 0;

        var builder = new StringBuilder();
        for (var i = 0; i < list.Count; i++)
        {
            var current = list[i];
            builder.Append(current.Text);
            // end 缺失 = 没给结构信息，按换行处理
            if (current.End is null)
            {
                builder.Append('\n');
                continue;
            }
            if (current.End.Contains('\n'))
            {
                builder.Append(current.End);
                continue;
            }
            // end 是空串或空格：用几何判断是否真的换行（表格单元格之间就是这种情况）
            var nextIsNewRow = i + 1 < list.Count
                && rowTolerance > 0
                && !double.IsNaN(current.CenterY)
                && !double.IsNaN(list[i + 1].CenterY)
                && Math.Abs(list[i + 1].CenterY - current.CenterY) > rowTolerance;
            builder.Append(nextIsNewRow ? "\n" : current.End);
        }
        return builder.ToString().TrimEnd();
    }

    /// <summary>只有 text/end、没有几何信息的兼容重载（供单测与旧调用点使用）。</summary>
    public static string Compose(IEnumerable<(string? Text, string? End)> blocks) =>
        Compose(blocks.Select(b => new UmiBlock(b.Text, b.End, double.NaN, 0)));
}

/// <summary>Umi 返回的单个文本块：文本、行尾结束符，以及用于补行分隔的几何信息。</summary>
public readonly record struct UmiBlock(string? Text, string? End, double CenterY, double Height);

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
