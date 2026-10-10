using System.Net;
using System.Net.NetworkInformation;
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
        EnsureLocalComputer();
        TargetComputer(page.Controls, LocalComputerId, includeModuleActions: false);
        Profile.Pages.Add(page);
        SelectedPageId = page.Id;
        SelectedControlId = null;
        Commit();
    }

    internal static bool RunsOnComputer(RemoteActionType type) => type is
        RemoteActionType.ComputerMedia or RemoteActionType.ComputerKey or RemoteActionType.ComputerOpen or
        RemoteActionType.AppleShortcut or RemoteActionType.ComputerScript or RemoteActionType.OpenBuilds or
        RemoteActionType.Module or RemoteActionType.NetHomePower or RemoteActionType.NetHomeTemperature or
        RemoteActionType.NetHomeTemperatureStep or RemoteActionType.NetHomeMode or
        RemoteActionType.NetHomeFan or RemoteActionType.NetHomeAuto;

    private static bool RunsOnComputer(RemoteTextSource source) => source is
        RemoteTextSource.ComputerScript or RemoteTextSource.AppleShortcut or
        RemoteTextSource.NowPlaying or RemoteTextSource.OpenBuildsPosition;

    // Module runtimes such as Matter exist only in the Mac companion, so this PC never targets itself for them.
    internal static void TargetComputer(
        IEnumerable<RemoteControl> controls,
        string? computerId,
        bool replaceExisting = true,
        bool includeModuleActions = true)
    {
        if (string.IsNullOrEmpty(computerId))
        {
            return;
        }
        bool Targets(RemoteActionType type) =>
            RunsOnComputer(type) && (includeModuleActions || type != RemoteActionType.Module);
        Guid? textComputerId = Guid.TryParse(computerId, out var parsedId) ? parsedId : null;
        foreach (var control in controls)
        {
            if (Targets(control.Action.Type) && (replaceExisting || string.IsNullOrEmpty(control.Action.ComputerID)))
            {
                control.Action.ComputerID = computerId;
            }
            if (control.TextBox is not { } textBox)
            {
                continue;
            }
            if (textComputerId is not null && RunsOnComputer(textBox.Source) && (replaceExisting || textBox.ComputerID is null))
            {
                textBox.ComputerID = textComputerId;
            }
            if (textBox.TapAction is { } tapAction && Targets(tapAction.Type) &&
                (replaceExisting || string.IsNullOrEmpty(tapAction.ComputerID)))
            {
                tapAction.ComputerID = computerId;
            }
        }
    }

    // Mirrors the Mac editor so a type change never keeps the previous action's text or values.
    internal static void ApplyActionDefaults(RemoteControl control, RemoteActionType type)
    {
        if (control.Action.Type == type)
        {
            return;
        }
        var host = control.Action.Host;
        var computerId = control.Action.ComputerID;
        control.IconBitmap = null;
        control.Action = type switch
        {
            RemoteActionType.IPhoneMedia => new() { Text = "playPause" },
            RemoteActionType.ComputerMedia => new() { Text = "playPause", ComputerID = computerId },
            RemoteActionType.IPhoneHomePower => new() { Host = host, Text = "toggle" },
            RemoteActionType.ComputerKey => new() { Text = "space", ComputerID = computerId },
            RemoteActionType.OpenBuilds => new() { Host = "127.0.0.1", Text = "jogXPositive", Value = 1, ComputerID = computerId },
            RemoteActionType.WledPower or RemoteActionType.EWeLinkPower => new() { Host = host, Text = "toggle" },
            RemoteActionType.WledPreset => new() { Host = host, Value = 1 },
            RemoteActionType.WledBrightness => new() { Host = host, Value = 128 },
            RemoteActionType.LocalHTTP => new() { Host = host, Text = "/", HttpMethod = "GET" },
            RemoteActionType.NetHomePower => new() { Host = host, Text = "toggle", ComputerID = computerId },
            RemoteActionType.NetHomeTemperature => new() { Host = host, Value = 22, ValueTenths = 220, ComputerID = computerId },
            RemoteActionType.NetHomeTemperatureStep => new() { Host = host, Value = 1, ComputerID = computerId },
            RemoteActionType.NetHomeMode => new() { Host = host, Text = "auto", ComputerID = computerId },
            RemoteActionType.NetHomeFan => new() { Host = host, Value = 40, ComputerID = computerId },
            RemoteActionType.NetHomeAuto => new()
            {
                Host = host, Text = "cool", Value = 22, ComputerID = computerId,
                DeadbandTenths = 10, HumidityThreshold = 65, MinimumCycleMinutes = 10,
            },
            RemoteActionType.Page => new(),
            _ => new() { ComputerID = computerId },
        };
        control.Action.Type = type;
        if (type == RemoteActionType.ComputerOpen)
        {
            control.Title = "Open App or URL";
        }
        if (control.Kind == RemoteControlKind.TextBox)
        {
            return;
        }
        control.Kind = type is RemoteActionType.WledBrightness or RemoteActionType.NetHomeTemperature or
            RemoteActionType.NetHomeFan ? RemoteControlKind.Slider : RemoteControlKind.Button;
        if (control.Kind == RemoteControlKind.Slider)
        {
            control.IsToggle = null;
        }
        else if (type is RemoteActionType.NetHomeAuto or RemoteActionType.EWeLinkPower or RemoteActionType.IPhoneHomePower)
        {
            control.IsToggle = true;
        }
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
        TargetOpenBuilds([control], ExistingOpenBuildsComputerId ?? LocalComputerId);
        TargetComputer([control], LocalComputerId, replaceExisting: false, includeModuleActions: false);
        page.Controls.Add(control);
        SelectedControlId = control.Id;
        Commit();
        return true;
    }

    private string? LocalComputerId =>
        Profile.Computers.FirstOrDefault(computer => computer.Token == configuration.Token)?.Id.ToString();

    public string? EnsureLocalComputerId()
    {
        EnsureLocalComputer();
        return LocalComputerId;
    }

    private string? ExistingOpenBuildsComputerId => Profile.Pages
        .SelectMany(page => page.Controls)
        .Where(control => control.Action.Type == RemoteActionType.OpenBuilds)
        .Select(control => control.Action.ComputerID)
        .FirstOrDefault(id => !string.IsNullOrEmpty(id));

    private static bool IsLoopback(string? host) =>
        (host?.Trim() ?? string.Empty) is "" or "127.0.0.1" or "localhost" or "::1";

    // OpenBuilds at 127.0.0.1 means "the computer running it"; untargeted it would use the profile's default computer.
    internal static void TargetOpenBuilds(IEnumerable<RemoteControl> controls, string? computerId)
    {
        if (computerId is null)
        {
            return;
        }
        foreach (var control in controls)
        {
            if (control.Action.Type == RemoteActionType.OpenBuilds &&
                string.IsNullOrEmpty(control.Action.ComputerID) &&
                IsLoopback(control.Action.Host))
            {
                control.Action.ComputerID = computerId;
            }
            if (control.TextBox is { Source: RemoteTextSource.OpenBuildsPosition, ComputerID: null } textBox &&
                IsLoopback(textBox.SourceText.Split('|')[0]) &&
                Guid.TryParse(computerId, out var textComputerId))
            {
                textBox.ComputerID = textComputerId;
            }
        }
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
        if (page is null)
        {
            return;
        }
        var controls = page.Controls.Take(RemoteProfile.MaximumControlsPerPage).ToList();
        var sourceIndex = controls.FindIndex(candidate => candidate.Id == controlId);
        if (sourceIndex < 0 || Rearranged(controls, sourceIndex, requestedSlot, page) is not { } slots)
        {
            return;
        }
        for (var index = 0; index < slots.Length; index++)
        {
            controls[index].LayoutSlot = slots[index];
        }
        Commit();
    }

    private static GridPlacement?[] Placements(IReadOnlyList<RemoteControl> controls, RemotePage page)
    {
        var occupied = new HashSet<int>(ReservedCells(page));
        var result = new GridPlacement?[controls.Count];
        bool Place(int index, int slot)
        {
            if (slot < 0 || slot >= page.GridColumns * page.GridRows ||
                Placement(controls[index], slot, page) is not { } candidate)
            {
                return false;
            }
            var cells = Cells(candidate, page.GridColumns);
            if (occupied.Overlaps(cells))
            {
                return false;
            }
            occupied.UnionWith(cells);
            result[index] = candidate;
            return true;
        }
        for (var index = 0; index < controls.Count; index++)
        {
            if (controls[index].LayoutSlot is { } slot)
            {
                Place(index, slot);
            }
        }
        for (var index = 0; index < controls.Count; index++)
        {
            for (var slot = 0; result[index] is null && slot < page.GridColumns * page.GridRows; slot++)
            {
                Place(index, slot);
            }
        }
        return result;
    }

    // Final anchor slot for every control, or null if the drop isn't possible.
    // Dropping onto exactly one other control swaps the two.
    private static int?[]? Rearranged(
        IReadOnlyList<RemoteControl> controls, int sourceIndex, int requestedSlot, RemotePage page)
    {
        var columns = page.GridColumns;
        var current = Placements(controls, page);
        if (current[sourceIndex] is not { } source ||
            requestedSlot < 0 || requestedSlot >= columns * page.GridRows ||
            Placement(controls[sourceIndex], requestedSlot, page) is not { } requested ||
            requested.Slot == source.Slot)
        {
            return null;
        }
        var requestedCells = Cells(requested, columns);
        var occupants = Enumerable.Range(0, controls.Count)
            .Where(index => index != sourceIndex && current[index] is { } placement &&
                requestedCells.Overlaps(Cells(placement, columns)))
            .ToList();
        var slots = current.Select(placement => placement?.Slot).ToArray();
        switch (occupants.Count)
        {
            case 0:
                slots[sourceIndex] = requested.Slot;
                break;
            case 1:
                slots[sourceIndex] = current[occupants[0]]!.Value.Slot;
                slots[occupants[0]] = source.Slot;
                break;
            default:
                return null;
        }

        var occupied = new HashSet<int>(ReservedCells(page));
        for (var index = 0; index < slots.Length; index++)
        {
            if (slots[index] is not { } slot)
            {
                continue;
            }
            if (Placement(controls[index], slot, page) is not { } moved || moved.Slot != slot)
            {
                return null;
            }
            var cells = Cells(moved, columns);
            if (occupied.Overlaps(cells))
            {
                return null;
            }
            occupied.UnionWith(cells);
        }
        return slots;
    }

    public void Commit()
    {
        if (!isApplyingDeviceProfile)
        {
            Profile.MarkUpdated();
        }
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
                throw new InvalidOperationException(DeviceFailureMessage(response.StatusCode));
            }
            var loadedProfile = RemoteProfileJson.Deserialize(json);
            if (Profile.UpdatedAtMilliseconds > loadedProfile.UpdatedAtMilliseconds)
            {
                using var newerRequest = AuthorizedRequest(HttpMethod.Post, requestUri);
                newerRequest.Content = new StringContent(
                    RemoteProfileJson.Serialize(Profile),
                    Encoding.UTF8,
                    "application/json");
                using var newerResponse = await httpClient.SendAsync(newerRequest);
                newerResponse.EnsureSuccessStatusCode();
                HasLoadedDeviceProfile = true;
                return "Local settings were newer and were installed on M5Paper";
            }
            if (Profile.UpdatedAtMilliseconds == loadedProfile.UpdatedAtMilliseconds &&
                Profile.UpdatedAtMilliseconds > 0)
            {
                HasLoadedDeviceProfile = true;
                return "Settings are already current";
            }
            isApplyingDeviceProfile = true;
            try
            {
                Profile = loadedProfile;
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
                throw new InvalidOperationException(DeviceFailureMessage(response.StatusCode));
            }
            Save();
            return "Remote installed on M5Paper";
        });
    }

    internal static string DeviceFailureMessage(HttpStatusCode status) => status == HttpStatusCode.Unauthorized
        ? $"M5Paper doesn't recognize {Environment.MachineName} yet. Pair this PC from a computer the M5Paper already trusts (Connections > Find Computers)."
        : $"M5Paper returned {(int)status}.";

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

    public bool IsLocalComputer(RemoteComputer computer) => computer.Token == configuration.Token;

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

    private static int LayoutUnits(RemotePage page) =>
        ReservedCells(page).Count + page.Controls.Sum(control => LayoutUnits(control, page));

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

    // The settings panel content is 152x430 px; it occupies whole cells, matching the firmware.
    internal static (int Slot, int Width, int Height)? OpenBuildsSettingsBlock(RemotePage page)
    {
        if (page.Layout != RemotePageLayout.OpenBuildsController)
        {
            return null;
        }
        var columns = page.GridColumns;
        var rows = page.GridRows;
        var width = Math.Min(columns, (164 * columns + 503) / 504);
        var height = Math.Min(rows, (442 * rows + 711) / 712);
        if (page.OpenBuildsController?.SettingsSlot is { } slot && slot >= 0 &&
            slot % columns + width <= columns && slot / columns + height <= rows)
        {
            return (slot, width, height);
        }
        var row = Math.Min((150 * rows + 711) / 712, rows - height);
        return (row * columns + columns - width, width, height);
    }

    internal static HashSet<int> ReservedCells(RemotePage page) =>
        OpenBuildsSettingsBlock(page) is { } block
            ? Cells(new GridPlacement(block.Slot, block.Width, block.Height), page.GridColumns)
            : [];

    public void MoveOpenBuildsSettings(int requestedSlot)
    {
        var page = SelectedPage;
        if (page is null || OpenBuildsSettingsBlock(page) is not { } current)
        {
            return;
        }
        var columns = page.GridColumns;
        var column = Math.Clamp(requestedSlot % columns, 0, columns - current.Width);
        var row = Math.Clamp(requestedSlot / columns, 0, page.GridRows - current.Height);
        var moved = new GridPlacement(row * columns + column, current.Width, current.Height);
        if (moved.Slot == current.Slot)
        {
            return;
        }
        var controls = page.Controls.Take(RemoteProfile.MaximumControlsPerPage).ToList();
        var placements = Placements(controls, page);
        var movedCells = Cells(moved, columns);
        if (placements.Any(placement => placement is { } existing && movedCells.Overlaps(Cells(existing, columns))))
        {
            return;
        }
        for (var index = 0; index < placements.Length; index++)
        {
            controls[index].LayoutSlot = placements[index]?.Slot;
        }
        page.OpenBuildsController ??= new OpenBuildsControllerSettings();
        page.OpenBuildsController.SettingsSlot = moved.Slot;
        Commit();
    }

    internal static string? LocalIpv4Address()
    {
        var candidates = NetworkInterface.GetAllNetworkInterfaces()
            .Where(network => network.OperationalStatus == OperationalStatus.Up)
            .Select(network => (Network: network, Properties: network.GetIPProperties()))
            .SelectMany(candidate => candidate.Properties.UnicastAddresses
                .Where(unicast => unicast.Address.AddressFamily == AddressFamily.InterNetwork)
                .Select(unicast => (
                    unicast.Address,
                    HasDefaultGateway: candidate.Properties.GatewayAddresses.Any(gateway =>
                        gateway.Address.AddressFamily == AddressFamily.InterNetwork &&
                        !gateway.Address.Equals(IPAddress.Any)))))
            .ToArray();
        return PreferredIpv4Address(candidates);
    }

    internal static string? PreferredIpv4Address(
        IEnumerable<(IPAddress Address, bool HasDefaultGateway)> candidates) => candidates
        .Where(candidate => !IPAddress.IsLoopback(candidate.Address) &&
            !candidate.Address.Equals(IPAddress.Any) &&
            !candidate.Address.GetAddressBytes().Take(2).SequenceEqual(new byte[] { 169, 254 }))
        .OrderByDescending(candidate => candidate.HasDefaultGateway)
        .Select(candidate => candidate.Address.ToString())
        .FirstOrDefault();

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