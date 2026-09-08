namespace PaperGIF.Windows.Core.Models;

public enum TemperatureUnit
{
    Celsius,
    Fahrenheit,
}

public enum RemoteControlKind
{
    Button,
    Slider,
    TextBox,
}

public enum RemotePageLayout
{
    OpenBuildsController,
}

public enum RemoteJogMode
{
    Incremental,
    Continuous,
}

public enum RemoteTextSource
{
    StaticText,
    DateTime,
    MacScript,
    MacShortcut,
    ControlValue,
    NowPlaying,
    OpenBuildsPosition,
}

public enum RemoteTextSize
{
    Small,
    Medium,
    Large,
    ExtraLarge,
    AutoFit,
}

public enum RemoteTextHorizontalAlignment
{
    Leading,
    Center,
    Trailing,
}

public enum RemoteTextVerticalAlignment
{
    Top,
    Center,
    Bottom,
}

public enum RemoteTextTapBehavior
{
    DisplayOnly,
    Refresh,
    Action,
}

public enum RemoteActionType
{
    MacMedia,
    MacKey,
    MacOpen,
    MacShortcut,
    MacScript,
    OpenBuilds,
    WledPower,
    WledPreset,
    WledBrightness,
    NetHomePower,
    NetHomeTemperature,
    NetHomeTemperatureStep,
    NetHomeMode,
    NetHomeFan,
    NetHomeAuto,
    Page,
}

public sealed class RemoteScheduleEntry
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public List<int> Weekdays { get; set; } = [1, 2, 3, 4, 5, 6, 7];
    public int Hour { get; set; } = 8;
    public int Minute { get; set; }
    public string? Text { get; set; }
    public int? Value { get; set; }
    public int? ValueTenths { get; set; }
}

public sealed class RemoteAction
{
    public RemoteActionType Type { get; set; }
    public string Host { get; set; } = string.Empty;
    public string Text { get; set; } = string.Empty;
    public int Value { get; set; }
    public int? ValueTenths { get; set; }
    public List<string> Modifiers { get; set; } = [];
    public string? ComputerID { get; set; }
    public int? DeadbandTenths { get; set; }
    public int? HumidityThreshold { get; set; }
    public int? MinimumCycleMinutes { get; set; }
    public bool? ScheduleEnabled { get; set; }
    public int? ScheduleHour { get; set; }
    public int? ScheduleMinute { get; set; }
    public List<RemoteScheduleEntry>? Schedules { get; set; }
}

public sealed class RemoteComputer
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = string.Empty;
    public string Host { get; set; } = string.Empty;
    public int Port { get; set; } = 43_821;
    public string Token { get; set; } = string.Empty;
}

public sealed class RemoteTextBox
{
    public RemoteTextSource Source { get; set; } = RemoteTextSource.StaticText;
    public string SourceText { get; set; } = "Text";
    public Guid? ReferencedControlID { get; set; }
    public Guid? ComputerID { get; set; }
    public string DateFormat { get; set; } = "%b %e, %H:%M";
    public string Placeholder { get; set; } = "Unavailable";
    public int GridWidth { get; set; } = 2;
    public int GridHeight { get; set; } = 1;
    public RemoteTextSize TextSize { get; set; } = RemoteTextSize.AutoFit;
    public RemoteTextHorizontalAlignment HorizontalAlignment { get; set; } = RemoteTextHorizontalAlignment.Leading;
    public RemoteTextVerticalAlignment VerticalAlignment { get; set; } = RemoteTextVerticalAlignment.Top;
    public RemoteTextTapBehavior TapBehavior { get; set; } = RemoteTextTapBehavior.DisplayOnly;
    public RemoteAction? TapAction { get; set; }
    public int? RefreshIntervalSeconds { get; set; }
}

public sealed class RemoteControl
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = string.Empty;
    public string Symbol { get; set; } = string.Empty;
    public string? IconBitmap { get; set; }
    public string TintHex { get; set; } = "202020";
    public RemoteControlKind Kind { get; set; }
    public bool? IsToggle { get; set; }
    public int? ButtonHeight { get; set; }
    public int? GridWidth { get; set; }
    public int? GridHeight { get; set; }
    public RemoteAction Action { get; set; } = new();
    public int? LayoutSlot { get; set; }
    public RemoteTextBox? TextBox { get; set; }
}

public sealed class RemotePage
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = string.Empty;
    public List<RemoteControl> Controls { get; set; } = [];
    public int GridColumns { get; set; } = 2;
    public int GridRows { get; set; } = 8;
    public RemotePageLayout? Layout { get; set; }
    public OpenBuildsControllerSettings? OpenBuildsController { get; set; }
    public string? ModuleID { get; set; }
    public string? ModulePageID { get; set; }
}

public sealed class OpenBuildsControllerSettings
{
    public string Host { get; set; } = "127.0.0.1";
    public int JogSpeed { get; set; } = 1_000;
    public RemoteJogMode JogMode { get; set; } = RemoteJogMode.Incremental;
    public int JogDistanceTenths { get; set; } = 10;
}

public sealed class RemoteProfile
{
    public const int CurrentVersion = 6;

    public int Version { get; set; } = CurrentVersion;
    public string WifiSSID { get; set; } = string.Empty;
    public string WifiPassword { get; set; } = string.Empty;
    public string MacHost { get; set; } = string.Empty;
    public int MacPort { get; set; } = 43_821;
    public string MacToken { get; set; } = string.Empty;
    public List<RemoteComputer> Computers { get; set; } = [];
    public int ScreensaverDelaySeconds { get; set; } = 30;
    public TemperatureUnit TemperatureUnit { get; set; } = TemperatureUnit.Celsius;
    public int TimeZoneOffsetMinutes { get; set; } = (int)TimeZoneInfo.Local.GetUtcOffset(DateTimeOffset.Now).TotalMinutes;
    public List<RemotePage> Pages { get; set; } = [];
}