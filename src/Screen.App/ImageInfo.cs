using System.Buffers.Binary;

namespace Screen.App;

public static class ImageInfo
{
    public static (string Type, int Width, int Height) Read(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length >= 24 && bytes[..8].SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }))
        {
            var w = BinaryPrimitives.ReadInt32BigEndian(bytes[16..20]);
            var h = BinaryPrimitives.ReadInt32BigEndian(bytes[20..24]);
            if (w > 0 && h > 0 && (long)w * h <= 100_000_000) return ("image/png", w, h);
        }
        if (bytes.Length > 4 && bytes[0] == 255 && bytes[1] == 216)
        {
            var offset = 2;
            while (offset + 4 <= bytes.Length)
            {
                if (bytes[offset++] != 255) break;
                var marker = bytes[offset++];
                if (marker == 255) { offset--; continue; }
                if (marker is 0xD9 or 0xDA) break;
                if (marker is >= 0xD0 and <= 0xD7) continue;
                var len = BinaryPrimitives.ReadUInt16BigEndian(bytes[offset..]);
                if (len < 2 || offset + len > bytes.Length) break;
                if (marker is 0xC0 or 0xC1 or 0xC2 && len >= 7)
                {
                    var h = BinaryPrimitives.ReadUInt16BigEndian(bytes[(offset + 3)..]);
                    var w = BinaryPrimitives.ReadUInt16BigEndian(bytes[(offset + 5)..]);
                    if (w > 0 && h > 0 && (long)w * h <= 100_000_000) return ("image/jpeg", w, h);
                }
                offset += len;
            }
        }
        throw new ArgumentException("请选择有效的 PNG 或 JPEG 图片（最多一亿像素）。");
    }
}
