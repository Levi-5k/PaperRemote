using System.ComponentModel;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Host;

internal sealed class RemotePreviewPanel : Control
{
    private readonly Dictionary<Guid, Rectangle> controlFrames = [];
    private readonly Dictionary<Guid, int> controlSlots = [];
    private RemotePage? page;
    private Guid? draggedControlId;
    private int? draggedSourceSlot;
    private bool draggingSettings;
    private Rectangle settingsFrame;
    private int settingsSlot = -1;
    private Point dragStart;
    private Rectangle gridFrame;
    private int maxButtonTextSize = RemoteProfile.MaximumButtonTextSize;

    public RemotePreviewPanel()
    {
        DoubleBuffered = true;
        SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.ResizeRedraw, true);
        BackColor = Color.Transparent;
        Cursor = Cursors.Hand;
    }

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public RemotePage? Page
    {
        get => page;
        set
        {
            page = value;
            Invalidate();
        }
    }

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Guid? SelectedControlId { get; set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public int MaxButtonTextSize
    {
        get => maxButtonTextSize;
        set
        {
            maxButtonTextSize = Math.Clamp(value,
                RemoteProfile.MinimumButtonTextSize, RemoteProfile.MaximumButtonTextSize);
            Invalidate();
        }
    }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public int PageIndex { get; set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public IReadOnlyList<string> PageNames { get; set; } = [];
    public event EventHandler<Guid>? ControlSelected;
    public event EventHandler<ControlMoveEventArgs>? ControlMoved;
    public event EventHandler<int>? SettingsMoved;

    protected override void OnMouseDown(MouseEventArgs eventArgs)
    {
        base.OnMouseDown(eventArgs);
        var match = controlFrames.FirstOrDefault(pair => pair.Value.Contains(eventArgs.Location));
        draggedControlId = match.Key == Guid.Empty ? null : match.Key;
        draggedSourceSlot = draggedControlId is { } controlId && controlSlots.TryGetValue(controlId, out var slot)
            ? slot
            : null;
        draggingSettings = draggedControlId is null && settingsSlot >= 0 &&
            settingsFrame.Contains(eventArgs.Location);
        if (draggingSettings)
        {
            draggedSourceSlot = settingsSlot;
        }
        dragStart = eventArgs.Location;
    }

    protected override void OnMouseUp(MouseEventArgs eventArgs)
    {
        base.OnMouseUp(eventArgs);
        if ((draggedControlId is null && !draggingSettings) || draggedSourceSlot is not { } sourceSlot)
        {
            draggedControlId = null;
            draggedSourceSlot = null;
            draggingSettings = false;
            return;
        }
        var columns = Math.Clamp(page?.GridColumns ?? 2, 1, 12);
        var rows = Math.Clamp(page?.GridRows ?? 8, 1, 16);
        var columnOffset = (int)Math.Round(
            (eventArgs.X - dragStart.X) * columns / (double)Math.Max(1, gridFrame.Width),
            MidpointRounding.AwayFromZero);
        var rowOffset = (int)Math.Round(
            (eventArgs.Y - dragStart.Y) * rows / (double)Math.Max(1, gridFrame.Height),
            MidpointRounding.AwayFromZero);
        var column = sourceSlot % columns + columnOffset;
        var row = sourceSlot / columns + rowOffset;
        if (column >= 0 && column < columns && row >= 0 && row < rows)
        {
            if (draggingSettings)
            {
                SettingsMoved?.Invoke(this, row * columns + column);
            }
            else if (draggedControlId is { } controlId)
            {
                ControlMoved?.Invoke(this, new ControlMoveEventArgs(controlId, row * columns + column));
            }
        }
        draggedControlId = null;
        draggedSourceSlot = null;
        draggingSettings = false;
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
        using var pattern = new SolidBrush(Color.FromArgb(26, 255, 255, 255));
        for (var x = 16; x < Width; x += 24)
        {
            for (var y = 16; y < Height; y += 24)
            {
                graphics.FillEllipse(pattern, x - 1, y - 1, 2.5f, 2.5f);
            }
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
        var shadowFrame = Rectangle.Inflate(screen, 9, 9);
        shadowFrame.Offset(0, 6);
        using var shadow = new SolidBrush(Color.FromArgb(110, 0, 0, 0));
        EditorTheme.FillRoundedRectangle(graphics, shadow, shadowFrame, 10);
        using var screenBrush = new SolidBrush(EditorTheme.Paper);
        EditorTheme.FillRoundedRectangle(graphics, screenBrush, screen, 6);
        using var border = new Pen(Color.FromArgb(53, 65, 59), 2);
        EditorTheme.DrawRoundedRectangle(graphics, border, screen, 6);

        var headerHeight = Math.Max(30, screen.Height / 15);
        var footerHeight = Math.Max(24, screen.Height / 18);
        using var headerFont = new Font("Segoe UI Variable Display Semibold", Math.Max(8, screen.Width / 32f));
        graphics.DrawString(page?.Name ?? "Select a page", headerFont, Brushes.Black,
            new RectangleF(screen.Left + 12, screen.Top + 8, screen.Width - 24, headerHeight));
        DrawPageTabs(graphics, screen);

        controlFrames.Clear();
        controlSlots.Clear();
        settingsSlot = -1;
        if (page is null)
        {
            return;
        }
        if (page.Layout == RemotePageLayout.OpenBuildsController)
        {
            gridFrame = ScaleFrame(screen, new RectangleF(24, 142, 504, 712));
            DrawOpenBuildsController(graphics, screen, page);
            return;
        }
        var grid = new Rectangle(
            screen.Left + 10,
            screen.Top + headerHeight,
            screen.Width - 20,
            screen.Height - headerHeight - footerHeight);
        gridFrame = grid;
        DrawControls(graphics, grid, page, screen.Width / 540f);
    }

    private void DrawPageTabs(Graphics graphics, Rectangle screen)
    {
        if (PageNames.Count == 0)
        {
            return;
        }
        using var font = new Font("Segoe UI Variable Text Semibold", Math.Max(6, screen.Width / 49f));
        using var outline = new Pen(Color.Black, Math.Max(1, screen.Width / 540f));
        using var centered = new StringFormat
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Center,
            Trimming = StringTrimming.EllipsisWord,
            FormatFlags = StringFormatFlags.LineLimit,
        };
        for (var index = 0; index < PageNames.Count; index++)
        {
            var left = 24f + index * 492f / PageNames.Count;
            var right = 24f + (index + 1) * 492f / PageNames.Count;
            var top = index == PageIndex ? 850 : 858;
            var frame = ScaleFrame(screen, new RectangleF(left, top, right - left, 918 - top));
            EditorTheme.FillRoundedRectangle(
                graphics, index == PageIndex ? Brushes.Black : Brushes.White, frame, 4);
            EditorTheme.DrawRoundedRectangle(graphics, outline, frame, 4);
            graphics.DrawString(
                PageNames[index], font, index == PageIndex ? Brushes.White : Brushes.Black,
                Rectangle.Inflate(frame, -4, -2), centered);
        }
    }

    private void DrawOpenBuildsController(Graphics graphics, Rectangle screen, RemotePage controllerPage)
    {
        var columns = Math.Clamp(controllerPage.GridColumns, 1, 12);
        var rows = Math.Clamp(controllerPage.GridRows, 1, 16);
        var occupied = new bool[columns * rows];
        var block = RemoteEditorStore.OpenBuildsSettingsBlock(controllerPage);
        float ox = 364, oy = 292;
        if (block is { } settingsBlock && columns == controllerPage.GridColumns && rows == controllerPage.GridRows)
        {
            MarkOccupied(settingsBlock.Slot, settingsBlock.Width, settingsBlock.Height, occupied, columns);
            settingsSlot = settingsBlock.Slot;
            ox = 24 + settingsBlock.Slot % columns * 504f / columns;
            oy = 142 + settingsBlock.Slot / columns * 712f / rows;
            settingsFrame = ScaleFrame(screen, new RectangleF(ox, oy, 152, 430));
        }
        RectangleF At(float x, float y, float width, float height) => new(ox + x - 364, oy + y - 292, width, height);
        foreach (var control in controllerPage.Controls.Take(RemoteProfile.MaximumControlsPerPage))
        {
            var (width, height) = Span(control, columns, rows);
            var slot = FindSlot(control.LayoutSlot, width, height, occupied, columns, rows);
            if (slot < 0)
            {
                continue;
            }
            MarkOccupied(slot, width, height, occupied, columns);
            var column = slot % columns;
            var row = slot / columns;
            var canonical = new RectangleF(
                24 + column * 504f / columns,
                142 + row * 712f / rows,
                width * 504f / columns - 12,
                height * 712f / rows - 12);
            var frame = ScaleFrame(screen, canonical);
            controlFrames[control.Id] = frame;
            controlSlots[control.Id] = slot;
            DrawControl(graphics, frame, control, screen.Width / 540f);
        }

        var settings = controllerPage.OpenBuildsController ?? new OpenBuildsControllerSettings();
        var rail = ScaleFrame(screen, At(364, 292, 152, 430));
        using var labelFont = new Font("Segoe UI Variable Text Semibold", Math.Max(6, screen.Width / 55f));
        using var detailFont = new Font("Segoe UI Variable Text", Math.Max(6, screen.Width / 58f));
        graphics.DrawString("UNITS", labelFont, Brushes.Black, rail.Left, rail.Top);
        DrawControllerChip(graphics, ScaleFrame(screen, At(364, 326, 72, 42)),
            "MM", settings.Units == OpenBuildsUnits.Mm, detailFont);
        DrawControllerChip(graphics, ScaleFrame(screen, At(444, 326, 72, 42)),
            "IN", settings.Units == OpenBuildsUnits.In, detailFont);

        var speedLabel = ScaleFrame(screen, At(364, 386, 152, 24));
        graphics.DrawString("JOG SPEED", labelFont, Brushes.Black, speedLabel);
        var speedText = $"{settings.JogSpeed} {(settings.Units == OpenBuildsUnits.In ? "in" : "mm")}/min";
        var speedSize = graphics.MeasureString(speedText, detailFont);
        graphics.DrawString(speedText, detailFont, Brushes.Black, rail.Right - speedSize.Width, speedLabel.Top);

        var track = ScaleFrame(screen, At(364, 416, 152, 38));
        using var trackOutline = new Pen(Color.Black, 1);
        EditorTheme.DrawRoundedRectangle(graphics, trackOutline, track, 5);
        var minimumSpeed = settings.Units == OpenBuildsUnits.In ? 4 : 100;
        var maximumSpeed = settings.Units == OpenBuildsUnits.In ? 400 : 10_000;
        var progress = Math.Clamp(
            (settings.JogSpeed - minimumSpeed) / (float)(maximumSpeed - minimumSpeed), 0, 1);
        var fill = Rectangle.Inflate(track, -3, -3);
        fill.Width = Math.Max(2, (int)(fill.Width * progress));
        EditorTheme.FillRoundedRectangle(graphics, Brushes.Black, fill, 4);

        var modeLabel = ScaleFrame(screen, At(364, 474, 152, 24));
        graphics.DrawString("JOG MODE", labelFont, Brushes.Black, modeLabel);
        DrawControllerChip(graphics, ScaleFrame(screen, At(364, 502, 72, 42)),
            "STEP", settings.JogMode == RemoteJogMode.Incremental, detailFont);
        DrawControllerChip(graphics, ScaleFrame(screen, At(444, 502, 72, 42)),
            "HOLD", settings.JogMode == RemoteJogMode.Continuous, detailFont);

        var distanceLabel = ScaleFrame(screen, At(364, 568, 152, 24));
        graphics.DrawString(settings.JogMode == RemoteJogMode.Continuous
            ? "RELEASE TO STOP" : "STEP DISTANCE", labelFont, Brushes.Black, distanceLabel);
        if (settings.JogMode == RemoteJogMode.Continuous)
        {
            var help = ScaleFrame(screen, At(364, 612, 152, 70));
            graphics.DrawString("Motion stops\nwhen released.", detailFont, Brushes.Black, help);
        }
        else
        {
            var distances = settings.Units == OpenBuildsUnits.In
                ? new[] { (1, ".001"), (10, ".01"), (100, ".1"), (1_000, "1") }
                : new[] { (100, "0.1"), (1_000, "1"), (10_000, "10"), (100_000, "100") };
            for (var index = 0; index < distances.Length; index++)
            {
                var chip = ScaleFrame(screen, At(
                    364 + index % 2 * 80, 598 + index / 2 * 56, 72, 42));
                DrawControllerChip(graphics, chip, distances[index].Item2,
                    settings.JogDistanceThousandths == distances[index].Item1, detailFont);
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

    private void DrawControls(Graphics graphics, Rectangle grid, RemotePage remotePage, float screenScale)
    {
        var columns = Math.Clamp(remotePage.GridColumns, 1, 12);
        var rows = Math.Clamp(remotePage.GridRows, 1, 16);
        var occupied = new bool[columns * rows];
        foreach (var control in remotePage.Controls.Take(RemoteProfile.MaximumControlsPerPage))
        {
            var (width, height) = Span(control, columns, rows);
            var slot = FindSlot(control.LayoutSlot, width, height, occupied, columns, rows);
            if (slot < 0)
            {
                continue;
            }
            MarkOccupied(slot, width, height, occupied, columns);
            var column = slot % columns;
            var row = slot / columns;
            var cellWidth = grid.Width / (float)columns;
            var cellHeight = grid.Height / (float)rows;
            var frame = Rectangle.Round(new RectangleF(
                grid.Left + column * cellWidth + 4,
                grid.Top + row * cellHeight + 4,
                cellWidth * width - 8,
                cellHeight * height - 8));
            controlFrames[control.Id] = frame;
            controlSlots[control.Id] = slot;
            DrawControl(graphics, frame, control, screenScale);
        }
    }

    private void DrawControl(Graphics graphics, Rectangle frame, RemoteControl control, float screenScale)
    {
        if (frame.Width <= 0 || frame.Height <= 0 || screenScale <= 0)
        {
            return;
        }
        var selected = control.Id == SelectedControlId;
        using var fill = new SolidBrush(selected ? EditorTheme.PaperSelected : EditorTheme.PaperControl);
        using var outline = new Pen(selected ? EditorTheme.PaperAccent : Color.FromArgb(157, 168, 162), selected ? 2 : 1);
        EditorTheme.FillRoundedRectangle(graphics, fill, frame, 5);
        EditorTheme.DrawRoundedRectangle(graphics, outline, frame, 5);
        if (selected)
        {
            using var accent = new SolidBrush(EditorTheme.Coral);
            graphics.FillRectangle(accent, frame.Left + 7, frame.Top + 7, 3, Math.Max(4, frame.Height - 14));
        }
        if (control.Kind == RemoteControlKind.TextBox &&
            control.TextBox?.Source == RemoteTextSource.OpenBuildsPosition)
        {
            using var titleFont = new Font("Segoe UI Variable Text Semibold", Math.Max(7, frame.Width / 15f));
            using var valueFont = new Font("Segoe UI Variable Text", Math.Max(6, frame.Width / 21f));
            using var format = new StringFormat
            {
                Alignment = StringAlignment.Center,
                LineAlignment = StringAlignment.Center,
                Trimming = StringTrimming.EllipsisCharacter,
            };
            var components = control.TextBox.SourceText.Split('|');
            var axis = components.Length > 1 ? components[1].ToUpperInvariant() : "X";
            var units = components.Length > 2 ? components[2].ToLowerInvariant() : "mm";
            var content = RectangleF.Inflate(frame, -7, -7);
            var labelFrame = new RectangleF(content.Left, content.Top, content.Width, content.Height * 0.35f);
            var valueFrame = new RectangleF(
                content.Left, content.Top + content.Height * 0.28f,
                content.Width, content.Height * 0.72f);
            graphics.DrawString(axis, valueFont, Brushes.Black, labelFrame, format);
            graphics.DrawString($"0.000 {units}", titleFont, Brushes.Black, valueFrame, format);
            return;
        }
        var text = control.Kind == RemoteControlKind.TextBox
            ? control.TextBox?.SourceText ?? control.Title
            : control.Title;
        if (control.Kind == RemoteControlKind.Slider)
        {
            var progress = Math.Clamp(control.Action.Value, 0, 255) / 255f;
            var sliderFill = Rectangle.Inflate(
                frame,
                control.SliderOutlineInsetPixels.HasValue ? -1 : -3,
                control.SliderOutlineInsetPixels.HasValue ? -1 : -3);
            sliderFill.Width = Math.Max(1, (int)(sliderFill.Width * progress));
            EditorTheme.FillRoundedRectangle(graphics, Brushes.Black, sliderFill, 4);
            if (control.SliderOutlineInsetPixels is int outlineInset)
            {
                var inset = Math.Clamp(outlineInset, 1, Math.Max(1, Math.Min(frame.Width, frame.Height) / 2 - 2));
                var outlineFrame = Rectangle.Inflate(frame, -inset, -inset);
                EditorTheme.FillRoundedRectangle(graphics, Brushes.White, outlineFrame, Math.Max(2, 5 - inset / 2));
            }
            var lightText = !control.SliderOutlineInsetPixels.HasValue && progress >= 0.5f;
            var textBrush = lightText ? Brushes.White : Brushes.Black;
            var seekSlider = control.Action.Type == RemoteActionType.ComputerMedia && control.Action.Text == "seek";
            if (!seekSlider && HasIcon(control) && DeviceIconLayout(frame, screenScale, true) is { } sliderLayout)
            {
                DrawControlIcon(graphics, control, sliderLayout.Icon, lightText ? Color.White : Color.Black);
                using var sliderLabel = NativeButtonLabelLayout.Fit(
                    graphics, text, sliderLayout.Title, MaxButtonTextSize, screenScale);
                sliderLabel.Draw(graphics, textBrush);
                return;
            }
            var contentFrame = RectangleF.Inflate(frame, -10 * screenScale, -7 * screenScale);
            using var label = NativeButtonLabelLayout.Fit(
                graphics, text, contentFrame, MaxButtonTextSize, screenScale, wordOnlyWrap: !seekSlider);
            label.Draw(graphics, textBrush);
            return;
        }
        if (control.Kind == RemoteControlKind.Button && HasIcon(control) &&
            DeviceIconLayout(frame, screenScale, false) is { } layout)
        {
            DrawIconAndTitle(graphics, control, text, layout, screenScale);
            return;
        }
        using var title = NativeButtonLabelLayout.Fit(graphics, text,
            RectangleF.Inflate(frame, -7 * screenScale, -7 * screenScale), MaxButtonTextSize, screenScale,
            wordOnlyWrap: control.Kind == RemoteControlKind.Button);
        title.Draw(graphics, Brushes.Black);
    }

    internal readonly record struct IconLayout(
        RectangleF Content, RectangleF Icon, RectangleF Title, float Extent, float Gap, bool Horizontal);

    private static bool HasIcon(RemoteControl control) =>
        !string.IsNullOrEmpty(control.Symbol) || control.IconBitmap is not null;

    // Preserve device icon geometry/halo, but center Windows titles in the actual
    // remaining space rather than reserving a phantom second icon on the right.
    internal static IconLayout? DeviceIconLayout(Rectangle frame, float scale, bool forceHorizontal)
    {
        var width = (int)Math.Round(frame.Width / scale);
        var height = (int)Math.Round(frame.Height / scale);
        if (width <= 2 || height <= 2)
        {
            return null;
        }
        var padding = Math.Min(12, Math.Max(1, Math.Min(width, height) / 6));
        var contentWidth = width - padding * 2;
        var contentHeight = height - padding * 2;
        var horizontal = forceHorizontal || height <= width * 2 / 3;
        var gap = Math.Min(8, Math.Max(1, Math.Min(width, height) / 10));
        var extent = horizontal
            ? Math.Min(40, Math.Min(contentHeight, Math.Min(Math.Max(16, contentWidth / 4),
                (contentWidth - Math.Max(8, contentWidth / 3)) / 2 - gap)))
            : Math.Min(48, Math.Min(contentWidth, Math.Min(Math.Max(16, contentHeight / 3), contentHeight * 2 / 3)));
        if (extent < 16)
        {
            return null;
        }
        var iconSize = extent - 8;
        RectangleF Scaled(float x, float y, float w, float h) =>
            new(frame.Left + x * scale, frame.Top + y * scale, w * scale, h * scale);
        var content = Scaled(padding, padding, contentWidth, contentHeight);
        return horizontal
            ? new IconLayout(content,
                Scaled(padding + extent / 2 - iconSize / 2, height / 2 - iconSize / 2, iconSize, iconSize),
                Scaled(padding + extent + gap, padding, contentWidth - extent - gap, contentHeight),
                extent * scale, gap * scale, true)
            : new IconLayout(content,
                Scaled(width / 2 - iconSize / 2, padding + extent / 2 - iconSize / 2, iconSize, iconSize),
                Scaled(padding, padding + extent + gap, contentWidth, contentHeight - extent - gap),
                extent * scale, gap * scale, false);
    }

    private void DrawIconAndTitle(Graphics graphics, RemoteControl control, string text, IconLayout layout,
        float screenScale)
    {
        using var label = NativeButtonLabelLayout.Fit(graphics, text, layout.Title, MaxButtonTextSize, screenScale);
        if (layout.Horizontal)
        {
            DrawControlIcon(graphics, control, layout.Icon, Color.Black);
            label.Draw(graphics, Brushes.Black);
            return;
        }
        // Like the firmware, center the icon and measured title together as one group.
        var textHeight = text.Length == 0 ? 0 : Math.Min(layout.Title.Height, label.MeasuredSize.Height);
        var gap = textHeight > 0 ? layout.Gap : 0;
        var top = layout.Content.Top + (layout.Content.Height - layout.Extent - gap - textHeight) / 2;
        var icon = layout.Icon;
        icon.Y = top + layout.Extent / 2 - icon.Height / 2;
        DrawControlIcon(graphics, control, icon, Color.Black);
        var shift = top + layout.Extent + gap - label.TextBounds.Top;
        var shiftedTitle = layout.Title;
        shiftedTitle.Offset(0, shift);
        using var shifted = NativeButtonLabelLayout.Fit(graphics, text, shiftedTitle, MaxButtonTextSize, screenScale);
        shifted.Draw(graphics, Brushes.Black);
    }

    private static void DrawControlIcon(Graphics graphics, RemoteControl control, RectangleF bounds, Color color)
    {
        var state = graphics.Save();
        try
        {
            using var bitmap = DecodeIconBitmap(control.IconBitmap, color);
            if (bitmap is not null)
            {
                graphics.InterpolationMode = InterpolationMode.NearestNeighbor;
                graphics.PixelOffsetMode = PixelOffsetMode.Half;
                graphics.DrawImage(bitmap, bounds);
                return;
            }
            using var path = RemoteIconGlyphs.CreatePath(control.Symbol, bounds);
            if (path is null)
            {
                return;
            }
            using var brush = new SolidBrush(color);
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.FillPath(brush, path);
        }
        finally
        {
            graphics.Restore(state);
        }
    }

    // Same 1-bit, row-major, MSB-first hex mask the firmware accepts (32 or 64 pixels square).
    private static Bitmap? DecodeIconBitmap(string? hex, Color color)
    {
        var dimension = hex?.Length switch { 256 => 32, 1024 => 64, _ => 0 };
        if (hex is null || dimension == 0)
        {
            return null;
        }
        var bitmap = new Bitmap(dimension, dimension, PixelFormat.Format32bppArgb);
        for (var index = 0; index < hex.Length / 2; index++)
        {
            if (!byte.TryParse(hex.AsSpan(index * 2, 2), NumberStyles.HexNumber,
                    CultureInfo.InvariantCulture, out var value))
            {
                bitmap.Dispose();
                return null;
            }
            for (var bit = 0; bit < 8; bit++)
            {
                if ((value & (0x80 >> bit)) != 0)
                {
                    var pixel = index * 8 + bit;
                    bitmap.SetPixel(pixel % dimension, pixel / dimension, color);
                }
            }
        }
        return bitmap;
    }

    private static (int Width, int Height) Span(RemoteControl control, int columns, int rows)
    {
        var legacyWidth = control.Kind == RemoteControlKind.TextBox
            ? Math.Clamp(control.TextBox?.GridWidth ?? 2, 1, 2)
            : 1;
        var legacyHeight = control.Kind switch
        {
            RemoteControlKind.Slider => 1,
            RemoteControlKind.TextBox => Math.Clamp(control.TextBox?.GridHeight ?? 1, 1, 8),
            _ => Math.Clamp(control.ButtonHeight ?? 2, 1, 2),
        };
        return (
            Math.Clamp(control.GridWidth ?? legacyWidth, 1, columns),
            Math.Clamp(control.GridHeight ?? legacyHeight, 1, rows));
    }

    private static int FindSlot(
        int? preferred, int width, int height, bool[] occupied, int columns, int rows)
    {
        if (preferred is >= 0 && preferred < columns * rows &&
            Fits(preferred.Value, width, height, occupied, columns, rows))
        {
            return preferred.Value;
        }
        for (var slot = 0; slot < columns * rows; slot++)
        {
            if (Fits(slot, width, height, occupied, columns, rows))
            {
                return slot;
            }
        }
        return -1;
    }

    private static bool Fits(
        int slot, int width, int height, bool[] occupied, int columns, int rows)
    {
        var column = slot % columns;
        var row = slot / columns;
        if (column + width > columns || row + height > rows)
        {
            return false;
        }
        for (var y = row; y < row + height; y++)
        {
            for (var x = column; x < column + width; x++)
            {
                if (occupied[y * columns + x])
                {
                    return false;
                }
            }
        }
        return true;
    }

    private static void MarkOccupied(
        int slot, int width, int height, bool[] occupied, int columns)
    {
        var column = slot % columns;
        var row = slot / columns;
        for (var y = row; y < row + height; y++)
        {
            for (var x = column; x < column + width; x++)
            {
                occupied[y * columns + x] = true;
            }
        }
    }
}

internal sealed record ControlMoveEventArgs(Guid ControlId, int Slot);