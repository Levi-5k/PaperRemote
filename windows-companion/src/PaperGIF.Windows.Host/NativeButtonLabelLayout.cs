using System.Drawing.Drawing2D;
using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Host;

// Measure and draw using the same native font/wrapping rules; never resize a text bitmap.
internal sealed class NativeButtonLabelLayout : IDisposable
{
    private NativeButtonLabelLayout(string text, Font font, RectangleF contentBounds,
        SizeF measuredSize, float nativeSize, bool fits)
    {
        Text = text;
        Font = font;
        ContentBounds = contentBounds;
        MeasuredSize = measuredSize;
        NativeSize = nativeSize;
        Fits = fits;
    }

    public string Text { get; }
    public Font Font { get; }
    public RectangleF ContentBounds { get; }
    public SizeF MeasuredSize { get; }
    public float NativeSize { get; }
    public bool Fits { get; }
    public RectangleF TextBounds => new(ContentBounds.Left,
        ContentBounds.Top + (ContentBounds.Height - MeasuredSize.Height) / 2,
        ContentBounds.Width, MeasuredSize.Height);

    internal static StringFormat CreateFormat(bool singleLine = false) => new(StringFormat.GenericTypographic)
    {
        Alignment = StringAlignment.Center,
        LineAlignment = StringAlignment.Center,
        Trimming = StringTrimming.None,
        FormatFlags = StringFormatFlags.MeasureTrailingSpaces |
            (singleLine ? StringFormatFlags.NoWrap : 0),
    };

    public static NativeButtonLabelLayout Fit(Graphics graphics, string text,
        RectangleF contentBounds, int maximumNativeSize, float screenScale, bool wordOnlyWrap = true)
    {
        var maximum = Math.Clamp(maximumNativeSize,
            RemoteProfile.MinimumButtonTextSize, RemoteProfile.MaximumButtonTextSize);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(screenScale);
        using var format = CreateFormat();
        using var wordFormat = CreateFormat(singleLine: true);
        var words = wordOnlyWrap
            ? text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            : Array.Empty<string>();
        var validBounds = contentBounds.Width > 0 && contentBounds.Height > 0;
        for (float size = maximum; ;)
        {
            // Device coordinates are 540×960 pixels. Pixel units avoid adding Windows
            // monitor DPI to the preview's screen.Width / 540 scale a second time.
            var font = new Font("Segoe UI Variable Text Semibold", size * screenScale,
                FontStyle.Regular, GraphicsUnit.Pixel);
            // Native wrapping can fall back to breaking an oversized word. Reject
            // that font first, so buttons/ordinary sliders wrap only between words.
            var widestWord = 0f;
            foreach (var word in words)
            {
                widestWord = Math.Max(widestWord,
                    graphics.MeasureString(word, font, PointF.Empty, wordFormat).Width);
            }
            // Measure the complete wrapped block with unrestricted height so a
            // truncated last line cannot be mistaken for a fully fitting label.
            // Text boxes/seek labels keep their existing measurement/minimum size.
            var measured = graphics.MeasureString(text, font,
                new SizeF(Math.Max(wordOnlyWrap ? float.Epsilon : 1, contentBounds.Width), 1_000_000), format,
                out var charactersFitted, out _);
            var fits = validBounds && widestWord <= contentBounds.Width &&
                charactersFitted == text.Length && measured.Width <= contentBounds.Width &&
                measured.Height <= contentBounds.Height;
            // The user setting is a maximum, not a minimum fitting size. Continue
            // below 9 (and below 1 for exceptionally long words), using native fonts.
            var nextSize = size > 1 ? size - 1 : size / 2;
            if (fits || !validBounds || (!wordOnlyWrap && size == RemoteProfile.MinimumButtonTextSize) ||
                nextSize * screenScale <= 0)
            {
                return new NativeButtonLabelLayout(text, font, contentBounds, measured, size, fits);
            }
            font.Dispose();
            size = nextSize;
        }
    }

    public void Draw(Graphics graphics, Brush brush)
    {
        if (ContentBounds.Width <= 0 || ContentBounds.Height <= 0 || Text.Length == 0)
        {
            return;
        }
        var state = graphics.Save();
        try
        {
            graphics.SetClip(ContentBounds, CombineMode.Intersect);
            using var format = CreateFormat();
            // Center the whole measured block, even when the minimum size overflows;
            // the explicit clip keeps such labels and glyph overhang inside the control.
            graphics.DrawString(Text, Font, brush, TextBounds, format);
        }
        finally
        {
            graphics.Restore(state);
        }
    }

    public void Dispose() => Font.Dispose();
}