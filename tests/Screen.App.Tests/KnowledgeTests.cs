using Screen.App;
using Microsoft.Data.Sqlite;
using Xunit;

[assembly: CollectionBehavior(DisableTestParallelization = true)]
namespace Screen.App.Tests;

public sealed class KnowledgeTests : IDisposable
{
    internal static readonly byte[] Png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=");
    private readonly string directory = Path.Combine(Path.GetTempPath(), "screen-test-" + Guid.NewGuid().ToString("N"));
    private readonly KnowledgeStore store;
    public KnowledgeTests() { store = new(directory); store.Initialize(); }
    [Fact]
    public void OriginalBytesSurviveDuplicateObservations()
    {
        var run = store.CreateRun("知识整理");
        var first = store.AddFrame(run.Id, Png, "import"); var second = store.AddFrame(run.Id, Png, "screen");
        Assert.NotEqual(first.Id, second.Id); Assert.Equal(first.Sha256, second.Sha256);
        Assert.Equal(new[] { 1, 2 }, store.Frames(run.Id).Select(f => f.Sequence));
        Assert.Equal(Png, File.ReadAllBytes(store.ImagePath(first.Sha256)));
        Assert.Single(Directory.GetFiles(Path.Combine(directory, "images")));
        Assert.Equal(2, store.Jobs().Count);
    }
    [Fact]
    public void InterruptedOcrIsRecoveredAndFailureCanBeRetried()
    {
        var frame = store.AddFrame(store.CreateRun("恢复").Id, Png, "import");
        var job = store.ClaimJob()!; Assert.Equal("processing", store.FrameById(frame.Id)!.OcrState);
        store.Initialize(); Assert.Equal("pending", store.FrameById(frame.Id)!.OcrState);
        job = store.ClaimJob()!; store.Fail(job, "测试识别失败");
        Assert.Equal("failed", store.FrameById(frame.Id)!.OcrState); Assert.Equal("测试识别失败", store.Jobs().Single().Error);
        var retry = store.Retry(frame.Id); Assert.NotEqual(job.Id, retry);
        Assert.Equal(retry, store.Retry(frame.Id));
        var next = store.ClaimJob()!; store.Complete(next, new("世界书配置完成", "test-engine"));
        Assert.Equal("succeeded", store.FrameById(frame.Id)!.OcrState); Assert.Null(store.FrameById(frame.Id)!.Error);
        Assert.Single(store.Search("世界书"));
    }
    [Fact]
    public void CorrectionsKeepHistoryAndReplaceSearchIndex()
    {
        var frame = store.AddFrame(store.CreateRun("校对").Id, Png, "import", text: "旧版错误内容");
        store.CorrectText(frame.Id, "新版世界书 插入点配置 API settings");
        Assert.Empty(store.Search("旧版")); Assert.Single(store.Search("世界书 插入点"));
        Assert.Single(store.Search("API settings")); Assert.Single(store.Search("书"));
        Assert.Equal(2, store.Revisions(frame.Id).Length);
        Assert.Equal(Png, File.ReadAllBytes(store.ImagePath(frame.Sha256)));
    }
    [Fact]
    public void ConcurrentImportsHaveUniqueMonotonicSequenceNumbers()
    {
        var run = store.CreateRun("并发导入");
        Parallel.For(0, 12, i => store.AddFrame(run.Id, Png, "import", text: $"独立正文内容 {i}"));
        Assert.Equal(Enumerable.Range(1, 12), store.Frames(run.Id).Select(f => f.Sequence));
    }
    [Fact]
    public void ClosedRunRejectsNewFramesButRemainsReadable()
    {
        var run = store.CreateRun("归档"); store.AddFrame(run.Id, Png, "import", text: "已保存的文字"); store.FinishRun(run.Id);
        Assert.Throws<InvalidOperationException>(() => store.AddFrame(run.Id, Png, "import"));
        Assert.Single(store.Frames(run.Id)); Assert.Single(store.Search("保存"));
    }
    [Fact]
    public void SharedSentenceDoesNotDiscardUnrelatedNewText()
    {
        var run = store.CreateRun("重复句子");
        store.AddFrame(run.Id, Png, "import", text: "上一屏独有的讨论内容甲\n上一屏独有的讨论内容乙\n建议把世界书放在角色定义之后");
        store.AddFrame(run.Id, Png, "import", text: "下一段新增的关键配置说明\n建议把世界书放在角色定义之后\n下一段新增的最终结论");
        var merged = Documents.Merge(store.Frames(run.Id));
        Assert.Contains("下一段新增的关键配置说明", merged.Text); Assert.Equal(0, merged.RemovedLines); Assert.NotEmpty(merged.Warnings);
    }
    [Fact]
    public void OnlyContinuousSuffixPrefixIsRemoved()
    {
        var common = new[] { "第一条足够长的共同正文用于验证连续重叠", "第二条足够长的共同正文用于验证连续重叠", "第三条足够长的共同正文用于验证连续重叠" };
        Assert.Equal(3, Documents.Overlap(new[] { "更早的消息" }.Concat(common).ToArray(), common.Concat(new[] { "新增内容" }).ToArray()));
        Assert.Equal(0, Documents.Overlap(common, new[] { "新内容" }.Concat(common).ToArray()));
    }
    [Fact]
    public void MotionUsesActualScrollDirectionAndRejectsAmbiguousImages()
    {
        const int width = 80, height = 100, offset = 17; var random = new Random(42); var before = new byte[width * height]; random.NextBytes(before);
        var after = new byte[before.Length]; random.NextBytes(after); Array.Copy(before, offset * width, after, 0, (height - offset) * width);
        var motion = MotionEstimator.Estimate(new(width, height, before), new(width, height, after));
        Assert.True(motion.Reliable); Assert.Equal(offset, motion.OffsetPixels); Assert.Equal(.83, motion.Overlap, 2);
        var changed = new byte[before.Length]; random.NextBytes(changed);
        Assert.False(MotionEstimator.Estimate(new(width, height, before), new(width, height, changed)).Reliable);
    }
    [Fact]
    public void IdenticalImageIsStationary()
    {
        var pixels = new byte[80 * 100]; new Random(1).NextBytes(pixels);
        var estimate = MotionEstimator.Estimate(new(80, 100, pixels), new(80, 100, pixels));
        Assert.True(estimate.Reliable); Assert.Equal(0, estimate.OffsetPixels);
    }
    public void Dispose() { SqliteConnection.ClearAllPools(); Directory.Delete(directory, true); }
}
