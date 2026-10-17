using System.Text.Json;
using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Core.Ble;

public sealed record BleCandidate(ulong Address, string Name);

/// <summary>Finds and connects PaperRemote BLE peripherals. Implemented with WinRT by the host and faked in tests.</summary>
public interface IBleDeviceConnector
{
    Task<IReadOnlyList<BleCandidate>> ScanAsync(TimeSpan duration, CancellationToken cancellationToken);
    Task<IBleDeviceLink> ConnectAsync(BleCandidate candidate, CancellationToken cancellationToken);
}

/// <summary>A GATT connection to the PaperRemote service with notifications enabled on the control characteristic.</summary>
public interface IBleDeviceLink : IAsyncDisposable
{
    BleCandidate Candidate { get; }
    bool IsConnected { get; }
    event EventHandler<byte[]>? NotificationReceived;
    event EventHandler? Disconnected;
    /// <summary>Writes one frame to the control characteristic with response.</summary>
    Task WriteControlAsync(byte[] frame, CancellationToken cancellationToken);
    /// <summary>Reads the descriptor characteristic (see <see cref="BleControlCodec.ReadDescriptorAsync"/>).</summary>
    Task<string> ReadDescriptorAsync(CancellationToken cancellationToken);
}

/// <summary>Request/notification state machine for device controls and the relay on one BLE link.</summary>
public sealed class BleDeviceSession : IAsyncDisposable
{
    private readonly object sync = new();
    private readonly SemaphoreSlim requestGate = new(1, 1);
    private readonly SemaphoreSlim writeGate = new(1, 1);
    private readonly BleSnapshotAssembler snapshots = new();
    private readonly BleRelayAssembler relays = new();
    private readonly TimeSpan timeout;
    private TaskCompletionSource<DeviceControlSnapshot>? pendingSnapshot;
    private TaskCompletionSource<DeviceControlError?>? pendingStatus;
    private TaskCompletionSource<DeviceControlSnapshot>? pendingSetSnapshot;
    private bool setSnapshotArmed;
    private TaskCompletionSource<BleRelayRegistration>? pendingRegistration;
    private int disposed;

    public BleDeviceSession(IBleDeviceLink link, string deviceId, TimeSpan? timeout = null)
    {
        Link = link;
        DeviceId = deviceId;
        this.timeout = timeout ?? TimeSpan.FromSeconds(8);
        link.NotificationReceived += HandleNotification;
        link.Disconnected += HandleDisconnected;
    }

    public IBleDeviceLink Link { get; }
    public string DeviceId { get; }
    public bool IsConnected => Volatile.Read(ref disposed) == 0 && Link.IsConnected;
    public DeviceControlSnapshot? LatestSnapshot { get; private set; }

    /// <summary>Raised for every complete snapshot, including unsolicited ones after on-device changes.</summary>
    public event EventHandler<DeviceControlSnapshot>? SnapshotReceived;
    public event EventHandler<BleRelayFrameResult>? RelayReceived;
    public event EventHandler? Disconnected;

    public async Task<DeviceControlSnapshot> GetSnapshotAsync(CancellationToken cancellationToken)
    {
        await requestGate.WaitAsync(cancellationToken);
        try
        {
            var completion = NewCompletion<DeviceControlSnapshot>();
            lock (sync) pendingSnapshot = completion;
            await WriteAsync(BleControlCodec.EncodeSnapshotRequest(), cancellationToken);
            return await AwaitAsync(completion.Task, "snapshot", cancellationToken);
        }
        finally
        {
            lock (sync) pendingSnapshot = null;
            requestGate.Release();
        }
    }

