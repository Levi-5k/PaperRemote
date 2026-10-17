using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Core.Ble;

/// <summary>One received advertisement or scan response. <paramref name="LocalName"/> usually arrives in the scan response.</summary>
public sealed record BleAdvertisement(ulong Address, string? LocalName, short Rssi, bool HasPaperRemoteService);

/// <summary>A nearby device advertising the PaperRemote service. <paramref name="DeviceId"/> is known once its descriptor was read.</summary>
public sealed record BleNearbyDevice(ulong Address, string Name, short Rssi, DateTimeOffset LastSeen, string? DeviceId = null)
{
    public BleCandidate Candidate => new(Address, Name);
}

/// <summary>Platform advertisement watcher (WinRT on Windows, fakes in tests).</summary>
public interface IBleAdvertisementScanner : IDisposable
{
    event EventHandler<BleAdvertisement>? Received;
    bool IsRunning { get; }
    void Start();
    void Stop();
}

/// <summary>
/// Thread-safe list of nearby PaperRemote devices built from advertisements. Names from scan responses are merged
/// with the service UUID from the primary advertisement, and devices unseen for <see cref="Expiry"/> are dropped.
/// </summary>
public sealed class BleNearbyDeviceTracker(TimeProvider? timeProvider = null, TimeSpan? expiry = null)
{
    private const int MaximumTracked = 256;
    private readonly object sync = new();
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly Dictionary<ulong, Entry> entries = [];
    private readonly Dictionary<ulong, string> identities = [];

    public TimeSpan Expiry { get; } = expiry ?? TimeSpan.FromSeconds(30);

    public event EventHandler? Changed;

    public IReadOnlyList<BleNearbyDevice> Devices
    {
        get
        {
            lock (sync)
                return entries
                    .Where(entry => entry.Value.HasService)
                    .Select(entry => new BleNearbyDevice(entry.Key, entry.Value.Name, entry.Value.Rssi, entry.Value.LastSeen,
                        identities.GetValueOrDefault(entry.Key)))
                    .OrderBy(device => device.Name, StringComparer.CurrentCultureIgnoreCase)
                    .ThenBy(device => device.Address)
                    .ToList();
        }
    }

