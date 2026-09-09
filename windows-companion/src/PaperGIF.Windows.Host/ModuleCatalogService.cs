using System.Text.Json;
using System.Text.RegularExpressions;
using PaperGIF.Windows.Core.Models;
using PaperGIF.Windows.Core.Serialization;

namespace PaperGIF.Windows.Host;

internal sealed class ModuleCatalogService
{
    internal const string DefaultIndexUrl =
        "https://raw.githubusercontent.com/Levi-5k/PaperRemote/main/modules/index.json";
    private const int MaximumDownloadBytes = 512 * 1024;
    private static readonly Regex IdentifierPattern = new(
        "^[a-z0-9]+(?:-[a-z0-9]+)*$",
        RegexOptions.CultureInvariant);
    private readonly HttpClient httpClient = new() { Timeout = TimeSpan.FromSeconds(15) };
    private readonly Uri indexUri;
    private readonly string installedDirectory;
    private readonly Dictionary<string, PaperModuleManifest> installed = new(StringComparer.Ordinal);

    public ModuleCatalogService()
        : this(new Uri(DefaultIndexUrl), Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "paperGIF",
            "modules"))
    {
    }

    internal ModuleCatalogService(Uri indexUri, string installedDirectory)
    {
        this.indexUri = indexUri;
        this.installedDirectory = installedDirectory;
        LoadInstalled();
    }

    public IReadOnlyList<PaperModuleListing> AvailableModules { get; private set; } = [];

    public IReadOnlyList<PaperModuleManifest> InstalledModules => installed.Values
        .OrderBy(module => module.Name, StringComparer.OrdinalIgnoreCase)
        .ToArray();

    public IReadOnlyList<RemoteControlTemplate> InstalledTemplates => installed.Values
        .OrderBy(module => module.Name, StringComparer.OrdinalIgnoreCase)
        .SelectMany(module => module.Controls.Select(definition => new RemoteControlTemplate(
            $"{module.Id}:{definition.Id}",
            definition.Category,
            definition.Control.Title,
            definition.Detail,
            () => CloneControl(definition.Control))))
        .ToArray();

    public bool IsInstalled(string id, string version) =>
        installed.TryGetValue(id, out var module) && module.Version == version;

    public PaperModuleManifest? GetInstalled(string id) =>
        installed.GetValueOrDefault(id);

    public async Task RefreshAsync(CancellationToken cancellationToken = default)
    {
        var payload = await DownloadAsync(indexUri, cancellationToken);
        var index = JsonSerializer.Deserialize<PaperModuleIndex>(payload, RemoteProfileJson.Options)
            ?? throw new InvalidDataException("The module catalog was empty.");
        if (index.SchemaVersion != 1)
        {
            throw new InvalidDataException($"Unsupported module catalog version {index.SchemaVersion}.");
        }
        AvailableModules = index.Modules
            .Where(module => IsValidIdentifier(module.Id) &&
                !string.IsNullOrWhiteSpace(module.Name) &&
                !string.IsNullOrWhiteSpace(module.Manifest))
            .OrderBy(module => module.Name, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    public async Task<PaperModuleManifest> InstallAsync(
        PaperModuleListing listing,
        CancellationToken cancellationToken = default)
    {
        var manifestUri = new Uri(indexUri, listing.Manifest);
        if (manifestUri.Scheme != Uri.UriSchemeHttps)
        {
            throw new InvalidDataException("Module manifests must use HTTPS.");
        }
        var payload = await DownloadAsync(manifestUri, cancellationToken);
        var manifest = JsonSerializer.Deserialize<PaperModuleManifest>(payload, RemoteProfileJson.Options)
            ?? throw new InvalidDataException("The module manifest was empty.");
        ValidateManifest(manifest, listing.Id);

        Directory.CreateDirectory(installedDirectory);
        var destination = Path.Combine(installedDirectory, $"{manifest.Id}.json");
        var temporary = destination + ".tmp";
        await File.WriteAllBytesAsync(temporary, payload, cancellationToken);
        File.Move(temporary, destination, true);
        installed[manifest.Id] = manifest;
        return manifest;
    }

    public static RemoteControl CloneControl(RemoteControl source)
    {
        var clone = JsonSerializer.Deserialize<RemoteControl>(
            JsonSerializer.Serialize(source, RemoteProfileJson.Options),
            RemoteProfileJson.Options) ?? throw new InvalidDataException("A module control could not be copied.");
        clone.Id = Guid.NewGuid();
        clone.LayoutSlot = null;
        return clone;
    }

    public static RemotePage ClonePage(PaperModulePage definition, string moduleId)
    {
        var clone = JsonSerializer.Deserialize<RemotePage>(
            JsonSerializer.Serialize(definition.Page, RemoteProfileJson.Options),
            RemoteProfileJson.Options) ?? throw new InvalidDataException("A module page could not be copied.");
        clone.Id = Guid.NewGuid();
        foreach (var control in clone.Controls)
        {
            control.Id = Guid.NewGuid();
        }
        clone.ModuleID = moduleId;
        clone.ModulePageID = definition.Id;
        return clone;
    }

    private async Task<byte[]> DownloadAsync(Uri uri, CancellationToken cancellationToken)
    {
        using var response = await httpClient.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength > MaximumDownloadBytes)
        {
            throw new InvalidDataException("The module download is too large.");
        }
        await using var source = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var destination = new MemoryStream();
        var buffer = new byte[16 * 1024];
        while (true)
        {
            var count = await source.ReadAsync(buffer, cancellationToken);
            if (count == 0)
            {
                break;
            }
            if (destination.Length + count > MaximumDownloadBytes)
            {
                throw new InvalidDataException("The module download is too large.");
            }
            destination.Write(buffer, 0, count);
        }
        return destination.ToArray();
    }

    private void LoadInstalled()
    {
        if (!Directory.Exists(installedDirectory))
        {
            return;
        }
        foreach (var path in Directory.EnumerateFiles(installedDirectory, "*.json"))
        {
            try
            {
                var manifest = JsonSerializer.Deserialize<PaperModuleManifest>(
                    File.ReadAllText(path),
                    RemoteProfileJson.Options);
                if (manifest is not null)
                {
                    ValidateManifest(manifest, manifest.Id);
                    installed[manifest.Id] = manifest;
                }
            }
            catch (Exception exception) when (exception is IOException or JsonException or InvalidDataException)
            {
                // Ignore corrupt local manifests; reinstalling replaces them atomically.
            }
        }
    }

    private static void ValidateManifest(PaperModuleManifest manifest, string expectedId)
    {
        if (manifest.SchemaVersion != 1 ||
            manifest.Id != expectedId ||
            !IsValidIdentifier(manifest.Id) ||
            string.IsNullOrWhiteSpace(manifest.Name) ||
            string.IsNullOrWhiteSpace(manifest.Version) ||
            manifest.Controls.Count is < 1 or > 16 ||
            manifest.Controls.Any(control =>
                !IsValidIdentifier(control.Id) ||
                string.IsNullOrWhiteSpace(control.Category) ||
                string.IsNullOrWhiteSpace(control.Detail) ||
                string.IsNullOrWhiteSpace(control.Control.Title)) ||
            manifest.Controls.Select(control => control.Id).Distinct(StringComparer.Ordinal).Count() != manifest.Controls.Count ||
            manifest.Pages.Count > 8 ||
            manifest.Pages.Any(page =>
                !IsValidIdentifier(page.Id) ||
                string.IsNullOrWhiteSpace(page.Detail) ||
                string.IsNullOrWhiteSpace(page.Page.Name) ||
                page.Page.Controls.Count > RemoteProfile.MaximumControlsPerPage) ||
            manifest.Pages.Select(page => page.Id).Distinct(StringComparer.Ordinal).Count() != manifest.Pages.Count)
        {
            throw new InvalidDataException("The module manifest is invalid.");
        }
    }

    private static bool IsValidIdentifier(string id) => IdentifierPattern.IsMatch(id);
}

internal sealed class PaperModuleIndex
{
    public int SchemaVersion { get; set; }
    public List<PaperModuleListing> Modules { get; set; } = [];
}

internal sealed class PaperModuleListing
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Summary { get; set; } = string.Empty;
    public string Version { get; set; } = string.Empty;
    public string Author { get; set; } = string.Empty;
    public string Manifest { get; set; } = string.Empty;
}

internal sealed class PaperModuleManifest
{
    public int SchemaVersion { get; set; }
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Summary { get; set; } = string.Empty;
    public string Version { get; set; } = string.Empty;
    public string Author { get; set; } = string.Empty;
    public List<PaperModuleControl> Controls { get; set; } = [];
    public List<PaperModulePage> Pages { get; set; } = [];
}

internal sealed class PaperModuleControl
{
    public string Id { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;
    public string Detail { get; set; } = string.Empty;
    public RemoteControl Control { get; set; } = new();
}

internal sealed class PaperModulePage
{
    public string Id { get; set; } = string.Empty;
    public string Detail { get; set; } = string.Empty;
    public RemotePage Page { get; set; } = new();
}