using System.Text.Json;
using PaperGIF.Windows.Core.Models;
using PaperGIF.Windows.Core.Serialization;

namespace PaperGIF.Windows.Host;

// Readable activity text for the tray and companion window instead of wire names and full paths.
internal static class ActionDescriptions
{
    private const string AppsFolderPrefix = @"shell:AppsFolder\";

    private static readonly Dictionary<string, string> MediaCommands = new(StringComparer.Ordinal)
    {
        ["playPause"] = "Play / Pause",
        ["previous"] = "Previous",
        ["next"] = "Next",
        ["volumeUp"] = "Volume Up",
        ["volumeDown"] = "Volume Down",
        ["volume"] = "Set Volume",
        ["mute"] = "Mute",
        ["seek"] = "Seek",
    };

    public static string Describe(string wireType, string? text)
    {
        var typeName = TypeName(wireType);
        return string.IsNullOrWhiteSpace(text) ? typeName : $"{typeName}: {Detail(text)}";
    }

    internal static string TypeName(string wireType)
    {
        try
        {
            var type = JsonSerializer.Deserialize<RemoteActionType>(
                JsonSerializer.Serialize(wireType), RemoteProfileJson.Options);
            return RemoteActionTypeNameConverter.Names.GetValueOrDefault(type, wireType);
        }
        catch (JsonException)
        {
            return wireType;
        }
    }

    internal static string Detail(string text)
    {
        if (MediaCommands.TryGetValue(text, out var command))
        {
            return command;
        }
        if (text.StartsWith(AppsFolderPrefix, StringComparison.OrdinalIgnoreCase))
        {
            var identifier = text[AppsFolderPrefix.Length..];
            return identifier.Split('_', '!')[0];
        }
        return Path.IsPathFullyQualified(text) || text.StartsWith('/')
            ? Path.GetFileNameWithoutExtension(text)
            : text;
    }
}
