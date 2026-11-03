namespace Screen.App;

/// <summary>热键组合键解析：放在跨平台目录，便于在非 Windows 构建下做单元测试。</summary>
public static class HotkeyParser
{
    public const uint ModAlt = 0x1;
    public const uint ModControl = 0x2;
    public const uint ModShift = 0x4;
    public const uint ModWin = 0x8;
    public const uint ModNoRepeat = 0x4000;

    /// <summary>解析 "Ctrl+Alt+S" → modifiers + virtual-key。失败时 problem 给出可读原因。</summary>
    public static bool TryParse(string? combo, out uint modifiers, out uint key, out string problem)
    {
        modifiers = ModNoRepeat;
        key = 0;
        problem = "";
        if (string.IsNullOrWhiteSpace(combo)) { problem = "组合键为空"; return false; }
        foreach (var rawPart in combo.Split('+'))
        {
            var part = rawPart.Trim();
            if (part.Length == 0) { problem = $"组合键 \"{combo}\" 含空段"; return false; }
            switch (part.ToLowerInvariant())
            {
                case "ctrl":
                case "control": modifiers |= ModControl; continue;
                case "alt": modifiers |= ModAlt; continue;
                case "shift": modifiers |= ModShift; continue;
                case "win": modifiers |= ModWin; continue;
            }
            if (part.Length == 1 && char.IsLetterOrDigit(part[0]))
            {
                key = char.ToUpperInvariant(part[0]);
            }
            else if (part.Length is >= 2 and <= 3 && (part[0] is 'F' or 'f') &&
                     int.TryParse(part[1..], out var fn) && fn is >= 1 and <= 24)
            {
                key = (uint)(0x70 + fn - 1);
            }
            else
            {
                problem = $"\"{part}\" 不是可识别的按键（支持 A-Z / 0-9 / F1-F24）";
                return false;
            }
        }
        if (key == 0) { problem = $"组合键 \"{combo}\" 缺少主键"; return false; }
        return true;
    }

    /// <summary>把解析结果格式化为便于日志展示的形式。</summary>
    public static string Describe(string? combo)
    {
        if (!TryParse(combo, out _, out var key, out var problem)) return $"\"{combo}\"（{problem}）";
        return string.IsNullOrWhiteSpace(combo) ? combo! : combo!.Trim();
    }
}
