using PaperGIF.Windows.Core.Ble;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Security.Cryptography;
using Windows.Storage.Streams;

namespace PaperGIF.Windows.Host;

/// <summary>
/// WinRT (Windows.Devices.Bluetooth) implementation of the PaperRemote BLE link. Untested at runtime on
/// non-Windows build machines; all protocol logic lives in Core and is covered there with fakes.
/// </summary>
internal sealed class WinRtBleConnector : IBleDeviceConnector
{
    public async Task<IReadOnlyList<BleCandidate>> ScanAsync(TimeSpan duration, CancellationToken cancellationToken)
    {
        var found = new Dictionary<ulong, (string Name, bool HasService)>();
        var watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
        void Received(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementReceivedEventArgs args)
        {
            lock (found)
            {
                found.TryGetValue(args.BluetoothAddress, out var entry);
                var name = string.IsNullOrEmpty(args.Advertisement.LocalName) ? entry.Name : args.Advertisement.LocalName;
                found[args.BluetoothAddress] = (name ?? string.Empty,
                    entry.HasService || args.Advertisement.ServiceUuids.Contains(BleProtocol.ServiceUuid));
            }
        }
        watcher.Received += Received;
        try
        {
            watcher.Start();
            await Task.Delay(duration, cancellationToken);
        }
        finally
        {
            watcher.Received -= Received;
            if (watcher.Status == BluetoothLEAdvertisementWatcherStatus.Started) watcher.Stop();
        }
        lock (found)
            return found.Where(entry => entry.Value.HasService)
                .Select(entry => new BleCandidate(entry.Key, entry.Value.Name))
                .ToList();
    }

    public async Task<IBleDeviceLink> ConnectAsync(BleCandidate candidate, CancellationToken cancellationToken)
    {
        var device = await BluetoothLEDevice.FromBluetoothAddressAsync(candidate.Address).AsTask(cancellationToken)
            ?? throw new IOException("Bluetooth device is not available.");
        try
        {
            var services = await device.GetGattServicesForUuidAsync(BleProtocol.ServiceUuid, BluetoothCacheMode.Uncached)
                .AsTask(cancellationToken);
            if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
                throw new IOException($"PaperRemote service unavailable ({services.Status}).");
            var service = services.Services[0];
            var control = await CharacteristicAsync(service, BleProtocol.ControlCharacteristicUuid, cancellationToken);
            var descriptor = await CharacteristicAsync(service, BleProtocol.DescriptorCharacteristicUuid, cancellationToken);
            var link = new WinRtBleLink(candidate, device, service, control, descriptor);
            try
            {
                await link.EnableNotificationsAsync(cancellationToken);
                return link;
            }
            catch
            {
                await link.DisposeAsync();
                throw;
            }
        }
        catch
        {
            device.Dispose();
            throw;
        }
    }

    private static async Task<GattCharacteristic> CharacteristicAsync(GattDeviceService service, Guid uuid,
        CancellationToken cancellationToken)
    {
        var result = await service.GetCharacteristicsForUuidAsync(uuid, BluetoothCacheMode.Uncached).AsTask(cancellationToken);
        if (result.Status != GattCommunicationStatus.Success || result.Characteristics.Count == 0)
            throw new IOException($"Characteristic {uuid} unavailable ({result.Status}).");
        return result.Characteristics[0];
    }
}

/// <summary>
/// Continuous active scan for the editor's device picker. The PaperRemote service UUID travels in the primary
/// advertisement while the local name arrives in the scan response, so a WinRT AdvertisementFilter on the UUID
/// would drop the names; filtering on the UUID happens in <see cref="BleNearbyDeviceTracker"/> instead.
/// </summary>
internal sealed class WinRtBleAdvertisementScanner : IBleAdvertisementScanner
{
    private readonly object sync = new();
    private BluetoothLEAdvertisementWatcher? watcher;

    public event EventHandler<BleAdvertisement>? Received;

    public bool IsRunning
    {
        get { lock (sync) return watcher?.Status is BluetoothLEAdvertisementWatcherStatus.Started or BluetoothLEAdvertisementWatcherStatus.Created; }
    }

    public void Start()
    {
        lock (sync)
        {
            if (watcher is { Status: BluetoothLEAdvertisementWatcherStatus.Started }) return;
            Detach();
            watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
            watcher.Received += HandleReceived;
            watcher.Stopped += HandleStopped;
            try { watcher.Start(); }
            catch (Exception exception) when (exception is not OutOfMemoryException)
            {
                DiagnosticLog.Error("Bluetooth scan could not start", exception);
                Detach();
            }
        }
    }

    public void Stop()
    {
        lock (sync) Detach();
    }

    public void Dispose() => Stop();

