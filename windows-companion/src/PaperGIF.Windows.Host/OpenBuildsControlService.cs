using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Collections.Concurrent;
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
        var unitScale = modifiers?.Contains("units=in", StringComparer.Ordinal) == true ? 25.4 : 1;
        var distance = Distance(modifiers, valueTenths ?? value * 10) * unitScale;
        var configuredFeed = Feed(modifiers);
        var xyFeed = ScaledFeed(configuredFeed ?? 1_000, unitScale);
        var zFeed = ScaledFeed(configuredFeed ?? 500, unitScale);
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
            "continuousJogXNegative" => ContinuousJog(-1, 0, ScaledFeed(value, unitScale)),
            "continuousJogXPositive" => ContinuousJog(1, 0, ScaledFeed(value, unitScale)),
            "continuousJogYNegative" => ContinuousJog(0, -1, ScaledFeed(value, unitScale)),
            "continuousJogYPositive" => ContinuousJog(0, 1, ScaledFeed(value, unitScale)),
            "continuousJogXNegativeYNegative" => ContinuousJog(-1, -1, ScaledFeed(value, unitScale)),
            "continuousJogXNegativeYPositive" => ContinuousJog(-1, 1, ScaledFeed(value, unitScale)),
            "continuousJogXPositiveYNegative" => ContinuousJog(1, -1, ScaledFeed(value, unitScale)),
            "continuousJogXPositiveYPositive" => ContinuousJog(1, 1, ScaledFeed(value, unitScale)),
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
        distance is >= 0.001 and <= 100 && feed is >= 100 and <= 10_000
            ? new("jog", OpenBuildsPayloadKind.String,
                StringValue: $"{axis},{(direction * distance).ToString("0.####", CultureInfo.InvariantCulture)},{feed}")
            : null;

    private static OpenBuildsEmission? JogXY(int xDirection, int yDirection, double distance, int feed) =>
        distance is >= 0.001 and <= 100 && feed is >= 100 and <= 10_000
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

    private static double Distance(IReadOnlyList<string>? modifiers, int fallbackTenths)
    {
        var value = modifiers?.FirstOrDefault(modifier => modifier.StartsWith("dist=", StringComparison.Ordinal));
        return value is not null && int.TryParse(value.AsSpan(5), out var thousandths)
            ? thousandths / 1_000d
            : fallbackTenths / 10d;
    }

    private static int ScaledFeed(int feed, double scale) =>
        (int)Math.Round(feed * scale, MidpointRounding.AwayFromZero);
}

internal sealed class OpenBuildsControlService : IDisposable
{
    private static readonly int[] DefaultPorts = [3_000, 3_020, 3_200, 3_220];
    private readonly HttpClient httpClient = new() { Timeout = TimeSpan.FromMilliseconds(1_250) };
    private readonly ConcurrentDictionary<string, OpenBuildsPositionSession> positionSessions = new();

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
                var session = positionSessions.GetOrAdd(
                    endpoint.AbsoluteUri,
                    _ => new OpenBuildsPositionSession(endpoint));
                return await session.PositionAsync(cancellationToken);
            }
        }
        return null;
    }

    public void Dispose()
    {
        foreach (var session in positionSessions.Values)
        {
            session.Dispose();
        }
        positionSessions.Clear();
        httpClient.Dispose();
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

    private sealed class OpenBuildsPositionSession : IDisposable
    {
        private static readonly TimeSpan Freshness = TimeSpan.FromSeconds(2);
        private readonly SocketIOClient.SocketIO client;
        private readonly SemaphoreSlim connectionLock = new(1, 1);
        private readonly object positionLock = new();
        private OpenBuildsPosition? latestPosition;
        private DateTimeOffset latestPositionAt = DateTimeOffset.MinValue;
        private TaskCompletionSource<OpenBuildsPosition> nextPosition = NewPositionCompletion();

        public OpenBuildsPositionSession(Uri endpoint)
        {
            client = new SocketIOClient.SocketIO(endpoint, new SocketIOOptions
            {
                Reconnection = false,
                ConnectionTimeout = TimeSpan.FromSeconds(3),
            });
            client.On("status", response =>
            {
                try
                {
                    Publish(ParsePosition(response.GetValue<JsonElement>()));
                }
                catch (JsonException)
                {
                }
            });
        }

        public async Task<OpenBuildsPosition?> PositionAsync(CancellationToken cancellationToken)
        {
            try
            {
                Task<OpenBuildsPosition> next;
                lock (positionLock)
                {
                    if (latestPosition is not null &&
                        DateTimeOffset.UtcNow - latestPositionAt <= Freshness)
                    {
                        return latestPosition;
                    }
                    next = nextPosition.Task;
                }

                await EnsureConnectedAsync(cancellationToken);
                return await next.WaitAsync(TimeSpan.FromSeconds(3), cancellationToken);
            }
            catch (Exception exception) when (
                exception is HttpRequestException or TaskCanceledException or TimeoutException or WebSocketException)
            {
                return null;
            }
        }

        private async Task EnsureConnectedAsync(CancellationToken cancellationToken)
        {
            if (client.Connected)
            {
                return;
            }
            await connectionLock.WaitAsync(cancellationToken);
            try
            {
                if (!client.Connected)
                {
                    await client.ConnectAsync();
                }
            }
            finally
            {
                connectionLock.Release();
            }
        }

        private void Publish(OpenBuildsPosition? position)
        {
            if (position is null)
            {
                return;
            }
            TaskCompletionSource<OpenBuildsPosition> completion;
            lock (positionLock)
            {
                latestPosition = position;
                latestPositionAt = DateTimeOffset.UtcNow;
                completion = nextPosition;
                nextPosition = NewPositionCompletion();
            }
            completion.TrySetResult(position);
        }

        private static TaskCompletionSource<OpenBuildsPosition> NewPositionCompletion() =>
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public void Dispose()
        {
            if (client.Connected)
            {
                client.DisconnectAsync().GetAwaiter().GetResult();
            }
            client.Dispose();
            connectionLock.Dispose();
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