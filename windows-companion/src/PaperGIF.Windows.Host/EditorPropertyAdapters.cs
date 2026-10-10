using System.ComponentModel;
using System.Globalization;
using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Host;

internal sealed class ControlProperties(RemoteControl control, RemotePage page, RemoteEditorStore store) : ICustomTypeDescriptor
{
    [Category("Appearance")]
    public string Title { get => control.Title; set { control.Title = value; store.Commit(); } }

    [Category("Appearance"), TypeConverter(typeof(RemoteIconNameConverter))]
    public string Symbol { get => control.Symbol; set { control.Symbol = value; store.Commit(); } }

    [Category("Appearance"), DisplayName("Tint (hex)")]
    public string TintHex { get => control.TintHex; set { control.TintHex = value; store.Commit(); } }

    [Category("Layout"), TypeConverter(typeof(RemoteControlKindNameConverter))]
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

    [Category("Action"), DisplayName("Type"), TypeConverter(typeof(RemoteActionTypeNameConverter))]
    public RemoteActionType ActionType
    {
        get => control.Action.Type;
        set { RemoteEditorStore.ApplyActionDefaults(control, value); store.Commit(); }
    }

    [Browsable(false)]
    public string ComputerID { get => control.Action.ComputerID ?? string.Empty; set { control.Action.ComputerID = EmptyToNull(value); store.Commit(); } }

    [Category("Action"), DisplayName("Target / command")]
    public string ActionText
    {
        get => control.Action.Text;
        set
        {
            control.Action.Text = value;
            if (control.Action.Type == RemoteActionType.ComputerOpen)
            {
                control.IconBitmap = null;
            }
            store.Commit();
        }
    }

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

    // Legacy single-schedule fields; the Schedules dialog owns these.
    [Browsable(false)]
    public bool ScheduleEnabled { get => control.Action.ScheduleEnabled ?? false; set { control.Action.ScheduleEnabled = value; store.Commit(); } }

    [Browsable(false)]
    public int ScheduleHour { get => control.Action.ScheduleHour ?? 8; set { control.Action.ScheduleHour = Math.Clamp(value, 0, 23); store.Commit(); } }

    [Browsable(false)]
    public int ScheduleMinute { get => control.Action.ScheduleMinute ?? 0; set { control.Action.ScheduleMinute = Math.Clamp(value, 0, 59); store.Commit(); } }

    [Category("Text Box"), DisplayName("Source"), TypeConverter(typeof(RemoteTextSourceNameConverter))]
    public RemoteTextSource TextSource { get => TextBox.Source; set { TextBox.Source = value; store.Commit(); } }

    [Category("Text Box"), DisplayName("Text / source")]
    public string SourceText { get => TextBox.SourceText; set { TextBox.SourceText = value; store.Commit(); } }

    [Category("Text Box")]
    public string Placeholder { get => TextBox.Placeholder; set { TextBox.Placeholder = value; store.Commit(); } }

    [Category("Text Box"), DisplayName("Date format")]
    public string DateFormat { get => TextBox.DateFormat; set { TextBox.DateFormat = value; store.Commit(); } }

    [Category("Text Box"), DisplayName("Horizontal alignment"), TypeConverter(typeof(HorizontalAlignmentNameConverter))]
    public RemoteTextHorizontalAlignment HorizontalAlignment
    {
        get => TextBox.HorizontalAlignment;
        set { TextBox.HorizontalAlignment = value; store.Commit(); }
    }

    [Category("Text Box"), DisplayName("Vertical alignment"), TypeConverter(typeof(VerticalAlignmentNameConverter))]
    public RemoteTextVerticalAlignment VerticalAlignment
    {
        get => TextBox.VerticalAlignment;
        set { TextBox.VerticalAlignment = value; store.Commit(); }
    }

    [Category("Text Box"), DisplayName("When tapped"), TypeConverter(typeof(TapBehaviorNameConverter))]
    public RemoteTextTapBehavior TapBehavior
    {
        get => TextBox.TapBehavior;
        set { TextBox.TapBehavior = value; store.Commit(); }
    }

    [Browsable(false)]
    public string ReferencedControlID
    {
        get => TextBox.ReferencedControlID?.ToString() ?? string.Empty;
        set { TextBox.ReferencedControlID = Guid.TryParse(value, out var id) ? id : null; store.Commit(); }
    }

    [Browsable(false)]
    public string TextComputerID
    {
        get => TextBox.ComputerID?.ToString() ?? string.Empty;
        set { TextBox.ComputerID = Guid.TryParse(value, out var id) ? id : null; store.Commit(); }
    }

    [Category("Text Box"), DisplayName("Text size"), TypeConverter(typeof(TextSizeNameConverter))]
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

