using PaperGIF.Windows.Core.Ble;
using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Host;

/// <summary>
/// Nearby PaperRemote devices over Bluetooth for the editor's device picker. Scans only while
/// <see cref="Start"/> has been called (the editor window is visible) and expires devices unseen for 30 s.
/// </summary>
internal sealed class BleNearbyDeviceService : IDisposable
{
    private static readonly TimeSpan PruneInterval = TimeSpan.FromSeconds(5);
    private readonly IBleAdvertisementScanner scanner;
    private readonly BleDeviceIdentifier identifier;
    private readonly System.Threading.Timer pruneTimer;

    public BleNearbyDeviceService(IBleAdvertisementScanner scanner, IBleDeviceConnector connector, BleSessionPool pool)
    {
        this.scanner = scanner;
        identifier = new BleDeviceIdentifier(connector, Tracker, pool);
        scanner.Received += HandleReceived;
        Tracker.Changed += HandleTrackerChanged;
        pruneTimer = new System.Threading.Timer(_ => Tracker.Prune());
    }

    public BleNearbyDeviceTracker Tracker { get; } = new();
    public IReadOnlyList<BleNearbyDevice> Devices => Tracker.Devices;
    public event EventHandler? Changed;

    public void Start()
    {
        scanner.Start();
        pruneTimer.Change(PruneInterval, PruneInterval);
    }

    public void Stop()
    {
        scanner.Stop();
        pruneTimer.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    /// <summary>Reads and validates the device's descriptor over BLE, then disconnects.</summary>
    public Task<DeviceDescriptor> IdentifyAsync(BleNearbyDevice device, CancellationToken cancellationToken) =>
        identifier.IdentifyAsync(device, cancellationToken);

    public void Dispose()
    {
        scanner.Received -= HandleReceived;
        Tracker.Changed -= HandleTrackerChanged;
        pruneTimer.Dispose();
        scanner.Dispose();
    }

    private void HandleReceived(object? sender, BleAdvertisement advertisement) => Tracker.Observe(advertisement);
    private void HandleTrackerChanged(object? sender, EventArgs eventArgs) => Changed?.Invoke(this, EventArgs.Empty);
}
