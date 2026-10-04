using System.Drawing.Drawing2D;
using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Host;

// Measure and draw using the same native font/wrapping rules; never resize a text bitmap.
internal sealed class NativeButtonLabelLayout : IDisposable
{
    private NativeButtonLabelLayout(string text, Font font, RectangleF contentBounds,
        SizeF measuredSize, int nativeSize, bool fits)
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
    public int NativeSize { get; }
    public bool Fits { get; }
    public RectangleF TextBounds => new(ContentBounds.Left,
        ContentBounds.Top + (ContentBounds.Height - MeasuredSize.Height) / 2,
        ContentBounds.Width, MeasuredSize.Height);

    internal static StringFormat CreateFormat() => new(StringFormat.GenericTypographic)
    {
        Alignment = StringAlignment.Center,
        LineAlignment = StringAlignment.Center,
        Trimming = StringTrimming.None,
        FormatFlags = StringFormatFlags.MeasureTrailingSpaces,
    };

    public static NativeButtonLabelLayout Fit(Graphics graphics, string text,
        RectangleF contentBounds, int maximumNativeSize, float screenScale)
    {
        var maximum = Math.Clamp(maximumNativeSize,
            RemoteProfile.MinimumButtonTextSize, RemoteProfile.MaximumButtonTextSize);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(screenScale);
        using var format = CreateFormat();
        for (var size = maximum; size >= RemoteProfile.MinimumButtonTextSize; size--)
        {
            // Device coordinates are 540×960 pixels. Pixel units avoid adding Windows
            // monitor DPI to the preview's screen.Width / 540 scale a second time.
            var font = new Font("Segoe UI Variable Text Semibold", size * screenScale,
                FontStyle.Regular, GraphicsUnit.Pixel);
            // Measure with unrestricted height, not the draw rectangle: otherwise a
            // truncated last line could be mistaken for a label that fully fits.
            var measured = graphics.MeasureString(text, font,
                new SizeF(Math.Max(1, contentBounds.Width), 1_000_000), format,
                out var charactersFitted, out _);
            var fits = contentBounds.Width > 0 && contentBounds.Height > 0 &&
                charactersFitted == text.Length && measured.Width <= contentBounds.Width &&
                measured.Height <= contentBounds.Height;
            if (fits || size == RemoteProfile.MinimumButtonTextSize)
            {
                return new NativeButtonLabelLayout(text, font, contentBounds, measured, size, fits);
            }
            font.Dispose();
        }
        throw new InvalidOperationException("No native button font candidate was evaluated.");
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