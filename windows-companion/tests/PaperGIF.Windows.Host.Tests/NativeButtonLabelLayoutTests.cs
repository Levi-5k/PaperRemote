using System.Drawing;
using Xunit;

namespace PaperGIF.Windows.Host.Tests;

public sealed class NativeButtonLabelLayoutTests
{
    [Theory]
    [InlineData(9)]
    [InlineData(16)]
    [InlineData(24)]
    public void ShortLabelUsesTheUserCapRatherThanButtonWidth(int cap)
    {
        using var bitmap = new Bitmap(540, 200);
        using var graphics = Graphics.FromImage(bitmap);
        using var label = NativeButtonLabelLayout.Fit(graphics, "STOP",
            new RectangleF(10, 10, 500, 180), cap, 1);

        Assert.True(label.Fits);
        Assert.Equal(cap, label.NativeSize);
        Assert.Equal(GraphicsUnit.Pixel, label.Font.Unit);
        Assert.Equal(cap, label.Font.Size);
    }

    [Theory]
    [InlineData(96, 0.5f)]
    [InlineData(192, 0.5f)]
    [InlineData(96, 1.0f)]
    [InlineData(192, 1.0f)]
    [InlineData(144, 1.5f)]
    public void NativeFontUsesPreviewScreenScaleWithoutAnExtraMonitorDpiFactor(int dpi, float scale)
    {
        using var bitmap = new Bitmap(540, 200);
        bitmap.SetResolution(dpi, dpi);
        using var graphics = Graphics.FromImage(bitmap);
        using var label = NativeButtonLabelLayout.Fit(graphics, "STOP",
            new RectangleF(0, 0, 300 * scale, 100 * scale), 24, scale);

        Assert.True(label.Fits);
        Assert.Equal(24, label.NativeSize);
        Assert.Equal(24 * scale, label.Font.Size);
    }

    [Fact]
    public void WrappedLabelSelectsLargestFullyFittingNativeSize()
    {
        using var bitmap = new Bitmap(240, 200);
        using var graphics = Graphics.FromImage(bitmap);
        var bounds = new RectangleF(10, 10, 120, 55);
        using var label = NativeButtonLabelLayout.Fit(graphics, "Move the machine to home", bounds, 24, 1);

        Assert.True(label.Fits);
        Assert.InRange(label.NativeSize, 9, 23);
        Assert.True(label.MeasuredSize.Height > label.Font.GetHeight(graphics));
        Assert.True(label.MeasuredSize.Width <= bounds.Width);
        Assert.True(label.MeasuredSize.Height <= bounds.Height);
        AssertWordsFit(graphics, label);
        // Every larger candidate must fail, not merely the next smaller candidate.
        for (var size = label.NativeSize + 1; size <= 24; size++)
        {
            using var font = new Font(label.Font.FontFamily, size, FontStyle.Regular, GraphicsUnit.Pixel);
            using var format = NativeButtonLabelLayout.CreateFormat(singleLine: false);
            var measured = graphics.MeasureString(label.Text, font,
                new SizeF(bounds.Width, 1_000_000), format, out var characters, out _);
            Assert.True(!WordsFit(graphics, label.Text, font, bounds.Width) ||
                characters != label.Text.Length || measured.Width > bounds.Width || measured.Height > bounds.Height);
        }
    }

    [Fact]
    public void ExplicitMultilineTextIsCenteredAsAWholeBlock()
    {
        using var bitmap = new Bitmap(300, 200);
        using var graphics = Graphics.FromImage(bitmap);
        var bounds = new RectangleF(20, 30, 250, 140);
        using var label = NativeButtonLabelLayout.Fit(graphics, "First line\nSecond line\nThird line", bounds, 24, 1);
        using var format = NativeButtonLabelLayout.CreateFormat(singleLine: false);

        Assert.True(label.Fits);
        Assert.Equal(24, label.NativeSize);
        Assert.Equal("First line\nSecond line\nThird line", label.Text);
        Assert.True(label.MeasuredSize.Height > label.Font.GetHeight(graphics) * 2);
        AssertWordsFit(graphics, label);
        Assert.Equal(bounds.Left + bounds.Width / 2, label.TextBounds.Left + label.TextBounds.Width / 2);
        Assert.Equal(bounds.Top + bounds.Height / 2, label.TextBounds.Top + label.TextBounds.Height / 2);
        Assert.Equal(StringAlignment.Center, format.Alignment);
        Assert.Equal(StringAlignment.Center, format.LineAlignment);
        Assert.Equal(StringTrimming.None, format.Trimming);
        Assert.False(format.FormatFlags.HasFlag(StringFormatFlags.NoWrap));
    }

