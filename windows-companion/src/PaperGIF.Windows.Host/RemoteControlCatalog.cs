using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Host;

internal sealed record RemoteControlTemplate(
    string Id,
    string Category,
    string Title,
    string Detail,
    Func<RemoteControl> Factory);

internal static class RemoteControlCatalog
{
    public static IReadOnlyList<RemoteControlTemplate> All { get; } =
    [
        Template("blank-button", "Basic", "Button", "Configure a custom action", RemoteControlKind.Button, RemoteActionType.MacMedia, "playPause"),
        Template("blank-slider", "Basic", "Slider", "Configure a compact slider", RemoteControlKind.Slider, RemoteActionType.WledBrightness),
        TextTemplate("blank-text", "Basic", "Text Box", "Display static or dynamic text"),
        Template("previous", "Playback", "Previous", "Previous track", RemoteControlKind.Button, RemoteActionType.MacMedia, "previous"),
        Template("play-pause", "Playback", "Play / Pause", "Toggle playback", RemoteControlKind.Button, RemoteActionType.MacMedia, "playPause"),
        Template("next", "Playback", "Next", "Next track", RemoteControlKind.Button, RemoteActionType.MacMedia, "next"),
        Template("volume-down", "Volume", "Volume Down", "Lower computer volume", RemoteControlKind.Button, RemoteActionType.MacMedia, "volumeDown"),
        Template("volume", "Volume", "Volume Slider", "Set computer volume", RemoteControlKind.Slider, RemoteActionType.MacMedia, "volume", 128),
        Template("mute", "Volume", "Mute", "Toggle computer mute", RemoteControlKind.Button, RemoteActionType.MacMedia, "mute"),
        Template("volume-up", "Volume", "Volume Up", "Raise computer volume", RemoteControlKind.Button, RemoteActionType.MacMedia, "volumeUp"),
        Key("undo", "Editing", "Undo", "Ctrl+Z", "z", "control"),
        Key("redo", "Editing", "Redo", "Ctrl+Shift+Z", "z", "control", "shift"),
        Key("cut", "Editing", "Cut", "Ctrl+X", "x", "control"),
        Key("copy", "Editing", "Copy", "Ctrl+C", "c", "control"),
        Key("paste", "Editing", "Paste", "Ctrl+V", "v", "control"),
        Key("select-all", "Editing", "Select All", "Ctrl+A", "a", "control"),
        Key("save", "Editing", "Save", "Ctrl+S", "s", "control"),
        Key("find", "Editing", "Find", "Ctrl+F", "f", "control"),
        Key("close-window", "Windows", "Close Window", "Alt+F4", "f4", "alt"),
        Key("new-window", "Windows", "New Window", "Ctrl+N", "n", "control"),
        Key("new-tab", "Windows", "New Tab", "Ctrl+T", "t", "control"),
        Key("switch-app", "Windows", "Switch App", "Alt+Tab", "tab", "alt"),
        Key("lock-screen", "System", "Lock Screen", "Windows+L", "l", "windows"),
        Key("escape", "Navigation", "Escape", "Escape key", "escape"),
        Key("return", "Navigation", "Enter", "Enter key", "return"),
        Key("arrow-up", "Navigation", "Up", "Up arrow", "up"),
        Key("arrow-down", "Navigation", "Down", "Down arrow", "down"),
        Key("arrow-left", "Navigation", "Left", "Left arrow", "left"),
        Key("arrow-right", "Navigation", "Right", "Right arrow", "right"),
        Template("open", "Launch", "Open App or URL", "Choose an app, file, or URL", RemoteControlKind.Button, RemoteActionType.MacOpen, "https://"),
        Template("script", "Automation", "Run Approved Script", "Run an allowed PowerShell script", RemoteControlKind.Button, RemoteActionType.MacScript),
        Template("wled-toggle", "Lighting", "Lights", "Toggle WLED power", RemoteControlKind.Button, RemoteActionType.WledPower, "toggle"),
        Template("wled-on", "Lighting", "Lights On", "Turn WLED on", RemoteControlKind.Button, RemoteActionType.WledPower, "on"),
        Template("wled-off", "Lighting", "Lights Off", "Turn WLED off", RemoteControlKind.Button, RemoteActionType.WledPower, "off"),
        Template("wled-preset", "Lighting", "Light Scene", "Recall a WLED preset", RemoteControlKind.Button, RemoteActionType.WledPreset, value: 1),
        Template("wled-brightness", "Lighting", "Brightness", "Set WLED brightness", RemoteControlKind.Slider, RemoteActionType.WledBrightness, value: 128),
        Template("nethome-power", "Climate", "Air Conditioner", "Toggle NetHome power", RemoteControlKind.Button, RemoteActionType.NetHomePower, "toggle"),
        Template("nethome-temperature", "Climate", "Temperature", "Set NetHome temperature", RemoteControlKind.Slider, RemoteActionType.NetHomeTemperature, value: 22, valueTenths: 220),
        Template("nethome-temperature-up", "Climate", "Temperature Up", "Increase the NetHome setpoint", RemoteControlKind.Button, RemoteActionType.NetHomeTemperatureStep, value: 1),
        Template("nethome-temperature-down", "Climate", "Temperature Down", "Decrease the NetHome setpoint", RemoteControlKind.Button, RemoteActionType.NetHomeTemperatureStep, value: -1),
        Template("nethome-mode", "Climate", "Climate Mode", "Set the NetHome operating mode", RemoteControlKind.Button, RemoteActionType.NetHomeMode, "auto"),
        Template("nethome-fan", "Climate", "Fan Speed", "Set NetHome fan speed", RemoteControlKind.Slider, RemoteActionType.NetHomeFan, value: 40),
        Template("nethome-auto", "Climate", "Automatic Climate", "Maintain a temperature automatically", RemoteControlKind.Button, RemoteActionType.NetHomeAuto, "cool", value: 22),
        Template("page", "Remote", "Open Page", "Jump to another remote page", RemoteControlKind.Button, RemoteActionType.Page),
    ];

    public static RemoteControl Create(string id) =>
        All.First(template => template.Id == id).Factory();

    private static RemoteControlTemplate Template(
        string id,
        string category,
        string title,
        string detail,
        RemoteControlKind kind,
        RemoteActionType actionType,
        string text = "",
        int value = 0,
        int? valueTenths = null) => new(
            id,
            category,
            title,
            detail,
            () => new RemoteControl
            {
                Title = title,
                Kind = kind,
                TintHex = actionType is RemoteActionType.WledPower or RemoteActionType.WledPreset or RemoteActionType.WledBrightness
                    ? "F2C14E"
                    : "202020",
                Action = new RemoteAction { Type = actionType, Text = text, Value = value, ValueTenths = valueTenths },
            });

    private static RemoteControlTemplate Key(
        string id,
        string category,
        string title,
        string detail,
        string key,
        params string[] modifiers) => new(
            id,
            category,
            title,
            detail,
            () => new RemoteControl
            {
                Title = title,
                Kind = RemoteControlKind.Button,
                Action = new RemoteAction
                {
                    Type = RemoteActionType.MacKey,
                    Text = key,
                    Modifiers = [.. modifiers],
                },
            });

    private static RemoteControlTemplate TextTemplate(
        string id,
        string category,
        string title,
        string detail) => new(
            id,
            category,
            title,
            detail,
            () => new RemoteControl
            {
                Title = title,
                Kind = RemoteControlKind.TextBox,
                Action = new RemoteAction { Type = RemoteActionType.MacMedia, Text = "playPause" },
                TextBox = new RemoteTextBox(),
            });
}