using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace PaperGIF.Windows.Host;

internal enum WindowBackdrop
{
    Mica = 2,
    Acrylic = 3,
}

// Windows 11 chrome: dark caption, rounded corners, and a translucent Mica or Acrylic system backdrop.
internal static class FluentWindow
{
    private const int ImmersiveDarkModeAttribute = 20;
    private const int SystemBackdropTypeAttribute = 38;

    public static void Apply(Form form, WindowBackdrop backdrop, bool ambientCanvas = false)
    {
        form.BackColor = EditorTheme.Canvas;
        form.ForeColor = EditorTheme.Ink;
        form.Font = EditorTheme.BodyFont;
        form.FormCornerPreference = FormCornerPreference.Round;
        form.HandleCreated += (_, _) => ApplyBackdrop(form, backdrop);
        if (form.IsHandleCreated)
        {
            ApplyBackdrop(form, backdrop);
        }
        if (ambientCanvas)
        {
            _ = new AmbientCanvas(form);
        }
    }

    private static void ApplyBackdrop(Form form, WindowBackdrop backdrop)
    {
        var enabled = 1;
        var type = (int)backdrop;
        // Older Windows builds ignore unknown attributes, keeping the solid dark frame.
        _ = DwmSetWindowAttribute(form.Handle, ImmersiveDarkModeAttribute, ref enabled, sizeof(int));
        _ = DwmSetWindowAttribute(form.Handle, SystemBackdropTypeAttribute, ref type, sizeof(int));
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(nint window, int attribute, ref int value, int size);

    // Soft accent-tinted glow behind translucent panels, cached because every glass child repaints it.
    private sealed class AmbientCanvas
    {
        private readonly Form form;
        private Bitmap? cache;
        private Color accent;

        public AmbientCanvas(Form form)
        {
            this.form = form;
            accent = ReadAccent();
            form.Paint += HandlePaint;
            form.Resize += HandleResize;
            Application.SystemVisualSettingsChanged += HandleSystemVisualSettingsChanged;
            form.Disposed += (_, _) =>
            {
                Application.SystemVisualSettingsChanged -= HandleSystemVisualSettingsChanged;
                cache?.Dispose();
            };
        }

        private static Color ReadAccent()
        {
            var color = Application.SystemVisualSettings.AccentColor;
            return color.IsEmpty || color.A == 0 ? EditorTheme.ForestText : color;
        }

        private void HandleSystemVisualSettingsChanged(object? sender, SystemVisualSettingsChangedEventArgs eventArgs)
        {
            if ((eventArgs.Changed & SystemVisualSettingsCategories.AccentColor) == 0)
            {
                return;
            }
            accent = ReadAccent();
            Reset();
        }

        private void HandleResize(object? sender, EventArgs eventArgs) => Reset();

        private void Reset()
        {
            cache?.Dispose();
            cache = null;
            form.Invalidate(true);
        }

        private void HandlePaint(object? sender, PaintEventArgs eventArgs)
        {
            var size = form.ClientSize;
            if (size.Width <= 0 || size.Height <= 0)
            {
                return;
            }
            cache ??= Render(size, accent);
            eventArgs.Graphics.DrawImageUnscaled(cache, 0, 0);
        }

        private static Bitmap Render(Size size, Color accent)
        {
            var bitmap = new Bitmap(size.Width, size.Height);
            using var graphics = Graphics.FromImage(bitmap);
            graphics.Clear(EditorTheme.Canvas);
            Glow(graphics, new RectangleF(-size.Width * 0.25f, -size.Height * 0.55f, size.Width * 0.95f, size.Height * 1.15f), accent, 96);
            Glow(graphics, new RectangleF(size.Width * 0.45f, size.Height * 0.35f, size.Width * 0.9f, size.Height * 1.0f), EditorTheme.Forest, 84);
            return bitmap;
        }

        private static void Glow(Graphics graphics, RectangleF bounds, Color color, int alpha)
        {
            using var path = new GraphicsPath();
            path.AddEllipse(bounds);
            using var brush = new PathGradientBrush(path)
            {
                CenterColor = Color.FromArgb(alpha, color),
                SurroundColors = [Color.FromArgb(0, color)],
            };
            graphics.FillPath(brush, path);
        }
    }
}
