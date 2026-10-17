using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Core.Ble;

public sealed record BleRelayTarget(string DeviceId, string? NameHint, string Token);

public enum BleRelayState { Idle, LanReachable, WaitingForGrace, Connecting, Registered, Rejected, Failed }

public sealed record BleRelayDelivery(byte Sequence, bool Delivered, string? Error);

/// <summary>
/// Keeps a BLE relay registered (role 0, the computer itself) only while the device is unreachable over the LAN,
/// executes relayed <c>/action</c> bodies and acknowledges them, then disconnects once LAN delivery works again.
/// </summary>
public sealed class BleRelayCoordinator : IAsyncDisposable
{
    private readonly BleSessionPool pool;
    private readonly Func<CancellationToken, Task<bool>> lanProbe;
    private readonly Func<string, CancellationToken, Task<bool>> execute;
    private readonly TimeProvider time;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private BleRelayTarget? target;
    private DateTimeOffset? unreachableSince;
    private DateTimeOffset retryAfter = DateTimeOffset.MinValue;
    private BleSessionLease? lease;
    private string? registeredComputerId;

    public BleRelayCoordinator(
        BleSessionPool pool,
        Func<CancellationToken, Task<bool>> lanProbe,
        Func<string, CancellationToken, Task<bool>> execute,
        TimeProvider? time = null)
    {
        this.pool = pool;
        this.lanProbe = lanProbe;
        this.execute = execute;
        this.time = time ?? TimeProvider.System;
    }

    public TimeSpan GracePeriod { get; init; } = TimeSpan.FromSeconds(20);
    public TimeSpan ProbeInterval { get; init; } = TimeSpan.FromSeconds(10);
    public TimeSpan FailureBackoff { get; init; } = TimeSpan.FromSeconds(30);
    public TimeSpan RejectedBackoff { get; init; } = TimeSpan.FromMinutes(5);

    public BleRelayState State { get; private set; } = BleRelayState.Idle;
    public string? LastError { get; private set; }
    public bool IsRegistered => lease is { Session.IsConnected: true } && registeredComputerId is not null;

    public event EventHandler<BleRelayState>? StateChanged;
    public event EventHandler<BleRelayDelivery>? RelayHandled;

    /// <summary>Probes and ticks until cancelled.</summary>
    public async Task RunAsync(Func<BleRelayTarget?> currentTarget, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try { await TickAsync(currentTarget(), cancellationToken); }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            catch (Exception exception) when (exception is not OutOfMemoryException) { LastError = exception.Message; }
            try { await Task.Delay(ProbeInterval, time, cancellationToken); }
            catch (OperationCanceledException) { break; }
        }
    }

    /// <summary>One health-check step. Pass null when no BLE-capable device is selected.</summary>
    public async Task TickAsync(BleRelayTarget? newTarget, CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (newTarget != target)
            {
                await DisconnectAsync();
                target = newTarget;
                unreachableSince = null;
                retryAfter = DateTimeOffset.MinValue;
            }
            if (target is null)
            {
                SetState(BleRelayState.Idle);
                return;
            }

            bool reachable;
            try { reachable = await lanProbe(cancellationToken); }
            catch (Exception exception) when (exception is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
            {
                reachable = false;
            }
            var now = time.GetUtcNow();
            if (reachable)
            {
                unreachableSince = null;
                retryAfter = DateTimeOffset.MinValue;
                await DisconnectAsync();
                SetState(BleRelayState.LanReachable);
                return;
            }

            unreachableSince ??= now;
            if (IsRegistered) return;
            if (lease is not null) await DisconnectAsync();
            if (now - unreachableSince < GracePeriod)
            {
                SetState(BleRelayState.WaitingForGrace);
                return;
            }
            if (now < retryAfter) return;
            await ConnectAsync(target, cancellationToken);
        }
        finally { gate.Release(); }
    }

    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel();
        await gate.WaitAsync();
        try { await DisconnectAsync(); }
        finally { gate.Release(); }
        lifetime.Dispose();
    }

    private async Task ConnectAsync(BleRelayTarget relayTarget, CancellationToken cancellationToken)
    {
        SetState(BleRelayState.Connecting);
        try
        {
            lease = await pool.AcquireAsync(relayTarget.DeviceId, relayTarget.NameHint, cancellationToken);
            lease.Session.RelayReceived += HandleRelay;
            var registration = await lease.Session.RegisterRelayAsync(BleRelayRole.Computer, relayTarget.Token, cancellationToken);
            if (!registration.Registered)
            {
                LastError = "The device does not recognize this computer's pairing token.";
                retryAfter = time.GetUtcNow() + RejectedBackoff;
                await DisconnectAsync();
                SetState(BleRelayState.Rejected);
                return;
            }
            registeredComputerId = registration.ComputerId;
            LastError = null;
            SetState(BleRelayState.Registered);
        }
        catch (Exception exception) when (exception is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            LastError = exception.Message;
            retryAfter = time.GetUtcNow() + FailureBackoff;
            await DisconnectAsync();
            SetState(BleRelayState.Failed);
        }
    }

    private async Task DisconnectAsync()
    {
        registeredComputerId = null;
        if (lease is null) return;
        lease.Session.RelayReceived -= HandleRelay;
        var released = lease;
        lease = null;
        await released.DisposeAsync();
    }

    private void HandleRelay(object? sender, BleRelayFrameResult relay)
    {
        if (sender is not BleDeviceSession session) return;
        _ = HandleRelayAsync(session, relay, registeredComputerId);
    }

    private async Task HandleRelayAsync(BleDeviceSession session, BleRelayFrameResult relay, string? computerId)
    {
        var delivered = false;
        var error = relay.Error;
        try
        {
            if (relay.Action is { } action)
            {
                if (computerId is null || action.ComputerId != computerId)
                    error = "Relay message is addressed to a different computer.";
                else
                    delivered = await execute(action.BodyJson, lifetime.Token);
            }
        }
        catch (Exception exception) when (exception is not OutOfMemoryException) { error = exception.Message; }
        try { await session.AcknowledgeRelayAsync(relay.Sequence, delivered, lifetime.Token); }
        catch (Exception exception) when (exception is not OutOfMemoryException) { error ??= $"Acknowledgement failed: {exception.Message}"; }
        RelayHandled?.Invoke(this, new BleRelayDelivery(relay.Sequence, delivered, delivered ? null : error ?? "Action failed."));
    }

    private void SetState(BleRelayState state)
    {
        if (State == state) return;
        State = state;
        StateChanged?.Invoke(this, state);
    }
}
