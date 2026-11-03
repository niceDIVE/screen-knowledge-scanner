using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Screen.App;

public static class Documents
{
    public static MergeResult Merge(IEnumerable<Frame> frames, IEnumerable<string>? notes = null)
    {
        var output = new List<string>(); var warnings = new List<string>(notes ?? []); var removed = 0;
        Frame? previous = null;
        foreach (var frame in frames.OrderBy(f => f.Sequence))
        {
            if (frame.OcrState != "succeeded") warnings.Add($"第 {frame.Sequence} 帧识别状态：{frame.OcrState}，原图已保留。{frame.Error}");
            var lines = frame.OcrText.Replace("\r", "").Trim('\n').Split('\n');
            if (string.IsNullOrWhiteSpace(frame.OcrText)) { previous = null; continue; }
            if (previous?.Sha256 == frame.Sha256 && previous.OcrText == frame.OcrText)
            { removed += lines.Length; previous = frame; continue; }
            var overlap = previous is null ? 0 : Overlap(previous.OcrText.Replace("\r", "").Trim('\n').Split('\n'), lines);
            if (previous is not null && overlap == 0)
            {
                warnings.Add($"第 {frame.Sequence} 帧未确认连续文字重叠，已完整保留，请对照截图核对衔接。");
                output.Add(""); output.Add($"> 第 {frame.Sequence} 帧 · 衔接待核对"); output.Add("");
            }
            output.AddRange(lines.Skip(overlap)); removed += overlap;
            if (Regex.IsMatch(frame.OcrText, "[\\{\\}]|```|\"[^\"]+\"\\s*[:：]"))
                warnings.Add($"第 {frame.Sequence} 帧包含代码或 JSON，请对照截图校对。");
            previous = frame;
        }
        return new(string.Join('\n', output), warnings.Distinct().ToArray(), removed);
    }

    public static int Overlap(string[] previous, string[] next)
    {
        // Only a contiguous suffix/prefix can establish reading order. A shared sentence cannot.
        for (var length = Math.Min(previous.Length, next.Length); length >= 3; length--)
        {
            var suffix = previous[^length..];
            if (suffix.Sum(s => s.Length) < 40) continue;
            if (suffix.Select(Normalize).SequenceEqual(next.Take(length).Select(Normalize))) return length;
        }
        return 0;
    }
    private static string Normalize(string line) => line.Normalize(NormalizationForm.FormKC);

    public static string Markdown(ScanRun run, IReadOnlyList<Frame> frames, MergeResult merged)
    {
        var b = new StringBuilder();
        b.AppendLine("---").AppendLine($"title: {JsonSerializer.Serialize(run.Title)}")
            .AppendLine($"run: {run.Id}").AppendLine($"created: {run.CreatedAt}").AppendLine("---")
            .AppendLine().AppendLine($"# {run.Title}").AppendLine();
        if (merged.Warnings.Count > 0)
        {
            b.AppendLine("## 需要核对").AppendLine();
            foreach (var warning in merged.Warnings) b.AppendLine($"- {warning}");
            b.AppendLine();
        }
        b.AppendLine("## 整理正文").AppendLine().AppendLine(merged.Text).AppendLine();
        b.AppendLine("## 原始证据").AppendLine();
        foreach (var f in frames)
        {
            b.AppendLine($"### 第 {f.Sequence} 帧 · {f.CapturedAt}").AppendLine()
                .AppendLine($"![第 {f.Sequence} 帧](images/{f.Id}{(f.ImageType == "image/png" ? ".png" : ".jpg")})").AppendLine()
                .AppendLine($"识别：{f.OcrEngine} / {f.OcrState} · SHA-256：{f.Sha256}").AppendLine()
                .AppendLine(f.OcrText).AppendLine();
        }
        return b.ToString();
    }
}
