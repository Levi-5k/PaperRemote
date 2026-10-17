using System.Text.Json;
using System.Text.Json.Serialization;
using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Core.Serialization;

public static class RemoteProfileJson
{
    public static JsonSerializerOptions Options { get; } = CreateOptions();

    public static RemoteProfile Deserialize(string json)
    {
        using var document = JsonDocument.Parse(json);
        var sourceVersion = document.RootElement.TryGetProperty("version", out var versionElement)
            ? versionElement.GetInt32()
            : 1;
        if (sourceVersion is < 1 or > RemoteProfile.HardwareBindingsVersion)
        {
            throw new JsonException($"Unsupported remote profile version {sourceVersion}.");
        }
        if (sourceVersion < 7 && document.RootElement.TryGetProperty("hardwareBindings", out _))
            throw new JsonException("Hardware bindings require profile version 7.");
        if (sourceVersion == 7)
        {
            if (!document.RootElement.TryGetProperty("hardwareBindings", out var bindings) ||
                bindings.ValueKind != JsonValueKind.Array || bindings.GetArrayLength() > 256)
                throw new JsonException("v7 requires a bounded hardwareBindings array.");
            foreach (var binding in bindings.EnumerateArray())
            {
                if (binding.ValueKind != JsonValueKind.Object ||
                    new[] { "inputID", "event", "mode" }.Any(name =>
                        !binding.TryGetProperty(name, out var field) || field.ValueKind != JsonValueKind.String) ||
                    new[] { "minimum", "maximum", "step" }.Any(name =>
                        !binding.TryGetProperty(name, out var field) || field.ValueKind != JsonValueKind.Number ||
                        !field.TryGetDouble(out var value) || !double.IsFinite(value)) ||
                    !binding.TryGetProperty("action", out var action) || action.ValueKind != JsonValueKind.Object ||
                    new[] { "type", "host", "text" }.Any(name =>
                        !action.TryGetProperty(name, out var field) || field.ValueKind != JsonValueKind.String) ||
                    !action.TryGetProperty("value", out var actionValue) || actionValue.ValueKind != JsonValueKind.Number || !actionValue.TryGetInt32(out _) ||
                    !action.TryGetProperty("modifiers", out var modifiers) || modifiers.ValueKind != JsonValueKind.Array)
                    throw new JsonException("Invalid v7 hardware binding or action.");
            }
        }

        var profile = JsonSerializer.Deserialize<RemoteProfile>(json, Options)
            ?? throw new JsonException("Remote profile was empty.");
        profile.Version = Math.Max(sourceVersion, RemoteProfile.CurrentVersion);
        if (BindingValidationMessage(profile.HardwareBindings ?? []) is { } bindingError)
            throw new JsonException(bindingError);
        profile.Computers ??= [];
        profile.Pages ??= [];
        if (!document.RootElement.TryGetProperty("pages", out var pagesElement) || pagesElement.ValueKind != JsonValueKind.Array ||
            profile.Pages.Any(page => page is null || page.Controls is null ||
                page.Controls.Any(control => control is null || control.Action is null)) ||
            profile.Computers.Any(computer => computer is null) || profile.ButtonTexture is null)
            throw new JsonException("Invalid profile pages, controls, computers or texture.");
        var pageElements = pagesElement.EnumerateArray().ToArray();
        for (var index = 0; index < Math.Min(profile.Pages.Count, pageElements.Length); index++)
        {
            if (profile.Pages[index].OpenBuildsController is { } settings &&
                pageElements[index].TryGetProperty("openBuildsController", out var controllerElement) &&
                !controllerElement.TryGetProperty("jogDistanceThousandths", out _))
            {
                settings.JogDistanceThousandths = settings.JogDistanceTenths * 100;
            }
            if (profile.Pages[index].Layout == RemotePageLayout.OpenBuildsController &&
                !pageElements[index].TryGetProperty("gridColumns", out _))
            {
                UpgradeLegacyOpenBuildsGrid(profile.Pages[index]);
            }
        }
        if (profile.Computers.Count == 0 && !string.IsNullOrWhiteSpace(profile.MacHost))
        {
            profile.Computers.Add(new RemoteComputer
            {
                Name = "Default Computer",
                Host = profile.MacHost,
                Port = profile.MacPort,
                Token = profile.MacToken,
            });
        }

        return profile;
    }

    private static void UpgradeLegacyOpenBuildsGrid(RemotePage page)
    {
        page.GridColumns = 9;
        page.GridRows = 14;
        var slots = new Dictionary<string, int>
        {
            ["XNegativeYPositive"] = 18, ["YPositive"] = 20, ["XPositiveYPositive"] = 22,
            ["XNegative"] = 36, ["XPositive"] = 40,
            ["XNegativeYNegative"] = 54, ["YNegative"] = 56, ["XPositiveYNegative"] = 58,
        };
        foreach (var control in page.Controls)
        {
            if (control.TextBox?.Source == RemoteTextSource.OpenBuildsPosition)
            {
                var components = control.TextBox.SourceText.Split('|');
                var axis = components.Length > 1 ? components[1].ToLowerInvariant() : "x";
                control.LayoutSlot = axis switch { "y" => 3, "z" => 6, _ => 0 };
                control.GridWidth = 3;
                control.GridHeight = 2;
                continue;
            }
            var direction = control.Action.Text
                .Replace("continuousJog", string.Empty, StringComparison.Ordinal)
                .Replace("jog", string.Empty, StringComparison.Ordinal);
            if (!slots.TryGetValue(direction, out var slot))
            {
                continue;
            }
            control.LayoutSlot = slot;
            control.GridWidth = 2;
            control.GridHeight = 2;
        }
    }

