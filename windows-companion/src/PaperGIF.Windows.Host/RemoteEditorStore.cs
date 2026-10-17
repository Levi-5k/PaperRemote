using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using PaperGIF.Windows.Core.Models;
using PaperGIF.Windows.Core.Serialization;
using PaperGIF.Windows.Core;
using PaperGIF.Windows.Core.Ble;

namespace PaperGIF.Windows.Host;

internal sealed class RemoteEditorStore : IDisposable
{
    private readonly CompanionConfiguration configuration;
    private readonly HttpClient httpClient = new(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(15) };
    private readonly HttpClient catalogClient = new(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(10) };
    // DeviceControlClient applies its own per-request timeout.
    private readonly HttpClient controlsClient = new(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = Timeout.InfiniteTimeSpan };
    private readonly BleSessionPool? blePool;
    private readonly Dictionary<string, SavedDevice> devices = new(StringComparer.Ordinal);
    private CancellationTokenSource sessionCancellation = new();
    private int sessionGeneration;
    private string deviceAddress = "192.168.4.1";
    private string? activeDeviceId;
    private IDeviceAdapter? adapter;
    private DeviceLayout? manualLayout;
    private CancellationTokenSource? liveSyncCancellation;
    // What the M5Paper is known to have installed; edits are diffed against it.
    private JsonObject? deviceProfileJson;
    private bool isApplyingDeviceProfile;

    public RemoteEditorStore(CompanionConfiguration configuration, BleSessionPool? blePool = null)
    {
        this.configuration = configuration;
        this.blePool = blePool;
        var document = LoadDocument();
        Profile = document?.Profile ?? CreateStarterProfile();
        deviceAddress = document?.DeviceAddress ?? "192.168.4.1";
        foreach (var device in document?.Devices ?? [])
            devices[device.DeviceID] = device;
        activeDeviceId = document?.ActiveDeviceID;
        if (activeDeviceId is { } id && devices.TryGetValue(id, out var saved))
        {
            Profile = saved.Profile;
            manualLayout = saved.LayoutOverride;
            RestoreOfflineDescriptor(saved);
        }
        EnsureLocalComputer();
        SelectedPageId = Profile.Pages.FirstOrDefault()?.Id;
    }

    public event EventHandler? Changed;
    public event EventHandler? StatusChanged;

