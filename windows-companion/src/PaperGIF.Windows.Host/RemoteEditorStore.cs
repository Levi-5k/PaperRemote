using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using PaperGIF.Windows.Core.Models;
using PaperGIF.Windows.Core.Serialization;

namespace PaperGIF.Windows.Host;

internal sealed class RemoteEditorStore : IDisposable
{
    private readonly CompanionConfiguration configuration;
    private readonly HttpClient httpClient = new() { Timeout = TimeSpan.FromSeconds(15) };
    private CancellationTokenSource? liveSyncCancellation;
    private bool isApplyingDeviceProfile;

    public RemoteEditorStore(CompanionConfiguration configuration)
    {
        this.configuration = configuration;
        var document = LoadDocument();
        Profile = document?.Profile ?? CreateStarterProfile();
        DeviceAddress = document?.DeviceAddress ?? "192.168.4.1";
        EnsureLocalComputer();
        SelectedPageId = Profile.Pages.FirstOrDefault()?.Id;
    }

    public event EventHandler? Changed;
    public event EventHandler? StatusChanged;

    public RemoteProfile Profile { get; private set; }
    public string DeviceAddress { get; set; }
    public Guid? SelectedPageId { get; set; }
    public Guid? SelectedControlId { get; set; }
    public string Status { get; private set; } = "Ready";
    public bool IsBusy { get; private set; }
    public bool HasLoadedDeviceProfile { get; private set; }
    public IReadOnlyList<DeviceWifiNetwork> WifiNetworks { get; private set; } = [];

    public RemotePage? SelectedPage =>
        Profile.Pages.FirstOrDefault(page => page.Id == SelectedPageId);

    public RemoteControl? SelectedControl => Profile.Pages
        .SelectMany(page => page.Controls)
        .FirstOrDefault(control => control.Id == SelectedControlId);

    public void RefreshLocalCompanion(string previousToken)
    {
        var local = Profile.Computers.FirstOrDefault(computer => computer.Token == previousToken) ??
            Profile.Computers.FirstOrDefault(computer =>
                computer.Name.Equals(Environment.MachineName, StringComparison.OrdinalIgnoreCase));
        if (local is not null)
        {
            local.Host = LocalIpv4Address() ?? $"{Environment.MachineName}.local";
            local.Port = configuration.Port;
            local.Token = configuration.Token;
            Profile.MacHost = local.Host;
            Profile.MacPort = local.Port;
            Profile.MacToken = local.Token;
        }
        else
        {
            EnsureLocalComputer();
        }
        Commit();
    }

    public string? ValidationMessage => ValidateProfile(Profile);

    internal static string? ValidateProfile(RemoteProfile profile)
    {
        if (profile.Pages.Count is < 1 or > 8)
        {
            return "A remote needs between 1 and 8 pages.";
        }
        if (profile.Pages.Any(page =>
            page.Controls.Count > RemoteProfile.MaximumControlsPerPage ||
            LayoutUnits(page) > page.GridColumns * page.GridRows))
        {
            return "A page has more controls than fit on the display.";
        }
        if (profile.Pages.Any(page => string.IsNullOrWhiteSpace(page.Name)))
        {
            return "Every page needs a name.";
        }
        return null;
    }

    public void AddPage()
    {
        if (Profile.Pages.Count >= 8)
        {
            return;
        }
        var page = new RemotePage { Name = $"Page {Profile.Pages.Count + 1}" };
        Profile.Pages.Add(page);
        SelectedPageId = page.Id;
        SelectedControlId = null;
        Commit();
    }

    public void AddPage(RemotePage page)
    {
        if (Profile.Pages.Count >= 8)
        {
            return;
        }
        Profile.Pages.Add(page);
        SelectedPageId = page.Id;
        SelectedControlId = null;
        Commit();
    }

