using System.IO.Compression;
using System.Net;
using System.Reflection;
using System.Text;
using System.Text.Json;
using Screen.App;
using Microsoft.AspNetCore.Http.Features;

var builder = WebApplication.CreateBuilder(new WebApplicationOptions { Args = args, ContentRootPath = AppContext.BaseDirectory });
var options = builder.Configuration.GetSection("Scanner").Get<ScannerOptions>() ?? new();
if (options.CaptureFocusDelayMs is < 0 or > 10_000)
    throw new ArgumentException("CaptureFocusDelayMs 必须在 0–10000 之间。");
if (options.ScrollStabilityWaitMs is < 200 or > 5000)
    throw new ArgumentException("ScrollStabilityWaitMs 必须在 200–5000 之间。");
// 版本号从构建元数据读取（csproj 的 <Version> + git 提交号），不再硬编码
var appVersion = typeof(ScannerOptions).Assembly
    .GetCustomAttribute<System.Reflection.AssemblyInformationalVersionAttribute>()?.InformationalVersion
    ?? typeof(ScannerOptions).Assembly.GetName().Version?.ToString()
    ?? "0.0.0";
var buildMetadataIndex = appVersion.IndexOf('+');
if (buildMetadataIndex > 0) appVersion = appVersion[..buildMetadataIndex];
var defaultDataDirectory = "data";
#if WINDOWS
var legacyDataDirectory = Path.Combine(builder.Environment.ContentRootPath, "data");
if (!File.Exists(Path.Combine(legacyDataDirectory, KnowledgeStore.DatabaseFileName)))
    defaultDataDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Screen", "data");
