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
        using var stream=new MemoryStream(image); using var source=new Bitmap(stream);
        var scale=Math.Min(160.0/source.Width,320.0/source.Height);
        var w=Math.Clamp((int)(source.Width*scale),12,160); var h=Math.Clamp((int)(source.Height*scale),12,320);
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
        if(target==0||!Native.GetWindowRect(target,out targetBounds)) throw new InvalidOperationException("未找到当前阅读窗口。");
        sessionRegion=CaptureBounds(region);
        if(!IsTargetActive()) throw new InvalidOperationException("请将鼠标放在前台阅读窗口和采集区域内，再开始采集。");
    }
    public bool IsTargetActive()
    {
        return Native.GetForegroundWindow()==target && Native.GetWindowRect(target,out var bounds) && bounds.Equals(targetBounds)
            && Native.GetCursorPos(out var point) && sessionRegion.Contains(point.X,point.Y)
            && Rectangle.FromLTRB(bounds.Left,bounds.Top,bounds.Right,bounds.Bottom).Contains(point.X,point.Y);
    }
    public void Scroll(int notches)
    {
        if(!IsTargetActive()) throw new InvalidOperationException("阅读窗口或鼠标位置已变化。");
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