    public async Task<DeviceControlSnapshot> SetAsync(string id, JsonElement? value, CancellationToken cancellationToken)
    {
        var frame = BleControlCodec.EncodeSetRequest(new DeviceControlSetRequest(id, value));
        await requestGate.WaitAsync(cancellationToken);
        try
        {
            var status = NewCompletion<DeviceControlError?>();
            var snapshot = NewCompletion<DeviceControlSnapshot>();
            lock (sync)
            {
                pendingStatus = status;
                pendingSetSnapshot = snapshot;
                setSnapshotArmed = false;
            }
            await WriteAsync(frame, cancellationToken);
            if (await AwaitAsync(status.Task, "set status", cancellationToken) is { } error)
                throw new DeviceControlException(error, DeviceControlException.Describe(error));
            return await AwaitAsync(snapshot.Task, "snapshot after set", cancellationToken);
        }
        finally
        {
            lock (sync)
            {
                pendingStatus = null;
                pendingSetSnapshot = null;
                setSnapshotArmed = false;
            }
            requestGate.Release();
        }
    }

    public async Task<BleRelayRegistration> RegisterRelayAsync(BleRelayRole role, string token, CancellationToken cancellationToken)
    {
        var frame = BleControlCodec.EncodeRelayRegistration(role, token);
        await requestGate.WaitAsync(cancellationToken);
        try
        {
            var completion = NewCompletion<BleRelayRegistration>();
            lock (sync) pendingRegistration = completion;
            await WriteAsync(frame, cancellationToken);
            return await AwaitAsync(completion.Task, "relay registration", cancellationToken);
        }
        finally
        {
            lock (sync) pendingRegistration = null;
            requestGate.Release();
        }
    }

    public Task AcknowledgeRelayAsync(byte sequence, bool delivered, CancellationToken cancellationToken) =>
        WriteAsync(BleControlCodec.EncodeRelayAck(sequence, delivered), cancellationToken);

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        Link.NotificationReceived -= HandleNotification;
        Link.Disconnected -= HandleDisconnected;
        FailPending(new DeviceControlException(DeviceControlError.Transport, "Bluetooth connection closed."));
        await Link.DisposeAsync();
    }

    private async Task WriteAsync(byte[] frame, CancellationToken cancellationToken)
    {
        if (!IsConnected) throw new DeviceControlException(DeviceControlError.Transport, "Bluetooth is not connected.");
        await writeGate.WaitAsync(cancellationToken);
        try { await Link.WriteControlAsync(frame, cancellationToken); }
        catch (Exception exception) when (exception is not (OperationCanceledException or DeviceControlException))
        {
            throw new DeviceControlException(DeviceControlError.Transport, $"Bluetooth write failed: {exception.Message}", exception);
        }
        finally { writeGate.Release(); }
    }

    private async Task<T> AwaitAsync<T>(Task<T> task, string what, CancellationToken cancellationToken)
    {
        try { return await task.WaitAsync(timeout, cancellationToken); }
        catch (TimeoutException exception)
        {
            throw new DeviceControlException(DeviceControlError.Transport, $"Bluetooth {what} timed out.", exception);
        }
    }

    private static TaskCompletionSource<T> NewCompletion<T>() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    private void HandleNotification(object? sender, byte[] frame)
    {
        if (frame.Length == 0) return;
        try
        {
            switch (frame[0])
            {
                case BleProtocol.SnapshotFragment:
                    if (snapshots.Append(frame) is { } snapshot)
                    {
                        LatestSnapshot = snapshot;
                        lock (sync)
                        {
                            pendingSnapshot?.TrySetResult(snapshot);
                            if (setSnapshotArmed) pendingSetSnapshot?.TrySetResult(snapshot);
                        }
                        SnapshotReceived?.Invoke(this, snapshot);
                    }
                    break;
                case BleProtocol.SetStatus:
                    var status = BleControlCodec.DecodeSetStatus(frame);
                    lock (sync)
                    {
                        setSnapshotArmed = status is null;
                        pendingStatus?.TrySetResult(status);
                    }
                    break;
                case BleProtocol.RelayRegistered:
                    var registration = BleControlCodec.DecodeRelayRegistered(frame);
                    lock (sync) pendingRegistration?.TrySetResult(registration);
                    break;
                case BleProtocol.RelayFrame:
                    if (relays.Append(frame) is { } relay) RelayReceived?.Invoke(this, relay);
                    break;
            }
        }
        catch (BleProtocolException exception)
        {
            var error = new DeviceControlException(DeviceControlError.Protocol, exception.Message);
            lock (sync)
            {
                if (frame[0] == BleProtocol.SnapshotFragment)
                {
                    pendingSnapshot?.TrySetException(error);
                    pendingSetSnapshot?.TrySetException(error);
                }
                else if (frame[0] == BleProtocol.SetStatus) pendingStatus?.TrySetException(error);
                else if (frame[0] == BleProtocol.RelayRegistered) pendingRegistration?.TrySetException(error);
            }
        }
    }

    private void HandleDisconnected(object? sender, EventArgs eventArgs)
    {
        snapshots.Reset();
        relays.Reset();
        FailPending(new DeviceControlException(DeviceControlError.Transport, "Bluetooth device disconnected."));
        Disconnected?.Invoke(this, EventArgs.Empty);
    }

    private void FailPending(Exception exception)
    {
        lock (sync)
        {
            pendingSnapshot?.TrySetException(exception);
            pendingStatus?.TrySetException(exception);
            pendingSetSnapshot?.TrySetException(exception);
            pendingRegistration?.TrySetException(exception);
        }
    }
}

