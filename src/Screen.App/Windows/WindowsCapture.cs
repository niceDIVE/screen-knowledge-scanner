using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace Screen.App.Windows;

public sealed class WindowsCapture : ICaptureSource
{
    private nint target;
    private Native.Rect targetBounds;
    private Rectangle sessionRegion;
    public bool Available => Environment.UserInteractive;
    public string UnavailableReason => "需要登录到交互式 Windows 桌面后运行。";
    public static void EnableDpiAwareness() => Native.SetProcessDpiAwarenessContext(new nint(-4));
    public CaptureResult Capture(Region? region)
    {
        if(!Available) throw new NotSupportedException(UnavailableReason);
        var bounds=CaptureBounds(region);
        using var bitmap=new Bitmap(bounds.Width,bounds.Height,PixelFormat.Format24bppRgb);
        using(var g=Graphics.FromImage(bitmap)) g.CopyFromScreen(bounds.Location,Point.Empty,bounds.Size);
        using var memory=new MemoryStream(); bitmap.Save(memory,ImageFormat.Png);
        return new(memory.ToArray(),new(bounds.X,bounds.Y,bounds.Width,bounds.Height));
    }
    private static Rectangle CaptureBounds(Region? region)
    {
        var screen=System.Windows.Forms.SystemInformation.VirtualScreen;
        var bounds=region is null ? screen : Rectangle.Intersect(screen,new(region.X,region.Y,region.Width,region.Height));
        if(bounds.Width<40||bounds.Height<40) throw new ArgumentException("采集区域不在当前屏幕内。");
        return bounds;
    }
    public GrayFrame Gray(byte[] image)
    {
        // 320 宽缩略图：160 宽在 900px 窗口下每行仅约 3.5px，密集小字/周期性内容的位移估计区分度不足
        using var stream=new MemoryStream(image); using var source=new Bitmap(stream);
        var scale=Math.Min(320.0/source.Width,640.0/source.Height);
        var w=Math.Clamp((int)(source.Width*scale),12,320); var h=Math.Clamp((int)(source.Height*scale),12,640);
        return Downscale(source,w,h);
    }
    /// <summary>原分辨率灰度（逐 2 像素抽样，控制开销）：仅在缩略图判定零位移时用于二次确认。</summary>
    public GrayFrame GrayFull(byte[] image)
    {
        using var stream=new MemoryStream(image); using var source=new Bitmap(stream);
        return Downscale(source,source.Width,source.Height);
    }
    private static GrayFrame Downscale(Bitmap source,int w,int h)
    {
        using var small=new Bitmap(w,h,PixelFormat.Format24bppRgb);
        using(var graphics=Graphics.FromImage(small)) graphics.DrawImage(source,0,0,w,h);
        var data=small.LockBits(new(0,0,w,h),ImageLockMode.ReadOnly,PixelFormat.Format24bppRgb);
        try
        {
            var raw=new byte[data.Stride*h]; Marshal.Copy(data.Scan0,raw,0,raw.Length); var pixels=new byte[w*h];
            for(var y=0;y<h;y++) for(var x=0;x<w;x++)
            {
                var i=y*data.Stride+x*3;
                pixels[y*w+x]=(byte)((raw[i+2]*299+raw[i+1]*587+raw[i]*114)/1000);
            }
            return new(w,h,pixels);
        }
        finally { small.UnlockBits(data); }
    }
    public void BeginSession(Region? region)
    {
        target=Native.GetForegroundWindow();
        if(target==0||!Native.GetWindowRect(target,out targetBounds)) throw new TargetInactiveException("未找到当前阅读窗口。");
        sessionRegion=CaptureBounds(region);
        if(!IsTargetActive()) throw new TargetInactiveException("请将鼠标放在前台阅读窗口和采集区域内，再开始采集。");
    }
    public bool IsTargetActive()
    {
        return Native.GetForegroundWindow()==target && Native.GetWindowRect(target,out var bounds) && bounds.Equals(targetBounds)
            && Native.GetCursorPos(out var point) && sessionRegion.Contains(point.X,point.Y)
            && Rectangle.FromLTRB(bounds.Left,bounds.Top,bounds.Right,bounds.Bottom).Contains(point.X,point.Y);
    }
    public void Scroll(int notches)
    {
        if(!IsTargetActive()) throw new TargetInactiveException("阅读窗口或鼠标位置已变化，已停止采集。");
        Native.mouse_event(0x0800,0,0,-120*notches,0);
    }
    private static class Native
    {
        [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
        [StructLayout(LayoutKind.Sequential)] public struct CursorPoint { public int X,Y; }
        [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(nint context);
        [DllImport("user32.dll")] public static extern nint GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool GetWindowRect(nint hwnd,out Rect rect);
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out CursorPoint point);
        [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,int data,nuint extra);
    }
}
