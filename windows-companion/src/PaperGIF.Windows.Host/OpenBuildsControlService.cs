using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text.Json;
using System.Text.Json.Serialization;
using SocketIOClient;

namespace PaperGIF.Windows.Host;

internal enum OpenBuildsPayloadKind
{
    Boolean,
    Integer,
    String,
    Stop,
}

internal sealed record OpenBuildsStopPayload(
    [property: JsonPropertyName("stop")] bool Stop,
    [property: JsonPropertyName("jog")] bool Jog,
    [property: JsonPropertyName("abort")] bool Abort);

internal sealed record OpenBuildsEmission(
    string Event,
    OpenBuildsPayloadKind Kind,
    bool BooleanValue = false,
    int IntegerValue = 0,
    string? StringValue = null,
    OpenBuildsStopPayload? StopValue = null);

internal static class OpenBuildsCommandMapper
{
    public static OpenBuildsEmission? Create(string command, int value) => command switch
    {
        "jogXNegative" => Jog("X", -1, value, 1_000),
        "jogXPositive" => Jog("X", 1, value, 1_000),
        "jogYNegative" => Jog("Y", -1, value, 1_000),
        "jogYPositive" => Jog("Y", 1, value, 1_000),
        "jogZNegative" => Jog("Z", -1, value, 500),
        "jogZPositive" => Jog("Z", 1, value, 500),
        "pause" => new("pause", OpenBuildsPayloadKind.Boolean, BooleanValue: true),
        "resume" => new("resume", OpenBuildsPayloadKind.Boolean, BooleanValue: true),
        "stop" => new("stop", OpenBuildsPayloadKind.Stop,
            StopValue: new OpenBuildsStopPayload(true, false, false)),
        "abort" => new("stop", OpenBuildsPayloadKind.Stop,
            StopValue: new OpenBuildsStopPayload(false, false, true)),
        "unlock" => new("clearAlarm", OpenBuildsPayloadKind.Integer, IntegerValue: 2),
        "home" => new("runCommand", OpenBuildsPayloadKind.String, StringValue: "$H\n"),
        _ => null,
    };

    private static OpenBuildsEmission? Jog(string axis, int direction, int distance, int feed) =>
        distance is >= 1 and <= 100
            ? new("jog", OpenBuildsPayloadKind.String,
                StringValue: $"{axis},{direction * distance},{feed}")
            : null;
}

internal sealed class OpenBuildsControlService
{
    private static readonly int[] DefaultPorts = [3_000, 3_020, 3_200, 3_220];
    private readonly HttpClient httpClient = new() { Timeout = TimeSpan.FromMilliseconds(1_250) };

    public bool Perform(RemoteRequest request) =>
        PerformAsync(request).GetAwaiter().GetResult();

    internal async Task<bool> PerformAsync(RemoteRequest request)
    {
        var emission = OpenBuildsCommandMapper.Create(request.Text, request.Value);
        if (emission is null)
        {
            return false;
        }
        foreach (var endpoint in Endpoints(request.Host ?? string.Empty))
        {
            if (await IsOpenBuildsControlAsync(endpoint))
            {
                return await EmitAsync(endpoint, emission);
            }
        }
        return false;
    }

    internal static IReadOnlyList<Uri> Endpoints(string host)
    {
        var rawTarget = string.IsNullOrWhiteSpace(host) ? "127.0.0.1" : host.Trim();
        if (rawTarget.IndexOfAny(['/', '?', '#', '@']) >= 0 ||
            !Uri.TryCreate($"http://{rawTarget}", UriKind.Absolute, out var parsed) ||
            !IsLocalNetworkHost(parsed.Host))
        {
            return [];
        }
        if (!parsed.IsDefaultPort)
        {
            return [parsed];
        }
        return DefaultPorts.Select(port => new UriBuilder(Uri.UriSchemeHttp, parsed.Host, port).Uri).ToArray();
    }

    private static bool IsLocalNetworkHost(string host)
    {
        if (host.Equals("localhost", StringComparison.OrdinalIgnoreCase) ||
            host.EndsWith(".local", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }
        if (!IPAddress.TryParse(host, out var address))
        {
            return false;
        }
        if (IPAddress.IsLoopback(address))
        {
            return true;
        }
        if (address.AddressFamily != AddressFamily.InterNetwork)
        {
            return address.IsIPv6LinkLocal;
        }
        var octets = address.GetAddressBytes();
        return octets[0] == 10 ||
            octets[0] == 127 ||
            octets[0] == 169 && octets[1] == 254 ||
            octets[0] == 172 && octets[1] is >= 16 and <= 31 ||
            octets[0] == 192 && octets[1] == 168;
    }

    private async Task<bool> IsOpenBuildsControlAsync(Uri endpoint)
    {
        try
        {
            using var response = await httpClient.GetAsync(new Uri(endpoint, "/api/version"));
            if (!response.IsSuccessStatusCode)
            {
                return false;
            }
            await using var stream = await response.Content.ReadAsStreamAsync();
            using var document = await JsonDocument.ParseAsync(stream);
            return document.RootElement.TryGetProperty("application", out var application) &&
                application.GetString() == "OMD";
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or JsonException)
        {
            return false;
        }
    }

    private static async Task<bool> EmitAsync(Uri endpoint, OpenBuildsEmission emission)
    {
        using var client = new SocketIOClient.SocketIO(endpoint, new SocketIOOptions
        {
            Reconnection = false,
            ConnectionTimeout = TimeSpan.FromSeconds(3),
        });
        try
        {
            await client.ConnectAsync();
            switch (emission.Kind)
            {
                case OpenBuildsPayloadKind.Boolean:
                    await client.EmitAsync(emission.Event, emission.BooleanValue);
                    break;
                case OpenBuildsPayloadKind.Integer:
                    await client.EmitAsync(emission.Event, emission.IntegerValue);
                    break;
                case OpenBuildsPayloadKind.String:
                    await client.EmitAsync(emission.Event, emission.StringValue!);
                    break;
                case OpenBuildsPayloadKind.Stop:
                    await client.EmitAsync(emission.Event, emission.StopValue!);
                    break;
            }
            await client.DisconnectAsync();
            return true;
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or TimeoutException or WebSocketException)
        {
            return false;
        }
    }
}