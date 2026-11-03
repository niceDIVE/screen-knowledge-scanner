namespace Screen.App;

public sealed class ScannerOptions
{
    public string? DataDirectory { get; set; }
    public string OcrEngine { get; set; } = "auto";
    public string TesseractExecutable { get; set; } = "tesseract";
    public string TesseractLanguages { get; set; } = "eng";
    public string UmiUrl { get; set; } = "http://127.0.0.1:1224/api/ocr";
    public bool Hotkeys { get; set; } = true;
    public bool OpenBrowser { get; set; } = true;
    public int CaptureFocusDelayMs { get; set; } = 3000;
    public int ScrollStabilityWaitMs { get; set; } = 2000;
    public HotkeyOptions HotkeyKeys { get; set; } = new();
}

/// <summary>四组全局热键，格式 "Ctrl+Alt+S"；支持 Ctrl/Alt/Shift/Win + A-Z/0-9/F1-F12。</summary>
public sealed class HotkeyOptions
{
    public string Capture { get; set; } = "Ctrl+Alt+S";
    public string Scroll { get; set; } = "Ctrl+Alt+W";
    public string Stop { get; set; } = "Ctrl+Alt+Q";
    public string Region { get; set; } = "Ctrl+Alt+R";
}

/// <summary>前台阅读窗口或鼠标位置发生变化：属于可恢复的中止，不是执行故障。</summary>
public sealed class TargetInactiveException(string message) : InvalidOperationException(message);

public record Region(int X, int Y, int Width, int Height);
public record ScanRun(string Id, string Title, string CreatedAt, string State, int FrameCount);
public record Frame(string Id, string RunId, int Sequence, string CapturedAt, string Source,
    string Sha256, string ImageType, int Width, int Height, Region? Region,
    string OcrState, string OcrText, string OcrEngine, string? Error);
public record Job(string Id, string FrameId, string State, int Attempts, string? Error,
    string CreatedAt, string UpdatedAt);
public record SearchHit(string FrameId, string RunId, string Title, int Sequence, string Text, double Score);
public record RunDetail(ScanRun Run, IReadOnlyList<Frame> Frames, MergeResult Document);
public record MergeResult(string Text, IReadOnlyList<string> Warnings, int RemovedLines);
public record CaptureResult(byte[] Bytes, Region Region);
public record OcrResult(string Text, string Engine);
public record GrayFrame(int Width, int Height, byte[] Pixels);
public record MotionEstimate(bool Reliable, int OffsetPixels, double Confidence, double Overlap, double Difference);
public record ScrollRequest(string RunId, Region? Region, int Steps = 12, int DelayMs = 700, int WheelNotches = 1);
public record ScrollState(string State, string? RunId, int Captured, string? Note);
public record CreateRunRequest(string Title);
public record TextCorrection(string Text);
public record CaptureRequest(string RunId, Region? Region);
public record RegionSelection(Region? Region);
public interface IRegionPicker { Task<Region?> PickAsync(); }
public sealed class UnavailableRegionPicker : IRegionPicker
{
    public Task<Region?> PickAsync() => throw new NotSupportedException("框选区域需要 Windows 桌面版。");
}

public interface ICaptureSource
{
    bool Available { get; }
    string UnavailableReason { get; }
    CaptureResult Capture(Region? region);
    GrayFrame Gray(byte[] image);
    /// <summary>原分辨率灰度（仅抽样采样以控制开销）：用于零位移判定的二次确认。</summary>
    GrayFrame GrayFull(byte[] image);
    bool IsTargetActive();
    void BeginSession(Region? region);
    void Scroll(int notches);
}

public sealed class UnavailableCapture : ICaptureSource
{
    public bool Available => false;
    public string UnavailableReason => "屏幕采集需要 Windows 桌面版；当前仍可导入图片、识别和检索。";
    public CaptureResult Capture(Region? region) => throw new NotSupportedException(UnavailableReason);
    public GrayFrame Gray(byte[] image) => throw new NotSupportedException(UnavailableReason);
    public GrayFrame GrayFull(byte[] image) => throw new NotSupportedException(UnavailableReason);
    public bool IsTargetActive() => false;
    public void BeginSession(Region? region) => throw new NotSupportedException(UnavailableReason);
    public void Scroll(int notches) => throw new NotSupportedException(UnavailableReason);
}
