using System.Buffers.Binary;
using System.Drawing.Drawing2D;
using System.Globalization;
using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Host;

internal static class ButtonImageStore
{
    private static readonly string DirectoryPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "paperGIF", "button-images");

    internal static Color ColorFromHex(string? hex, Color fallback) =>
        hex?.Length == 6 && int.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var value)
            ? Color.FromArgb((value >> 16) & 255, (value >> 8) & 255, value & 255) : fallback;

    internal static string Hex(Color color) => $"{color.R:X2}{color.G:X2}{color.B:X2}";

    internal static byte[] Encode(Image image)
    {
        var scale = Math.Min(1, 400d / Math.Max(image.Width, image.Height));
        var width = Math.Max(1, (int)Math.Round(image.Width * scale));
        var height = Math.Max(1, (int)Math.Round(image.Height * scale));
        using var resized = new Bitmap(width, height);
        using (var graphics = Graphics.FromImage(resized))
        {
            graphics.Clear(Color.White);
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.DrawImage(image, new Rectangle(0, 0, width, height));
        }
        var output = new byte[10 + width * height * 2];
        "PBGI"u8.CopyTo(output);
        output[4] = 2;
        BinaryPrimitives.WriteUInt16LittleEndian(output.AsSpan(6), (ushort)width);
        BinaryPrimitives.WriteUInt16LittleEndian(output.AsSpan(8), (ushort)height);
        for (var row = 0; row < height; row++)
        for (var column = 0; column < width; column++)
        {
            var color = resized.GetPixel(column, row);
            var value = (ushort)((color.R >> 3) << 11 | (color.G >> 2) << 5 | (color.B >> 3));
            BinaryPrimitives.WriteUInt16LittleEndian(output.AsSpan(10 + (row * width + column) * 2), value);
        }
        return output;
    }

    internal static void Save(Guid id, byte[] bytes)
    {
        Directory.CreateDirectory(DirectoryPath);
        File.WriteAllBytes(Path.Combine(DirectoryPath, $"{id:D}.pbgi"), bytes);
    }

    internal static byte[]? Load(Guid id)
    {
        var path = Path.Combine(DirectoryPath, $"{id:D}.pbgi");
        return File.Exists(path) ? File.ReadAllBytes(path) : null;
    }

    internal static Bitmap RenderPattern(RemoteButtonTexture texture, int width, int height,
        Color background, Color foreground, string? tintHex)
    {
        var result = new Bitmap(width, height);
        var ink = ColorFromHex(tintHex, foreground);
        var lineWidth = Math.Clamp(texture.LineWidth, 1, 8);
        var offset = lineWidth % 2 == 0 ? 0.5f : 0;
        for (var row = 0; row < height; row++)
        for (var column = 0; column < width; column++)
        {
            var coverage = PatternCoverage(texture.Pattern, column - width / 2 + offset,
                row - height / 2 + offset, Math.Max(2, texture.Scale), lineWidth);
            var luminance = 255 - (int)MathF.Round(255 * coverage * (100 - Math.Clamp(texture.Fade, 0, 90)) / 100,
                MidpointRounding.AwayFromZero);
            var amount = 255 - (luminance * 15 + 127) / 255 * 17;
            result.SetPixel(column, row, Blend(background, ink, amount));
        }
        return result;
    }

    private static Color Blend(Color background, Color foreground, int amount) => Color.FromArgb(
        (background.R * (255 - amount) + foreground.R * amount + 127) / 255,
        (background.G * (255 - amount) + foreground.G * amount + 127) / 255,
        (background.B * (255 - amount) + foreground.B * amount + 127) / 255);

    private static float PatternCoverage(RemoteButtonPattern pattern, float x, float y, float spacing, float lineWidth)
    {
        float Line(float distance) => Math.Clamp(lineWidth / 2 + 0.5f - distance, 0, 1);
        float Near(float value) => MathF.Abs(value - spacing * MathF.Round(value / spacing, MidpointRounding.AwayFromZero));
        float Mod(float value, float divisor) => value - divisor * MathF.Floor(value / divisor);
        switch (pattern)
        {
            case RemoteButtonPattern.Hexagons:
                var px = x / spacing;
                var py = y / spacing;
                var ax = Mod(px, 1) - 0.5f;
                var ay = Mod(py, 1.7320508f) - 0.8660254f;
                var bx = Mod(px - 0.5f, 1) - 0.5f;
                var by = Mod(py - 0.8660254f, 1.7320508f) - 0.8660254f;
                var useFirst = ax * ax + ay * ay < bx * bx + by * by;
                var gx = MathF.Abs(useFirst ? ax : bx);
                var gy = MathF.Abs(useFirst ? ay : by);
                return Line(MathF.Abs(0.5f - MathF.Max(gx * 0.5f + gy * 0.8660254f, gx)) * spacing);
            case RemoteButtonPattern.Triangles:
                var step = spacing * 0.8660254f;
                float TriangleNear(float value) => MathF.Abs(value - step * MathF.Round(value / step, MidpointRounding.AwayFromZero));
                return Line(MathF.Min(TriangleNear(y), MathF.Min(TriangleNear(x * 0.8660254f + y * 0.5f), TriangleNear(x * 0.8660254f - y * 0.5f))));
            case RemoteButtonPattern.Grid: return Line(MathF.Min(Near(x), Near(y)));
            case RemoteButtonPattern.Dots:
                var dx = Near(x);
                var dy = Near(y);
                return Math.Clamp(MathF.Max(1, spacing * 0.15f + lineWidth / 2) + 0.5f - MathF.Sqrt(dx * dx + dy * dy), 0, 1);
            case RemoteButtonPattern.Diagonal: return Line(Near((x + y) * 0.70710678f));
            case RemoteButtonPattern.Checker:
                var cx = Mod(x, spacing);
                var cy = Mod(y, spacing);
                var edge = MathF.Min(MathF.Min(cx, spacing - cx), MathF.Min(cy, spacing - cy));
                var inside = (((int)MathF.Floor(x / spacing) + (int)MathF.Floor(y / spacing)) & 1) != 0;
                return Math.Clamp(0.5f + (inside ? edge : -edge), 0, 1);
            case RemoteButtonPattern.Waves:
                var amplitude = spacing * 0.25f;
                var wave = MathF.PI / spacing;
                var slope = amplitude * wave * MathF.Cos(x * wave);
                return Line(Near(y - amplitude * MathF.Sin(x * wave)) / MathF.Sqrt(1 + slope * slope));
            case RemoteButtonPattern.Rings: return Line(Near(MathF.Sqrt(x * x + y * y)));
            case RemoteButtonPattern.Spiral: return Line(Near(MathF.Sqrt(x * x + y * y) - MathF.Atan2(y, x) * (0.15915494f * spacing)));
            case RemoteButtonPattern.Truchet:
                var column = (int)MathF.Floor(x / spacing);
                var row = (int)MathF.Floor(y / spacing);
                var hash = unchecked((uint)column * 0x9E3779B1u ^ (uint)row * 0x85EBCA77u);
                hash ^= hash >> 15;
                hash = unchecked(hash * 0x2C1B3C6Du);
                hash ^= hash >> 12;
                var lx = x - column * spacing;
                var ly = y - row * spacing;
                if ((hash & 1) != 0) lx = spacing - lx;
                var sx = spacing - lx;
                var sy = spacing - ly;
                return Line(MathF.Min(MathF.Abs(MathF.Sqrt(lx * lx + ly * ly) - spacing / 2),
                    MathF.Abs(MathF.Sqrt(sx * sx + sy * sy) - spacing / 2)));
            default: return 0;
        }
    }

    internal static Bitmap? Render(byte[] bytes, RemoteButtonTexture texture, int width, int height,
        Color background, Color foreground, string? tintHex)
    {
        if (bytes.Length < 10 || !bytes.AsSpan(0, 4).SequenceEqual("PBGI"u8) ||
            bytes[4] is not (1 or 2) || bytes[5] != 0) return null;
        var sourceWidth = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(6));
        var sourceHeight = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(8));
        var stride = bytes[4] == 2 ? 2 : 1;
        if (sourceWidth == 0 || sourceHeight == 0 || sourceWidth > 540 || sourceHeight > 540 ||
            bytes.Length != 10 + sourceWidth * sourceHeight * stride) return null;
        var scale = Math.Max(width / (double)sourceWidth, height / (double)sourceHeight);
        var cropX = (sourceWidth - width / scale) / 2;
        var cropY = (sourceHeight - height / scale) / 2;
        var result = new Bitmap(width, height);
        var inkColor = ColorFromHex(tintHex, foreground);
        var fade = Math.Clamp(texture.Fade, 0, 90);
        for (var row = 0; row < height; row++)
        for (var column = 0; column < width; column++)
        {
            var sourceX = Math.Clamp((int)(cropX + (column + 0.5) / scale), 0, sourceWidth - 1);
            var sourceY = Math.Clamp((int)(cropY + (row + 0.5) / scale), 0, sourceHeight - 1);
            var offset = 10 + (sourceY * sourceWidth + sourceX) * stride;
            Color source;
            if (stride == 2)
            {
                var packed = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(offset));
                source = Color.FromArgb(((packed >> 11) & 31) * 255 / 31,
                    ((packed >> 5) & 63) * 255 / 63, (packed & 31) * 255 / 31);
            }
            else source = Color.FromArgb(bytes[offset], bytes[offset], bytes[offset]);
            var preserve = texture.PreserveColor && stride == 2 && tintHex == null;
            var gray = (source.R * 299 + source.G * 587 + source.B * 114) / 1000;
            var composite = 255 - (int)Math.Round((255 - gray) * (100 - fade) / 100d, MidpointRounding.AwayFromZero);
            var amount = preserve ? (100 - fade) * 255 / 100 : 255 - QuantizedLevel(texture, composite, column, row) * 17;
            var color = preserve ? source : inkColor;
            result.SetPixel(column, row, Blend(background, color, amount));
        }
        return result;
    }

    private static int QuantizedLevel(RemoteButtonTexture texture, int luminance, int column, int row)
    {
        if (texture.Mode == RemoteButtonImageMode.Threshold ||
            texture.Mode == RemoteButtonImageMode.Monochrome && texture.Levels == 0)
            return luminance < texture.Threshold ? 0 : 15;
        var spacing = Math.Max(2, texture.DotSpacing);
        var angle = texture.Angle * Math.PI / 180;
        var screenX = (column + 0.5) * Math.Cos(angle) + (row + 0.5) * Math.Sin(angle);
        var screenY = -(column + 0.5) * Math.Sin(angle) + (row + 0.5) * Math.Cos(angle);
        var localX = screenX - Math.Floor(screenX / spacing) * spacing - spacing / 2d;
        var localY = screenY - Math.Floor(screenY / spacing) * spacing - spacing / 2d;
        var rank = Math.Min(1, Math.PI * (localX * localX + localY * localY) / (spacing * spacing));
        var gain = texture.DotGain / 100d;
        var adjusted = Math.Clamp(luminance + 128 - texture.Threshold, 0, 255);
        if (texture.Mode == RemoteButtonImageMode.Halftone || texture.Mode == RemoteButtonImageMode.Combined && texture.Levels == 0)
        {
            var value = texture.Mode == RemoteButtonImageMode.Combined ? adjusted : luminance;
            return rank < Math.Clamp(1 - value / 255d + gain, 0, 1) ? 0 : 15;
        }
        var levels = Math.Clamp(texture.Levels, 2, 16);
        var scaled = adjusted * (levels - 1) / 255d;
        var darker = Math.Floor(scaled);
        var quantized = texture.Mode == RemoteButtonImageMode.Combined
            ? rank < Math.Clamp(1 - (scaled - darker) + gain, 0, 1) ? darker : Math.Min(levels - 1, darker + 1)
            : Math.Round(scaled, MidpointRounding.AwayFromZero);
        return (int)Math.Round(quantized * 15 / (levels - 1), MidpointRounding.AwayFromZero);
    }
}