    public RemoteProfile Profile { get; private set; }
    public string DeviceAddress
    {
        get => deviceAddress;
        set
        {
            if (deviceAddress == value) return;
            Save();
            sessionCancellation.Cancel();
            sessionCancellation.Dispose();
            sessionCancellation = new();
            sessionGeneration++;
            liveSyncCancellation?.Cancel();
            deviceAddress = value;
            adapter = null;
            Descriptor = null;
            Layout = null;
            manualLayout = null;
            deviceProfileJson = null;
            HasLoadedDeviceProfile = false;
            IsBusy = false;
            var saved = devices.Values.Where(device => device.Address == value)
                .OrderBy(device => device.Descriptor is null ? 1 : 0).FirstOrDefault();
            activeDeviceId = saved?.DeviceID;
            Profile = saved?.Profile ?? CreateEmptyProfile();
            manualLayout = saved?.LayoutOverride;
            if (saved is not null) RestoreOfflineDescriptor(saved);
            SelectedPageId = Profile.Pages.FirstOrDefault()?.Id;
            SelectedControlId = null;
            SelectedInputID = null;
            EnsureLocalComputer();
            Save();
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }
    public DeviceDescriptor? Descriptor { get; private set; }
    public DeviceLayout? Layout { get; private set; }
    public string CatalogStatus { get; private set; } = "Connect to identify device";
    public bool CanEditTouchscreen => Descriptor?.Display?.Touch == true;
    public bool CanUploadMedia => Descriptor is { Display: { Width: 540, Height: 960, PixelFormat: "gray4" }, Capabilities.Media: true };
    public bool CanInstallM5Firmware => adapter is not null && FirmwareCompatibility.SupportsM5PaperUpdate(Descriptor);
    public string? SelectedInputID { get; set; }
    public IReadOnlyList<SavedDevice> SavedDevices => devices.Values.ToArray();
    public CancellationToken DeviceSessionCancellation => sessionCancellation.Token;

    private void RestoreOfflineDescriptor(SavedDevice saved)
    {
        try
        {
            saved.Descriptor?.Validate();
            Descriptor = saved.Descriptor;
            if (Descriptor is not null)
            {
                ApplyLayout(Descriptor.Layout);
                CatalogStatus = "Saved device layout (offline; reconnect to verify capabilities)";
            }
        }
        catch (JsonException) { Descriptor = null; Layout = null; }
    }
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

    public string? ValidationMessage
    {
        get
        {
            if (ValidateProfile(Profile, Descriptor) is { } error) return error;
            if (Descriptor is { } descriptor)
            {
                try { _ = RemoteProfileJson.SerializeForDevice(Profile, descriptor); }
                catch (InvalidOperationException exception) { return exception.Message; }
            }
            return null;
        }
    }

    public async Task IdentifyDeviceAsync()
    {
        var generation = sessionGeneration;
        var cancellationToken = sessionCancellation.Token;
        var identified = await DeviceAdapters.IdentifyAsync(httpClient, DeviceRemoteUri(), configuration.Token, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        if (generation != sessionGeneration) return;
        if (activeDeviceId != identified.Descriptor.DeviceID)
        {
            // Only the verified legacy adapter inherits the old single-device document.
            if (devices.TryGetValue(identified.Descriptor.DeviceID, out var saved))
            {
                Profile = saved.Profile;
                manualLayout = saved.LayoutOverride;
            }
            else if (!identified.IsLegacy)
            {
                Profile = CreateEmptyProfile();
                manualLayout = null;
            }
            activeDeviceId = identified.Descriptor.DeviceID;
            EnsureLocalComputer();
            SelectedPageId = Profile.Pages.FirstOrDefault()?.Id;
            SelectedControlId = null;
        }
        var unchanged = adapter is not null && Descriptor is not null &&
            JsonSerializer.Serialize(Descriptor, DeviceDescriptor.JsonOptions) ==
            JsonSerializer.Serialize(identified.Descriptor, DeviceDescriptor.JsonOptions);
        adapter = identified;
        if (unchanged)
        {
            Save();
            return;
        }
        Descriptor = identified.Descriptor;
        var catalog = new BoardCatalog(catalogClient, Path.Combine(Path.GetDirectoryName(DocumentPath)!, "boards"));
        var cached = catalog.Cached(Descriptor);
        ApplyLayout(cached.Layout);
        CatalogStatus = cached.Status;
        Save();
        Changed?.Invoke(this, EventArgs.Empty);
        _ = RefreshBoardAsync(catalog, Descriptor, generation, cancellationToken);
    }

    private async Task RefreshBoardAsync(BoardCatalog catalog, DeviceDescriptor descriptor, int generation, CancellationToken cancellationToken)
    {
        try
        {
            var resolved = await catalog.ResolveAsync(descriptor, cancellationToken);
            if (generation != sessionGeneration || cancellationToken.IsCancellationRequested ||
                !ReferenceEquals(Descriptor, descriptor)) return;
            ApplyLayout(resolved.Layout);
            CatalogStatus = resolved.Status;
            Changed?.Invoke(this, EventArgs.Empty);
        }
        catch (OperationCanceledException) { }
    }

    public async Task RefreshBoardCatalogAsync()
    {
        if (Descriptor is not { } descriptor) return;
        var catalog = new BoardCatalog(catalogClient, Path.Combine(Path.GetDirectoryName(DocumentPath)!, "boards"));
        await RefreshBoardAsync(catalog, descriptor, sessionGeneration, sessionCancellation.Token);
    }

    private void ApplyLayout(DeviceLayout layout)
    {
        if (manualLayout is not null)
        {
            try { Descriptor!.ValidateLayout(manualLayout); layout = manualLayout; }
            catch (JsonException) { manualLayout = null; }
        }
        Layout = layout;
    }

    public void ImportLayout(string json)
    {
        if (Descriptor is null) throw new InvalidOperationException("Identify a device before importing a layout.");
        if (Encoding.UTF8.GetByteCount(json) > 65_536) throw new JsonException("Layout exceeds 64 KiB.");
        var layout = JsonSerializer.Deserialize<DeviceLayout>(json, DeviceDescriptor.JsonOptions)
            ?? throw new JsonException("Empty layout.");
        Descriptor.ValidateLayout(layout);
        manualLayout = layout;
        Layout = layout;
        Commit();
    }

    public void UseAutomaticLayout()
    {
        manualLayout = null;
        if (Descriptor is { } descriptor) Layout = descriptor.Layout;
        Commit();
        _ = RefreshBoardCatalogAsync();
    }

    public HardwareBinding BindingFor(string inputID, string eventName, string? direction = null)
    {
        if (Descriptor is null || !Descriptor.Inputs.Any(input => input.Id == inputID && input.Events.Contains(eventName)))
            throw new InvalidOperationException("Unknown physical input/event.");
        Profile.HardwareBindings ??= [];
        var binding = Profile.HardwareBindings.FirstOrDefault(binding => binding.InputID == inputID && binding.Event == eventName && binding.Direction == direction);
        if (binding is not null) return binding;
        binding = new() { InputID = inputID, Event = eventName, Direction = direction,
            Mode = direction is not null ? "action" : eventName == "rotate" ? "relative" : eventName == "change" ? "absolute" : "action",
            Action = new() { Type = direction is null && eventName is "rotate" or "change" ? RemoteActionType.WledBrightness : RemoteActionType.ComputerKey,
                Text = direction is null && eventName is "rotate" or "change" ? "" : "space", ComputerID = LocalComputerId } };
        Profile.HardwareBindings.Add(binding);
        Profile.Version = 7;
        Commit();
        return binding;
    }

    internal static string? ValidateProfile(RemoteProfile profile, DeviceDescriptor? descriptor = null)
    {
        if (profile.Pages.Count < 1 || profile.Pages.Count > (descriptor?.Capabilities.MaxPages ?? 8))
        {
            return $"A remote needs between 1 and {descriptor?.Capabilities.MaxPages ?? 8} pages.";
        }
        if (profile.Pages.Any(page =>
            page.Controls.Count > (descriptor?.Capabilities.MaxControls ?? RemoteProfile.MaximumControlsPerPage) ||
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
        if (Profile.Pages.Count >= (Descriptor?.Capabilities.MaxPages ?? 8))
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
        if (Profile.Pages.Count >= (Descriptor?.Capabilities.MaxPages ?? 8))
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
        if (page is null || ArrangementAfterMove(page, controlId, requestedSlot) is not { } slots)
        {
            return;
        }
        var controls = page.Controls.Take(RemoteProfile.MaximumControlsPerPage).ToList();
        for (var index = 0; index < slots.Length; index++)
        {
            controls[index].LayoutSlot = slots[index];
        }
        Commit();
    }

    // Slot for each of the page's first controls after the move, or null if the drop isn't possible.
    internal static int?[]? ArrangementAfterMove(RemotePage page, Guid controlId, int requestedSlot)
    {
        var controls = page.Controls.Take(RemoteProfile.MaximumControlsPerPage).ToList();
        var sourceIndex = controls.FindIndex(candidate => candidate.Id == controlId);
        return sourceIndex < 0 ? null : Rearranged(controls, sourceIndex, requestedSlot, page);
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
    // Controls under the drop move into the space it left, or else the nearest free spot.
    private static int?[]? Rearranged(
        IReadOnlyList<RemoteControl> controls, int sourceIndex, int requestedSlot, RemotePage page)
    {
        var columns = page.GridColumns;
        var rows = page.GridRows;
        var current = Placements(controls, page);
        if (current[sourceIndex] is not { } source ||
            requestedSlot < 0 || requestedSlot >= columns * rows ||
            Placement(controls[sourceIndex], requestedSlot, page) is not { } requested ||
            requested.Slot == source.Slot)
        {
            return null;
        }
        var requestedCells = Cells(requested, columns);
        var occupied = new HashSet<int>(ReservedCells(page));
        if (occupied.Overlaps(requestedCells))
        {
            return null;
        }
        var occupants = Enumerable.Range(0, controls.Count)
            .Where(index => index != sourceIndex && current[index] is { } placement &&
                requestedCells.Overlaps(Cells(placement, columns)))
            .ToList();
        var slots = current.Select(placement => placement?.Slot).ToArray();
        slots[sourceIndex] = requested.Slot;
        occupied.UnionWith(requestedCells);
        for (var index = 0; index < controls.Count; index++)
        {
            if (index != sourceIndex && !occupants.Contains(index) && current[index] is { } pinned)
            {
                occupied.UnionWith(Cells(pinned, columns));
            }
        }

        var columnShift = source.Slot % columns - requested.Slot % columns;
        var rowShift = source.Slot / columns - requested.Slot / columns;
        foreach (var index in occupants)
        {
            var original = current[index]!.Value;
            int Distance(int slot)
            {
                var dx = slot % columns - original.Slot % columns;
                var dy = slot / columns - original.Slot / columns;
                return dx * dx + dy * dy;
            }
            var shiftedColumn = original.Slot % columns + columnShift;
            var shiftedRow = original.Slot / columns + rowShift;
            IEnumerable<int> candidates = Enumerable.Range(0, columns * rows)
                .OrderBy(Distance).ThenBy(slot => slot);
            if (shiftedColumn >= 0 && shiftedColumn < columns && shiftedRow >= 0 && shiftedRow < rows)
            {
                candidates = candidates.Prepend(shiftedRow * columns + shiftedColumn);
            }
            GridPlacement? fit = null;
            foreach (var candidate in candidates)
            {
                if (Placement(controls[index], candidate, page) is { } moved && moved.Slot == candidate &&
                    !occupied.Overlaps(Cells(moved, columns)))
                {
                    fit = moved;
                    break;
                }
            }
            if (fit is not { } placed)
            {
                return null;
            }
            slots[index] = placed.Slot;
            occupied.UnionWith(Cells(placed, columns));
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
        await RunDeviceOperationAsync("Identifying and loading device...", async requestUri =>
        {
            var currentAdapter = adapter ?? throw new InvalidOperationException("Unsupported device adapter.");
            var cancellationToken = sessionCancellation.Token;
            var json = await currentAdapter.ReadProfileAsync(cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            var loadedProfile = RemoteProfileJson.Deserialize(json);
            _ = RemoteProfileJson.SerializeForDevice(loadedProfile, currentAdapter.Descriptor);
            if (Profile.UpdatedAtMilliseconds > loadedProfile.UpdatedAtMilliseconds)
            {
                await currentAdapter.WriteProfileAsync(Profile, cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
                deviceProfileJson = JsonNode.Parse(RemoteProfileJson.SerializeForDevice(Profile, currentAdapter.Descriptor)) as JsonObject;
                HasLoadedDeviceProfile = true;
                return "Local settings were newer and were installed on device";
            }
            deviceProfileJson = JsonNode.Parse(json) as JsonObject;
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
            return "Loaded from device";
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
        return await RunDeviceOperationAsync("Sending to device...", async requestUri =>
        {
            var currentAdapter = adapter ?? throw new InvalidOperationException("Unsupported device adapter.");
            var cancellationToken = sessionCancellation.Token;
            var profileJson = RemoteProfileJson.SerializeForDevice(Profile, currentAdapter.Descriptor);
            var current = JsonNode.Parse(profileJson) as JsonObject;
            if (currentAdapter.IsLegacy && deviceProfileJson is { } installed && current is not null &&
                ChangedControls(installed, current) is { } changes)
            {
                if (changes.Count == 0)
                {
                    return "M5Paper is up to date";
                }
                var controlsUri = new UriBuilder(requestUri) { Path = "/remote/controls" }.Uri;
                using var controlsRequest = AuthorizedRequest(HttpMethod.Post, controlsUri);
                controlsRequest.Content = new StringContent(
                    ControlUpdatePayload(current, changes), Encoding.UTF8, "application/json");
                using var controlsResponse = await httpClient.SendAsync(controlsRequest, cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
                if (controlsResponse.IsSuccessStatusCode)
                {
                    await DeviceAdapters.RequireAcknowledgementAsync(controlsResponse, cancellationToken);
                    cancellationToken.ThrowIfCancellationRequested();
                    deviceProfileJson = current;
                    Save();
                    return "Remote updated on M5Paper";
                }
                // Older firmware or a profile changed elsewhere: send everything instead.
                deviceProfileJson = null;
            }
            await currentAdapter.WriteProfileAsync(Profile, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            deviceProfileJson = current;
            Save();
            return "Remote installed on device";
        });
    }

    // Controls whose settings differ, or null when anything else changed and the whole profile must be sent.
    internal static List<(string PageId, JsonNode Control)>? ChangedControls(JsonObject installed, JsonObject current)
    {
        var before = (JsonObject)installed.DeepClone();
        var after = (JsonObject)current.DeepClone();
        before.Remove("updatedAtMilliseconds");
        after.Remove("updatedAtMilliseconds");
        if (before["pages"] is not JsonArray beforePages || after["pages"] is not JsonArray afterPages ||
            beforePages.Count != afterPages.Count)
        {
            return null;
        }
        var changes = new List<(string PageId, JsonNode Control)>();
        for (var pageIndex = 0; pageIndex < afterPages.Count; pageIndex++)
        {
            if (beforePages[pageIndex] is not JsonObject beforePage || afterPages[pageIndex] is not JsonObject afterPage ||
                beforePage["controls"] is not JsonArray beforeControls ||
                afterPage["controls"] is not JsonArray afterControls ||
                beforeControls.Count != afterControls.Count)
            {
                return null;
            }
            for (var controlIndex = 0; controlIndex < afterControls.Count; controlIndex++)
            {
                var beforeControl = beforeControls[controlIndex];
                var afterControl = afterControls[controlIndex];
                if (beforeControl?["id"]?.ToString() != afterControl?["id"]?.ToString())
                {
                    return null;
                }
                if (!JsonNode.DeepEquals(beforeControl, afterControl))
                {
                    changes.Add((afterPage["id"]?.ToString() ?? string.Empty, afterControl!.DeepClone()));
                }
            }
            beforePage.Remove("controls");
            afterPage.Remove("controls");
        }
        return JsonNode.DeepEquals(before, after) ? changes : null;
    }

    // Body for the M5Paper's POST /remote/controls.
    internal static string ControlUpdatePayload(JsonObject profile, IEnumerable<(string PageId, JsonNode Control)> changes)
    {
        var body = new JsonObject
        {
            ["updatedAtMilliseconds"] = profile["updatedAtMilliseconds"]?.DeepClone(),
            ["controls"] = new JsonArray(changes
                .Select(change => (JsonNode)new JsonObject
                {
                    ["pageID"] = change.PageId,
                    ["control"] = change.Control.DeepClone(),
                })
                .ToArray()),
        };
        if (profile["buttonBackground"] is { } background)
        {
            body["buttonBackground"] = background.DeepClone();
        }
        return body.ToJsonString();
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
            exception is HttpRequestException or OperationCanceledException or InvalidOperationException or JsonException or DecoderFallbackException)
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
        sessionCancellation.Cancel();
        sessionCancellation.Dispose();
        catalogClient.Dispose();
        controlsClient.Dispose();
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
        var generation = sessionGeneration;
        // Edits to existing controls go to the M5Paper at once; other changes wait for typing to settle.
        var immediate = deviceProfileJson is { } installed &&
            JsonNode.Parse(RemoteProfileJson.Serialize(Profile)) is JsonObject current &&
            ChangedControls(installed, current) is not null;
        _ = SyncAsync();
        async Task SyncAsync()
        {
            try
            {
                await Task.Delay(immediate ? 0 : 650, cancellationToken);
                if (generation != sessionGeneration || cancellationToken.IsCancellationRequested || ValidationMessage is not null)
                {
                    return;
                }
                // Let an in-flight update finish instead of falling back to the slower retry delays.
                for (var waited = 0; IsBusy && waited < 5000; waited += 25)
                {
                    await Task.Delay(25, cancellationToken);
                }
                foreach (var retryDelay in new[] { TimeSpan.Zero, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(3) })
                {
                    if (retryDelay > TimeSpan.Zero)
                    {
                        await Task.Delay(retryDelay, cancellationToken);
                    }
                    cancellationToken.ThrowIfCancellationRequested();
                    if (generation != sessionGeneration) return;
                    if (await SendToDeviceAttemptAsync())
                    {
                        return;
                    }
                }
            }
            catch (OperationCanceledException)
            {
            }
        }
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
        var generation = sessionGeneration;
        var cancellationToken = sessionCancellation.Token;
        SetStatus(pendingStatus);
        try
        {
            await IdentifyDeviceAsync();
            cancellationToken.ThrowIfCancellationRequested();
            SetStatus(await operation(DeviceRemoteUri()));
            return true;
        }
        catch (Exception exception) when (
            exception is HttpRequestException or OperationCanceledException or InvalidOperationException or JsonException or DecoderFallbackException)
        {
            if (generation == sessionGeneration)
                SetStatus(exception is HttpRequestException { StatusCode: HttpStatusCode.Unauthorized }
                    ? DeviceFailureMessage(HttpStatusCode.Unauthorized)
                    : $"Device unavailable or unsupported: {exception.Message}");
            return false;
        }
        finally
        {
            if (generation == sessionGeneration)
            {
                IsBusy = false;
                StatusChanged?.Invoke(this, EventArgs.Empty);
            }
        }
    }

    /// <summary>The selected device's HTTP base address, or null when the address is invalid.</summary>
    public Uri? DeviceBaseUri()
    {
        try { return new UriBuilder(DeviceRemoteUri()) { Path = "/" }.Uri; }
        catch (InvalidOperationException) { return null; }
    }

    /// <summary>
    /// Controls for the identified device: HTTP first, then BLE when the descriptor lists <c>ble</c> and HTTP fails
    /// with a transport error. Null when no descriptor declares controls.
    /// </summary>
    public DeviceControlSession? CreateDeviceControlSession()
    {
        if (Descriptor is not { DeviceControls.Count: > 0 } descriptor) return null;
        var http = DeviceBaseUri() is { } baseUri && descriptor.SupportsTransport("http")
            ? new DeviceControlClient(controlsClient, baseUri, configuration.Token)
            : null;
        var ble = blePool is not null && descriptor.SupportsTransport("ble")
            ? new BleDeviceControlTransport(blePool, descriptor.DeviceID, descriptor.Name)
            : null;
        if (http is null && ble is null) return null;
        return new DeviceControlSession(descriptor, http, ble);
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
        if (!Uri.TryCreate(address, UriKind.Absolute, out var baseUri) || baseUri.Scheme is not ("http" or "https") ||
            !string.IsNullOrEmpty(baseUri.UserInfo))
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
            var id = activeDeviceId ?? $"unidentified:{DeviceAddress}";
            devices[id] = new SavedDevice(id, DeviceAddress, Profile, Descriptor, manualLayout);
            var document = new RemoteEditorDocument(Profile, DeviceAddress, devices.Values.ToList(), activeDeviceId);
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

    private static RemoteProfile CreateEmptyProfile() => new() { Pages = [new() { Name = "Main" }] };
    internal sealed record SavedDevice(string DeviceID, string Address, RemoteProfile Profile,
        DeviceDescriptor? Descriptor = null, DeviceLayout? LayoutOverride = null);
    private sealed record RemoteEditorDocument(RemoteProfile Profile, string DeviceAddress,
        List<SavedDevice>? Devices = null, string? ActiveDeviceID = null);
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