#endif
var dataDirectory = Path.GetFullPath(options.DataDirectory ?? defaultDataDirectory, builder.Environment.ContentRootPath);
builder.Services.AddSingleton(options);
builder.Services.AddSingleton(_ => new KnowledgeStore(dataDirectory));
builder.Services.Configure<FormOptions>(o => o.MultipartBodyLengthLimit = 30 * 1024 * 1024);
builder.WebHost.ConfigureKestrel(k => k.Limits.MaxRequestBodySize = 32 * 1024 * 1024);
builder.Services.AddHttpClient("ocr", client => client.Timeout = TimeSpan.FromSeconds(100));
#if WINDOWS
Screen.App.Windows.WindowsCapture.EnableDpiAwareness();
builder.Services.AddSingleton<ICaptureSource,Screen.App.Windows.WindowsCapture>();
builder.Services.AddSingleton<IRegionPicker,Screen.App.Windows.RegionPicker>();
if(options.OcrEngine is "auto" or "windows") builder.Services.AddSingleton<IOcrEngine,Screen.App.Windows.WindowsOcr>();
else if(options.OcrEngine=="umi") builder.Services.AddSingleton<IOcrEngine,UmiOcr>();
else builder.Services.AddSingleton<IOcrEngine,TesseractOcr>();
if(options.Hotkeys) builder.Services.AddHostedService<Screen.App.Windows.HotkeyService>();
#else
builder.Services.AddSingleton<ICaptureSource, UnavailableCapture>();
builder.Services.AddSingleton<IRegionPicker, UnavailableRegionPicker>();
if (options.OcrEngine == "windows") throw new InvalidOperationException("Windows OCR 需要使用 WindowsDesktop 构建并在 Windows 桌面运行。");
if (options.OcrEngine == "umi") builder.Services.AddSingleton<IOcrEngine, UmiOcr>();
else builder.Services.AddSingleton<IOcrEngine, TesseractOcr>();
#endif
builder.Services.AddSingleton<ScrollCoordinator>();
builder.Services.AddHostedService<OcrWorker>();
var app = builder.Build();
var store = app.Services.GetRequiredService<KnowledgeStore>();
store.Initialize();
app.Logger.LogInformation("Knowledge data directory: {DataDirectory}", store.DirectoryPath);
app.Use(async (context, next) =>
{
    var request = context.Request;
    var host = request.Host.Host;
    context.Response.Headers["X-Content-Type-Options"] = "nosniff";
    context.Response.Headers["Content-Security-Policy"] =
        "default-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'";

    if ((!host.Equals("localhost", StringComparison.OrdinalIgnoreCase) && host is not ("127.0.0.1" or "[::1]")) ||
        (context.Connection.RemoteIpAddress is { } remote && !IPAddress.IsLoopback(remote)))
    {
        context.Response.StatusCode = StatusCodes.Status400BadRequest;
        await context.Response.WriteAsJsonAsync(new { error = "控制台仅接受本机访问。" });
        return;
    }

    if (request.Method is "POST" or "PUT" or "PATCH" or "DELETE")
    {
        var expectedOrigin = $"{request.Scheme}://{request.Host}";
        if ((request.Headers.TryGetValue("Origin", out var origin) &&
                !string.Equals(origin.ToString(), expectedOrigin, StringComparison.OrdinalIgnoreCase)) ||
            (request.Headers.TryGetValue("Sec-Fetch-Site", out var site) &&
                site.ToString() is not ("same-origin" or "none")))
        {
            context.Response.StatusCode = StatusCodes.Status403Forbidden;
            await context.Response.WriteAsJsonAsync(new { error = "已拒绝跨源操作。" });
            return;
        }
    }
    await next(context);
});
app.Use(async (context, next) =>
{
    try { await next(context); }
    catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or KeyNotFoundException or NotSupportedException)
    {
        if (context.Response.HasStarted) throw;
        context.Response.StatusCode = ex is KeyNotFoundException ? 404 : ex is NotSupportedException ? 409 : 400;
        await context.Response.WriteAsJsonAsync(new { error = ex.Message });
    }
});
app.UseDefaultFiles(); app.UseStaticFiles();
app.MapGet("/api/status", (ICaptureSource capture, IOcrEngine ocr, ScrollCoordinator scroll) => new
{
    counts = store.Stats(),
    canCapture = capture.Available,
    captureNote = capture.Available ? "Windows 桌面采集已启用" : capture.UnavailableReason,
    ocrEngine = ocr.Name,
    captureFocusDelayMs = options.CaptureFocusDelayMs,
    region = store.GetRegion(),
    scroll = scroll.State,
    version = appVersion
});
app.MapGet("/api/runs", () => store.Runs());
app.MapPost("/api/runs", (CreateRunRequest request) => Results.Created("/api/runs", store.CreateRun(request.Title)));
app.MapGet("/api/runs/{id}", (string id) =>
{
    var run = store.Run(id) ?? throw new KeyNotFoundException("采集批次不存在。");
    var frames = store.Frames(id); return new RunDetail(run, frames, Documents.Merge(frames, store.Notes(id)));
});
app.MapPost("/api/runs/{id}/close", (string id, ScrollCoordinator scroll) =>
{
    if (store.Run(id) is null) throw new KeyNotFoundException("采集批次不存在。");
    if (scroll.Active && scroll.State.RunId == id) throw new InvalidOperationException("请先停止滚动采集，再结束批次。");
    store.FinishRun(id); return Results.Ok(new { state = "closed" });
});
app.MapPost("/api/runs/{id}/frames", async (string id, HttpRequest request) =>
{
    var form = await request.ReadFormAsync();
    if (form.Files.Count != 1) throw new ArgumentException("每次请选择一张图片。");
    await using var memory = new MemoryStream(); await form.Files[0].CopyToAsync(memory);
    var frame = store.AddFrame(id, memory.ToArray(), "import", text: form.ContainsKey("text") ? form["text"].ToString() : null);
    return Results.Created($"/api/frames/{frame.Id}", frame);
});
app.MapGet("/api/frames/{id}", (string id) => store.FrameById(id) ?? throw new KeyNotFoundException("截图不存在。"));
app.MapGet("/api/images/{id}", (string id) =>
{
    var frame = store.FrameById(id) ?? throw new KeyNotFoundException("截图不存在。");
    return Results.File(store.ImagePath(frame.Sha256), frame.ImageType, enableRangeProcessing: true);
});
app.MapPost("/api/frames/{id}/retry", (string id) => Results.Accepted("/api/jobs", new { jobId = store.Retry(id) }));
app.MapPatch("/api/frames/{id}/text", (string id, TextCorrection text) =>
{
    store.CorrectText(id, text.Text); return Results.Ok(store.FrameById(id));
});
app.MapGet("/api/frames/{id}/revisions", (string id) => store.Revisions(id));
app.MapGet("/api/jobs", () => store.Jobs());
app.MapGet("/api/search", (string q) => store.Search(q));
app.MapPut("/api/region", (RegionSelection selection) =>
{
    if (selection.Region is { } r && (r.Width < 40 || r.Height < 40)) throw new ArgumentException("采集区域至少为 40 × 40 像素。");
    store.SetRegion(selection.Region); return Results.Ok(new { region = selection.Region });
});
app.MapPost("/api/region/pick", async (IRegionPicker picker) =>
{
    var region = await picker.PickAsync(); if (region is not null) store.SetRegion(region);
    return Results.Ok(new { region, cancelled = region is null });
});
app.MapPost("/api/capture", async (CaptureRequest request, ScrollCoordinator scroll, ICaptureSource capture, CancellationToken token) =>
{
    if (!capture.Available) throw new NotSupportedException(capture.UnavailableReason);
    await Task.Delay(options.CaptureFocusDelayMs, token);
    token.ThrowIfCancellationRequested();
    return Results.Ok(scroll.Single(request.RunId, request.Region));
});
app.MapPost("/api/scroll/start", (ScrollRequest request, ScrollCoordinator scroll) => Results.Accepted("/api/status", scroll.Start(request)));
app.MapPost("/api/scroll/stop", async (ScrollCoordinator scroll) => { await scroll.StopAsync(); return Results.Ok(scroll.State); });
app.MapGet("/api/runs/{id}/markdown", (string id) =>
{
    var run = store.Run(id) ?? throw new KeyNotFoundException("采集批次不存在。"); var frames = store.Frames(id);
    return Results.Text(Documents.Markdown(run, frames, Documents.Merge(frames, store.Notes(id))), "text/markdown; charset=utf-8");
});
app.MapGet("/api/runs/{id}/export", (string id, HttpContext context) =>
{
    var run = store.Run(id) ?? throw new KeyNotFoundException("采集批次不存在。"); var frames = store.Frames(id);
    var directory = Path.Combine(store.DirectoryPath, "exports"); Directory.CreateDirectory(directory);
    var path = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".zip");
    using (var archive = ZipFile.Open(path, ZipArchiveMode.Create))
    {
        using (var writer = new StreamWriter(archive.CreateEntry("scan.md").Open(), new UTF8Encoding(false)))
            writer.Write(Documents.Markdown(run, frames, Documents.Merge(frames, store.Notes(id))));
        using (var writer = new StreamWriter(archive.CreateEntry("manifest.json").Open(), new UTF8Encoding(false)))
            writer.Write(JsonSerializer.Serialize(new { run, frames, notes = store.Notes(id), revisions = frames.ToDictionary(f => f.Id, f => store.Revisions(f.Id)) }, new JsonSerializerOptions { WriteIndented = true }));
        foreach (var f in frames) archive.CreateEntryFromFile(store.ImagePath(f.Sha256), $"images/{f.Id}{(f.ImageType == "image/png" ? ".png" : ".jpg")}");
    }
    context.Response.OnCompleted(() => { File.Delete(path); return Task.CompletedTask; });
    return Results.File(path, "application/zip", $"screen-{run.Id}.zip");
});
#if WINDOWS
if (options.OpenBrowser)
{
    app.Lifetime.ApplicationStarted.Register(() =>
    {
        var url = app.Urls.FirstOrDefault();
        if (url is null) return;
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception ex) { app.Logger.LogWarning(ex, "Could not open the browser; use {Url}", url); }
    });
}
#endif
await app.RunAsync();

public partial class Program;
