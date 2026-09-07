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