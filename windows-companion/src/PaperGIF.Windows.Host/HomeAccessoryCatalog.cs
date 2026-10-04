using System.Text.Json;
using System.Text.Json.Serialization;

namespace PaperGIF.Windows.Host;

internal sealed record HomeAccessory(
    string HomeName,
    string AccessoryName,
    string ServiceName,
    string AccessoryID,
    string ServiceID)
{
    [JsonIgnore]
    public string Id => $"{AccessoryID}:{ServiceID}";

    [JsonIgnore]
    public string DisplayName => ServiceName == AccessoryName
        ? $"{HomeName} · {AccessoryName}"
        : $"{HomeName} · {AccessoryName} · {ServiceName}";
}

// Apple Home power accessories shared by the paired iPhone; Windows has no HomeKit access.
internal sealed class HomeAccessoryCatalog
{
    public const int MaximumAccessories = 128;
    public const int MaximumRequestBytes = 64 * 1024;
    private const int MaximumTextLength = 128;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly string path;
    private readonly object gate = new();
    private IReadOnlyList<HomeAccessory> accessories = [];

    public HomeAccessoryCatalog()
        : this(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "paperGIF",
            "home-accessories.json"))
    {
    }

    public HomeAccessoryCatalog(string path)
    {
        this.path = path;
        try
        {
            if (File.Exists(path) && Validate(File.ReadAllText(path)) is { } saved)
            {
                accessories = saved;
            }
        }
        catch (IOException)
        {
        }
    }

    public event EventHandler? Changed;

    public IReadOnlyList<HomeAccessory> Accessories
    {
        get
        {
            lock (gate)
            {
                return accessories;
            }
        }
    }

    // Returns null when the shared list is malformed or oversized.
    internal static IReadOnlyList<HomeAccessory>? Validate(string json)
    {
        try
        {
            var payload = JsonSerializer.Deserialize<SharePayload>(json, JsonOptions);
            if (payload?.Accessories is not { } list || list.Count > MaximumAccessories)
            {
                return null;
            }
            foreach (var accessory in list)
            {
                if (accessory is null ||
                    new[] { accessory.HomeName, accessory.AccessoryName, accessory.ServiceName }
                        .Any(text => text is null || text.Length > MaximumTextLength) ||
                    !Guid.TryParse(accessory.AccessoryID, out _) ||
                    !Guid.TryParse(accessory.ServiceID, out _))
                {
                    return null;
                }
            }
            return list;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public void Replace(IReadOnlyList<HomeAccessory> shared)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporaryPath = path + ".tmp";
        File.WriteAllText(temporaryPath, JsonSerializer.Serialize(new SharePayload(shared.ToList()), JsonOptions));
        File.Move(temporaryPath, path, true);
        lock (gate)
        {
            accessories = shared;
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private sealed record SharePayload(List<HomeAccessory> Accessories);
}
