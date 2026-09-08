using System.Drawing.Drawing2D;
using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Host;

internal sealed class RemotePreviewPanel : Control
{
    private readonly Dictionary<Guid, Rectangle> controlFrames = [];
    private RemotePage? page;
    private Guid? draggedControlId;
    private Rectangle gridFrame;

    public RemotePreviewPanel()
    {
        DoubleBuffered = true;
        BackColor = EditorTheme.Canvas;
        Cursor = Cursors.Hand;
    }

    public RemotePage? Page
    {
        get => page;
        set
        {
            page = value;
            Invalidate();
        }
    }

    public Guid? SelectedControlId { get; set; }
    public int PageIndex { get; set; }
    public int PageCount { get; set; }
    public event EventHandler<Guid>? ControlSelected;
    public event EventHandler<ControlMoveEventArgs>? ControlMoved;

    protected override void OnMouseDown(MouseEventArgs eventArgs)
    {
        base.OnMouseDown(eventArgs);
        var match = controlFrames.FirstOrDefault(pair => pair.Value.Contains(eventArgs.Location));
        draggedControlId = match.Key == Guid.Empty ? null : match.Key;
    }

    protected override void OnMouseUp(MouseEventArgs eventArgs)
    {
        base.OnMouseUp(eventArgs);
        if (page?.Layout == RemotePageLayout.OpenBuildsController)
        {
            draggedControlId = null;
            return;
        }
        if (draggedControlId is not { } controlId || !gridFrame.Contains(eventArgs.Location))
        {
            draggedControlId = null;
            return;
        }
        var column = Math.Clamp((eventArgs.X - gridFrame.Left) * 2 / Math.Max(1, gridFrame.Width), 0, 1);
        var row = Math.Clamp((eventArgs.Y - gridFrame.Top) * 8 / Math.Max(1, gridFrame.Height), 0, 7);
        ControlMoved?.Invoke(this, new ControlMoveEventArgs(controlId, row * 2 + column));
        draggedControlId = null;
    }

    protected override void OnMouseClick(MouseEventArgs eventArgs)
    {
        base.OnMouseClick(eventArgs);
        var match = controlFrames.FirstOrDefault(pair => pair.Value.Contains(eventArgs.Location));
        if (match.Key != Guid.Empty)
        {
            ControlSelected?.Invoke(this, match.Key);
        }
    }

    protected override void OnPaint(PaintEventArgs eventArgs)
    {
        base.OnPaint(eventArgs);
        var graphics = eventArgs.Graphics;
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var pattern = new Pen(Color.FromArgb(225, 231, 226));
        for (var x = 16; x < Width; x += 24)
        {
            graphics.DrawLine(pattern, x, 0, x, Height);
        }
        for (var y = 16; y < Height; y += 24)
        {
            graphics.DrawLine(pattern, 0, y, Width, y);
        }
        var available = new Rectangle(24, 18, Math.Max(1, Width - 48), Math.Max(1, Height - 36));
        const float aspect = 540f / 960f;
        var screenHeight = available.Height;
        var screenWidth = (int)(screenHeight * aspect);
        if (screenWidth > available.Width)
        {
            screenWidth = available.Width;
            screenHeight = (int)(screenWidth / aspect);
        }
        var screen = new Rectangle(
            available.Left + (available.Width - screenWidth) / 2,
            available.Top + (available.Height - screenHeight) / 2,
            screenWidth,
            screenHeight);
        var shadowFrame = Rectangle.Inflate(screen, 7, 7);
        shadowFrame.Offset(0, 3);
        using var shadow = new SolidBrush(Color.FromArgb(28, 30, 42, 35));
        EditorTheme.FillRoundedRectangle(graphics, shadow, shadowFrame, 7);
        using var screenBrush = new SolidBrush(EditorTheme.Surface);
        EditorTheme.FillRoundedRectangle(graphics, screenBrush, screen, 6);
        using var border = new Pen(Color.FromArgb(53, 65, 59), 2);
        EditorTheme.DrawRoundedRectangle(graphics, border, screen, 6);

        var headerHeight = Math.Max(30, screen.Height / 15);
        var footerHeight = Math.Max(24, screen.Height / 18);
        using var headerFont = new Font("Segoe UI Variable Display Semibold", Math.Max(8, screen.Width / 32f));
        using var smallFont = new Font("Segoe UI Variable Text", Math.Max(7, screen.Width / 42f));
        graphics.DrawString(page?.Name ?? "Select a page", headerFont, Brushes.Black,
            new RectangleF(screen.Left + 12, screen.Top + 8, screen.Width - 24, headerHeight));
        graphics.DrawString(
            PageCount == 0 ? string.Empty : $"{PageIndex + 1} / {PageCount}",
            smallFont,
            Brushes.DimGray,
            new RectangleF(screen.Left + 12, screen.Bottom - footerHeight, screen.Width - 24, footerHeight));

        controlFrames.Clear();
        if (page is null)
        {
            return;
        }
        if (page.Layout == RemotePageLayout.OpenBuildsController)
        {
            gridFrame = Rectangle.Empty;
            DrawOpenBuildsController(graphics, screen, page);
            return;
        }
        var grid = new Rectangle(
            screen.Left + 10,
            screen.Top + headerHeight,
            screen.Width - 20,
            screen.Height - headerHeight - footerHeight);
        gridFrame = grid;
        DrawControls(graphics, grid, page.Controls);
    }

