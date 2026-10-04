using System.Drawing;
using Xunit;

namespace PaperGIF.Windows.Host.Tests;

public sealed class RemoteIconGlyphsTests
{
    [Fact]
    public void EveryDeviceIconFillsInsideItsBounds()
    {
        var bounds = new RectangleF(10, 20, 48, 48);
        Assert.NotEmpty(RemoteIconGlyphs.Names);
        foreach (var name in RemoteIconGlyphs.Names)
        {
            using var path = RemoteIconGlyphs.CreatePath(name, bounds);
            Assert.NotNull(path);
            var extent = path.GetBounds();
            Assert.True(extent.Width * extent.Height > 20, name);
            Assert.True(RectangleF.Inflate(bounds, 0.01f, 0.01f).Contains(extent), name);
        }
    }

    [Fact]
    public void UnknownSymbolsHaveNoOutline()
    {
        Assert.False(RemoteIconGlyphs.Contains("keyboard"));
        Assert.Null(RemoteIconGlyphs.CreatePath("keyboard", new RectangleF(0, 0, 10, 10)));
        Assert.Null(RemoteIconGlyphs.CreatePath(null, new RectangleF(0, 0, 10, 10)));
    }
}