/// <summary>
/// Shares one BLE session per device between the controls panel and the relay, and disconnects once
/// nobody holds a lease, preserving the device's battery and connection slots.
/// </summary>
public sealed class BleSessionPool(IBleDeviceConnector connector, TimeSpan? scanDuration = null, TimeSpan? requestTimeout = null)
{
    private const int MaximumCandidates = 6;
    private readonly object sync = new();
    private readonly Dictionary<string, Entry> entries = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ulong> knownAddresses = new(StringComparer.Ordinal);
    private readonly TimeSpan scanDuration = scanDuration ?? TimeSpan.FromSeconds(5);

    public async Task<BleSessionLease> AcquireAsync(string deviceId, string? nameHint, CancellationToken cancellationToken)
    {
        Entry entry;
        lock (sync)
        {
            if (!entries.TryGetValue(deviceId, out entry!) || entry.Connecting.IsFaulted || entry.Connecting.IsCanceled ||
                entry.Connecting.IsCompletedSuccessfully && !entry.Connecting.Result.IsConnected)
            {
                entry = new Entry(ConnectAsync(deviceId, nameHint));
                entries[deviceId] = entry;
            }
            entry.Leases++;
        }
        try
        {
            var session = await entry.Connecting.WaitAsync(cancellationToken);
            return new BleSessionLease(this, entry, session);
        }
        catch
        {
            await ReleaseAsync(deviceId, entry);
            throw;
        }
    }

    /// <summary>Records an address already verified to belong to <paramref name="deviceId"/> so it is tried first.</summary>
    public void RememberAddress(string deviceId, ulong address)
    {
        lock (sync) knownAddresses[deviceId] = address;
    }

    public bool IsConnected(string deviceId)
    {
        lock (sync)
            return entries.TryGetValue(deviceId, out var entry) &&
                entry.Connecting.IsCompletedSuccessfully && entry.Connecting.Result.IsConnected;
    }

    internal async Task ReleaseAsync(string deviceId, Entry entry)
    {
        lock (sync)
        {
            if (--entry.Leases > 0) return;
            if (entries.TryGetValue(deviceId, out var current) && ReferenceEquals(current, entry)) entries.Remove(deviceId);
        }
        try
        {
            var session = await entry.Connecting;
            await session.DisposeAsync();
        }
        catch (Exception exception) when (exception is not OutOfMemoryException) { }
    }

