using System.Drawing.Drawing2D;

namespace PaperGIF.Windows.Host;

internal static class EditorTheme
{
    public static readonly Color Ink = Color.FromArgb(236, 240, 238);
    public static readonly Color Muted = Color.FromArgb(156, 166, 161);
    public static readonly Color Canvas = Color.FromArgb(17, 19, 21);
    public static readonly Color Layer = Color.FromArgb(29, 32, 35);
    public static readonly Color Surface = Color.FromArgb(38, 42, 46);
    public static readonly Color SurfaceMuted = Layer;
    public static readonly Color SurfaceHover = Color.FromArgb(52, 57, 62);
    public static readonly Color SurfacePressed = Color.FromArgb(62, 68, 74);
    public static readonly Color Border = Color.FromArgb(60, 66, 72);
    public static readonly Color Forest = Color.FromArgb(33, 128, 88);
    public static readonly Color ForestHover = Color.FromArgb(42, 146, 103);
    public static readonly Color ForestPressed = Color.FromArgb(28, 108, 75);
    public static readonly Color ForestText = Color.FromArgb(112, 214, 165);
    public static readonly Color ForestSoft = Color.FromArgb(31, 61, 49);
    public static readonly Color Coral = Color.FromArgb(240, 132, 104);
    public static readonly Color CoralSoft = Color.FromArgb(70, 240, 132, 104);

    // Translucent layers composite over the window's ambient backdrop.
    public static readonly Color Glass = Color.FromArgb(100, 26, 29, 33);
    // Disabled flat buttons drop the alpha channel, so the tint itself must already read as a dark surface.
    public static readonly Color GlassButton = Color.FromArgb(150, 58, 64, 70);
    public static readonly Color GlassEdge = Color.FromArgb(34, 255, 255, 255);
    public static readonly Color GlassChip = Color.FromArgb(48, 112, 214, 165);

    // The device preview stays e-paper colored regardless of the app theme.
    public static readonly Color Paper = Color.White;
    public static readonly Color PaperControl = Color.FromArgb(246, 248, 245);
    public static readonly Color PaperSelected = Color.FromArgb(220, 238, 229);
    public static readonly Color PaperAccent = Color.FromArgb(30, 111, 83);

    public static readonly Font BodyFont = new("Segoe UI Variable Text", 9F);
    public static readonly Font StrongFont = new("Segoe UI Variable Text Semibold", 9F);
    // Segoe Fluent Icons ships with Windows 11; Windows 10 has the same code points in MDL2 Assets.
    public static readonly Font IconFont = new(
        FontFamily.Families.Any(family => family.Name == "Segoe Fluent Icons") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets",
        9F);

    // Must run before the first window is created.
    public static void ConfigureApplication()
    {
        Application.SetColorMode(SystemColorMode.Dark);
        Application.SetDefaultVisualStylesMode(VisualStylesMode.Net11);
        Application.SetDefaultFormRevealMode(FormRevealMode.Deferred);
    }

    public static void StyleButton(Button button, bool prominent = false)
    {
        button.FlatStyle = FlatStyle.Flat;
        button.UseVisualStyleBackColor = false;
        button.BackColor = prominent ? Forest : GlassButton;
        button.ForeColor = prominent ? Color.White : Ink;
        button.Font = prominent ? StrongFont : BodyFont;
        button.FlatAppearance.BorderSize = prominent ? 0 : 1;
        button.FlatAppearance.BorderColor = Border;
        button.FlatAppearance.MouseOverBackColor = prominent ? ForestHover : SurfaceHover;
        button.FlatAppearance.MouseDownBackColor = prominent ? ForestPressed : SurfacePressed;
        button.Cursor = Cursors.Hand;
    }

    public static void StyleInput(Control control)
    {
        switch (control)
        {
            case TextBox textBox:
                textBox.Font = BodyFont;
                textBox.ForeColor = Ink;
                textBox.BackColor = Surface;
                textBox.BorderStyle = BorderStyle.Fixed3D;
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
                break;
            case ListBox { DrawMode: DrawMode.Normal } listBox:
                listBox.ForeColor = Ink;
                listBox.BackColor = Surface;
                listBox.BorderStyle = BorderStyle.None;
                break;
            case PropertyGrid grid:
                grid.BackColor = Layer;
                grid.ViewBackColor = Surface;
                grid.ViewForeColor = Ink;
                grid.ViewBorderColor = Border;
                grid.LineColor = Layer;
                grid.CategoryForeColor = ForestText;
                grid.CategorySplitterColor = Layer;
                grid.HelpBackColor = Layer;
                grid.HelpForeColor = Muted;
                grid.HelpBorderColor = Border;
                grid.SelectedItemWithFocusBackColor = Forest;
                grid.SelectedItemWithFocusForeColor = Color.White;
                return;
            case TrackBar trackBar:
                trackBar.BackColor = Layer;
                break;
            // Stock buttons are too short for the Net11 renderer's padding and clip their text.
            case Button { FlatStyle: FlatStyle.Standard } button:
                StyleButton(button, prominent: button.DialogResult == DialogResult.OK);
                button.Height = Math.Max(button.Height, 28);
                break;
        }
        foreach (Control child in control.Controls)
        {
            StyleInput(child);
        }
    }

