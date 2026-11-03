using Screen.App;
using Xunit;

namespace Screen.App.Tests;

/// <summary>
/// Umi 文本块拼接：按 tbpu.parser 给出的 end 结束符还原行与段落。
/// 这两种情况曾经都出错——按 '\n' 硬拼会把「同一行的多块」拆成多行，
/// 又会把「多栏的同一行」拼到一行里。
/// </summary>
public class UmiComposeTests
{
    [Fact]
    public void End空字符串表示同一行继续_不插入换行()
    {
        var blocks = new (string? Text, string? End)[]
        {
            ("项目", ""),
            ("端口", ""),
            ("状态", "\n"),
        };

        Assert.Equal("项目端口状态", UmiOcr.Compose(blocks));
    }

    [Fact]
    public void End为换行时逐行还原()
    {
        var blocks = new (string? Text, string? End)[]
        {
            ("第一行", "\n"),
            ("第二行", "\n"),
        };

        Assert.Equal("第一行\n第二行", UmiOcr.Compose(blocks));
    }

    [Fact]
    public void End为空格时保留行内空格()
    {
        var blocks = new (string? Text, string? End)[]
        {
            ("hello", " "),
            ("world", "\n"),
        };

        Assert.Equal("hello world", UmiOcr.Compose(blocks));
    }

    [Fact]
    public void 缺少end字段时按换行处理()
    {
        var blocks = new (string? Text, string? End)[]
        {
            ("甲", null),
            ("乙", null),
        };

        Assert.Equal("甲\n乙", UmiOcr.Compose(blocks));
    }

    [Fact]
    public void 空文本块被跳过_不产生空行()
    {
        var blocks = new (string? Text, string? End)[]
        {
            ("甲", "\n"),
            ("", "\n"),
            (null, "\n"),
            ("乙", "\n"),
        };

        Assert.Equal("甲\n乙", UmiOcr.Compose(blocks));
    }

    [Fact]
    public void 结果尾部空白被清除()
    {
        var blocks = new (string? Text, string? End)[]
        {
            ("末行", "\n\n"),
        };

        Assert.Equal("末行", UmiOcr.Compose(blocks));
    }

    [Fact]
    public void 空输入返回空串()
    {
        Assert.Equal("", UmiOcr.Compose(Array.Empty<(string?, string?)>()));
    }
}
