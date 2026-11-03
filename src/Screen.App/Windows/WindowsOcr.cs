using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace Screen.App.Windows;

public sealed class WindowsOcr : IOcrEngine
{
    public string Name => "Windows 本地 OCR";
    public async Task<OcrResult> RecognizeAsync(string path,CancellationToken token)
    {
        var engine=OcrEngine.TryCreateFromUserProfileLanguages()
            ??throw new InvalidOperationException("Windows OCR 没有可用语言包，请在 Windows 语言设置中安装中文文字识别组件。");
        using var memory=new InMemoryRandomAccessStream();
        using(var writer=new DataWriter(memory))
        {
            writer.WriteBytes(await File.ReadAllBytesAsync(path,token));
            await writer.StoreAsync().AsTask(token); writer.DetachStream();
        }
        memory.Seek(0);
        var decoder=await BitmapDecoder.CreateAsync(memory).AsTask(token);
        var scale=Math.Min(2.0,OcrEngine.MaxImageDimension/(double)Math.Max(decoder.PixelWidth,decoder.PixelHeight));
        var transform=new BitmapTransform {
            ScaledWidth=(uint)(decoder.PixelWidth*scale),ScaledHeight=(uint)(decoder.PixelHeight*scale)
        };
        using var bitmap=await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Premultiplied,
            transform,ExifOrientationMode.IgnoreExifOrientation,ColorManagementMode.DoNotColorManage).AsTask(token);
        var result=await engine.RecognizeAsync(bitmap).AsTask(token);
        var text=string.Join('\n',result.Lines.Select(l=>l.Text));
        text=System.Text.RegularExpressions.Regex.Replace(text,@"(?<=[\u3400-\u9fff])[ \t]+(?=[\u3400-\u9fff])",string.Empty);
        return new(text,$"Windows OCR · {engine.RecognizerLanguage.LanguageTag}");
    }
}
