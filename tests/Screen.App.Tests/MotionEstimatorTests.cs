using Screen.App;
using Xunit;

namespace Screen.App.Tests;

public sealed class MotionEstimatorTests
{
    private static GrayFrame Frame(int width, int height, Func<int, int, byte> pixel)
    {
        var bytes = new byte[width * height];
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
                bytes[y * width + x] = pixel(x, y);
        return new GrayFrame(width, height, bytes);
    }

    [Fact]
    public void Identical_frames_have_zero_difference()
    {
        var a = Frame(64, 64, (x, y) => (byte)((x * 7 + y * 13) % 256));
        var b = Frame(64, 64, (x, y) => (byte)((x * 7 + y * 13) % 256));
        Assert.Equal(0, MotionEstimator.Difference(a, b));
    }

    [Fact]
    public void Different_sizes_return_max_difference()
    {
        var a = Frame(64, 64, (_, _) => 0);
        var b = Frame(32, 32, (_, _) => 0);
        Assert.Equal(1, MotionEstimator.Difference(a, b));
    }

    [Fact]
    public void Unique_shift_is_estimated_within_one_row()
    {
        const int width = 100, height = 200, shift = 12;
        var random = new Random(7);
        var pixels = new byte[width * height];
        random.NextBytes(pixels);
        var previous = new GrayFrame(width, height, pixels);

        var shifted = new byte[width * height];
        Array.Copy(pixels, shift * width, shifted, 0, (height - shift) * width);
        var next = new GrayFrame(width, height, shifted);

        var estimate = MotionEstimator.Estimate(previous, next);
        Assert.True(estimate.Reliable, estimate.ToString());
        Assert.InRange(estimate.OffsetPixels, shift - 1, shift + 1);
    }

    [Fact]
    public void Periodic_content_keeps_zero_offset_instead_of_false_motion()
    {
        // 10 行一周期；整周期滚动后两帧完全相同 —— 已知不可判定，必须保留"未移动"而非编造位移
        var a = Frame(80, 200, (_, y) => (byte)(y % 10 < 4 ? 20 : 230));
        var b = Frame(80, 200, (_, y) => (byte)((y + 10) % 10 < 4 ? 20 : 230));
        Assert.Equal(0, MotionEstimator.Difference(a, b));
        var estimate = MotionEstimator.Estimate(a, b);
        Assert.Equal(0, estimate.OffsetPixels);
    }

    [Fact]
    public void Dynamic_noise_without_shift_is_not_reported_as_motion()
    {
        var random = new Random(11);
        var a = Frame(80, 120, (_, _) => (byte)random.Next(0, 60));
        var b = Frame(80, 120, (_, _) => (byte)random.Next(200, 256));
        var estimate = MotionEstimator.Estimate(a, b);
        // 两帧内容完全不同且无位移：应判不可靠而不是给出某个"位移"
        Assert.False(estimate.Reliable);
    }
}
