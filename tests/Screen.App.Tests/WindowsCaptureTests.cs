#if WINDOWS
using System.Drawing;
using System.Drawing.Imaging;
using Screen.App.Windows;
using Xunit;

namespace Screen.App.Tests;

public sealed class WindowsCaptureTests
{
    [Fact]
    public void GrayDecodesPngAndDownscalesWithoutChangingPixelOrder()
    {
        using var bitmap = new Bitmap(320, 200);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.Clear(Color.Black);
            graphics.FillRectangle(Brushes.White, 160, 0, 160, 200);
        }
        using var png = new MemoryStream();
        bitmap.Save(png, ImageFormat.Png);

        var gray = new WindowsCapture().Gray(png.ToArray());
        Assert.Equal(320, gray.Width);
        Assert.Equal(200, gray.Height);
        Assert.Equal(gray.Width * gray.Height, gray.Pixels.Length);
        // 320×200 源图缩略图保持 1:1：左半黑（0..159 列）、右半白（160..319 列）
        Assert.Equal(0, gray.Pixels[50 * gray.Width + 40]);
        Assert.Equal(255, gray.Pixels[50 * gray.Width + 240]);
    }

    [Fact]
    public void GrayFullKeepsSourceResolution()
    {
        using var bitmap = new Bitmap(640, 480);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.Clear(Color.Black);
            graphics.FillRectangle(Brushes.White, 320, 0, 320, 480);
        }
        using var png = new MemoryStream();
        bitmap.Save(png, ImageFormat.Png);

        var full = new WindowsCapture().GrayFull(png.ToArray());
        Assert.Equal(640, full.Width);
        Assert.Equal(480, full.Height);
        Assert.Equal(full.Width * full.Height, full.Pixels.Length);
        Assert.Equal(0, full.Pixels[100 * full.Width + 100]);
        Assert.Equal(255, full.Pixels[100 * full.Width + 500]);
    }
}
#endif
