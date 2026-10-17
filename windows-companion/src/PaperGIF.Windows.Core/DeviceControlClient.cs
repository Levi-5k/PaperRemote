using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Core;

/// <summary>Reads and changes device controls over one transport.</summary>
public interface IDeviceControlTransport
{
    string Name { get; }
    Task<DeviceControlSnapshot> GetSnapshotAsync(CancellationToken cancellationToken);
    /// <summary>Sends a set request (value omitted for actions) and returns the device's resulting snapshot.</summary>
    Task<DeviceControlSnapshot> SetAsync(string id, JsonElement? value, CancellationToken cancellationToken);
}

/// <summary><c>GET/POST /device/controls</c> with the same bearer token as <c>/remote</c>.</summary>
public sealed class DeviceControlClient(HttpClient client, Uri endpoint, string token, TimeSpan? timeout = null)
    : IDeviceControlTransport
{
    public const int MaximumResponseBytes = 65_536;
    private readonly TimeSpan timeout = timeout ?? TimeSpan.FromSeconds(5);

    public string Name => "Wi-Fi";
    private Uri ControlsUri => new(endpoint, "/device/controls");

    public async Task<DeviceControlSnapshot> GetSnapshotAsync(CancellationToken cancellationToken)
    {
        var (status, body) = await SendAsync(HttpMethod.Get, null, cancellationToken);
        if (status != HttpStatusCode.OK) throw StatusError(status, body);
        try { return DeviceControlJson.ParseSnapshot(body); }
        catch (JsonException exception)
        {
            throw new DeviceControlException(DeviceControlError.Protocol, "The device sent an invalid controls snapshot.", exception);
        }
    }

    public async Task<DeviceControlSnapshot> SetAsync(string id, JsonElement? value, CancellationToken cancellationToken)
    {
        var json = new DeviceControlSetRequest(id, value).ToJson();
        var (status, body) = await SendAsync(HttpMethod.Post, json, cancellationToken);
        DeviceControlSetResponse response;
        try { response = DeviceControlJson.ParseSetResponse(body); }
        catch (JsonException exception)
        {
            if (status != HttpStatusCode.OK) throw StatusError(status, body);
            throw new DeviceControlException(DeviceControlError.Protocol, "The device did not acknowledge the change with {\"ok\":true}.", exception);
        }
        if (!response.Ok)
        {
            var error = DeviceControlException.FromWire(response.Error);
            throw new DeviceControlException(error, DeviceControlException.Describe(error));
        }
        if (status != HttpStatusCode.OK)
            throw new DeviceControlException(DeviceControlError.Protocol, $"Unexpected HTTP {(int)status} for a successful change.");
        return response.Snapshot!;
    }

    private static DeviceControlException StatusError(HttpStatusCode status, string body)
    {
        try
        {
            var parsed = DeviceControlJson.ParseSetResponse(body);
            if (!parsed.Ok)
            {
                var wire = DeviceControlException.FromWire(parsed.Error);
                return new(wire, DeviceControlException.Describe(wire));
            }
        }
        catch (JsonException) { }
        var error = status switch
        {
            HttpStatusCode.Unauthorized => DeviceControlError.Unauthorized,
            HttpStatusCode.NotFound or HttpStatusCode.MethodNotAllowed => DeviceControlError.Unsupported,
            HttpStatusCode.Conflict => DeviceControlError.Busy,
            _ => DeviceControlError.Protocol,
        };
        return new(error, $"{DeviceControlException.Describe(error)} (HTTP {(int)status}).");
    }

    private async Task<(HttpStatusCode Status, string Body)> SendAsync(HttpMethod method, string? json, CancellationToken cancellationToken)
    {
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);
        using var request = new HttpRequestMessage(method, ControlsUri);
        if (!string.IsNullOrEmpty(token)) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (json is not null) request.Content = new StringContent(json, Encoding.UTF8, "application/json");
        HttpResponseMessage response;
        try
        {
            response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeoutSource.Token);
        }
        catch (OperationCanceledException exception) when (!cancellationToken.IsCancellationRequested)
        {
            throw new DeviceControlException(DeviceControlError.Transport, "The device did not respond over Wi-Fi.", exception);
        }
        catch (HttpRequestException exception)
        {
            throw new DeviceControlException(DeviceControlError.Transport, $"Device unreachable over Wi-Fi: {exception.Message}", exception);
        }
        using (response)
        {
            if (response.StatusCode is HttpStatusCode.Redirect or HttpStatusCode.MovedPermanently or
                HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect or HttpStatusCode.SeeOther)
                throw new DeviceControlException(DeviceControlError.Protocol, "Device controls do not follow redirects.");
            try
            {
                return (response.StatusCode, await DeviceAdapters.ReadBoundedAsync(response.Content, MaximumResponseBytes, timeoutSource.Token));
            }
            catch (OperationCanceledException exception) when (!cancellationToken.IsCancellationRequested)
            {
                throw new DeviceControlException(DeviceControlError.Transport, "The device stopped responding over Wi-Fi.", exception);
            }
            catch (IOException exception)
            {
                throw new DeviceControlException(DeviceControlError.Transport, "The Wi-Fi connection was interrupted.", exception);
            }
            catch (Exception exception) when (exception is InvalidOperationException or DecoderFallbackException)
            {
                throw new DeviceControlException(DeviceControlError.Protocol, exception.Message, exception);
            }
        }
    }
}

/// <summary>
/// Prefers the primary (HTTP) transport and uses the fallback (BLE) only when the primary fails with a
/// transport error. Device rejections, authorization and malformed replies are never retried.
/// </summary>
public sealed class FallbackDeviceControlTransport(IDeviceControlTransport primary, IDeviceControlTransport? fallback)
    : IDeviceControlTransport
{
    public string Name => LastUsed?.Name ?? primary.Name;
    public IDeviceControlTransport? LastUsed { get; private set; }

    public Task<DeviceControlSnapshot> GetSnapshotAsync(CancellationToken cancellationToken) =>
        RunAsync(transport => transport.GetSnapshotAsync(cancellationToken));

    public Task<DeviceControlSnapshot> SetAsync(string id, JsonElement? value, CancellationToken cancellationToken) =>
        RunAsync(transport => transport.SetAsync(id, value, cancellationToken));

    private async Task<DeviceControlSnapshot> RunAsync(Func<IDeviceControlTransport, Task<DeviceControlSnapshot>> operation)
    {
        try
        {
            var result = await operation(primary);
            LastUsed = primary;
            return result;
        }
        catch (DeviceControlException exception) when (exception.IsTransportError && fallback is not null)
        {
            var result = await operation(fallback);
            LastUsed = fallback;
            return result;
        }
    }
}
