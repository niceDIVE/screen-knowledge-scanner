namespace Screen.App;

public static class MotionEstimator
{
    public static MotionEstimate Estimate(GrayFrame previous, GrayFrame next)
    {
        if (previous.Width != next.Width || previous.Height != next.Height) return new(false, 0, 0, 0, 1);
        var w = previous.Width; var h = previous.Height;
        var top = Math.Max(1, h / 10); var bottom = h - top;
        double Error(int shift)
        {
            long error = 0; var count = 0;
            for (var y = top; y < bottom - shift; y += 2)
                for (var x = 4; x < w - 4; x += 2)
                {
                    // Downward scrolling moves old content UP: new[y] corresponds to old[y+shift].
                    error += Math.Abs(previous.Pixels[(y + shift) * w + x] - next.Pixels[y * w + x]); count++;
                }
            return count == 0 ? 1 : error / (255.0 * count);
        }
        var stationary = Error(0);
        if (stationary < 0.002) return new(true, 0, 1, 1, stationary);
        var maxShift = (int)(h * 0.65); var scores = new List<(int Shift, double Error)>();
        for (var dy = 1; dy <= maxShift; dy++) scores.Add((dy, Error(dy)));
        var best = scores.OrderBy(s => s.Error).First();
        var alternate = scores.Where(s => Math.Abs(s.Shift - best.Shift) > 2).Select(s => s.Error).DefaultIfEmpty(1).Min();
        var confidence = Math.Clamp(1 - best.Error / 0.12, 0, 1);
        var reliable = best.Error < 0.08 && stationary - best.Error > 0.01 && alternate - best.Error > 0.005;
        return new(reliable, best.Shift, confidence, 1 - best.Shift / (double)h, stationary);
    }
}
