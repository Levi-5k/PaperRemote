using System.Text.Json;
using PaperGIF.Windows.Core.Ble;

namespace PaperGIF.Windows.Host;

/// <summary>Executes <c>/action</c> bodies, whether they arrive over HTTP or through the BLE relay.</summary>
internal static class RelayedActionHandler
{
    // Minimal API JSON binding uses the Web defaults, so relayed bodies bind exactly like HTTP ones.
    private static readonly JsonSerializerOptions BindingOptions = new(JsonSerializerDefaults.Web);

    public static RemoteActionResult Perform(WindowsActionDispatcher dispatcher, RemoteRequest request) =>
        dispatcher.Perform(request);

    /// <summary>Binds and runs a relayed body; false when it is malformed or the action fails.</summary>
    public static bool Execute(WindowsActionDispatcher dispatcher, string bodyJson)
    {
        RemoteRequest? request;
        try { request = JsonSerializer.Deserialize<RemoteRequest>(bodyJson, BindingOptions); }
        catch (JsonException) { return false; }
        return request is not null && Perform(dispatcher, request).Succeeded;
    }
}

/// <summary>
/// Registers this computer as a BLE relay for the selected device only while it is unreachable over the LAN,
/// so device→computer actions keep working without Wi-Fi.
/// </summary>
internal sealed class BleRelayService(
    RemoteEditorStore store,
    CompanionConfiguration configuration,
    WindowsActionDispatcher dispatcher,
    BleSessionPool pool) : BackgroundService
{
    private readonly HttpClient probeClient = new(new HttpClientHandler { AllowAutoRedirect = false })
    {
        Timeout = TimeSpan.FromSeconds(3),
    };

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await using var coordinator = new BleRelayCoordinator(pool, ProbeLanAsync,
            (body, _) => Task.FromResult(RelayedActionHandler.Execute(dispatcher, body)));
        coordinator.StateChanged += (_, state) =>
            DiagnosticLog.Info($"BLE relay {state}{(coordinator.LastError is { } error ? $": {error}" : string.Empty)}");
        coordinator.RelayHandled += (_, delivery) =>
        {
            if (!delivery.Delivered) DiagnosticLog.Info($"BLE relay action {delivery.Sequence} failed: {delivery.Error}");
        };
        try { await coordinator.RunAsync(CurrentTarget, stoppingToken); }
        finally { probeClient.Dispose(); }
    }

    private BleRelayTarget? CurrentTarget() =>
        store.Descriptor is { } descriptor && descriptor.SupportsTransport("ble") && !string.IsNullOrEmpty(configuration.Token)
            ? new BleRelayTarget(descriptor.DeviceID, descriptor.Name, configuration.Token)
            : null;

    /// <summary>Any HTTP response from <c>GET /device</c> proves LAN delivery works.</summary>
    private async Task<bool> ProbeLanAsync(CancellationToken cancellationToken)
    {
        if (store.DeviceBaseUri() is not { } baseUri) return false;
        try
        {
            using var response = await probeClient.GetAsync(new Uri(baseUri, "/device"), HttpCompletionOption.ResponseHeadersRead,
                cancellationToken);
            return true;
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException && !cancellationToken.IsCancellationRequested)
        {
            return false;
        }
    }
}
