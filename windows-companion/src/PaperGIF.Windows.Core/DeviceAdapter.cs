using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using PaperGIF.Windows.Core.Models;
using PaperGIF.Windows.Core.Serialization;

namespace PaperGIF.Windows.Core;

public interface IDeviceAdapter
{
    DeviceDescriptor Descriptor { get; }
    bool IsLegacy { get; }
    Task<string> ReadProfileAsync(CancellationToken cancellationToken);
    Task WriteProfileAsync(RemoteProfile profile, CancellationToken cancellationToken);
}

public sealed class NativeDeviceAdapter(HttpClient client, Uri endpoint, string token, DeviceDescriptor descriptor)
    : IDeviceAdapter
{
    public DeviceDescriptor Descriptor { get; } = descriptor;
    public bool IsLegacy => false;
    public Task<string> ReadProfileAsync(CancellationToken cancellationToken) =>
        DeviceAdapters.ReadAsync(client, new Uri(endpoint, "/remote"), token, Descriptor.Capabilities.MaxProfileBytes, cancellationToken);
    public Task WriteProfileAsync(RemoteProfile profile, CancellationToken cancellationToken) =>
        DeviceAdapters.WriteAsync(client, new Uri(endpoint, "/remote"), token, profile, Descriptor, cancellationToken);
}

public sealed class LegacyM5PaperAdapter(HttpClient client, Uri endpoint, string token) : IDeviceAdapter
{
    public DeviceDescriptor Descriptor { get; } = DeviceDescriptor.Legacy(endpoint.GetLeftPart(UriPartial.Authority));
    public bool IsLegacy => true;
    public Task<string> ReadProfileAsync(CancellationToken cancellationToken) =>
        DeviceAdapters.ReadAsync(client, new Uri(endpoint, "/remote"), token, Descriptor.Capabilities.MaxProfileBytes, cancellationToken);
    public Task WriteProfileAsync(RemoteProfile profile, CancellationToken cancellationToken) =>
        DeviceAdapters.WriteAsync(client, new Uri(endpoint, "/remote"), token, profile, Descriptor, cancellationToken);
}

public static class DeviceAdapters
{
    public static async Task<IDeviceAdapter> IdentifyAsync(HttpClient client, Uri endpoint, string token,
        CancellationToken cancellationToken = default)
    {
        if (endpoint.Scheme is not ("http" or "https") || !string.IsNullOrEmpty(endpoint.UserInfo))
            throw new InvalidOperationException("A device needs a valid HTTP(S) endpoint.");
        using var request = Request(HttpMethod.Get, new Uri(endpoint, "/device"), token);
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            var json = await ReadBoundedAsync(response.Content, 65_536, cancellationToken);
            return new NativeDeviceAdapter(client, endpoint, token, DeviceDescriptor.Parse(json));
        }
        if (response.StatusCode != HttpStatusCode.NotFound)
            throw new InvalidOperationException($"Descriptor request failed ({(int)response.StatusCode}); not a legacy fallback.");
        var status = await ReadAsync(client, new Uri(endpoint, "/status"), token, 4096, cancellationToken);
        using var document = JsonDocument.Parse(status);
        if (document.RootElement.ValueKind != JsonValueKind.Object ||
            !document.RootElement.TryGetProperty("device", out var device) ||
            device.ValueKind != JsonValueKind.String || device.GetString() != "paperGIF")
            throw new InvalidOperationException("Unsupported device protocol. A compatible third-party adapter is required; configuration writes are disabled.");
        return new LegacyM5PaperAdapter(client, endpoint, token);
    }

    public static async Task<string> ReadAsync(HttpClient client, Uri uri, string token, int maximumBytes,
        CancellationToken cancellationToken)
    {
        using var request = Request(HttpMethod.Get, uri, token);
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        response.EnsureSuccessStatusCode();
        return await ReadBoundedAsync(response.Content, maximumBytes, cancellationToken);
    }

    internal static async Task WriteAsync(HttpClient client, Uri uri, string token, RemoteProfile profile,
        DeviceDescriptor descriptor, CancellationToken cancellationToken)
    {
        using var request = Request(HttpMethod.Post, uri, token);
        request.Content = new StringContent(RemoteProfileJson.SerializeForDevice(profile, descriptor), Encoding.UTF8, "application/json");
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if (response.StatusCode == HttpStatusCode.BadRequest)
        {
            var message = await ReadBoundedAsync(response.Content, 4096, cancellationToken);
            try
            {
                using var error = JsonDocument.Parse(message);
                if (error.RootElement.ValueKind == JsonValueKind.Object &&
                    error.RootElement.TryGetProperty("error", out var detail) && detail.ValueKind == JsonValueKind.String)
                {
                    var reason = detail.GetString() ?? "";
                    throw new InvalidOperationException($"Device refused profile: {reason[..Math.Min(256, reason.Length)]}");
                }
            }
            catch (JsonException) { }
        }
        await RequireAcknowledgementAsync(response, cancellationToken);
    }

    public static async Task RequireAcknowledgementAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        response.EnsureSuccessStatusCode();
        if (response.StatusCode is not (HttpStatusCode.OK or HttpStatusCode.Created))
            throw new InvalidOperationException("Device did not acknowledge installation (expected HTTP 200/201).");
        var json = await ReadBoundedAsync(response.Content, 4096, cancellationToken);
        try
        {
            using var acknowledgement = JsonDocument.Parse(json);
            if (acknowledgement.RootElement.ValueKind == JsonValueKind.Object &&
                acknowledgement.RootElement.TryGetProperty("ok", out var ok) && ok.ValueKind == JsonValueKind.True)
                return;
        }
        catch (JsonException) { }
        throw new InvalidOperationException("Device did not acknowledge installation with {\"ok\":true}.");
    }

    private static HttpRequestMessage Request(HttpMethod method, Uri uri, string token)
    {
        var request = new HttpRequestMessage(method, uri);
        if (!string.IsNullOrEmpty(token)) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return request;
    }

    public static async Task<string> ReadBoundedAsync(HttpContent content, int maximumBytes, CancellationToken cancellationToken)
    {
        if (content.Headers.ContentLength > maximumBytes)
            throw new InvalidOperationException("Device response exceeds its byte limit.");
        await using var source = await content.ReadAsStreamAsync(cancellationToken);
        using var buffer = new MemoryStream();
        var chunk = new byte[4096];
        while (true)
        {
            var read = await source.ReadAsync(chunk, cancellationToken);
            if (read == 0) break;
            if (buffer.Length + read > maximumBytes)
                throw new InvalidOperationException("Device response exceeds its byte limit.");
            buffer.Write(chunk, 0, read);
        }
        return new UTF8Encoding(false, true).GetString(buffer.ToArray());
    }
}
