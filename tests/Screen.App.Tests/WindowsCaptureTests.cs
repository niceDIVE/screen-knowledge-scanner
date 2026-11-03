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
        Assert.Equal(160, gray.Width);
        Assert.Equal(100, gray.Height);
        Assert.Equal(gray.Width * gray.Height, gray.Pixels.Length);
        Assert.Equal(0, gray.Pixels[50 * gray.Width + 40]);
        Assert.Equal(255, gray.Pixels[50 * gray.Width + 120]);
    }
}
#endif