    private void DrawOpenBuildsController(Graphics graphics, Rectangle screen, RemotePage controllerPage)
    {
        foreach (var control in controllerPage.Controls.Take(16))
        {
            RectangleF? canonicalFrame = null;
            if (control.Kind == RemoteControlKind.TextBox &&
                control.TextBox?.Source == RemoteTextSource.OpenBuildsPosition)
            {
                var axis = control.TextBox.SourceText.Split('|').LastOrDefault()?.ToLowerInvariant();
                var column = axis switch { "x" => 0, "y" => 1, "z" => 2, _ => -1 };
                if (column >= 0)
                {
                    canonicalFrame = new RectangleF(24 + column * 168, 142, 156, 70);
                }
            }
            else if (control.Action.Type == RemoteActionType.OpenBuilds)
            {
                var direction = control.Action.Text
                    .Replace("continuousJog", string.Empty, StringComparison.Ordinal)
                    .Replace("jog", string.Empty, StringComparison.Ordinal);
                var position = direction switch
                {
                    "XNegativeYPositive" => (Row: 0, Column: 0),
                    "YPositive" => (Row: 0, Column: 1),
                    "XPositiveYPositive" => (Row: 0, Column: 2),
                    "XNegative" => (Row: 1, Column: 0),
                    "XPositive" => (Row: 1, Column: 2),
                    "XNegativeYNegative" => (Row: 2, Column: 0),
                    "YNegative" => (Row: 2, Column: 1),
                    "XPositiveYNegative" => (Row: 2, Column: 2),
                    _ => (Row: -1, Column: -1),
                };
                if (position.Row >= 0)
                {
                    canonicalFrame = new RectangleF(
                        24 + position.Column * 108, 246 + position.Row * 108, 96, 96);
                }
            }
            if (canonicalFrame is not { } canonical)
            {
                continue;
            }
            var frame = ScaleFrame(screen, canonical);
            controlFrames[control.Id] = frame;
            DrawControl(graphics, frame, control);
        }

        var settings = controllerPage.OpenBuildsController ?? new OpenBuildsControllerSettings();
        var rail = ScaleFrame(screen, new RectangleF(364, 232, 152, 430));
        using var labelFont = new Font("Segoe UI Variable Text Semibold", Math.Max(6, screen.Width / 55f));
        using var detailFont = new Font("Segoe UI Variable Text", Math.Max(6, screen.Width / 58f));
        graphics.DrawString("JOG SPEED", labelFont, Brushes.Black, rail.Left, rail.Top);
        var speedText = $"{settings.JogSpeed} mm/min";
        var speedSize = graphics.MeasureString(speedText, detailFont);
        graphics.DrawString(speedText, detailFont, Brushes.Black, rail.Right - speedSize.Width, rail.Top);

        var track = ScaleFrame(screen, new RectangleF(364, 278, 152, 42));
        using var trackOutline = new Pen(Color.Black, 1);
        EditorTheme.DrawRoundedRectangle(graphics, trackOutline, track, 5);
        var progress = Math.Clamp((settings.JogSpeed - 100) / 9900f, 0, 1);
        var fill = Rectangle.Inflate(track, -3, -3);
        fill.Width = Math.Max(2, (int)(fill.Width * progress));
        EditorTheme.FillRoundedRectangle(graphics, Brushes.Black, fill, 4);

        var modeLabel = ScaleFrame(screen, new RectangleF(364, 350, 152, 24));
        graphics.DrawString("JOG MODE", labelFont, Brushes.Black, modeLabel);
        DrawControllerChip(graphics, ScaleFrame(screen, new RectangleF(364, 382, 72, 48)),
            "STEP", settings.JogMode == RemoteJogMode.Incremental, detailFont);
        DrawControllerChip(graphics, ScaleFrame(screen, new RectangleF(444, 382, 72, 48)),
            "HOLD", settings.JogMode == RemoteJogMode.Continuous, detailFont);

        var distanceLabel = ScaleFrame(screen, new RectangleF(364, 458, 152, 24));
        graphics.DrawString(settings.JogMode == RemoteJogMode.Continuous
            ? "RELEASE TO STOP" : "STEP DISTANCE", labelFont, Brushes.Black, distanceLabel);
        if (settings.JogMode == RemoteJogMode.Continuous)
        {
            var help = ScaleFrame(screen, new RectangleF(364, 500, 152, 70));
            graphics.DrawString("Motion stops\nwhen released.", detailFont, Brushes.Black, help);
        }
        else
        {
            var distances = new[] { (1, "0.1"), (10, "1"), (100, "10"), (1000, "100") };
            for (var index = 0; index < distances.Length; index++)
            {
                var chip = ScaleFrame(screen, new RectangleF(
                    364 + index % 2 * 80, 490 + index / 2 * 60, 72, 48));
                DrawControllerChip(graphics, chip, distances[index].Item2,
                    settings.JogDistanceTenths == distances[index].Item1, detailFont);
            }
        }
    }

