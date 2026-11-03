using Screen.App;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace Screen.App.Tests;

public sealed class ScrollTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task InitialEvidenceIsSavedBeforeAnyScroll(bool slowInitialPaint)
    {
        var path = Path.Combine(Path.GetTempPath(), "screen-scroll-" + Guid.NewGuid().ToString("N"));
        var store = new KnowledgeStore(path); store.Initialize(); var run = store.CreateRun("滚动顺序");
        var source = new FakeCapture { SlowInitialPaint = slowInitialPaint };
        var coordinator = new ScrollCoordinator(source, store, new Lifetime(), NullLogger<ScrollCoordinator>.Instance, new());
        coordinator.Start(new(run.Id, null, Steps: 1, DelayMs: 300), waitForFocus: false);
        for (var i = 0; i < 100 && coordinator.Active; i++) await Task.Delay(50);
        Assert.Equal("completed", coordinator.State.State);
        var frames = store.Frames(run.Id); Assert.Equal(2, frames.Count);
        Assert.Equal(0, File.ReadAllBytes(store.ImagePath(frames[0].Sha256))[^1]);
        Assert.Equal(10, File.ReadAllBytes(store.ImagePath(frames[1].Sha256))[^1]);
        Assert.All(frames, f => Assert.Equal("pending", f.OcrState));
        Assert.Empty(store.Notes(run.Id));
        Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools(); Directory.Delete(path, true);
    }
    [Fact]
    public void SingleCaptureDiscardsEvidenceWhenTheTargetChanges()
    {
        var path = Path.Combine(Path.GetTempPath(), "screen-single-" + Guid.NewGuid().ToString("N"));
        var store = new KnowledgeStore(path);
        store.Initialize();
        try
        {
            var run = store.CreateRun("单帧目标校验");
            var region = new Region(10, 10, 80, 100);
            store.SetRegion(region);
            var source = new FakeCapture { ChangeTargetDuringCapture = true };
            var coordinator = new ScrollCoordinator(source, store, new Lifetime(), NullLogger<ScrollCoordinator>.Instance, new());
            // 目标失活按新语义抛 TargetInactiveException（不再与执行异常混用 InvalidOperationException）
            Assert.Throws<TargetInactiveException>(() => coordinator.Single(run.Id, null));
            Assert.Equal(region, source.SessionRegion);
            Assert.Empty(store.Frames(run.Id));
            Assert.Empty(Directory.GetFiles(Path.Combine(path, "images")));
            source.ChangeTargetDuringCapture = false;
            Assert.Equal(1, coordinator.Single(run.Id, null).Sequence);
        }
        finally
        {
            Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
            Directory.Delete(path, true);
        }
    }
    private sealed class Lifetime : IHostApplicationLifetime
    {
        public CancellationToken ApplicationStarted => CancellationToken.None;
        public CancellationToken ApplicationStopping => CancellationToken.None;
        public CancellationToken ApplicationStopped => CancellationToken.None;
        public void StopApplication() { }
    }
    private sealed class FakeCapture : ICaptureSource
    {
        private int position; private readonly byte[] world = new byte[80 * 150];
        private int captures;
        private bool active = true;
        public bool SlowInitialPaint { get; init; }
        public bool ChangeTargetDuringCapture { get; set; }
        public Region? SessionRegion { get; private set; }
        public FakeCapture() { new Random(8).NextBytes(world); }
        public bool Available => true; public string UnavailableReason => "";
        public CaptureResult Capture(Region? region)
        {
            if (ChangeTargetDuringCapture) active = false;
            var animationOffset = SlowInitialPaint && captures < 6 && captures % 2 == 0 ? 10 : 0;
            captures++;
            return new(KnowledgeTests.Png.Concat(new[] { (byte)animationOffset, (byte)position }).ToArray(),
                region ?? new(0, 0, 80, 100));
        }
        public GrayFrame Gray(byte[] image)
        {
            var start = (image[^1] + image[^2]) * 80;
            return new(80, 100, world[start..(start + 80 * 100)]);
        }
        public GrayFrame GrayFull(byte[] image)
        {
            // 替身里原分辨率与缩略图等价：零位移复核路径可被覆盖，但不引入不同数据
            var start = (image[^1] + image[^2]) * 80;
            return new(80, 100, world[start..(start + 80 * 100)]);
        }
        public bool IsTargetActive() => active;
        public void BeginSession(Region? region) { SessionRegion = region; active = true; }
        public void Scroll(int notches) => position += 10;
    }
}
