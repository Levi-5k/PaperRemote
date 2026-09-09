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
        if (sourceVersion is < 1 or > RemoteProfile.CurrentVersion)
        {
            throw new JsonException($"Unsupported remote profile version {sourceVersion}.");
        }

        var profile = JsonSerializer.Deserialize<RemoteProfile>(json, Options)
            ?? throw new JsonException("Remote profile was empty.");
        profile.Version = RemoteProfile.CurrentVersion;
        profile.Computers ??= [];
        profile.Pages ??= [];
        var pageElements = document.RootElement.GetProperty("pages").EnumerateArray().ToArray();
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

    public static string Serialize(RemoteProfile profile) =>
        JsonSerializer.Serialize(profile, Options);

    private static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            PropertyNameCaseInsensitive = false,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            WriteIndented = false,
        };
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        return options;
    }
}