    private async Task<BleDeviceSession> ConnectAsync(string deviceId, string? nameHint)
    {
        // Connection is shared between leases, so it is not tied to a single caller's cancellation.
        await Task.Yield();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(45));
        var candidates = await connector.ScanAsync(scanDuration, cancellation.Token);
        ulong? known;
        lock (sync) known = knownAddresses.TryGetValue(deviceId, out var address) ? address : null;
        var ordered = candidates
            .OrderBy(candidate => candidate.Address == known ? 0 : candidate.Name == nameHint ? 1 : 2)
            .Take(MaximumCandidates)
            .ToList();
        Exception? lastError = null;
        foreach (var candidate in ordered)
        {
            IBleDeviceLink? link = null;
            try
            {
                link = await connector.ConnectAsync(candidate, cancellation.Token);
                var descriptor = DeviceDescriptor.Parse(await link.ReadDescriptorAsync(cancellation.Token));
                if (descriptor.DeviceID != deviceId)
                {
                    await link.DisposeAsync();
                    continue;
                }
                lock (sync) knownAddresses[deviceId] = candidate.Address;
                return new BleDeviceSession(link, deviceId, requestTimeout);
            }
            catch (Exception exception) when (exception is not OutOfMemoryException)
            {
                lastError = exception;
                if (link is not null) await link.DisposeAsync();
            }
        }
        throw new DeviceControlException(DeviceControlError.Transport,
            ordered.Count == 0 ? "No PaperRemote Bluetooth device found nearby." :
            $"The device was not found over Bluetooth{(lastError is null ? "." : $": {lastError.Message}")}", lastError);
    }

    internal sealed class Entry(Task<BleDeviceSession> connecting)
    {
        public Task<BleDeviceSession> Connecting { get; } = connecting;
        public int Leases { get; set; }
    }
}

public sealed class BleSessionLease : IAsyncDisposable
{
    private readonly BleSessionPool pool;
    private readonly BleSessionPool.Entry entry;
    private int released;

    internal BleSessionLease(BleSessionPool pool, BleSessionPool.Entry entry, BleDeviceSession session)
    {
        this.pool = pool;
        this.entry = entry;
        Session = session;
    }

    public BleDeviceSession Session { get; }

    public ValueTask DisposeAsync() =>
        Interlocked.Exchange(ref released, 1) == 0 ? new(pool.ReleaseAsync(Session.DeviceId, entry)) : ValueTask.CompletedTask;
}

/// <summary>Device controls over BLE (0x50–0x53), connecting lazily and staying live through unsolicited snapshots.</summary>
public sealed class BleDeviceControlTransport(BleSessionPool pool, string deviceId, string? nameHint)
    : IDeviceControlTransport, IAsyncDisposable
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private BleSessionLease? lease;

    public string Name => "Bluetooth";
    public bool IsConnected => lease?.Session.IsConnected == true;
    public event EventHandler<DeviceControlSnapshot>? SnapshotReceived;

    public async Task<DeviceControlSnapshot> GetSnapshotAsync(CancellationToken cancellationToken) =>
        await (await SessionAsync(cancellationToken)).GetSnapshotAsync(cancellationToken);

    public async Task<DeviceControlSnapshot> SetAsync(string id, JsonElement? value, CancellationToken cancellationToken) =>
        await (await SessionAsync(cancellationToken)).SetAsync(id, value, cancellationToken);

    /// <summary>Drops the BLE connection, e.g. once Wi-Fi works again.</summary>
    public async Task ReleaseAsync()
    {
        await gate.WaitAsync();
        try { await ReleaseLeaseAsync(); }
        finally { gate.Release(); }
    }

    public async ValueTask DisposeAsync() => await ReleaseAsync();

    private async Task<BleDeviceSession> SessionAsync(CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (lease is { Session.IsConnected: true }) return lease.Session;
            await ReleaseLeaseAsync();
            try { lease = await pool.AcquireAsync(deviceId, nameHint, cancellationToken); }
            catch (Exception exception) when (exception is not (OperationCanceledException or DeviceControlException))
            {
                throw new DeviceControlException(DeviceControlError.Transport, $"Bluetooth unavailable: {exception.Message}", exception);
            }
            lease.Session.SnapshotReceived += ForwardSnapshot;
            return lease.Session;
        }
        finally { gate.Release(); }
    }

    private async Task ReleaseLeaseAsync()
    {
        if (lease is null) return;
        lease.Session.SnapshotReceived -= ForwardSnapshot;
        await lease.DisposeAsync();
        lease = null;
    }

    private void ForwardSnapshot(object? sender, DeviceControlSnapshot snapshot) => SnapshotReceived?.Invoke(this, snapshot);
}