    public int UpdateModulePages(PaperModuleManifest module)
    {
        var definitions = module.Pages.ToDictionary(page => page.Id, StringComparer.Ordinal);
        var updatedCount = 0;
        for (var index = 0; index < Profile.Pages.Count; index++)
        {
            var existing = Profile.Pages[index];
            if (existing.ModuleID != module.Id || existing.ModulePageID is null ||
                !definitions.TryGetValue(existing.ModulePageID, out var definition))
            {
                continue;
            }
            Profile.Pages[index] = ModuleCatalogService.UpdatedPage(existing, definition, module.Id);
            updatedCount++;
        }
        if (updatedCount == 0)
        {
            return 0;
        }
        if (SelectedControlId is not null &&
            !Profile.Pages.SelectMany(page => page.Controls).Any(control => control.Id == SelectedControlId))
        {
            SelectedControlId = null;
        }
        Commit();
        return updatedCount;
    }

    public void DeleteSelectedPage()
    {
        var page = SelectedPage;
        if (page is null || Profile.Pages.Count <= 1)
        {
            return;
        }
        var index = Profile.Pages.IndexOf(page);
        Profile.Pages.RemoveAt(index);
        SelectedPageId = Profile.Pages[Math.Min(index, Profile.Pages.Count - 1)].Id;
        SelectedControlId = null;
        Commit();
    }

    public void MoveSelectedPage(int offset)
    {
        var page = SelectedPage;
        if (page is null)
        {
            return;
        }
        var index = Profile.Pages.IndexOf(page);
        var destination = index + offset;
        if (destination < 0 || destination >= Profile.Pages.Count)
        {
            return;
        }
        Profile.Pages.RemoveAt(index);
        Profile.Pages.Insert(destination, page);
        Commit();
    }

    public bool AddControl(RemoteControl control)
    {
        var page = SelectedPage;
        if (page is null || page.Controls.Count >= RemoteProfile.MaximumControlsPerPage ||
            LayoutUnits(page) + LayoutUnits(control, page) > page.GridColumns * page.GridRows)
        {
            return false;
        }
        page.Controls.Add(control);
        SelectedControlId = control.Id;
        Commit();
        return true;
    }

    public void DeleteSelectedControl()
    {
        var page = SelectedPage;
        var control = SelectedControl;
        if (page is null || control is null)
        {
            return;
        }
        page.Controls.Remove(control);
        SelectedControlId = null;
        Commit();
    }

    public void DuplicateSelectedControl()
    {
        var page = SelectedPage;
        var control = SelectedControl;
        if (page is null || control is null)
        {
            return;
        }
        var copy = RemoteProfileJson.Deserialize(RemoteProfileJson.Serialize(new RemoteProfile
        {
            Pages = [new RemotePage { Name = "Copy", Controls = [control] }],
        })).Pages[0].Controls[0];
        copy.Id = Guid.NewGuid();
        copy.Title += " Copy";
        copy.LayoutSlot = null;
        AddControl(copy);
    }

    public void MoveSelectedControl(int offset)
    {
        var page = SelectedPage;
        var control = SelectedControl;
        if (page is null || control is null)
        {
            return;
        }
        var index = page.Controls.IndexOf(control);
        var destination = index + offset;
        if (destination < 0 || destination >= page.Controls.Count)
        {
            return;
        }
        page.Controls.RemoveAt(index);
        page.Controls.Insert(destination, control);
        Commit();
    }

    public void MoveControlToSlot(Guid controlId, int requestedSlot)
    {
        var page = SelectedPage;
        var control = page?.Controls.FirstOrDefault(candidate => candidate.Id == controlId);
        if (page is null || control is null ||
            requestedSlot is < 0 || requestedSlot >= page.GridColumns * page.GridRows)
        {
            return;
        }
        var destination = Placement(control, requestedSlot, page);
        if (destination is null)
        {
            return;
        }
        var destinationCells = Cells(destination.Value, page.GridColumns);
        foreach (var candidate in page.Controls.Where(candidate => candidate.Id != controlId))
        {
            if (candidate.LayoutSlot is { } slot &&
                Placement(candidate, slot, page) is { } placement &&
                destinationCells.Overlaps(Cells(placement, page.GridColumns)))
            {
                candidate.LayoutSlot = null;
            }
        }
        control.LayoutSlot = destination.Value.Slot;
        Commit();
    }

    public void Commit()
    {
        Save();
        Changed?.Invoke(this, EventArgs.Empty);
        if (HasLoadedDeviceProfile && !isApplyingDeviceProfile)
        {
            ScheduleLiveSync();
        }
    }