    // Dialogs built from stock controls get the same chrome, palette, and inputs as the editor.
    public static void StyleDialog(Form form)
    {
        FluentWindow.Apply(form, WindowBackdrop.Acrylic);
        StyleInput(form);
        if (form.Controls is [TableLayoutPanel { Dock: DockStyle.Fill } layout])
        {
            var needed = layout.GetPreferredSize(new Size(form.ClientSize.Width, 0)).Height;
            form.ClientSize = new Size(form.ClientSize.Width, Math.Max(form.ClientSize.Height, needed));
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
        ItemSize = new Size(96, 36);
        SizeMode = TabSizeMode.Fixed;
        // Paint the whole strip so the native light tab chrome never shows in dark mode.
        SetStyle(
            ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
            ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw,
            true);
    }

    protected override void OnPaintBackground(PaintEventArgs eventArgs)
    {
    }

    protected override void OnPaint(PaintEventArgs eventArgs)
    {
        var graphics = eventArgs.Graphics;
        using (var fill = new SolidBrush(EditorTheme.Layer))
        {
            graphics.FillRectangle(fill, ClientRectangle);
        }
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        for (var index = 0; index < TabCount; index++)
        {
            var selected = index == SelectedIndex;
            var bounds = Rectangle.Inflate(GetTabRect(index), -3, -5);
            if (selected)
            {
                using var pill = new SolidBrush(EditorTheme.GlassButton);
                EditorTheme.FillRoundedRectangle(graphics, pill, bounds, 6);
                using var accent = new SolidBrush(EditorTheme.ForestText);
                EditorTheme.FillRoundedRectangle(
                    graphics, accent, new Rectangle(bounds.Left + bounds.Width / 2 - 8, bounds.Bottom - 3, 16, 3), 1);
            }
            TextRenderer.DrawText(
                graphics,
                TabPages[index].Text,
                selected ? EditorTheme.StrongFont : EditorTheme.BodyFont,
                bounds,
                selected ? EditorTheme.Ink : EditorTheme.Muted,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        }
    }
}

// A rounded panel whose corners show its parent; a translucent Fill becomes a glass layer.
internal class CardPanel : Panel
{
    public CardPanel()
    {
        BackColor = Color.Transparent;
        DoubleBuffered = true;
        ResizeRedraw = true;
    }

    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public Color Fill { get; set { field = value; Invalidate(); } } = EditorTheme.Layer;

    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public Color Edge { get; set { field = value; Invalidate(); } } = EditorTheme.GlassEdge;

    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public int CornerRadius { get; set; } = 10;

    protected override void OnPaintBackground(PaintEventArgs eventArgs)
    {
        base.OnPaintBackground(eventArgs);
        var graphics = eventArgs.Graphics;
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        var bounds = new Rectangle(0, 0, Width - 1, Height - 1);
        using var fill = new SolidBrush(Fill);
        using var edge = new Pen(Edge);
        if (CornerRadius <= 0)
        {
            graphics.FillRectangle(fill, ClientRectangle);
            graphics.DrawLine(edge, 0, Height - 1, Width, Height - 1);
            return;
        }
        EditorTheme.FillRoundedRectangle(graphics, fill, bounds, CornerRadius);
        if (Edge.A > 0)
        {
            EditorTheme.DrawRoundedRectangle(graphics, edge, bounds, CornerRadius);
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
        var graphics = eventArgs.Graphics;
        using var background = new SolidBrush(BackColor);
        graphics.FillRectangle(background, eventArgs.Bounds);
        var pill = Rectangle.Inflate(eventArgs.Bounds, -6, -3);
        if (selected)
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using var highlight = new SolidBrush(EditorTheme.ForestSoft);
            EditorTheme.FillRoundedRectangle(graphics, highlight, pill, 6);
            using var accent = new SolidBrush(EditorTheme.ForestText);
            EditorTheme.FillRoundedRectangle(graphics, accent, new Rectangle(pill.Left, pill.Top + 10, 3, pill.Height - 20), 1);
        }
        var text = GetItemText(Items[eventArgs.Index]);
        TextRenderer.DrawText(
            graphics,
            text,
            selected ? EditorTheme.StrongFont : EditorTheme.BodyFont,
            Rectangle.Inflate(pill, -10, 0),
            selected ? EditorTheme.Ink : EditorTheme.Muted,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
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
        using (var background = new SolidBrush(BackColor))
        {
            eventArgs.Graphics.FillRectangle(background, eventArgs.Bounds);
        }
        eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        var selected = (eventArgs.State & DrawItemState.Selected) != 0;
        var row = Rectangle.Inflate(eventArgs.Bounds, -4, -4);
        using var fill = new SolidBrush(selected ? EditorTheme.ForestSoft : EditorTheme.Surface);
        using var outline = new Pen(selected ? EditorTheme.ForestText : EditorTheme.GlassEdge, selected ? 1.5f : 1);
        EditorTheme.FillRoundedRectangle(eventArgs.Graphics, fill, row, 8);
        EditorTheme.DrawRoundedRectangle(eventArgs.Graphics, outline, row, 8);

        var categoryColor = template.Category switch
        {
            "Playback" or "Volume" => EditorTheme.Coral,
            "Lighting" => Color.FromArgb(232, 184, 80),
            "Climate" => Color.FromArgb(84, 186, 210),
            "Automation" => Color.FromArgb(176, 146, 222),
            _ => EditorTheme.ForestText,
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