    public void Observe(BleAdvertisement advertisement)
    {
        bool changed;
        lock (sync)
        {
            var now = clock.GetUtcNow();
            if (!entries.TryGetValue(advertisement.Address, out var entry))
            {
                if (entries.Count >= MaximumTracked) PruneLocked(now);
                if (entries.Count >= MaximumTracked) return;
                entry = new Entry();
                entries[advertisement.Address] = entry;
            }
            var name = string.IsNullOrWhiteSpace(advertisement.LocalName) ? entry.Name : advertisement.LocalName.Trim();
            var hasService = entry.HasService || advertisement.HasPaperRemoteService;
            // Only list changes matter to the UI; RSSI and timestamps update silently.
            changed = hasService && (!entry.HasService || name != entry.Name);
            entry.Name = name;
            entry.HasService = hasService;
            entry.Rssi = advertisement.Rssi;
            entry.LastSeen = now;
        }
        if (changed) Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Drops devices not seen within <see cref="Expiry"/>; returns true when the visible list changed.</summary>
    public bool Prune()
    {
        bool changed;
        lock (sync) changed = PruneLocked(clock.GetUtcNow());
        if (changed) Changed?.Invoke(this, EventArgs.Empty);
        return changed;
    }

    /// <summary>Records the deviceID read from a device's descriptor so the picker can deduplicate it against the LAN.</summary>
    public void RememberIdentity(ulong address, string deviceId)
    {
        lock (sync)
        {
            if (identities.TryGetValue(address, out var known) && known == deviceId) return;
            identities[address] = deviceId;
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Clear()
    {
        lock (sync) entries.Clear();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private bool PruneLocked(DateTimeOffset now)
    {
        var expired = entries.Where(entry => now - entry.Value.LastSeen > Expiry).ToList();
        foreach (var entry in expired) entries.Remove(entry.Key);
        return expired.Any(entry => entry.Value.HasService);
    }

    private sealed class Entry
    {
        public string Name { get; set; } = string.Empty;
        public bool HasService { get; set; }
        public short Rssi { get; set; }
        public DateTimeOffset LastSeen { get; set; }
    }
}

public enum DevicePickerSource { Lan, Bluetooth }

/// <summary>A controller found on the LAN. <paramref name="DeviceId"/> is known when the address was identified before.</summary>
public sealed record LanPickerDevice(string Address, string Name, string? DeviceId = null);

public sealed record DevicePickerEntry(
    DevicePickerSource Source,
    string DisplayName,
    string? DeviceId,
    LanPickerDevice? Lan = null,
    BleNearbyDevice? Bluetooth = null);

/// <summary>Builds the editor's device picker: LAN devices first, then Bluetooth-only devices.</summary>
public static class DevicePickerMerger
{
    public const string BluetoothSuffix = " (Bluetooth)";

    /// <summary>
    /// A Bluetooth device whose identified deviceID matches a LAN device is hidden (LAN wins); several Bluetooth
    /// addresses for the same deviceID collapse to the most recently seen one.
    /// </summary>
    public static IReadOnlyList<DevicePickerEntry> Merge(IEnumerable<LanPickerDevice> lan, IEnumerable<BleNearbyDevice> bluetooth)
    {
        var result = new List<DevicePickerEntry>();
        var lanIds = new HashSet<string>(StringComparer.Ordinal);
        var lanAddresses = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var device in lan)
        {
            if (!lanAddresses.Add(device.Address)) continue;
            if (device.DeviceId is { Length: > 0 } id) lanIds.Add(id);
            result.Add(new(DevicePickerSource.Lan, device.Name, device.DeviceId, Lan: device));
        }
        var bleOnly = bluetooth
            .Where(device => device.DeviceId is not { Length: > 0 } id || !lanIds.Contains(id))
            .GroupBy(device => device.DeviceId is { Length: > 0 } id ? id : $"address:{device.Address}", StringComparer.Ordinal)
            .Select(group => group.OrderByDescending(device => device.LastSeen).ThenByDescending(device => device.Rssi).First())
            .OrderBy(device => DisplayName(device.Name), StringComparer.CurrentCultureIgnoreCase)
            .ThenByDescending(device => device.Rssi)
            .ToList();
        var duplicateNames = bleOnly.GroupBy(device => DisplayName(device.Name), StringComparer.CurrentCultureIgnoreCase)
            .Where(group => group.Count() > 1)
            .Select(group => group.Key)
            .ToHashSet(StringComparer.CurrentCultureIgnoreCase);
        foreach (var device in bleOnly)
        {
            var name = DisplayName(device.Name);
            var label = duplicateNames.Contains(name) ? $"{name} {AddressSuffix(device.Address)}" : name;
            result.Add(new(DevicePickerSource.Bluetooth, label + BluetoothSuffix, device.DeviceId, Bluetooth: device));
        }
        return result;
    }

    /// <summary>"paperGIF SuperMini S3" → "SuperMini S3"; a bare or missing name stays recognisable.</summary>
    public static string DisplayName(string? advertisedName)
    {
        var name = advertisedName?.Trim() ?? string.Empty;
        const string prefix = "paperGIF ";
        if (name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) && name.Length > prefix.Length)
            name = name[prefix.Length..].Trim();
        return name.Length == 0 ? "PaperRemote device" : name;
    }

    private static string AddressSuffix(ulong address) => $"[{(address >> 8) & 0xFF:X2}:{address & 0xFF:X2}]";
}

/// <summary>
/// Identifies a picked Bluetooth device: connects, reads and validates its descriptor over the paged lease, then
/// disconnects so the firmware's connection slot is free. Later control sessions reconnect through
/// <see cref="BleSessionPool"/>, which is told the address to skip a scan-and-probe cycle.
/// </summary>
public sealed class BleDeviceIdentifier(IBleDeviceConnector connector, BleNearbyDeviceTracker? tracker = null, BleSessionPool? pool = null)
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(30);

    public async Task<DeviceDescriptor> IdentifyAsync(BleNearbyDevice device, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(Timeout);
        DeviceDescriptor descriptor;
        var link = await connector.ConnectAsync(device.Candidate, timeout.Token);
        try
        {
            descriptor = DeviceDescriptor.Parse(await link.ReadDescriptorAsync(timeout.Token));
        }
        finally
        {
            await link.DisposeAsync();
        }
        tracker?.RememberIdentity(device.Address, descriptor.DeviceID);
        pool?.RememberAddress(descriptor.DeviceID, device.Address);
        return descriptor;
    }
}