    public async Task LoadFromDeviceAsync()
    {
        await RunDeviceOperationAsync("Loading from M5Paper...", async requestUri =>
        {
            using var request = AuthorizedRequest(HttpMethod.Get, requestUri);
            using var response = await httpClient.SendAsync(request);
            var json = await response.Content.ReadAsStringAsync();
            if (!response.IsSuccessStatusCode)
            {
                throw new InvalidOperationException($"M5Paper returned {(int)response.StatusCode}.");
            }
            isApplyingDeviceProfile = true;
            try
            {
                Profile = RemoteProfileJson.Deserialize(json);
                EnsureLocalComputer();
                SelectedPageId = Profile.Pages.FirstOrDefault()?.Id;
                SelectedControlId = null;
                HasLoadedDeviceProfile = true;
                Commit();
            }
            finally
            {
                isApplyingDeviceProfile = false;
            }
            return "Loaded from M5Paper";
        });
    }

    public async Task SendToDeviceAsync()
    {
        await SendToDeviceAttemptAsync();
    }

    private async Task<bool> SendToDeviceAttemptAsync()
    {
        if (ValidationMessage is { } validation)
        {
            SetStatus(validation);
            return false;
        }
        return await RunDeviceOperationAsync("Sending to M5Paper...", async requestUri =>
        {
            using var request = AuthorizedRequest(HttpMethod.Post, requestUri);
            request.Content = new StringContent(
                RemoteProfileJson.Serialize(Profile),
                Encoding.UTF8,
                "application/json");
            using var response = await httpClient.SendAsync(request);
            if (!response.IsSuccessStatusCode)
            {
                throw new InvalidOperationException($"M5Paper returned {(int)response.StatusCode}.");
            }
            Save();
            return "Remote installed on M5Paper";
        });
    }

