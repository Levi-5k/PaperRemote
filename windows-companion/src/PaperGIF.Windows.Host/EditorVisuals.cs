using System.Drawing.Drawing2D;

namespace PaperGIF.Windows.Host;

internal static class EditorTheme
{
    public static readonly Color Ink = Color.FromArgb(29, 39, 35);
    public static readonly Color Muted = Color.FromArgb(98, 111, 104);
    public static readonly Color Canvas = Color.FromArgb(239, 242, 238);
    public static readonly Color Surface = Color.FromArgb(255, 255, 255);
    public static readonly Color SurfaceMuted = Color.FromArgb(247, 249, 246);
    public static readonly Color Border = Color.FromArgb(211, 219, 214);
    public static readonly Color Forest = Color.FromArgb(30, 111, 83);
    public static readonly Color ForestSoft = Color.FromArgb(220, 238, 229);
    public static readonly Color Coral = Color.FromArgb(205, 92, 65);
    public static readonly Font BodyFont = new("Segoe UI Variable Text", 9F);
    public static readonly Font StrongFont = new("Segoe UI Variable Text Semibold", 9F);

    public static void StyleInput(Control control)
    {
        switch (control)
        {
            case TextBox textBox:
                textBox.Font = BodyFont;
                textBox.ForeColor = Ink;
                textBox.BackColor = Surface;
                textBox.BorderStyle = BorderStyle.FixedSingle;
                break;
            case ComboBox comboBox:
                comboBox.Font = BodyFont;
                comboBox.ForeColor = Ink;
                comboBox.BackColor = Surface;
                comboBox.FlatStyle = FlatStyle.Flat;
                break;
            case NumericUpDown numeric:
                numeric.Font = BodyFont;
                numeric.ForeColor = Ink;
                numeric.BackColor = Surface;
                numeric.BorderStyle = BorderStyle.FixedSingle;
                break;
            case CheckBox checkBox:
                checkBox.Font = BodyFont;
                checkBox.ForeColor = Ink;
                checkBox.FlatStyle = FlatStyle.Flat;
                break;
        }
        foreach (Control child in control.Controls)
        {
            StyleInput(child);
        }
    }

    public static void DrawRoundedRectangle(Graphics graphics, Pen pen, Rectangle rectangle, int radius)
    {
        using var path = RoundedRectangle(rectangle, radius);
        graphics.DrawPath(pen, path);
    }

    public static void FillRoundedRectangle(Graphics graphics, Brush brush, Rectangle rectangle, int radius)
    {
        using var path = RoundedRectangle(rectangle, radius);
        graphics.FillPath(brush, path);
    }

