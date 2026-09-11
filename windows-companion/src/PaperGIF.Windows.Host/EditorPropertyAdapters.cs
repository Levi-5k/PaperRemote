using System.ComponentModel;
using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Host;

internal sealed class ControlProperties(RemoteControl control, RemotePage page, RemoteEditorStore store)
{
    [Category("Appearance")]
    public string Title { get => control.Title; set { control.Title = value; store.Commit(); } }

    [Category("Appearance")]
    public string Symbol { get => control.Symbol; set { control.Symbol = value; store.Commit(); } }

    [Category("Appearance"), DisplayName("Tint (hex)")]
    public string TintHex { get => control.TintHex; set { control.TintHex = value; store.Commit(); } }

    [Category("Layout")]
    public RemoteControlKind Kind
    {
        get => control.Kind;
        set
        {
            control.Kind = value;
            control.TextBox = value == RemoteControlKind.TextBox
                ? control.TextBox ?? new RemoteTextBox()
                : null;
            store.Commit();
        }
    }

    [Category("Layout"), DisplayName("Toggle")]
    public bool IsToggle { get => control.IsToggle ?? false; set { control.IsToggle = value; store.Commit(); } }

    [Category("Layout"), DisplayName("Button height")]
    public int ButtonHeight { get => control.ButtonHeight ?? 2; set { control.ButtonHeight = Math.Clamp(value, 1, 2); store.Commit(); } }

    [Category("Layout"), DisplayName("Width (columns)")]
    public int ControlGridWidth
    {
        get => control.GridWidth ?? (control.Kind == RemoteControlKind.TextBox ? control.TextBox?.GridWidth ?? 2 : 1);
        set { control.GridWidth = Math.Clamp(value, 1, page.GridColumns); store.Commit(); }
    }

    [Category("Layout"), DisplayName("Height (rows)")]
    public int ControlGridHeight
    {
        get => control.GridHeight ?? (control.Kind switch
        {
            RemoteControlKind.Slider => 1,
            RemoteControlKind.TextBox => control.TextBox?.GridHeight ?? 1,
            _ => control.ButtonHeight ?? 2,
        });
        set { control.GridHeight = Math.Clamp(value, 1, page.GridRows); store.Commit(); }
    }

    [Category("Page grid"), DisplayName("Columns")]
    public int PageGridColumns
    {
        get => page.GridColumns;
        set { page.GridColumns = Math.Clamp(value, 1, 12); store.Commit(); }
    }

    [Category("Page grid"), DisplayName("Rows")]
    public int PageGridRows
    {
        get => page.GridRows;
        set { page.GridRows = Math.Clamp(value, 1, 16); store.Commit(); }
    }

    [Category("Layout"), DisplayName("Grid slot (-1 for automatic)")]
    public int LayoutSlot
    {
        get => control.LayoutSlot ?? -1;
        set { control.LayoutSlot = value < 0 ? null : Math.Clamp(value, 0, page.GridColumns * page.GridRows - 1); store.Commit(); }
    }

    [Category("Slider"), DisplayName("Outline")]
    public bool SliderOutlineEnabled
    {
        get => control.SliderOutlineInsetPixels.HasValue;
        set { control.SliderOutlineInsetPixels = value ? control.SliderOutlineInsetPixels ?? 3 : null; store.Commit(); }
    }

    [Category("Slider"), DisplayName("Outline inset (pixels)")]
    public int SliderOutlineInsetPixels
    {
        get => control.SliderOutlineInsetPixels ?? 3;
        set { control.SliderOutlineInsetPixels = Math.Clamp(value, 1, 32); store.Commit(); }
    }

    [Category("Action"), DisplayName("Type")]
    public RemoteActionType ActionType { get => control.Action.Type; set { control.Action.Type = value; store.Commit(); } }

    [Category("Action"), DisplayName("Computer ID")]
    public string ComputerID { get => control.Action.ComputerID ?? string.Empty; set { control.Action.ComputerID = EmptyToNull(value); store.Commit(); } }

    [Category("Action"), DisplayName("Target / command")]
    public string ActionText { get => control.Action.Text; set { control.Action.Text = value; store.Commit(); } }

    [Category("Action")]
    public string Host { get => control.Action.Host; set { control.Action.Host = value; store.Commit(); } }

    [Category("Action")]
    public int Value { get => control.Action.Value; set { control.Action.Value = value; store.Commit(); } }

    [Category("Action"), DisplayName("Value (tenths)")]
    public int ValueTenths
    {
        get => control.Action.ValueTenths ?? control.Action.Value * 10;
        set { control.Action.ValueTenths = value; store.Commit(); }
    }

    [Category("Climate"), DisplayName("Deadband (tenths C)")]
    public int DeadbandTenths
    {
        get => control.Action.DeadbandTenths ?? 10;
        set { control.Action.DeadbandTenths = Math.Clamp(value, 5, 30); store.Commit(); }
    }

    [Category("Climate"), DisplayName("Humidity assist (%)")]
    public int HumidityThreshold
    {
        get => control.Action.HumidityThreshold ?? 65;
        set { control.Action.HumidityThreshold = Math.Clamp(value, 40, 80); store.Commit(); }
    }

    [Category("Climate"), DisplayName("Minimum cycle (minutes)")]
    public int MinimumCycleMinutes
    {
        get => control.Action.MinimumCycleMinutes ?? 10;
        set { control.Action.MinimumCycleMinutes = Math.Clamp(value, 1, 30); store.Commit(); }
    }

    [Category("Action"), DisplayName("Modifiers (comma separated)")]
    public string Modifiers
    {
        get => string.Join(", ", control.Action.Modifiers);
        set
        {
            control.Action.Modifiers = value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();
            store.Commit();
        }
    }

