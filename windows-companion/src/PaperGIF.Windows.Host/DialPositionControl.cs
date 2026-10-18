using System.Drawing.Drawing2D;
using System.Globalization;
using System.Text.Json;
using PaperGIF.Windows.Core;
using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Host;

internal sealed class DialPositionControl : Control
{
    private DeviceControlSnapshot snapshot = DeviceControlSnapshot.Empty;
    private string? dragging;
    private double? draft;
    public event Action<string, double>? LimitChanged;

    public DialPositionControl()
    {
        DoubleBuffered = true;
        Height = 280;
        ForeColor = EditorTheme.Ink;
        BackColor = EditorTheme.Layer;
        AccessibleName = "Live dial position and draggable single-turn soft stops";
    }

    public static bool Supports(IReadOnlyList<DeviceControl> controls) =>
        new[] { "dialPosition", "dialMode", "dialStart", "dialSweep", "dialTurns" }
            .All(id => controls.Any(control => control.Id == id));

    public void UpdateSnapshot(DeviceControlSnapshot value)
    {
        snapshot = value;
        AccessibleDescription = $"{Number("dialPosition"):F2} degrees";
        Invalidate();
    }

    private double Number(string id, double fallback = 0) =>
        snapshot.Values.TryGetValue(id, out var value) && value.ValueKind == JsonValueKind.Number
            ? value.GetDouble() : fallback;
    private bool Flag(string id) =>
        snapshot.Values.TryGetValue(id, out var value) && value.ValueKind == JsonValueKind.True;
    private string Mode => snapshot.Values.TryGetValue("dialMode", out var value) && value.ValueKind == JsonValueKind.String
        ? value.GetString() ?? "single" : "single";
    private double Start => dragging == "dialStart" ? draft ?? Number("dialStart") : Number("dialStart");
    private double Sweep => dragging == "dialSweep" ? draft ?? Number("dialSweep", 360) : Number("dialSweep", 360);
    private double Turns => Number("dialTurns", 3);
    private bool CounterClockwise => (Mode == "single" ? Sweep : Turns) < 0;
    private double Direction => CounterClockwise ? -1 : 1;
    private PointF Center => new(ClientSize.Width / 2f, 102);
    private float Radius => Math.Min(75, Math.Max(30, ClientSize.Width / 2f - 25));
    private PointF At(double angle, float radius)
    {
        var radians = (angle - 90) * Math.PI / 180;
        return new PointF(Center.X + (float)Math.Cos(radians) * radius, Center.Y + (float)Math.Sin(radians) * radius);
    }
    private RectangleF Ring => new(Center.X - Radius, Center.Y - Radius, Radius * 2, Radius * 2);

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var graphics = e.Graphics;
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var track = new Pen(EditorTheme.Muted, 8);
        graphics.DrawEllipse(track, Ring);
        var position = Number("dialPosition");
        if (Mode == "single")
        {
            using var arc = new Pen(Color.SteelBlue, 8);
            graphics.DrawArc(arc, Ring, (float)(Start - 90), (float)Sweep);
            DrawStop(graphics, At(Start, Radius - 10), Color.SeaGreen, "Start");
            DrawStop(graphics, At(Start + Sweep, Radius + 10), Color.DarkOrange, "End");
        }
        else
        {
            DrawStop(graphics, At(Start, Radius - 10), Color.SeaGreen, "Start");
            if (Mode == "multi")
                DrawStop(graphics, At(Start + Turns * 360, Radius + 10), Color.DarkOrange,
                    $"End {Math.Abs(Turns).ToString("0.#", CultureInfo.CurrentCulture)} rev");
        }
        using var needle = new Pen(Flag("dialPresent") ? ForeColor : EditorTheme.Muted, 4);
        graphics.DrawLine(needle, Center, At(Number("dialAngle", Start + Direction * position), Radius - 16));
        var text = Flag("dialPresent")
            ? $"{position.ToString("F2", CultureInfo.CurrentCulture)} deg   |   {(position / 360).ToString("F2", CultureInfo.CurrentCulture)} rev"
            : "Dial sensor unavailable - check magnet and wiring";
        TextRenderer.DrawText(graphics, text, EditorTheme.StrongFont,
            new Rectangle(0, 202, Width, 24), ForeColor, TextFormatFlags.HorizontalCenter);
        var span = Math.Abs(Mode == "single" ? Sweep : Turns * 360);
        if (Mode != "continuous")
        {
            using var fill = new SolidBrush(Color.SteelBlue);
            graphics.FillRectangle(fill, 12, 234, Math.Max(1, Width - 24) * (float)Math.Clamp(position / span, 0, 1), 5);
        }
        TextRenderer.DrawText(graphics, Mode == "continuous" ? "Continuous - no soft stops"
                : $"Soft stops: 0 to {span.ToString("G", CultureInfo.CurrentCulture)} deg {(CounterClockwise ? "counterclockwise" : "clockwise")}",
            EditorTheme.BodyFont, new Rectangle(0, 250, Width, 24), EditorTheme.Muted, TextFormatFlags.HorizontalCenter);
    }

    private void DrawStop(Graphics graphics, PointF point, Color color, string label)
    {
        using var brush = new SolidBrush(color);
        graphics.FillEllipse(brush, point.X - 8, point.Y - 8, 16, 16);
        TextRenderer.DrawText(graphics, label, EditorTheme.BodyFont,
            new Point((int)point.X + 9, (int)point.Y - 8), color);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left || Mode != "single" || !snapshot.Values.ContainsKey("dialStart")) return;
        static double Distance(PointF a, PointF b) => Math.Pow(a.X - b.X, 2) + Math.Pow(a.Y - b.Y, 2);
        var startDistance = Distance(e.Location, At(Start, Radius - 10));
        var endDistance = Distance(e.Location, At(Start + Sweep, Radius + 10));
        if (Math.Min(startDistance, endDistance) > 24 * 24) return;
        dragging = startDistance < endDistance ? "dialStart" : "dialSweep";
        Capture = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (dragging is null) return;
        var angle = (Math.Atan2(e.X - Center.X, Center.Y - e.Y) * 180 / Math.PI + 360) % 360;
        draft = dragging == "dialStart" ? Math.Min(359.9, angle)
            : DialGeometry.SignedTravel(angle, Start, Number("dialSweep", 360));
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        var id = dragging;
        var value = draft;
        dragging = null;
        draft = null;
        Capture = false;
        if (id is not null && value.HasValue) LimitChanged?.Invoke(id, value.Value);
        Invalidate();
    }
}