    public static string Serialize(RemoteProfile profile)
    {
        if (BindingValidationMessage(profile.HardwareBindings ?? []) is { } error)
            throw new InvalidOperationException(error);
        if (profile.Version < 7 && profile.HardwareBindings is { Count: > 0 })
            throw new InvalidOperationException("Hardware bindings require profile version 7.");
        var node = JsonSerializer.SerializeToNode(profile, Options)!.AsObject();
        if (profile.Version < 7) node.Remove("hardwareBindings");
        else node["hardwareBindings"] = JsonSerializer.SerializeToNode(profile.HardwareBindings ?? [], Options);
        return node.ToJsonString(Options);
    }

    private static string? BindingValidationMessage(IReadOnlyList<HardwareBinding> bindings)
    {
        if (bindings.Count > 256 || bindings.Any(binding => binding is null))
            return "Hardware bindings must be non-null and bounded.";
        foreach (var binding in bindings)
            if (binding.ValidateShape() is { } error) return error;
        if (bindings.Select(binding => (binding.InputID, binding.Event, binding.Direction)).Distinct().Count() != bindings.Count ||
            bindings.GroupBy(binding => (binding.InputID, binding.Event)).Any(group =>
                group.Count() > 1 && group.Any(binding => binding.Direction is null)))
            return "Duplicate or overlapping wildcard/directional hardware bindings.";
        return null;
    }

    public static string SerializeForDevice(RemoteProfile profile, DeviceDescriptor device)
    {
        device.Validate();
        var hasBindings = profile.HardwareBindings is { Count: > 0 };
        var version = device.Capabilities.ProfileVersions.Contains(7) ? 7 : 6;
        if (hasBindings && version < 7)
            throw new InvalidOperationException("This device only supports v6; hardware bindings cannot be sent.");
        if (profile.Pages.Count > device.Capabilities.MaxPages ||
            profile.Pages.Any(page => page.Controls.Count > device.Capabilities.MaxControls))
            throw new InvalidOperationException("Profile exceeds the device's page/control capacity.");
        if ((device.Display is null || !device.Display.Touch) && profile.Pages.Any(page => page.Controls.Count > 0))
            throw new InvalidOperationException("This device has no touchscreen; remove screen controls and assign physical inputs.");
        var usesImages = profile.ButtonTexture.Kind == RemoteButtonTextureKind.Image ||
            profile.Pages.SelectMany(page => page.Controls).Any(control => control.ButtonTexture?.Kind == RemoteButtonTextureKind.Image);
        if (usesImages && device is not { BoardID: "m5stack.m5paper", Display: { Width: 540, Height: 960, PixelFormat: "gray4" }, Capabilities.Media: true })
            throw new InvalidOperationException("Button image assets use the M5Paper media format; custom-display conversion/upload is unavailable.");
        var bindings = profile.HardwareBindings ?? [];
        if (BindingValidationMessage(bindings) is { } bindingError)
            throw new InvalidOperationException(bindingError);
        if (bindings.Count > Math.Min(256, device.Capabilities.MaxControls))
            throw new InvalidOperationException("Hardware input/event bindings must be unique and bounded.");
        foreach (var binding in bindings)
            if (binding.Validate(device) is { } error)
                throw new InvalidOperationException(error);
        var node = JsonSerializer.SerializeToNode(profile, Options)!.AsObject();
        node["version"] = version;
        if (version == 6) node.Remove("hardwareBindings");
        else node["hardwareBindings"] = JsonSerializer.SerializeToNode(bindings, Options);
        var json = node.ToJsonString(Options);
        if (System.Text.Encoding.UTF8.GetByteCount(json) > device.Capabilities.MaxProfileBytes)
            throw new InvalidOperationException("Profile exceeds this device's byte limit.");
        return json;
    }

    private static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            PropertyNameCaseInsensitive = false,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            WriteIndented = false,
        };
        options.Converters.Add(new JsonStringEnumConverter(new LegacyEnumNamingPolicy()));
        return options;
    }

    // Renamed enum members keep their legacy wire names; see protocol/README.md.
    private sealed class LegacyEnumNamingPolicy : JsonNamingPolicy
    {
        private static readonly Dictionary<string, string> LegacyNames = new(StringComparer.Ordinal)
        {
            [nameof(RemoteActionType.ComputerMedia)] = "macMedia",
            [nameof(RemoteActionType.ComputerKey)] = "macKey",
            [nameof(RemoteActionType.ComputerOpen)] = "macOpen",
            [nameof(RemoteActionType.AppleShortcut)] = "macShortcut",
            [nameof(RemoteActionType.ComputerScript)] = "macScript",
        };

        public override string ConvertName(string name) =>
            LegacyNames.TryGetValue(name, out var legacyName) ? legacyName : CamelCase.ConvertName(name);
    }
}