    // Shows only the fields that apply to this control; the option rows above the grid cover the rest.
    private bool IsVisible(PropertyDescriptor property)
    {
        var type = control.Action.Type;
        var isTextBox = control.Kind == RemoteControlKind.TextBox;
        if (property.Category == "Text Box")
        {
            return isTextBox;
        }
        if (property.Category == "Slider")
        {
            return control.Kind == RemoteControlKind.Slider;
        }
        if (property.Name == nameof(ButtonHeight) || property.Name == nameof(IsToggle))
        {
            return control.Kind == RemoteControlKind.Button;
        }
        if (property.Category is "Action" or "Climate" &&
            isTextBox && control.TextBox?.TapBehavior != RemoteTextTapBehavior.Action)
        {
            return false;
        }
        return property.Name switch
        {
            nameof(DeadbandTenths) or nameof(HumidityThreshold) or nameof(MinimumCycleMinutes) =>
                type == RemoteActionType.NetHomeAuto,
            nameof(ActionText) => type is RemoteActionType.AppleShortcut or RemoteActionType.ComputerScript or
                RemoteActionType.Module or RemoteActionType.EWeLinkPower,
            nameof(Host) => type is RemoteActionType.EWeLinkPower or RemoteActionType.Module,
            nameof(Value) => type is RemoteActionType.NetHomeAuto or RemoteActionType.Module,
            nameof(ValueTenths) => false,
            nameof(Modifiers) => type == RemoteActionType.OpenBuilds,
            _ => true,
        };
    }

    AttributeCollection ICustomTypeDescriptor.GetAttributes() => TypeDescriptor.GetAttributes(this, true);
    string? ICustomTypeDescriptor.GetClassName() => TypeDescriptor.GetClassName(this, true);
    string? ICustomTypeDescriptor.GetComponentName() => TypeDescriptor.GetComponentName(this, true);
    TypeConverter ICustomTypeDescriptor.GetConverter() => TypeDescriptor.GetConverter(this, true);
    EventDescriptor? ICustomTypeDescriptor.GetDefaultEvent() => TypeDescriptor.GetDefaultEvent(this, true);
    PropertyDescriptor? ICustomTypeDescriptor.GetDefaultProperty() => TypeDescriptor.GetDefaultProperty(this, true);
    object? ICustomTypeDescriptor.GetEditor(Type editorBaseType) => TypeDescriptor.GetEditor(this, editorBaseType, true);
    EventDescriptorCollection ICustomTypeDescriptor.GetEvents() => TypeDescriptor.GetEvents(this, true);
    EventDescriptorCollection ICustomTypeDescriptor.GetEvents(Attribute[]? attributes) => TypeDescriptor.GetEvents(this, attributes, true);
    PropertyDescriptorCollection ICustomTypeDescriptor.GetProperties() => ((ICustomTypeDescriptor)this).GetProperties(null);
    PropertyDescriptorCollection ICustomTypeDescriptor.GetProperties(Attribute[]? attributes) =>
        new(TypeDescriptor.GetProperties(this, attributes, true).Cast<PropertyDescriptor>().Where(IsVisible).ToArray());
    object? ICustomTypeDescriptor.GetPropertyOwner(PropertyDescriptor? property) => this;
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

