using System.IO.Compression;
using System.Net;
using System.Net.Http.Json;
using Screen.App;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace Screen.App.Tests;

public sealed class ApiTests : IAsyncLifetime
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "screen-api-" + Guid.NewGuid().ToString("N"));
    private WebApplicationFactory<Program> factory = null!;
    private HttpClient client = null!;
    private readonly TestOcr ocr = new();
    public Task InitializeAsync()
    {
        factory = new WebApplicationFactory<Program>().WithWebHostBuilder(builder => builder.ConfigureTestServices(services =>
        {
            services.RemoveAll<KnowledgeStore>(); services.AddSingleton(new KnowledgeStore(directory));
            services.RemoveAll<IOcrEngine>(); services.AddSingleton<IOcrEngine>(ocr);
        }));
        client = factory.CreateClient(); return Task.CompletedTask;
    }
    private async Task<ScanRun> NewRun() => (await (await client.PostAsJsonAsync("/api/runs", new { title = "API 世界书验证" })).Content.ReadFromJsonAsync<ScanRun>())!;
    private async Task<Frame> Upload(string runId, string? text = null)
    {
        using var form = new MultipartFormDataContent(); form.Add(new ByteArrayContent(KnowledgeTests.Png), "image", "shot.png");
        if (text is not null) form.Add(new StringContent(text), "text");
        var response = await client.PostAsync($"/api/runs/{runId}/frames", form); response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<Frame>())!;
    }
    private async Task<Frame> WaitFrame(string id, string expected)
    {
        for (var i = 0; i < 100; i++)
        {
            var f = (await client.GetFromJsonAsync<Frame>($"/api/frames/{id}"))!;
            if (f.OcrState == expected) return f; await Task.Delay(40);
        }
        throw new Exception($"Frame did not reach {expected}");
    }
    [Fact]
    public async Task ImportOcrSearchCorrectionAndExportFormACompleteWorkflow()
    {
        var run = await NewRun(); var frame = await Upload(run.Id); await WaitFrame(frame.Id, "succeeded");
        var hits = await client.GetFromJsonAsync<SearchHit[]>("/api/search?q=" + Uri.EscapeDataString("世界书 插入点"));
        Assert.Single(hits!); Assert.Equal(frame.Id, hits![0].FrameId);
        Assert.Equal(KnowledgeTests.Png, await client.GetByteArrayAsync($"/api/images/{frame.Id}"));
        var response = await client.PatchAsJsonAsync($"/api/frames/{frame.Id}/text", new { text = "手动校对后的独立关键词和配置说明" }); response.EnsureSuccessStatusCode();
        Assert.Empty((await client.GetFromJsonAsync<SearchHit[]>("/api/search?q=" + Uri.EscapeDataString("插入点")))!);
        Assert.Single((await client.GetFromJsonAsync<SearchHit[]>("/api/search?q=" + Uri.EscapeDataString("独立关键词")))!);
        using var zip = new ZipArchive(new MemoryStream(await client.GetByteArrayAsync($"/api/runs/{run.Id}/export")));
        Assert.NotNull(zip.GetEntry($"images/{frame.Id}.png")); Assert.NotNull(zip.GetEntry("manifest.json"));
        using var reader = new StreamReader(zip.GetEntry("scan.md")!.Open()); Assert.Contains("手动校对", await reader.ReadToEndAsync());
    }
    [Fact]
    public async Task FailedJobsAreVisibleAndRetryWorksThroughTheApi()
    {
        ocr.FailNext = true; var frame = await Upload((await NewRun()).Id); var failed = await WaitFrame(frame.Id, "failed");
        Assert.Contains("临时识别失败", failed.Error);
        var jobs = await client.GetFromJsonAsync<Job[]>("/api/jobs"); Assert.Contains(jobs!, j => j.FrameId == frame.Id && j.State == "failed");
        (await client.PostAsync($"/api/frames/{frame.Id}/retry", null)).EnsureSuccessStatusCode();
        var recovered = await WaitFrame(frame.Id, "succeeded"); Assert.Null(recovered.Error); Assert.Contains("世界书", recovered.OcrText);
    }
    [Fact]
    public async Task PlatformLimitIsExplicitAndUploadedEvidenceDoesNotNeedDesktopApis()
    {
        var run = await NewRun(); var frame = await Upload(run.Id, "图片自带的人工文字");
        Assert.Equal("succeeded", frame.OcrState);
#if !WINDOWS
        var response = await client.PostAsJsonAsync("/api/capture", new { runId = run.Id, region = (object?)null });
        Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
#endif
        (await client.PostAsync($"/api/runs/{run.Id}/close", null)).EnsureSuccessStatusCode();
        using var form = new MultipartFormDataContent(); form.Add(new ByteArrayContent(KnowledgeTests.Png), "image", "x.png");
        Assert.Equal(HttpStatusCode.BadRequest, (await client.PostAsync($"/api/runs/{run.Id}/frames", form)).StatusCode);
    }
    [Fact]
    public async Task LocalConsoleRejectsRebindingAndCrossOriginActions()
    {
        using var rebinding = new HttpRequestMessage(HttpMethod.Get, "/api/runs");
        rebinding.Headers.Host = "attacker.example";
        Assert.Equal(HttpStatusCode.BadRequest, (await client.SendAsync(rebinding)).StatusCode);

        var run = await NewRun();
        foreach (var path in new[] { "/api/region/pick", "/api/scroll/stop", $"/api/runs/{run.Id}/frames" })
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, path);
            request.Headers.Add("Origin", "https://attacker.example");
            request.Headers.Add("Sec-Fetch-Site", "cross-site");
            if (path.EndsWith("/frames"))
            {
                var form = new MultipartFormDataContent();
                form.Add(new ByteArrayContent(KnowledgeTests.Png), "image", "shot.png");
                request.Content = form;
            }
            Assert.Equal(HttpStatusCode.Forbidden, (await client.SendAsync(request)).StatusCode);
        }
        using var sameSite = new HttpRequestMessage(HttpMethod.Post, "/api/scroll/stop");
        sameSite.Headers.Add("Sec-Fetch-Site", "same-site");
        Assert.Equal(HttpStatusCode.Forbidden, (await client.SendAsync(sameSite)).StatusCode);

        using var foreignOrigin = new HttpRequestMessage(HttpMethod.Post, "/api/scroll/stop");
        foreignOrigin.Headers.Add("Origin", "http://localhost:9999");
        Assert.Equal(HttpStatusCode.Forbidden, (await client.SendAsync(foreignOrigin)).StatusCode);
        Assert.Empty((await client.GetFromJsonAsync<RunDetail>($"/api/runs/{run.Id}"))!.Frames);

        using var sameOrigin = new HttpRequestMessage(HttpMethod.Post, "/api/scroll/stop");
        sameOrigin.Headers.Add("Origin", client.BaseAddress!.GetLeftPart(UriPartial.Authority));
        sameOrigin.Headers.Add("Sec-Fetch-Site", "same-origin");
        Assert.Equal(HttpStatusCode.OK, (await client.SendAsync(sameOrigin)).StatusCode);
        using var page = await client.GetAsync("/");
        Assert.Equal(HttpStatusCode.OK, page.StatusCode);
        Assert.Equal("nosniff", Assert.Single(page.Headers.GetValues("X-Content-Type-Options")));
        Assert.Contains("frame-ancestors 'none'", Assert.Single(page.Headers.GetValues("Content-Security-Policy")));
    }
    public async Task DisposeAsync()
    {
        client.Dispose(); await factory.DisposeAsync(); Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools(); Directory.Delete(directory, true);
    }
    private sealed class TestOcr : IOcrEngine
    {
        public string Name => "test OCR"; public bool FailNext;
        public Task<OcrResult> RecognizeAsync(string path, CancellationToken token)
        {
            if (FailNext) { FailNext = false; throw new InvalidOperationException("临时识别失败"); }
            Assert.True(File.Exists(path)); return Task.FromResult(new OcrResult("世界书插入点配置与测试正文", "test OCR"));
        }
    }
}