    [Category("Schedule"), DisplayName("Enabled")]
    public bool ScheduleEnabled { get => control.Action.ScheduleEnabled ?? false; set { control.Action.ScheduleEnabled = value; store.Commit(); } }

    [Category("Schedule"), DisplayName("Hour")]
    public int ScheduleHour { get => control.Action.ScheduleHour ?? 8; set { control.Action.ScheduleHour = Math.Clamp(value, 0, 23); store.Commit(); } }

    [Category("Schedule"), DisplayName("Minute")]
    public int ScheduleMinute { get => control.Action.ScheduleMinute ?? 0; set { control.Action.ScheduleMinute = Math.Clamp(value, 0, 59); store.Commit(); } }

    [Category("Text Box"), DisplayName("Source")]
    public RemoteTextSource TextSource { get => TextBox.Source; set { TextBox.Source = value; store.Commit(); } }

    [Category("Text Box"), DisplayName("Text / source")]
    public string SourceText { get => TextBox.SourceText; set { TextBox.SourceText = value; store.Commit(); } }

    [Category("Text Box")]
    public string Placeholder { get => TextBox.Placeholder; set { TextBox.Placeholder = value; store.Commit(); } }

    [Category("Text Box"), DisplayName("Date format")]
    public string DateFormat { get => TextBox.DateFormat; set { TextBox.DateFormat = value; store.Commit(); } }

    [Category("Text Box"), DisplayName("Horizontal alignment")]
    public RemoteTextHorizontalAlignment HorizontalAlignment
    {
        get => TextBox.HorizontalAlignment;
        set { TextBox.HorizontalAlignment = value; store.Commit(); }
    }

    [Category("Text Box"), DisplayName("Vertical alignment")]
    public RemoteTextVerticalAlignment VerticalAlignment
    {
        get => TextBox.VerticalAlignment;
        set { TextBox.VerticalAlignment = value; store.Commit(); }
    }

    [Category("Text Box"), DisplayName("Tap behavior")]
    public RemoteTextTapBehavior TapBehavior
    {
        get => TextBox.TapBehavior;
        set { TextBox.TapBehavior = value; store.Commit(); }
    }

    [Category("Text Box"), DisplayName("Referenced control ID")]
    public string ReferencedControlID
    {
        get => TextBox.ReferencedControlID?.ToString() ?? string.Empty;
        set { TextBox.ReferencedControlID = Guid.TryParse(value, out var id) ? id : null; store.Commit(); }
    }

    [Category("Text Box"), DisplayName("Computer ID")]
    public string TextComputerID
    {
        get => TextBox.ComputerID?.ToString() ?? string.Empty;
        set { TextBox.ComputerID = Guid.TryParse(value, out var id) ? id : null; store.Commit(); }
    }

    [Category("Text Box"), DisplayName("Text size")]
    public RemoteTextSize TextSize { get => TextBox.TextSize; set { TextBox.TextSize = value; store.Commit(); } }

    [Category("Text Box"), DisplayName("Refresh seconds")]
    public int RefreshIntervalSeconds
    {
        get => TextBox.RefreshIntervalSeconds ?? 60;
        set { TextBox.RefreshIntervalSeconds = Math.Clamp(value, 5, 3600); store.Commit(); }
    }

    [Category("Text Box"), DisplayName("Automatic refresh")]
    public bool AutomaticRefresh
    {
        get => TextBox.RefreshIntervalSeconds is not null;
        set { TextBox.RefreshIntervalSeconds = value ? TextBox.RefreshIntervalSeconds ?? 60 : null; store.Commit(); }
    }

    private RemoteTextBox TextBox => control.TextBox ??= new RemoteTextBox();
    private static string? EmptyToNull(string value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}

internal sealed class ProfileProperties(RemoteEditorStore store)
{
    [Category("M5Paper Wi-Fi"), DisplayName("Network name")]
    public string WifiSSID { get => store.Profile.WifiSSID; set { store.Profile.WifiSSID = value; store.Commit(); } }

    [Category("M5Paper Wi-Fi"), DisplayName("Password"), PasswordPropertyText(true)]
    public string WifiPassword { get => store.Profile.WifiPassword; set { store.Profile.WifiPassword = value; store.Commit(); } }

    [Category("Display"), DisplayName("Screensaver delay (seconds)")]
    public int ScreensaverDelaySeconds
    {
        get => store.Profile.ScreensaverDelaySeconds;
        set { store.Profile.ScreensaverDelaySeconds = Math.Clamp(value, 10, 3600); store.Commit(); }
    }

    [Category("Display"), DisplayName("Quality refresh every N presses")]
    public int ButtonQualityRefreshInterval
    {
        get => store.Profile.ButtonQualityRefreshInterval;
        set { store.Profile.ButtonQualityRefreshInterval = Math.Clamp(value, 1, 100); store.Commit(); }
    }

    [Category("Display"), DisplayName("Element spacing (milliseconds)")]
    public int ElementRefreshDelayMilliseconds
    {
        get => store.Profile.ElementRefreshDelayMilliseconds;
        set { store.Profile.ElementRefreshDelayMilliseconds = Math.Clamp(value, 0, 500); store.Commit(); }
    }

    [Category("Display"), DisplayName("Temperature units")]
    public TemperatureUnit TemperatureUnit
    {
        get => store.Profile.TemperatureUnit;
        set { store.Profile.TemperatureUnit = value; store.Commit(); }
    }

    [Category("Display"), DisplayName("Time zone offset (minutes)")]
    public int TimeZoneOffsetMinutes
    {
        get => store.Profile.TimeZoneOffsetMinutes;
        set { store.Profile.TimeZoneOffsetMinutes = Math.Clamp(value, -720, 840); store.Commit(); }
    }
}