    [Category("Display"), DisplayName("Maximum button text size (pt)")]
    [Description("Button labels fit and center within the control, up to this size (9–24 pt).")]
    public int MaxButtonTextSize
    {
        get => store.Profile.MaxButtonTextSize;
        set { store.Profile.MaxButtonTextSize = value; store.Commit(); }
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

// Lists the icons the M5Paper can draw while still accepting any typed name.
internal sealed class RemoteIconNameConverter : StringConverter
{
    public override bool GetStandardValuesSupported(ITypeDescriptorContext? context) => true;

    public override bool GetStandardValuesExclusive(ITypeDescriptorContext? context) => false;

    public override StandardValuesCollection GetStandardValues(ITypeDescriptorContext? context) =>
        new(RemoteIconGlyphs.Names.Order(StringComparer.Ordinal).Prepend(string.Empty).ToArray());
}

internal class DisplayNameEnumConverter<T>(IReadOnlyDictionary<T, string> names) : EnumConverter(typeof(T))
    where T : struct, Enum
{
    public override object? ConvertTo(
        ITypeDescriptorContext? context, CultureInfo? culture, object? value, Type destinationType) =>
        destinationType == typeof(string) && value is T member && names.TryGetValue(member, out var name)
            ? name
            : base.ConvertTo(context, culture, value, destinationType);

    public override object? ConvertFrom(ITypeDescriptorContext? context, CultureInfo? culture, object value)
    {
        foreach (var (member, name) in names)
        {
            if (value is string text && text == name)
            {
                return member;
            }
        }
        return base.ConvertFrom(context, culture, value);
    }
}

internal sealed class RemoteActionTypeNameConverter() : DisplayNameEnumConverter<RemoteActionType>(Names)
{
    internal static readonly Dictionary<RemoteActionType, string> Names = new()
    {
        [RemoteActionType.IPhoneMedia] = "iPhone media",
        [RemoteActionType.IPhoneHomePower] = "Apple Home power",
        [RemoteActionType.ComputerMedia] = "Media",
        [RemoteActionType.ComputerKey] = "Keyboard shortcut",
        [RemoteActionType.ComputerOpen] = "Open app or URL",
        [RemoteActionType.AppleShortcut] = "Apple Shortcut (Mac only)",
        [RemoteActionType.ComputerScript] = "Approved script",
        [RemoteActionType.OpenBuilds] = "OpenBuilds CONTROL",
        [RemoteActionType.WledPower] = "WLED power",
        [RemoteActionType.WledPreset] = "WLED preset",
        [RemoteActionType.WledBrightness] = "WLED brightness",
        [RemoteActionType.EWeLinkPower] = "eWeLink power",
        [RemoteActionType.LocalHTTP] = "Local HTTP request",
        [RemoteActionType.NetHomePower] = "NetHome power",
        [RemoteActionType.NetHomeTemperature] = "NetHome temperature",
        [RemoteActionType.NetHomeTemperatureStep] = "NetHome temperature step",
        [RemoteActionType.NetHomeMode] = "NetHome mode",
        [RemoteActionType.NetHomeFan] = "NetHome fan",
        [RemoteActionType.NetHomeAuto] = "Sensor auto mode",
        [RemoteActionType.Module] = "Module action",
        [RemoteActionType.Page] = "Open page",
    };
}

internal sealed class RemoteTextSourceNameConverter() : DisplayNameEnumConverter<RemoteTextSource>(Names)
{
    internal static readonly Dictionary<RemoteTextSource, string> Names = new()
    {
        [RemoteTextSource.StaticText] = "Static text",
        [RemoteTextSource.DateTime] = "Date and time",
        [RemoteTextSource.ComputerScript] = "Script output",
        [RemoteTextSource.AppleShortcut] = "Apple Shortcut output (Mac only)",
        [RemoteTextSource.ControlValue] = "Control value",
        [RemoteTextSource.NowPlaying] = "Now playing",
        [RemoteTextSource.OpenBuildsPosition] = "OpenBuilds position",
    };
}

internal sealed class RemoteControlKindNameConverter() : DisplayNameEnumConverter<RemoteControlKind>(new Dictionary<RemoteControlKind, string>
{
    [RemoteControlKind.Button] = "Button",
    [RemoteControlKind.Slider] = "Slider",
    [RemoteControlKind.TextBox] = "Text box",
});

internal sealed class HorizontalAlignmentNameConverter() : DisplayNameEnumConverter<RemoteTextHorizontalAlignment>(new Dictionary<RemoteTextHorizontalAlignment, string>
{
    [RemoteTextHorizontalAlignment.Leading] = "Left",
    [RemoteTextHorizontalAlignment.Center] = "Center",
    [RemoteTextHorizontalAlignment.Trailing] = "Right",
});

internal sealed class VerticalAlignmentNameConverter() : DisplayNameEnumConverter<RemoteTextVerticalAlignment>(new Dictionary<RemoteTextVerticalAlignment, string>
{
    [RemoteTextVerticalAlignment.Top] = "Top",
    [RemoteTextVerticalAlignment.Center] = "Center",
    [RemoteTextVerticalAlignment.Bottom] = "Bottom",
});

internal sealed class TapBehaviorNameConverter() : DisplayNameEnumConverter<RemoteTextTapBehavior>(new Dictionary<RemoteTextTapBehavior, string>
{
    [RemoteTextTapBehavior.DisplayOnly] = "Do nothing",
    [RemoteTextTapBehavior.Refresh] = "Refresh",
    [RemoteTextTapBehavior.Action] = "Run action",
});

internal sealed class TextSizeNameConverter() : DisplayNameEnumConverter<RemoteTextSize>(new Dictionary<RemoteTextSize, string>
{
    [RemoteTextSize.Small] = "Small",
    [RemoteTextSize.Medium] = "Medium",
    [RemoteTextSize.Large] = "Large",
    [RemoteTextSize.ExtraLarge] = "Extra large",
    [RemoteTextSize.AutoFit] = "Auto fit",
});