    [Fact]
    public void TextBoxAndSeekMinimumSizeOverflowIsDetectedAndClippedWithoutChangingGraphicsState()
    {
        using var bitmap = new Bitmap(120, 100);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.White);
        var bounds = new RectangleF(30, 30, 60, 20);
        var originalClip = graphics.ClipBounds;
        using var label = NativeButtonLabelLayout.Fit(graphics, string.Join("\n", Enumerable.Repeat("Overflow", 30)), bounds, 24, 1,
            wordOnlyWrap: false);

        Assert.False(label.Fits);
        Assert.Equal(9, label.NativeSize);
        label.Draw(graphics, Brushes.Black);
        Assert.Equal(originalClip, graphics.ClipBounds);
        var inkInside = false;
        for (var y = 0; y < bitmap.Height; y++)
        {
            for (var x = 0; x < bitmap.Width; x++)
            {
                var hasInk = bitmap.GetPixel(x, y).ToArgb() != Color.White.ToArgb();
                if (bounds.Contains(x, y))
                {
                    inkInside |= hasInk;
                }
                else
                {
                    Assert.False(hasInk);
                }
            }
        }
        Assert.True(inkInside);
    }

    [Fact]
    public void LongUnbrokenLabelFitsOneLineEvenBelowOneNativePixel()
    {
        using var bitmap = new Bitmap(120, 100);
        using var graphics = Graphics.FromImage(bitmap);
        using var label = NativeButtonLabelLayout.Fit(graphics, new string('W', 100),
            new RectangleF(0, 0, 50, 30), 24, 1);

        Assert.True(label.Fits);
        Assert.True(label.NativeSize < 1);
        AssertSingleLine(graphics, label);
        AssertWordsFit(graphics, label);
        using var larger = new Font(label.Font.FontFamily, label.NativeSize * 2,
            FontStyle.Regular, GraphicsUnit.Pixel);
        Assert.False(WordsFit(graphics, label.Text, larger, label.ContentBounds.Width));
    }

    [Theory]
    [InlineData("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")]
    [InlineData("Long-word/with.punctuation0123456789")]
    public void LongWordSelectsLargestFittingFontBelowNineWithoutSplitting(string text)
    {
        using var bitmap = new Bitmap(240, 200);
        using var graphics = Graphics.FromImage(bitmap);
        var bounds = new RectangleF(10, 10, 120, 100);
        using var label = NativeButtonLabelLayout.Fit(graphics, text, bounds, 24, 1);

        Assert.True(label.Fits);
        Assert.InRange(label.NativeSize, 1f, 8f);
        AssertSingleLine(graphics, label);
        AssertWordsFit(graphics, label);
        for (var size = label.NativeSize + 1; size <= 24; size++)
        {
            using var font = new Font(label.Font.FontFamily, size, FontStyle.Regular, GraphicsUnit.Pixel);
            using var format = NativeButtonLabelLayout.CreateFormat(singleLine: true);
            var measured = graphics.MeasureString(text, font, PointF.Empty, format);
            Assert.True(measured.Width > bounds.Width || measured.Height > bounds.Height);
        }
    }

    [Fact]
    public void MultiwordLabelWrapsAtTheCapInsteadOfShrinkingToOneLine()
    {
        using var bitmap = new Bitmap(240, 300);
        using var graphics = Graphics.FromImage(bitmap);
        var bounds = new RectangleF(10, 10, 120, 280);
        using var label = NativeButtonLabelLayout.Fit(graphics, "Move the machine to home", bounds, 24, 1);
        using var noWrap = NativeButtonLabelLayout.CreateFormat(singleLine: true);

        Assert.True(label.Fits);
        Assert.Equal(24, label.NativeSize);
        Assert.True(label.MeasuredSize.Height > label.Font.GetHeight(graphics));
        Assert.True(graphics.MeasureString(label.Text, label.Font, PointF.Empty, noWrap).Width > bounds.Width);
        AssertWordsFit(graphics, label);
    }

    [Fact]
    public void OversizedWordInMultiwordTextCannotUseNativeCharacterFallback()
    {
        using var bitmap = new Bitmap(240, 300);
        using var graphics = Graphics.FromImage(bitmap);
        var bounds = new RectangleF(10, 10, 80, 280);
        const string text = "Start ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 End";
        using var label = NativeButtonLabelLayout.Fit(graphics, text, bounds, 24, 1);

        Assert.True(label.Fits);
        Assert.True(label.NativeSize < 9);
        AssertWordsFit(graphics, label);
        for (var size = label.NativeSize + 1; size <= 24; size++)
        {
            using var font = new Font(label.Font.FontFamily, size, FontStyle.Regular, GraphicsUnit.Pixel);
            Assert.False(WordsFit(graphics, text, font, bounds.Width));
        }
    }

    [Fact]
    public void AmpleWidthKeepsLongLabelAtUserCap()
    {
        using var bitmap = new Bitmap(1000, 200);
        using var graphics = Graphics.FromImage(bitmap);
        using var label = NativeButtonLabelLayout.Fit(graphics, "Move the machine to home",
            new RectangleF(10, 10, 980, 180), 24, 1);

        Assert.True(label.Fits);
        Assert.Equal(24, label.NativeSize);
        AssertSingleLine(graphics, label);
    }

    [Theory]
    [InlineData(0.5f)]
    [InlineData(1f)]
    [InlineData(1.5f)]
    public void ResizingRefitsWordWrappedTextAndRestoresTheCap(float scale)
    {
        using var bitmap = new Bitmap(1000, 300);
        using var graphics = Graphics.FromImage(bitmap);
        const string text = "Move the machine to home";
        using var small = NativeButtonLabelLayout.Fit(graphics, text,
            new RectangleF(0, 0, 120 * scale, 55 * scale), 24, scale);
        using var large = NativeButtonLabelLayout.Fit(graphics, text,
            new RectangleF(0, 0, 980 * scale, 100 * scale), 24, scale);
        using var smallAgain = NativeButtonLabelLayout.Fit(graphics, text, small.ContentBounds, 24, scale);

        Assert.True(small.Fits && large.Fits && smallAgain.Fits);
        Assert.True(large.NativeSize > small.NativeSize);
        Assert.Equal(24, large.NativeSize);
        Assert.Equal(small.NativeSize, smallAgain.NativeSize);
        Assert.True(small.MeasuredSize.Height > small.Font.GetHeight(graphics));
        AssertWordsFit(graphics, small);
        AssertSingleLine(graphics, large);
    }

    [Fact]
    public void ButtonNewlinesRemainMultilineAndDrawingRestoresTheClip()
    {
        using var bitmap = new Bitmap(540, 200);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.White);
        var bounds = new RectangleF(30, 30, 480, 140);
        var originalClip = graphics.ClipBounds;
        using var label = NativeButtonLabelLayout.Fit(graphics,
            "First line\nSecond line\nThird line", bounds, 24, 1);

        Assert.Equal("First line\nSecond line\nThird line", label.Text);
        Assert.True(label.Fits);
        Assert.Equal(24, label.NativeSize);
        Assert.True(label.MeasuredSize.Height > label.Font.GetHeight(graphics) * 2);
        AssertWordsFit(graphics, label);
        label.Draw(graphics, Brushes.Black);
        Assert.Equal(originalClip, graphics.ClipBounds);
        var inkInside = false;
        for (var y = 0; y < bitmap.Height; y++)
        {
            for (var x = 0; x < bitmap.Width; x++)
            {
                var ink = bitmap.GetPixel(x, y).ToArgb() != Color.White.ToArgb();
                if (bounds.Contains(x, y)) inkInside |= ink;
                else Assert.False(ink);
            }
        }
        Assert.True(inkInside);
    }

    [Theory]
    [InlineData(0.5f)]
    [InlineData(1f)]
    [InlineData(1.5f)]
    public void HorizontalIconReservesOnlyItsLeftHaloAndGap(float scale)
    {
        var frame = Rectangle.Round(new RectangleF(20, 30, 400 * scale, 100 * scale));
        var layout = RemotePreviewPanel.DeviceIconLayout(frame, scale, forceHorizontal: true)!.Value;
        var halo = RectangleF.Inflate(layout.Icon, 4 * scale, 4 * scale);

        Assert.True(layout.Horizontal);
        Assert.True(layout.Content.Contains(halo));
        Assert.Equal(halo.Right + layout.Gap, layout.Title.Left);
        Assert.Equal(layout.Content.Right, layout.Title.Right);
        Assert.Equal(layout.Content.Width - layout.Extent - layout.Gap, layout.Title.Width);
        using var bitmap = new Bitmap(1000, 300);
        using var graphics = Graphics.FromImage(bitmap);
        using var label = NativeButtonLabelLayout.Fit(graphics, "Home All Axes", layout.Title, 24, scale);
        Assert.True(label.Fits);
        Assert.Equal(24, label.NativeSize);
        Assert.Equal((halo.Right + layout.Gap + layout.Content.Right) / 2,
            label.TextBounds.Left + label.TextBounds.Width / 2);
    }

    private static void AssertSingleLine(Graphics graphics, NativeButtonLabelLayout label)
    {
        using var format = NativeButtonLabelLayout.CreateFormat();
        Assert.False(format.FormatFlags.HasFlag(StringFormatFlags.NoWrap));
        var measured = graphics.MeasureString(label.Text, label.Font,
            new SizeF(label.ContentBounds.Width, 1_000_000), format, out var characters, out var lines);
        Assert.Equal(label.Text.Length, characters);
        Assert.Equal(1, lines);
        Assert.Equal(measured, label.MeasuredSize);
        Assert.True(label.MeasuredSize.Width <= label.ContentBounds.Width);
        Assert.True(label.MeasuredSize.Height <= label.ContentBounds.Height);
        Assert.Equal(label.ContentBounds.Left + label.ContentBounds.Width / 2,
            label.TextBounds.Left + label.TextBounds.Width / 2);
        Assert.Equal(label.ContentBounds.Top + label.ContentBounds.Height / 2,
            label.TextBounds.Top + label.TextBounds.Height / 2);
    }

    private static bool WordsFit(Graphics graphics, string text, Font font, float width)
    {
        using var format = NativeButtonLabelLayout.CreateFormat(singleLine: true);
        return text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .All(word => graphics.MeasureString(word, font, PointF.Empty, format).Width <= width);
    }

    private static void AssertWordsFit(Graphics graphics, NativeButtonLabelLayout label) =>
        Assert.True(WordsFit(graphics, label.Text, label.Font, label.ContentBounds.Width));

    [Fact]
    public void EmptyAndTinyContentBoundsAreSafe()
    {
        using var bitmap = new Bitmap(120, 100);
        using var graphics = Graphics.FromImage(bitmap);
        using var empty = NativeButtonLabelLayout.Fit(graphics, "", new RectangleF(0, 0, 100, 50), 24, 1);
        using var tiny = NativeButtonLabelLayout.Fit(graphics, "Label", new RectangleF(0, 0, -1, -1), 24, 1);

        Assert.True(empty.Fits);
        Assert.Equal(24, empty.NativeSize);
        Assert.False(tiny.Fits);
        empty.Draw(graphics, Brushes.Black);
        tiny.Draw(graphics, Brushes.Black);
    }
}