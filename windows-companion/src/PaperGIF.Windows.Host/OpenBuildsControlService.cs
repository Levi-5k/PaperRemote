using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using SocketIOClient;

namespace PaperGIF.Windows.Host;

internal enum OpenBuildsPayloadKind
{
    Boolean,
    Integer,
    String,
    JogXY,
    Stop,
}

internal sealed record OpenBuildsStopPayload(
    [property: JsonPropertyName("stop")] bool Stop,
    [property: JsonPropertyName("jog")] bool Jog,
    [property: JsonPropertyName("abort")] bool Abort);

internal sealed record OpenBuildsJogXYPayload(
    [property: JsonPropertyName("x")] double X,
    [property: JsonPropertyName("y")] double Y,
    [property: JsonPropertyName("feed")] int Feed);

internal sealed record OpenBuildsEmission(
    string Event,
    OpenBuildsPayloadKind Kind,
    bool BooleanValue = false,
    int IntegerValue = 0,
    string? StringValue = null,
    OpenBuildsJogXYPayload? JogXYValue = null,
    OpenBuildsStopPayload? StopValue = null);

internal sealed record OpenBuildsPosition(double X, double Y, double Z);

internal static class OpenBuildsCommandMapper
{
    public static OpenBuildsEmission? Create(
        string command,
        int value,
        int? valueTenths = null,
        IReadOnlyList<string>? modifiers = null)
    {
        var distance = (valueTenths ?? value * 10) / 10d;
        var configuredFeed = Feed(modifiers);
        var xyFeed = configuredFeed ?? 1_000;
        var zFeed = configuredFeed ?? 500;
        return command switch
        {
            "jogXNegative" => Jog("X", -1, distance, xyFeed),
            "jogXPositive" => Jog("X", 1, distance, xyFeed),
            "jogYNegative" => Jog("Y", -1, distance, xyFeed),
            "jogYPositive" => Jog("Y", 1, distance, xyFeed),
            "jogZNegative" => Jog("Z", -1, distance, zFeed),
            "jogZPositive" => Jog("Z", 1, distance, zFeed),
            "jogXNegativeYNegative" => JogXY(-1, -1, distance, xyFeed),
            "jogXNegativeYPositive" => JogXY(-1, 1, distance, xyFeed),
            "jogXPositiveYNegative" => JogXY(1, -1, distance, xyFeed),
            "jogXPositiveYPositive" => JogXY(1, 1, distance, xyFeed),
            "continuousJogXNegative" => ContinuousJog(-1, 0, value),
            "continuousJogXPositive" => ContinuousJog(1, 0, value),
            "continuousJogYNegative" => ContinuousJog(0, -1, value),
            "continuousJogYPositive" => ContinuousJog(0, 1, value),
            "continuousJogXNegativeYNegative" => ContinuousJog(-1, -1, value),
            "continuousJogXNegativeYPositive" => ContinuousJog(-1, 1, value),
            "continuousJogXPositiveYNegative" => ContinuousJog(1, -1, value),
            "continuousJogXPositiveYPositive" => ContinuousJog(1, 1, value),
            "cancelJog" => new("stop", OpenBuildsPayloadKind.Stop,
                StopValue: new OpenBuildsStopPayload(false, true, false)),
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
    }

    private static OpenBuildsEmission? Jog(string axis, int direction, double distance, int feed) =>
        distance is >= 0.1 and <= 100 && feed is >= 100 and <= 10_000
            ? new("jog", OpenBuildsPayloadKind.String,
                StringValue: $"{axis},{(direction * distance).ToString("0.###", CultureInfo.InvariantCulture)},{feed}")
            : null;

    private static OpenBuildsEmission? JogXY(int xDirection, int yDirection, double distance, int feed) =>
        distance is >= 0.1 and <= 100 && feed is >= 100 and <= 10_000
            ? new("jogXY", OpenBuildsPayloadKind.JogXY,
                JogXYValue: new OpenBuildsJogXYPayload(
                    xDirection * distance,
                    yDirection * distance,
                    feed))
            : null;

    private static OpenBuildsEmission? ContinuousJog(int x, int y, int feed)
    {
        if (feed is < 100 or > 10_000 || x == 0 && y == 0)
        {
            return null;
        }
        var xWord = x == 0 ? string.Empty : $" X{x * 1_000}";
        var yWord = y == 0 ? string.Empty : $" Y{y * 1_000}";
        return new("runCommand", OpenBuildsPayloadKind.String,
            StringValue: $"$J=G91 G21{xWord}{yWord} F{feed}\n");
    }

    private static int? Feed(IReadOnlyList<string>? modifiers)
    {
        var value = modifiers?.FirstOrDefault(modifier => modifier.StartsWith("feed=", StringComparison.Ordinal));
        return value is not null && int.TryParse(value.AsSpan(5), out var feed) ? feed : null;
    }
}

internal sealed class OpenBuildsControlService
{
    private static readonly int[] DefaultPorts = [3_000, 3_020, 3_200, 3_220];
    private readonly HttpClient httpClient = new() { Timeout = TimeSpan.FromMilliseconds(1_250) };

    public bool Perform(RemoteRequest request) =>
        PerformAsync(request).GetAwaiter().GetResult();

    internal async Task<bool> PerformAsync(RemoteRequest request)
    {
        var emission = OpenBuildsCommandMapper.Create(
            request.Text,
            request.Value,
            request.ValueTenths,
            request.Modifiers);
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

    internal async Task<OpenBuildsPosition?> PositionAsync(
        string host,
        CancellationToken cancellationToken = default)
    {
        foreach (var endpoint in Endpoints(host))
        {
            if (await IsOpenBuildsControlAsync(endpoint))
            {
                return await ReadPositionAsync(endpoint, cancellationToken);
            }
        }
        return null;
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
                case OpenBuildsPayloadKind.JogXY:
                    await client.EmitAsync(emission.Event, emission.JogXYValue!);
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

    private static async Task<OpenBuildsPosition?> ReadPositionAsync(
        Uri endpoint,
        CancellationToken cancellationToken)
    {
        using var client = new SocketIOClient.SocketIO(endpoint, new SocketIOOptions
        {
            Reconnection = false,
            ConnectionTimeout = TimeSpan.FromSeconds(3),
        });
        var completion = new TaskCompletionSource<OpenBuildsPosition?>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        client.On("status", response =>
        {
            try
            {
                completion.TrySetResult(ParsePosition(response.GetValue<JsonElement>()));
            }
            catch (JsonException)
            {
                completion.TrySetResult(null);
            }
        });
        try
        {
            await client.ConnectAsync();
            return await completion.Task.WaitAsync(TimeSpan.FromSeconds(3), cancellationToken);
        }
        catch (Exception exception) when (
            exception is HttpRequestException or TaskCanceledException or TimeoutException or WebSocketException)
        {
            return null;
        }
        finally
        {
            if (client.Connected)
            {
                await client.DisconnectAsync();
            }
        }
    }

    internal static OpenBuildsPosition? ParsePosition(JsonElement status)
    {
        if (!status.TryGetProperty("machine", out var machine) ||
            !machine.TryGetProperty("position", out var position) ||
            !position.TryGetProperty("work", out var work) ||
            !TryNumber(work, "x", out var x) ||
            !TryNumber(work, "y", out var y) ||
            !TryNumber(work, "z", out var z))
        {
            return null;
        }
        return new OpenBuildsPosition(x, y, z);
    }

    private static bool TryNumber(JsonElement parent, string name, out double value)
    {
        value = 0;
        if (!parent.TryGetProperty(name, out var element))
        {
            return false;
        }
        return element.ValueKind == JsonValueKind.Number
            ? element.TryGetDouble(out value)
            : element.ValueKind == JsonValueKind.String &&
                double.TryParse(element.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out value);
    }
}