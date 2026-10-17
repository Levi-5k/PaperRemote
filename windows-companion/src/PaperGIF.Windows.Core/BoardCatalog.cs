using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Core;

public sealed record BoardCatalogResult(DeviceLayout Layout, string Status, bool FromCache);
public sealed record BoardIndexEntry(
    [property: JsonPropertyName("boardID")] string BoardID,
    List<string> HardwareRevisions, int Version, string Path, string Sha256);
public sealed record BoardIndex(int SchemaVersion, List<BoardIndexEntry> Boards);

public sealed class BoardCatalog(HttpClient client, string cacheDirectory)
{
    public static Uri IndexUri { get; } =
        new("https://raw.githubusercontent.com/Levi-5k/PaperRemote/main/boards/index.json");
    private static readonly Uri RootUri = new(IndexUri, ".");

    public BoardCatalogResult Cached(DeviceDescriptor device)
    {
        device.Validate();
        try
        {
            var path = CachePath(device);
            if (File.Exists(path) && new FileInfo(path).Length <= 65_536)
            {
                var package = ParsePackage(File.ReadAllText(path), device);
                return new(package.Layout, "Cached board layout (refresh pending)", true);
            }
        }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException) { }
        try
        {
            var assembly = typeof(BoardCatalog).Assembly;
            using var indexStream = assembly.GetManifestResourceStream("Boards/index.json");
            if (indexStream is not null)
            {
                var index = JsonSerializer.Deserialize<BoardIndex>(indexStream, DeviceDescriptor.JsonOptions);
                var matches = index?.SchemaVersion == 1 ? index.Boards.Where(entry => entry.Version > 0 &&
                    entry.BoardID == device.BoardID && entry.HardwareRevisions.Contains(device.HardwareRevision, StringComparer.Ordinal)).ToArray() : [];
                if (matches.Length == 1 && SafePath(matches[0].Path))
                {
                    using var packageStream = assembly.GetManifestResourceStream("Boards/" + matches[0].Path);
                    if (packageStream is not null)
                    {
                        using var reader = new StreamReader(packageStream, Encoding.UTF8);
                        var json = reader.ReadToEnd();
                        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(json)));
                        if (digest.Equals(matches[0].Sha256, StringComparison.OrdinalIgnoreCase))
                            return new(ParsePackage(json, device, matches[0].Version).Layout, "Bundled board layout (refresh pending)", false);
                    }
                }
            }
        }
        catch (Exception exception) when (exception is IOException or JsonException) { }
        return new(device.Layout, "Device layout; catalog refresh pending", false);
    }

    public async Task<BoardCatalogResult> ResolveAsync(DeviceDescriptor device, CancellationToken cancellationToken = default)
    {
        var fallback = Cached(device);
        try
        {
            var indexJson = await FetchAsync(IndexUri, 262_144, cancellationToken);
            var index = JsonSerializer.Deserialize<BoardIndex>(indexJson, DeviceDescriptor.JsonOptions)
                ?? throw new JsonException("Empty board index.");
            if (index.SchemaVersion != 1 || index.Boards is null || index.Boards.Count > 1024 ||
                index.Boards.Any(entry => entry is null || string.IsNullOrWhiteSpace(entry.BoardID) ||
                    entry.HardwareRevisions is not { Count: > 0 } || entry.Version < 1 ||
                    !SafePath(entry.Path) || !Regex.IsMatch(entry.Sha256 ?? "", "^[a-fA-F0-9]{64}$")))
                throw new JsonException("Invalid board catalog index.");
            var matches = index.Boards.Where(entry => entry.BoardID == device.BoardID &&
                entry.HardwareRevisions.Contains(device.HardwareRevision, StringComparer.Ordinal))
                .OrderBy(entry => entry.Path, StringComparer.Ordinal).ToArray();
            if (matches.Length == 0)
                return fallback with { Status = $"No exact catalog board/revision match; {(fallback.FromCache ? "cached" : "device")} layout retained" };
            if (matches.Length != 1)
                throw new JsonException("Ambiguous catalog board/revision match.");
            var selected = matches[0];
            var json = await FetchAsync(new Uri(RootUri, selected.Path), 65_536, cancellationToken);
            var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(json)));
            if (!digest.Equals(selected.Sha256, StringComparison.OrdinalIgnoreCase))
                throw new JsonException("Board package digest mismatch.");
            var package = ParsePackage(json, device, selected.Version);
            Directory.CreateDirectory(cacheDirectory);
            var path = CachePath(device);
            var pending = path + "." + Guid.NewGuid().ToString("N") + ".pending";
            try
            {
                await File.WriteAllTextAsync(pending, json, cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
                File.Move(pending, path, true);
            }
            finally { if (File.Exists(pending)) File.Delete(pending); }
            return new(package.Layout, $"Catalog layout: {package.Name} (v{package.Version})", false);
        }
        catch (Exception exception) when (exception is HttpRequestException or IOException or JsonException or
            InvalidOperationException or UnauthorizedAccessException ||
            exception is OperationCanceledException && !cancellationToken.IsCancellationRequested)
        {
            return fallback with { Status = $"Catalog unavailable: {exception.Message}; {(fallback.FromCache ? "cached" : "device")} layout retained" };
        }
    }

    private static BoardPackage ParsePackage(string json, DeviceDescriptor device, int? expectedVersion = null)
    {
        var package = JsonSerializer.Deserialize<BoardPackage>(json, DeviceDescriptor.JsonOptions)
            ?? throw new JsonException("Empty board package.");
        package.ValidateFor(device);
        if (expectedVersion is { } version && package.Version != version)
            throw new JsonException("Board package version does not match the catalog index.");
        return package;
    }

    private string CachePath(DeviceDescriptor device) => Path.Combine(cacheDirectory,
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(device.BoardID + "\0" + device.HardwareRevision))) + ".json");

    private static bool SafePath(string? path) =>
        path is { Length: > 0 and < 200 } && Regex.IsMatch(path, @"^[a-zA-Z0-9_-]+\.json$");

    private async Task<string> FetchAsync(Uri uri, int limit, CancellationToken cancellationToken)
    {
        using var response = await client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if (response.RequestMessage?.RequestUri != uri)
            throw new InvalidOperationException("Catalog redirects are not allowed.");
        response.EnsureSuccessStatusCode();
        return await DeviceAdapters.ReadBoundedAsync(response.Content, limit, cancellationToken);
    }
}
