using System.Text.Json;

namespace PaperGIF.Windows.Host;

internal sealed class CompanionConfiguration
{
    public int Port { get; set; } = 43_821;
    public string Token { get; set; } = Guid.NewGuid().ToString();
    public List<string> AllowedScripts { get; set; } = [];
    public List<string> PairedDevices { get; set; } = [];

    public static string ConfigurationPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "paperGIF",
        "windows-companion.json");

    public static CompanionConfiguration LoadOrCreate()
    {
        if (File.Exists(ConfigurationPath))
        {
            var existing = JsonSerializer.Deserialize<CompanionConfiguration>(
                File.ReadAllText(ConfigurationPath));
            if (existing is not null && !string.IsNullOrWhiteSpace(existing.Token))
            {
                return existing;
            }
        }

        var configuration = new CompanionConfiguration();
        configuration.Save();
        return configuration;
    }

    public void Save()
    {
        var directory = Path.GetDirectoryName(ConfigurationPath)
            ?? throw new InvalidOperationException("The configuration directory is unavailable.");
        Directory.CreateDirectory(directory);
        var temporaryPath = ConfigurationPath + ".tmp";
        File.WriteAllText(temporaryPath, JsonSerializer.Serialize(this));
        File.Move(temporaryPath, ConfigurationPath, true);
    }
}