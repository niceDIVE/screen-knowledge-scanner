using System.Diagnostics;

namespace Screen.App;

public sealed class ScrollCoordinator(ICaptureSource capture, KnowledgeStore store, IHostApplicationLifetime lifetime,
    ILogger<ScrollCoordinator> log, ScannerOptions options)
{
    private readonly object gate = new();
    private CancellationTokenSource? cancellation;
    private Task? running;
    private ScrollState state = new("idle", null, 0, null);
    public ScrollState State { get { lock (gate) return state; } }
    public bool Active => State.State is "running" or "waiting" or "cancelling";
    private void Update(string value, string? note = null, int? count = null)
    { lock (gate) state = state with { State = value, Note = note, Captured = count ?? state.Captured }; }

    public ScrollState Start(ScrollRequest request, bool waitForFocus = true)
    {
        if (!capture.Available) throw new NotSupportedException(capture.UnavailableReason);
        if (request.Steps is < 1 or > 30 || request.DelayMs is < 300 or > 5000 || request.WheelNotches is < 1 or > 3)
            throw new ArgumentException("滚动参数范围：1–30 步、300–5000ms、每步 1–3 格。");
        if (store.Run(request.RunId) is not { State: "open" }) throw new ArgumentException("请选择未结束的采集批次。");
        lock (gate)
        {
            if (running is { IsCompleted: false }) throw new InvalidOperationException("已有滚动采集正在进行。");
            cancellation?.Dispose();
            cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.ApplicationStopping);
            cancellation.CancelAfter(TimeSpan.FromMinutes(3));
            state = new(waitForFocus ? "waiting" : "running", request.RunId, 0, waitForFocus ? "4 秒后开始，请切换到阅读窗口，将鼠标放在采集区域内。" : "正在保存首帧");
            var token = cancellation.Token;
            running = Task.Run(() => CaptureAsync(request, waitForFocus, token), CancellationToken.None);
            return state;
        }
    }
    public async Task StopAsync()
    {
        Task? task;
        lock (gate)
        {
            if (running is not { IsCompleted: false }) return;
            state = state with { State = "cancelling", Note = "正在停止，已采集的原图会保留。" };
            cancellation!.Cancel(); task = running;
        }
        await task;
    }
    public Frame Single(string runId, Region? region)
    {
        lock (gate)
        {
            if (running is { IsCompleted: false }) throw new InvalidOperationException("请先停止滚动采集。");
            var selectedRegion = region ?? store.GetRegion();
            capture.BeginSession(selectedRegion);
            var shot = CaptureTarget(selectedRegion);
            return store.AddFrame(runId, shot.Bytes, "screen", shot.Region);
        }
    }
    private CaptureResult CaptureTarget(Region? region)
    {
        const string changed = "阅读窗口或鼠标位置发生变化，已停止采集。";
        if (!capture.IsTargetActive()) throw new InvalidOperationException(changed);
        var shot = capture.Capture(region);
        if (!capture.IsTargetActive()) throw new InvalidOperationException(changed);
        return shot;
    }
    private async Task<CaptureResult> Stable(Region? region, CancellationToken token)
    {
        var last = CaptureTarget(region);
        var elapsed = Stopwatch.StartNew();
        var remaining = (long)options.ScrollStabilityWaitMs;
        while (remaining > 0)
        {
            await Task.Delay((int)Math.Min(200, remaining), token);
            var next = CaptureTarget(region);
            var motion = MotionEstimator.Estimate(capture.Gray(last.Bytes), capture.Gray(next.Bytes));
            if (motion.Difference < 0.004) return next;
            last = next;
            remaining = options.ScrollStabilityWaitMs - elapsed.ElapsedMilliseconds;
        }
        store.AddNote(state.RunId!, "部分画面在等待期间仍有变化，请对照原图检查动态内容。");
        return last;
    }
    private async Task CaptureAsync(ScrollRequest request, bool waitForFocus, CancellationToken token)
    {
        try
        {
            if (waitForFocus) await Task.Delay(4000, token);
            var region = request.Region ?? store.GetRegion();
            capture.BeginSession(region);
            Update("running", "正在保存起始画面");
            var first = await Stable(region, token);
            store.AddFrame(request.RunId, first.Bytes, "scroll", first.Region);
            Update("running", "首帧已保存", 1);
            var previous = capture.Gray(first.Bytes); var noMovement = 0;
            for (var step = 0; step < request.Steps; step++)
            {
                await Task.Delay(request.DelayMs, token);
                if (!capture.IsTargetActive()) throw new InvalidOperationException("阅读窗口或鼠标位置发生变化，已停止采集。");
                capture.Scroll(request.WheelNotches);
                var shot = await Stable(region, token);
                store.AddFrame(request.RunId, shot.Bytes, "scroll", shot.Region);
                Update("running", $"已保存第 {step + 2} 帧", step + 2);
                var gray = capture.Gray(shot.Bytes); var motion = MotionEstimator.Estimate(previous, gray);
                if (!motion.Reliable || motion.Overlap < 0.4)
                {
                    var note = $"第 {step + 2} 帧画面重叠无法确认，已保留原图并停止自动滚动，请核对后继续。";
                    store.AddNote(request.RunId, note); Update("needs-review", note); return;
                }
                var physicalOffset = (int)Math.Round(motion.OffsetPixels * shot.Region.Height / (double)gray.Height);
                Update("running", $"已保存第 {step + 2} 帧 · 位移约 {physicalOffset}px · 重叠 {motion.Overlap:P0}");
                noMovement = motion.OffsetPixels == 0 ? noMovement + 1 : 0;
                if (noMovement >= 2) { Update("completed", "连续两步画面未移动，本段采集结束。"); return; }
                previous = gray;
            }
            Update("completed", "已达到本段步数，原图已保存，OCR 在后台继续。");
        }
        catch (OperationCanceledException) { Update("stopped", "采集已停止，原图与识别任务已保留。"); }
        catch (Exception ex)
        {
            log.LogWarning(ex, "Scroll capture stopped");
            store.AddNote(request.RunId, ex.Message); Update("failed", ex.Message);
        }
    }
}
