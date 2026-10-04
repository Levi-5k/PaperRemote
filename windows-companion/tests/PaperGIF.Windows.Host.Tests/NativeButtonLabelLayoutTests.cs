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
        // Every larger candidate must fail, not merely the next smaller candidate.
        for (var size = label.NativeSize + 1; size <= 24; size++)
        {
            using var font = new Font(label.Font.FontFamily, size, FontStyle.Regular, GraphicsUnit.Pixel);
            using var format = NativeButtonLabelLayout.CreateFormat();
            var measured = graphics.MeasureString(label.Text, font,
                new SizeF(bounds.Width, 1_000_000), format, out var characters, out _);
            Assert.True(characters != label.Text.Length || measured.Width > bounds.Width || measured.Height > bounds.Height);
        }
    }

    [Fact]
    public void ExplicitMultilineTextIsCenteredAsAWholeBlock()
    {
        using var bitmap = new Bitmap(300, 200);
        using var graphics = Graphics.FromImage(bitmap);
        var bounds = new RectangleF(20, 30, 250, 140);
        using var label = NativeButtonLabelLayout.Fit(graphics, "First line\nSecond line\nThird line", bounds, 24, 1);
        using var format = NativeButtonLabelLayout.CreateFormat();

        Assert.True(label.Fits);
        Assert.Equal(24, label.NativeSize);
        Assert.Equal(bounds.Left + bounds.Width / 2, label.TextBounds.Left + label.TextBounds.Width / 2);
        Assert.Equal(bounds.Top + bounds.Height / 2, label.TextBounds.Top + label.TextBounds.Height / 2);
        Assert.Equal(StringAlignment.Center, format.Alignment);
        Assert.Equal(StringAlignment.Center, format.LineAlignment);
        Assert.Equal(StringTrimming.None, format.Trimming);
    }

    [Fact]
    public void MinimumSizeOverflowIsDetectedAndClippedWithoutChangingGraphicsState()
    {
        using var bitmap = new Bitmap(120, 100);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.White);
        var bounds = new RectangleF(30, 30, 60, 20);
        var originalClip = graphics.ClipBounds;
        using var label = NativeButtonLabelLayout.Fit(graphics, string.Join("\n", Enumerable.Repeat("Overflow", 30)), bounds, 24, 1);

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
    public void LongUnbrokenLabelWrapsInsteadOfPassingAClippedMeasurement()
    {
        using var bitmap = new Bitmap(120, 100);
        using var graphics = Graphics.FromImage(bitmap);
        using var label = NativeButtonLabelLayout.Fit(graphics, new string('W', 100),
            new RectangleF(0, 0, 50, 30), 24, 1);

        Assert.False(label.Fits);
        Assert.Equal(9, label.NativeSize);
        Assert.True(label.MeasuredSize.Height > label.ContentBounds.Height);
    }

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