using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace PaperGIF.Windows.Host;

internal static class PaperGifIcon
{
    public static Icon Create(int size)
    {
        using var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.Clear(Color.Transparent);

        using var background = new SolidBrush(Color.FromArgb(31, 72, 61));
        using var paper = new SolidBrush(Color.FromArgb(248, 246, 239));
        using var fold = new SolidBrush(Color.FromArgb(221, 96, 70));
        using var ink = new Pen(Color.FromArgb(31, 72, 61), Math.Max(1.5f, size * 0.055f))
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round,
        };

        var inset = size * 0.04f;
        using var backgroundPath = RoundedRectangle(
            new RectangleF(inset, inset, size - inset * 2, size - inset * 2),
            size * 0.2f);
        graphics.FillPath(background, backgroundPath);

        var left = size * 0.25f;
        var top = size * 0.17f;
        var width = size * 0.5f;
        var height = size * 0.66f;
        var foldSize = size * 0.16f;
        var page = new PointF[]
        {
            new(left, top),
            new(left + width - foldSize, top),
            new(left + width, top + foldSize),
            new(left + width, top + height),
            new(left, top + height),
        };
        graphics.FillPolygon(paper, page);
        graphics.FillPolygon(fold, new PointF[]
        {
            new(left + width - foldSize, top),
            new(left + width - foldSize, top + foldSize),
            new(left + width, top + foldSize),
        });
        for (var line = 0; line < 3; line++)
        {
            var y = top + foldSize + size * (0.12f + line * 0.13f);
            graphics.DrawLine(ink, left + size * 0.1f, y, left + width - size * 0.1f, y);
        }

        var handle = bitmap.GetHicon();
        try
        {
            return (Icon)Icon.FromHandle(handle).Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    private static GraphicsPath RoundedRectangle(RectangleF bounds, float radius)
    {
        var diameter = radius * 2;
        var path = new GraphicsPath();
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr handle);
}