    public async Task<string> PairComputerAsync(string name, string host, int port)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"http://{host}:{port}/pair")
        {
            Content = new StringContent(
                JsonSerializer.Serialize(new PairingRequest(Environment.MachineName)),
                Encoding.UTF8,
                "application/json"),
        };
        using var response = await httpClient.SendAsync(request);
        if (response.StatusCode == HttpStatusCode.Forbidden)
        {
            throw new InvalidOperationException($"Pairing was declined on {name}.");
        }
        response.EnsureSuccessStatusCode();
        var pairing = JsonSerializer.Deserialize<PairingResponse>(
            await response.Content.ReadAsStringAsync(),
            RemoteProfileJson.Options);
        if (string.IsNullOrWhiteSpace(pairing?.Token))
        {
            throw new InvalidOperationException($"{name} did not return pairing credentials.");
        }
        var existing = Profile.Computers.FirstOrDefault(computer =>
            computer.Host.Equals(host, StringComparison.OrdinalIgnoreCase) && computer.Port == port);
        if (existing is null)
        {
            if (Profile.Computers.Count >= 8)
            {
                throw new InvalidOperationException("A profile can contain at most 8 computers.");
            }
            Profile.Computers.Add(new RemoteComputer
            {
                Name = name,
                Host = host,
                Port = port,
                Token = pairing.Token,
            });
        }
        else
        {
            existing.Name = name;
            existing.Token = pairing.Token;
        }
        Commit();
        return $"Paired with {name}.";
    }

    public async Task ScanWifiNetworksAsync()
    {
        if (IsBusy)
        {
            return;
        }
        IsBusy = true;
        SetStatus("Scanning Wi-Fi through M5Paper...");
        try
        {
            var baseUri = DeviceRemoteUri();
            var wifiUri = new UriBuilder(baseUri) { Path = "/wifi/networks", Query = string.Empty }.Uri;
            using var request = AuthorizedRequest(HttpMethod.Get, wifiUri);
            using var response = await httpClient.SendAsync(request);
            response.EnsureSuccessStatusCode();
            var result = JsonSerializer.Deserialize<DeviceWifiScanResponse>(
                await response.Content.ReadAsStringAsync(),
                RemoteProfileJson.Options);
            WifiNetworks = result?.Networks
                .Where(network => !string.IsNullOrWhiteSpace(network.Ssid))
                .GroupBy(network => network.Ssid, StringComparer.Ordinal)
                .Select(group => group.MaxBy(network => network.Rssi)!)
                .OrderByDescending(network => network.Rssi)
                .ToArray() ?? [];
            SetStatus($"Found {WifiNetworks.Count} Wi-Fi networks");
        }
        catch (Exception exception) when (
            exception is HttpRequestException or TaskCanceledException or InvalidOperationException or JsonException)
        {
            SetStatus($"Wi-Fi scan failed: {exception.Message}");
        }
        finally
        {
            IsBusy = false;
            StatusChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public async Task<IReadOnlyList<RemoteApplication>> LoadApplicationsAsync(RemoteComputer computer)
    {
        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            $"http://{computer.Host}:{computer.Port}/applications");
        request.Headers.Authorization = new("Bearer", computer.Token);
        using var response = await httpClient.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return JsonSerializer.Deserialize<List<RemoteApplication>>(
            await response.Content.ReadAsStringAsync(),
            RemoteProfileJson.Options) ?? [];
    }

    public void Dispose()
    {
        liveSyncCancellation?.Cancel();
        liveSyncCancellation?.Dispose();
        httpClient.Dispose();
    }

    private void ScheduleLiveSync()
    {
        liveSyncCancellation?.Cancel();
        liveSyncCancellation?.Dispose();
        liveSyncCancellation = new CancellationTokenSource();
        var cancellationToken = liveSyncCancellation.Token;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(650, cancellationToken);
                if (cancellationToken.IsCancellationRequested || ValidationMessage is not null)
                {
                    return;
                }
                foreach (var retryDelay in new[] { TimeSpan.Zero, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(3) })
                {
                    if (retryDelay > TimeSpan.Zero)
                    {
                        await Task.Delay(retryDelay, cancellationToken);
                    }
                    if (await SendToDeviceAttemptAsync())
                    {
                        return;
                    }
                }
            }
            catch (OperationCanceledException)
            {
            }
        }, cancellationToken);
    }

    private async Task<bool> RunDeviceOperationAsync(
        string pendingStatus,
        Func<Uri, Task<string>> operation)
    {
        if (IsBusy)
        {
            return false;
        }
        IsBusy = true;
        SetStatus(pendingStatus);
        try
        {
            SetStatus(await operation(DeviceRemoteUri()));
            return true;
        }
        catch (Exception exception) when (
            exception is HttpRequestException or TaskCanceledException or InvalidOperationException or JsonException)
        {
            SetStatus($"Could not reach M5Paper: {exception.Message}");
            return false;
        }
        finally
        {
            IsBusy = false;
            StatusChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private HttpRequestMessage AuthorizedRequest(HttpMethod method, Uri uri)
    {
        var request = new HttpRequestMessage(method, uri);
        request.Headers.Authorization = new("Bearer", configuration.Token);
        return request;
    }

    private Uri DeviceRemoteUri()
    {
        var address = DeviceAddress.Trim();
        if (!address.Contains("://", StringComparison.Ordinal))
        {
            address = $"http://{address}";
        }
        if (!Uri.TryCreate(address, UriKind.Absolute, out var baseUri) || baseUri.Scheme != "http")
        {
            throw new InvalidOperationException("The M5Paper address is invalid.");
        }
        return new UriBuilder(baseUri) { Path = "/remote", Query = string.Empty }.Uri;
    }

    private void EnsureLocalComputer()
    {
        var local = Profile.Computers.FirstOrDefault(computer => computer.Token == configuration.Token);
        var host = LocalIpv4Address() ?? $"{Environment.MachineName}.local";
        if (local is null)
        {
            local = new RemoteComputer
            {
                Name = Environment.MachineName,
                Host = host,
                Port = configuration.Port,
                Token = configuration.Token,
            };
            if (Profile.Computers.Count < 8)
            {
                Profile.Computers.Add(local);
            }
        }
        else
        {
            local.Name = Environment.MachineName;
            local.Host = host;
            local.Port = configuration.Port;
        }
        Profile.MacHost = local.Host;
        Profile.MacPort = local.Port;
        Profile.MacToken = local.Token;
    }

    private void SetStatus(string value)
    {
        Status = value;
        StatusChanged?.Invoke(this, EventArgs.Empty);
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(DocumentPath)!);
            var document = new RemoteEditorDocument(Profile, DeviceAddress);
            var json = JsonSerializer.Serialize(document, RemoteProfileJson.Options);
            var temporaryPath = DocumentPath + ".tmp";
            File.WriteAllText(temporaryPath, json);
            File.Move(temporaryPath, DocumentPath, true);
        }
        catch (IOException exception)
        {
            SetStatus($"Could not save editor: {exception.Message}");
        }
    }

    private static RemoteEditorDocument? LoadDocument()
    {
        try
        {
            return File.Exists(DocumentPath)
                ? JsonSerializer.Deserialize<RemoteEditorDocument>(
                    File.ReadAllText(DocumentPath),
                    RemoteProfileJson.Options)
                : null;
        }
        catch (Exception exception) when (exception is IOException or JsonException)
        {
            return null;
        }
    }

    private static RemoteProfile CreateStarterProfile() => new()
    {
        Pages =
        [
            new RemotePage
            {
                Name = "Main",
                Controls =
                [
                    RemoteControlCatalog.Create("play-pause"),
                    RemoteControlCatalog.Create("volume-down"),
                    RemoteControlCatalog.Create("volume-up"),
                ],
            },
        ],
    };

    private static int LayoutUnits(RemotePage page) => page.Controls.Sum(control => LayoutUnits(control, page));

    private static int LayoutUnits(RemoteControl control, RemotePage page)
    {
        var (width, height) = Span(control, page);
        return width * height;
    }

    private static (int Width, int Height) Span(RemoteControl control, RemotePage page)
    {
        var legacyWidth = control.Kind == RemoteControlKind.TextBox
            ? Math.Clamp(control.TextBox?.GridWidth ?? 2, 1, 2)
            : 1;
        var legacyHeight = control.Kind switch
        {
            RemoteControlKind.Slider => 1,
            RemoteControlKind.TextBox => Math.Clamp(control.TextBox?.GridHeight ?? 1, 1, 8),
            _ => Math.Clamp(control.ButtonHeight ?? 2, 1, 2),
        };
        return (
            Math.Clamp(control.GridWidth ?? legacyWidth, 1, page.GridColumns),
            Math.Clamp(control.GridHeight ?? legacyHeight, 1, page.GridRows));
    }

    private static GridPlacement? Placement(RemoteControl control, int requestedSlot, RemotePage page)
    {
        var (width, height) = Span(control, page);
        var row = requestedSlot / page.GridColumns;
        var column = width == page.GridColumns ? 0 : requestedSlot % page.GridColumns;
        return column + width <= page.GridColumns && row + height <= page.GridRows
            ? new GridPlacement(row * page.GridColumns + column, width, height)
            : null;
    }

    private static HashSet<int> Cells(GridPlacement placement, int columns)
    {
        var cells = new HashSet<int>();
        var row = placement.Slot / columns;
        var column = placement.Slot % columns;
        for (var y = row; y < row + placement.Height; y++)
        {
            for (var x = column; x < column + placement.Width; x++)
            {
                cells.Add(y * columns + x);
            }
        }
        return cells;
    }

    private static string? LocalIpv4Address() => Dns.GetHostAddresses(Dns.GetHostName())
        .FirstOrDefault(address => address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(address))
        ?.ToString();

    private static string DocumentPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "paperGIF",
        "remote-editor.json");

    private sealed record RemoteEditorDocument(RemoteProfile Profile, string DeviceAddress);
    private sealed record PairingRequest(string DeviceName);
    private sealed record PairingResponse(string Token);
    private sealed record DeviceWifiScanResponse(List<DeviceWifiNetwork> Networks);
    private readonly record struct GridPlacement(int Slot, int Width, int Height);
}

internal sealed record DeviceWifiNetwork(string Ssid, int Rssi, bool Secure)
{
    public string DisplayName => $"{Ssid}  ({Rssi} dBm){(Secure ? "  secured" : string.Empty)}";
}

internal sealed record RemoteApplication(string Name, string Path, string? IconBitmap);