import Foundation

struct RemoteControlTemplate: Identifiable, Sendable {
    let id: String
    let category: String
    let title: String
    let detail: String
    let symbol: String
    let kind: RemoteControlKind
    let action: RemoteAction
    let textBox: RemoteTextBox?

    var control: RemoteControl {
        RemoteControl(title: title, symbol: symbol, kind: kind, action: action, textBox: textBox)
    }

    func matches(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty || [title, detail, category, action.type.title]
            .contains { $0.localizedCaseInsensitiveContains(normalized) }
    }

    static let all: [Self] = [
        template("blank-button", "Basic", "Button", "Configure a custom action", "circle.fill", .button, .init(type: .macMedia, text: "playPause")),
        template("blank-slider", "Basic", "Slider", "Configure a compact slider", "slider.horizontal.3", .slider, .init(type: .wledBrightness)),
        template("blank-text", "Basic", "Text Box", "Display static or dynamic text", "text.alignleft", .textBox, .init(type: .macMedia, text: "playPause"), textBox: RemoteTextBox()),
        media("previous", "Playback", "Previous", "Previous track", "backward.fill", "previous"),
        media("play-pause", "Playback", "Play / Pause", "Toggle playback", "playpause.fill", "playPause"),
        media("next", "Playback", "Next", "Next track", "forward.fill", "next"),
        media("volume-down", "Volume", "Volume Down", "Lower Mac volume", "speaker.fill", "volumeDown"),
        template("volume-preset", "Volume", "Volume Preset", "Set Mac volume to a chosen level", "speaker.wave.2.fill", .button, .init(type: .macMedia, text: "volume", value: 128)),
        template("volume-slider", "Volume", "Volume Slider", "Set Mac volume continuously", "speaker.wave.2.fill", .slider, .init(type: .macMedia, text: "volume", value: 128)),
        media("mute", "Volume", "Mute", "Toggle Mac mute", "speaker.slash.fill", "mute"),
        media("volume-up", "Volume", "Volume Up", "Raise Mac volume", "speaker.wave.2.fill", "volumeUp"),

        key("undo", "Editing", "Undo", "Command-Z", "arrow.left", "z", ["command"]),
        key("redo", "Editing", "Redo", "Shift-Command-Z", "arrow.right", "z", ["command", "shift"]),
        key("cut", "Editing", "Cut", "Command-X", "xmark", "x", ["command"]),
        key("copy", "Editing", "Copy", "Command-C", "display", "c", ["command"]),
        key("paste", "Editing", "Paste", "Command-V", "checkmark", "v", ["command"]),
        key("select-all", "Editing", "Select All", "Command-A", "circle.fill", "a", ["command"]),
        key("save", "Editing", "Save", "Command-S", "checkmark", "s", ["command"]),
        key("find", "Editing", "Find", "Command-F", "circle.fill", "f", ["command"]),

        key("close-window", "Windows", "Close Window", "Command-W", "xmark", "w", ["command"]),
        key("new-window", "Windows", "New Window", "Command-N", "plus", "n", ["command"]),
        key("new-tab", "Windows", "New Tab", "Command-T", "plus", "t", ["command"]),
        key("minimize", "Windows", "Minimize", "Command-M", "minus", "m", ["command"]),
        key("hide-app", "Windows", "Hide App", "Command-H", "moon.fill", "h", ["command"]),
        key("full-screen", "Windows", "Full Screen", "Control-Command-F", "display", "f", ["control", "command"]),
        key("switch-app", "Windows", "Switch App", "Command-Tab", "arrow.right", "tab", ["command"]),

        key("spotlight", "Navigation", "Spotlight", "Command-Space", "circle.fill", "space", ["command"]),
        key("mission-control", "Navigation", "Mission Control", "Control-Up", "arrow.up", "up", ["control"]),
        key("app-windows", "Navigation", "App Windows", "Control-Down", "arrow.down", "down", ["control"]),
        key("desktop-left", "Navigation", "Desktop Left", "Control-Left", "arrow.left", "left", ["control"]),
        key("desktop-right", "Navigation", "Desktop Right", "Control-Right", "arrow.right", "right", ["control"]),
        key("escape", "Navigation", "Escape", "Escape key", "xmark", "escape", []),
        key("return", "Navigation", "Return", "Return key", "checkmark", "return", []),
        key("arrow-up", "Navigation", "Up", "Up arrow", "arrow.up", "up", []),
        key("arrow-down", "Navigation", "Down", "Down arrow", "arrow.down", "down", []),
        key("arrow-left", "Navigation", "Left", "Left arrow", "arrow.left", "left", []),
        key("arrow-right", "Navigation", "Right", "Right arrow", "arrow.right", "right", []),

        key("lock-screen", "System", "Lock Screen", "Control-Command-Q", "lock.fill", "q", ["control", "command"]),
        key("screenshot", "System", "Screenshot", "Shift-Command-3", "display", "3", ["shift", "command"]),
        key("screenshot-region", "System", "Capture Region", "Shift-Command-4", "display", "4", ["shift", "command"]),

        template("open", "Launch", "Open App or URL", "Choose an app, file, or URL", "display", .button, .init(type: .macOpen, text: "https://")),
        template("shortcut", "Automation", "Run Shortcut", "Run an Apple Shortcut by name", "bolt.fill", .button, .init(type: .macShortcut)),
        template("script", "Automation", "Run Approved Script", "Run a command allowed in Settings", "gearshape.fill", .button, .init(type: .macScript)),

        template("wled-toggle", "Lighting", "Lights", "Toggle WLED power", "lightbulb.fill", .button, .init(type: .wledPower, text: "toggle")),
        template("wled-on", "Lighting", "Lights On", "Turn WLED on", "lightbulb.fill", .button, .init(type: .wledPower, text: "on")),
        template("wled-off", "Lighting", "Lights Off", "Turn WLED off", "power", .button, .init(type: .wledPower, text: "off")),
        template("wled-preset", "Lighting", "Light Scene", "Recall a WLED preset", "sparkles", .button, .init(type: .wledPreset, value: 1)),
        template("wled-brightness", "Lighting", "Brightness", "Set WLED brightness", "sun.max.fill", .slider, .init(type: .wledBrightness, value: 128)),
        template("page", "Remote", "Open Page", "Jump to another remote page", "arrow.right", .button, .init(type: .page)),
    ]

    static var categories: [String] {
        all.reduce(into: []) { categories, template in
            if !categories.contains(template.category) { categories.append(template.category) }
        }
    }

    private static func media(
        _ id: String, _ category: String, _ title: String, _ detail: String,
        _ symbol: String, _ command: String
    ) -> Self {
        template(id, category, title, detail, symbol, .button, .init(type: .macMedia, text: command))
    }

    private static func key(
        _ id: String, _ category: String, _ title: String, _ detail: String,
        _ symbol: String, _ key: String, _ modifiers: [String]
    ) -> Self {
        template(id, category, title, detail, symbol, .button, .init(type: .macKey, text: key, modifiers: modifiers))
    }

    private static func template(
        _ id: String, _ category: String, _ title: String, _ detail: String,
        _ symbol: String, _ kind: RemoteControlKind, _ action: RemoteAction,
        textBox: RemoteTextBox? = nil
    ) -> Self {
        Self(id: id, category: category, title: title, detail: detail, symbol: symbol, kind: kind, action: action, textBox: textBox)
    }
}