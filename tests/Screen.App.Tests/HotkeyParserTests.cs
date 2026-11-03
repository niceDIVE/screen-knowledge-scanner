using Screen.App;
using Xunit;

namespace Screen.App.Tests;

public sealed class HotkeyParserTests
{
    [Theory]
    [InlineData("Ctrl+Alt+S", 0x4000u | 0x2u | 0x1u, 0x53u)]
    [InlineData("ctrl+shift+F12", 0x4000u | 0x2u | 0x4u, 0x7Bu)]
    [InlineData("Win+Alt+0", 0x4000u | 0x8u | 0x1u, 0x30u)]
    [InlineData("Alt+F1", 0x4000u | 0x1u, 0x70u)]
    [InlineData(" Ctrl + Alt + Q ", 0x4000u | 0x2u | 0x1u, 0x51u)]
    public void Parses_valid_combos(string combo, uint expectedMods, uint expectedKey)
    {
        Assert.True(HotkeyParser.TryParse(combo, out var mods, out var key, out var problem), problem);
        Assert.Equal(expectedMods, mods);
        Assert.Equal(expectedKey, key);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("Ctrl+")]
    [InlineData("Ctrl+Alt")]
    [InlineData("Ctrl+Alt+Xyz")]
    [InlineData("Ctrl+Alt+F25")]
    [InlineData("Ctrl+Alt+!")]
    public void Rejects_invalid_combos_with_reason(string combo)
    {
        Assert.False(HotkeyParser.TryParse(combo, out _, out _, out var problem));
        Assert.False(string.IsNullOrWhiteSpace(problem));
    }

    [Fact]
    public void Describe_reports_problem_for_bad_combo()
    {
        var text = HotkeyParser.Describe("Ctrl+Alt+Bogus");
        Assert.Contains("不是可识别的按键", text);
    }
}
