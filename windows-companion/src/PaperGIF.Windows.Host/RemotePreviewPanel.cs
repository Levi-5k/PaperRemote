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
        var grid = new Rectangle(
            screen.Left + 10,
            screen.Top + headerHeight,
            screen.Width - 20,
            screen.Height - headerHeight - footerHeight);
        gridFrame = grid;
        DrawControls(graphics, grid, page.Controls);
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
            ? control.TextBox?.SourceText ?? control.Title
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