    private static Rectangle ScaleFrame(Rectangle screen, RectangleF frame) => Rectangle.Round(new RectangleF(
        screen.Left + frame.Left * screen.Width / 540f,
        screen.Top + frame.Top * screen.Height / 960f,
        frame.Width * screen.Width / 540f,
        frame.Height * screen.Height / 960f));

    private static void DrawControllerChip(
        Graphics graphics, Rectangle frame, string text, bool selected, Font font)
    {
        EditorTheme.FillRoundedRectangle(graphics, selected ? Brushes.Black : Brushes.White, frame, 4);
        using var outline = new Pen(Color.Black, 1);
        EditorTheme.DrawRoundedRectangle(graphics, outline, frame, 4);
        using var format = new StringFormat
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Center,
        };
        graphics.DrawString(text, font, selected ? Brushes.White : Brushes.Black, frame, format);
    }

    private void DrawControls(Graphics graphics, Rectangle grid, IReadOnlyList<RemoteControl> controls)
    {
        var occupied = new bool[16];
        foreach (var control in controls.Take(16))
        {
            var width = control.Kind == RemoteControlKind.TextBox
                ? Math.Clamp(control.TextBox?.GridWidth ?? 2, 1, 2)
                : 1;
            var height = control.Kind switch
            {
                RemoteControlKind.Slider => 1,
                RemoteControlKind.TextBox => Math.Clamp(control.TextBox?.GridHeight ?? 1, 1, 8),
                _ => Math.Clamp(control.ButtonHeight ?? 2, 1, 2),
            };
            var slot = FindSlot(control.LayoutSlot, width, height, occupied);
            if (slot < 0)
            {
                continue;
            }
            MarkOccupied(slot, width, height, occupied);
            var column = slot % 2;
            var row = slot / 2;
            var cellWidth = grid.Width / 2f;
            var cellHeight = grid.Height / 8f;
            var frame = Rectangle.Round(new RectangleF(
                grid.Left + column * cellWidth + 4,
                grid.Top + row * cellHeight + 4,
                cellWidth * width - 8,
                cellHeight * height - 8));
            controlFrames[control.Id] = frame;
            DrawControl(graphics, frame, control);
        }
    }

    private void DrawControl(Graphics graphics, Rectangle frame, RemoteControl control)
    {
        var selected = control.Id == SelectedControlId;
        using var fill = new SolidBrush(selected ? EditorTheme.ForestSoft : Color.FromArgb(246, 248, 245));
        using var outline = new Pen(selected ? EditorTheme.Forest : Color.FromArgb(157, 168, 162), selected ? 2 : 1);
        EditorTheme.FillRoundedRectangle(graphics, fill, frame, 5);
        EditorTheme.DrawRoundedRectangle(graphics, outline, frame, 5);
        if (selected)
        {
            using var accent = new SolidBrush(EditorTheme.Coral);
            graphics.FillRectangle(accent, frame.Left + 7, frame.Top + 7, 3, Math.Max(4, frame.Height - 14));
        }
        using var titleFont = new Font("Segoe UI Variable Text Semibold", Math.Max(7, frame.Width / 15f));
        using var valueFont = new Font("Segoe UI Variable Text", Math.Max(6, frame.Width / 21f));
        var format = new StringFormat
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Center,
            Trimming = StringTrimming.EllipsisCharacter,
        };
        var text = control.Kind == RemoteControlKind.TextBox
            ? control.TextBox?.Source == RemoteTextSource.OpenBuildsPosition
                ? $"{control.TextBox.SourceText.Split('|').LastOrDefault()?.ToUpperInvariant() ?? "X"} 0.000"
                : control.TextBox?.SourceText ?? control.Title
            : control.Title;
        graphics.DrawString(text, titleFont, Brushes.Black, RectangleF.Inflate(frame, -7, -7), format);
        if (control.Kind == RemoteControlKind.Slider)
        {
            var trackY = frame.Bottom - Math.Max(8, frame.Height / 4);
            graphics.DrawLine(Pens.DimGray, frame.Left + 10, trackY, frame.Right - 10, trackY);
            var thumbX = frame.Left + 10 + (frame.Width - 20) * Math.Clamp(control.Action.Value, 0, 255) / 255;
            graphics.FillEllipse(Brushes.Black, thumbX - 4, trackY - 4, 8, 8);
            graphics.DrawString(control.Action.Value.ToString(), valueFont, Brushes.DimGray, frame.Left + 5, frame.Top + 4);
        }
    }

    private static int FindSlot(int? preferred, int width, int height, bool[] occupied)
    {
        if (preferred is >= 0 and < 16 && Fits(preferred.Value, width, height, occupied))
        {
            return preferred.Value;
        }
        for (var slot = 0; slot < 16; slot++)
        {
            if (Fits(slot, width, height, occupied))
            {
                return slot;
            }
        }
        return -1;
    }

    private static bool Fits(int slot, int width, int height, bool[] occupied)
    {
        var column = slot % 2;
        var row = slot / 2;
        if (column + width > 2 || row + height > 8)
        {
            return false;
        }
        for (var y = row; y < row + height; y++)
        {
            for (var x = column; x < column + width; x++)
            {
                if (occupied[y * 2 + x])
                {
                    return false;
                }
            }
        }
        return true;
    }

    private static void MarkOccupied(int slot, int width, int height, bool[] occupied)
    {
        var column = slot % 2;
        var row = slot / 2;
        for (var y = row; y < row + height; y++)
        {
            for (var x = column; x < column + width; x++)
            {
                occupied[y * 2 + x] = true;
            }
        }
    }
}

internal sealed record ControlMoveEventArgs(Guid ControlId, int Slot);