    private void Detach()
    {
        if (watcher is null) return;
        watcher.Received -= HandleReceived;
        watcher.Stopped -= HandleStopped;
        try
        {
            if (watcher.Status == BluetoothLEAdvertisementWatcherStatus.Started) watcher.Stop();
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            DiagnosticLog.Error("Bluetooth scan could not stop", exception);
        }
        watcher = null;
    }

    private void HandleReceived(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementReceivedEventArgs args)
    {
        try
        {
            Received?.Invoke(this, new BleAdvertisement(
                args.BluetoothAddress,
                args.Advertisement.LocalName,
                args.RawSignalStrengthInDBm,
                args.Advertisement.ServiceUuids.Contains(BleProtocol.ServiceUuid)));
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            DiagnosticLog.Error("Bluetooth advertisement handling failed", exception);
        }
    }

    private void HandleStopped(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementWatcherStoppedEventArgs args)
    {
        if (args.Error != BluetoothError.Success) DiagnosticLog.Info($"Bluetooth scan stopped: {args.Error}");
    }
}

internal sealed class WinRtBleLink(
    BleCandidate candidate,
    BluetoothLEDevice device,
    GattDeviceService service,
    GattCharacteristic control,
    GattCharacteristic descriptor) : IBleDeviceLink
{
    private static readonly TimeSpan DescriptorTimeout = TimeSpan.FromSeconds(20);
    private readonly SemaphoreSlim descriptorGate = new(1, 1);
    private int disposed;

    public BleCandidate Candidate => candidate;
    public bool IsConnected => Volatile.Read(ref disposed) == 0 && device.ConnectionStatus == BluetoothConnectionStatus.Connected;
    public event EventHandler<byte[]>? NotificationReceived;
    public event EventHandler? Disconnected;

    public async Task EnableNotificationsAsync(CancellationToken cancellationToken)
    {
        control.ValueChanged += HandleValueChanged;
        device.ConnectionStatusChanged += HandleConnectionStatusChanged;
        var status = await control.WriteClientCharacteristicConfigurationDescriptorAsync(
            GattClientCharacteristicConfigurationDescriptorValue.Notify).AsTask(cancellationToken);
        if (status != GattCommunicationStatus.Success) throw new IOException($"Could not enable notifications ({status}).");
    }

    public Task WriteControlAsync(byte[] frame, CancellationToken cancellationToken) => WriteAsync(control, frame, cancellationToken);

    public async Task<string> ReadDescriptorAsync(CancellationToken cancellationToken)
    {
        await descriptorGate.WaitAsync(cancellationToken);
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(DescriptorTimeout);
            return await BleControlCodec.ReadDescriptorAsync(
                (bytes, token) => WriteAsync(descriptor, bytes, token),
                async token =>
                {
                    var result = await descriptor.ReadValueAsync(BluetoothCacheMode.Uncached).AsTask(token);
                    if (result.Status != GattCommunicationStatus.Success) throw new IOException($"Descriptor read failed ({result.Status}).");
                    return ToArray(result.Value);
                },
                timeout.Token);
        }
        finally { descriptorGate.Release(); }
    }

    public ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return ValueTask.CompletedTask;
        control.ValueChanged -= HandleValueChanged;
        device.ConnectionStatusChanged -= HandleConnectionStatusChanged;
        // Disposing the service and device releases Windows' GATT session so the peripheral can disconnect.
        service.Dispose();
        device.Dispose();
        return ValueTask.CompletedTask;
    }

    private static async Task WriteAsync(GattCharacteristic characteristic, byte[] bytes, CancellationToken cancellationToken)
    {
        var result = await characteristic.WriteValueWithResultAsync(
            CryptographicBuffer.CreateFromByteArray(bytes), GattWriteOption.WriteWithResponse).AsTask(cancellationToken);
        if (result.Status != GattCommunicationStatus.Success)
            throw new IOException($"Bluetooth write failed ({result.Status}{(result.ProtocolError is { } error ? $", ATT 0x{error:X2}" : string.Empty)}).");
    }

    private static byte[] ToArray(IBuffer? buffer)
    {
        if (buffer is null || buffer.Length == 0) return [];
        CryptographicBuffer.CopyToByteArray(buffer, out var bytes);
        return bytes;
    }

    private void HandleValueChanged(GattCharacteristic sender, GattValueChangedEventArgs args)
    {
        try { NotificationReceived?.Invoke(this, ToArray(args.CharacteristicValue)); }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            DiagnosticLog.Error("Bluetooth notification handling failed", exception);
        }
    }

    private void HandleConnectionStatusChanged(BluetoothLEDevice sender, object args)
    {
        if (sender.ConnectionStatus == BluetoothConnectionStatus.Disconnected) Disconnected?.Invoke(this, EventArgs.Empty);
    }
}