    private static GraphicsPath RoundedRectangle(Rectangle rectangle, int radius)
    {
        var diameter = Math.Min(radius * 2, Math.Min(rectangle.Width, rectangle.Height));
        var path = new GraphicsPath();
        path.AddArc(rectangle.Left, rectangle.Top, diameter, diameter, 180, 90);
        path.AddArc(rectangle.Right - diameter, rectangle.Top, diameter, diameter, 270, 90);
        path.AddArc(rectangle.Right - diameter, rectangle.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rectangle.Left, rectangle.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}

internal sealed class ModernTabControl : TabControl
{
    public ModernTabControl()
    {
        DrawMode = TabDrawMode.OwnerDrawFixed;
        ItemSize = new Size(108, 38);
        SizeMode = TabSizeMode.Fixed;
        SetStyle(ControlStyles.OptimizedDoubleBuffer, true);
    }

    protected override void OnDrawItem(DrawItemEventArgs eventArgs)
    {
        var selected = eventArgs.Index == SelectedIndex;
        var bounds = GetTabRect(eventArgs.Index);
        using var background = new SolidBrush(EditorTheme.Surface);
        eventArgs.Graphics.FillRectangle(background, bounds);
        TextRenderer.DrawText(
            eventArgs.Graphics,
            TabPages[eventArgs.Index].Text,
            selected ? EditorTheme.StrongFont : EditorTheme.BodyFont,
            bounds,
            selected ? EditorTheme.Ink : EditorTheme.Muted,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        if (selected)
        {
            using var accent = new SolidBrush(EditorTheme.Forest);
            eventArgs.Graphics.FillRectangle(accent, bounds.Left + 12, bounds.Bottom - 3, bounds.Width - 24, 3);
        }
    }
}

internal sealed class PageListBox : ListBox
{
    public PageListBox()
    {
        DrawMode = DrawMode.OwnerDrawFixed;
        ItemHeight = 44;
        IntegralHeight = false;
        BorderStyle = BorderStyle.None;
    }

    protected override void OnDrawItem(DrawItemEventArgs eventArgs)
    {
        if (eventArgs.Index < 0)
        {
            return;
        }
        var selected = (eventArgs.State & DrawItemState.Selected) != 0;
        using var background = new SolidBrush(selected ? EditorTheme.ForestSoft : EditorTheme.SurfaceMuted);
        eventArgs.Graphics.FillRectangle(background, eventArgs.Bounds);
        if (selected)
        {
            using var accent = new SolidBrush(EditorTheme.Forest);
            eventArgs.Graphics.FillRectangle(accent, eventArgs.Bounds.Left, eventArgs.Bounds.Top + 7, 3, eventArgs.Bounds.Height - 14);
        }
        var text = GetItemText(Items[eventArgs.Index]);
        TextRenderer.DrawText(
            eventArgs.Graphics,
            text,
            selected ? EditorTheme.StrongFont : EditorTheme.BodyFont,
            Rectangle.Inflate(eventArgs.Bounds, -12, 0),
            EditorTheme.Ink,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        using var separator = new Pen(EditorTheme.Border);
        eventArgs.Graphics.DrawLine(separator, eventArgs.Bounds.Left + 12, eventArgs.Bounds.Bottom - 1, eventArgs.Bounds.Right - 8, eventArgs.Bounds.Bottom - 1);
    }
}

internal sealed class CatalogListBox : ListBox
{
    public CatalogListBox()
    {
        DrawMode = DrawMode.OwnerDrawFixed;
        ItemHeight = 66;
        IntegralHeight = false;
        BorderStyle = BorderStyle.None;
    }

    protected override void OnDrawItem(DrawItemEventArgs eventArgs)
    {
        if (eventArgs.Index < 0 || Items[eventArgs.Index] is not RemoteControlTemplate template)
        {
            return;
        }
        eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        var selected = (eventArgs.State & DrawItemState.Selected) != 0;
        var row = Rectangle.Inflate(eventArgs.Bounds, -4, -4);
        using var fill = new SolidBrush(selected ? EditorTheme.ForestSoft : EditorTheme.Surface);
        using var outline = new Pen(selected ? EditorTheme.Forest : EditorTheme.Border, selected ? 2 : 1);
        EditorTheme.FillRoundedRectangle(eventArgs.Graphics, fill, row, 6);
        EditorTheme.DrawRoundedRectangle(eventArgs.Graphics, outline, row, 6);

        var categoryColor = template.Category switch
        {
            "Playback" or "Volume" => EditorTheme.Coral,
            "Lighting" => Color.FromArgb(194, 143, 35),
            "Climate" => Color.FromArgb(31, 119, 138),
            "Automation" => Color.FromArgb(113, 83, 148),
            _ => EditorTheme.Forest,
        };
        using var categoryBrush = new SolidBrush(categoryColor);
        eventArgs.Graphics.FillRectangle(categoryBrush, row.Left, row.Top + 8, 3, row.Height - 16);
        TextRenderer.DrawText(
            eventArgs.Graphics,
            template.Title,
            EditorTheme.StrongFont,
            new Rectangle(row.Left + 14, row.Top + 9, row.Width - 100, 21),
            EditorTheme.Ink,
            TextFormatFlags.Left | TextFormatFlags.EndEllipsis);
        using var categoryFont = new Font("Segoe UI Variable Text Semibold", 7.5F);
        TextRenderer.DrawText(
            eventArgs.Graphics,
            template.Category.ToUpperInvariant(),
            categoryFont,
            new Rectangle(row.Right - 88, row.Top + 10, 76, 18),
            categoryColor,
            TextFormatFlags.Right | TextFormatFlags.EndEllipsis);
        TextRenderer.DrawText(
            eventArgs.Graphics,
            template.Detail,
            EditorTheme.BodyFont,
            new Rectangle(row.Left + 14, row.Top + 32, row.Width - 28, 22),
            EditorTheme.Muted,
            TextFormatFlags.Left | TextFormatFlags.EndEllipsis);
    }
}