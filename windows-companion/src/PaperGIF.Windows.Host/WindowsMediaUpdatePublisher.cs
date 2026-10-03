using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace PaperGIF.Windows.Host;

// Authenticated /text-source reads subscribe their peer, not a caller-provided URL.
// The firmware stops polling seek/playback controls after receiving a timeline.
internal sealed class WindowsMediaUpdatePublisher(
    CompanionConfiguration configuration,
    HttpClient client,
    TimeProvider clock) : IDisposable
{
    internal const int MaximumDevices = 8;
    internal const int MaximumControls = 128;
    private readonly object gate = new();
    private readonly SemaphoreSlim publishing = new(1, 1);
    private readonly Dictionary<IPAddress, Subscriber> subscribers = [];

    public bool HasSubscribers
    {
        get { lock (gate) { return subscribers.Values.Any(subscriber => subscriber.Controls.Count != 0); } }
    }

    public void Register(IPAddress? address, TextSourceBatchRequest request)
    {
        if (address is null) return;
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        // Only LAN peers may receive the companion's bearer token in a callback.
        if (!IsLocalPeer(address)) return;
        lock (gate)
        {
            foreach (var item in request.Items)
            {
                var id = item.Id[..Math.Min(item.Id.Length, 40)];
                if (string.IsNullOrWhiteSpace(id)) continue;
                subscribers.TryGetValue(address, out var subscriber);
                if (item.Source is not ("nowPlaying" or "playbackState" or "outputVolume"))
                {
                    subscriber?.Controls.Remove(id);
                    continue;
                }
                if (subscriber is null)
                {
                    if (subscribers.Count == MaximumDevices)
                        subscribers.Remove(subscribers.MinBy(pair => pair.Value.LastRegistered).Key);
                    subscriber = new Subscriber(address);
                    subscribers.Add(address, subscriber);
                }
                var now = clock.GetUtcNow();
                subscriber.LastRegistered = now;
                subscriber.RetryAt = now;
                subscriber.Failures = 0;
                // Merge partial page/control polls; never replace other subscriptions.
                if (subscriber.Controls.TryGetValue(id, out var existing) && existing.Source == item.Source)
                    continue;
                if (subscriber.Controls.Count == MaximumControls && !subscriber.Controls.ContainsKey(id))
                    subscriber.Controls.Remove(subscriber.Controls.First().Key);
                subscriber.Controls[id] = new Subscription(id, item.Source);
                DiagnosticLog.Info($"Windows media subscribed: peer={address}, source={item.Source}, controls={subscriber.Controls.Count}");
            }
        }
    }

    public async Task PublishAsync(TextSourceBatchResponse snapshot, CancellationToken cancellationToken)
    {
        await publishing.WaitAsync(cancellationToken);
        try
        {
            Subscriber[] targets;
            lock (gate) targets = subscribers.Values.ToArray();
            await Task.WhenAll(targets.Select(target => PublishAsync(target, snapshot, cancellationToken)));
        }
        finally { publishing.Release(); }
    }

    private async Task PublishAsync(
        Subscriber subscriber,
        TextSourceBatchResponse snapshot,
        CancellationToken cancellationToken)
    {
        var now = clock.GetUtcNow();
        var sources = snapshot.Items.ToDictionary(item => item.Id, StringComparer.Ordinal);
        var track = sources.GetValueOrDefault("nowPlaying")?.Text;
        List<Pending> pending = [];
        lock (gate)
        {
            if (now < subscriber.RetryAt) return;
            foreach (var subscription in subscriber.Controls.Values)
            {
                if (!sources.TryGetValue(subscription.Source, out var source)) continue;
                var response = source with { Id = subscription.Id };
                // Smooth elapsed progress is extrapolated by the remote. A track change
                // must also resync transport-only pages, even when playing stays true.
                var signature = new Signature(response with
                {
                    ElapsedMilliseconds = null,
                    Value = subscription.Source == "nowPlaying" ? null : response.Value,
                }, subscription.Source == "outputVolume" ? null : track);
                var heartbeat = response.Available && response.DurationMilliseconds > 0 &&
                    now - subscription.DeliveredAt >= TimeSpan.FromSeconds(30);
                if (signature != subscription.Delivered || heartbeat)
                    pending.Add(new Pending(subscription, response, signature));
            }
        }

        foreach (var batch in pending.Chunk(16))
        {
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Post, subscriber.Callback);
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", configuration.Token);
                // Arduino WebServer requires Content-Length; JsonContent streams a
                // chunked body that it treats as an empty/invalid update.
                request.Content = new ByteArrayContent(JsonSerializer.SerializeToUtf8Bytes(
                    new TextSourceBatchResponse(batch.Select(item => item.Response).ToArray()),
                    new JsonSerializerOptions(JsonSerializerDefaults.Web)));
                request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
                using var response = await client.SendAsync(request, cancellationToken);
                response.EnsureSuccessStatusCode();
                lock (gate)
                {
                    foreach (var item in batch)
                    {
                        // An in-flight result must not acknowledge a retargeted source.
                        if (subscriber.Controls.GetValueOrDefault(item.Subscription.Id) != item.Subscription) continue;
                        item.Subscription.Delivered = item.Signature;
                        item.Subscription.DeliveredAt = now;
                    }
                    subscriber.Failures = 0;
                    subscriber.RetryAt = now;
                }
                DiagnosticLog.Info($"Windows media push: peer={subscriber.Address}, items={batch.Length}, HTTP={(int)response.StatusCode}");
            }
            catch (Exception exception) when (exception is HttpRequestException or OperationCanceledException)
            {
                cancellationToken.ThrowIfCancellationRequested();
                lock (gate)
                {
                    subscriber.Failures = Math.Min(subscriber.Failures + 1, 6);
                    subscriber.RetryAt = clock.GetUtcNow() + TimeSpan.FromSeconds(
                        Math.Min(60, 1 << subscriber.Failures));
                }
                // Do not cache failed deliveries: retry the newest snapshot, not stale text.
                var statusCode = (exception as HttpRequestException)?.StatusCode;
                DiagnosticLog.Info($"Windows media push failed: peer={subscriber.Address}, error={exception.GetType().Name}, HTTP={statusCode}; will retry");
                return;
            }
        }
    }

    private static bool IsLocalPeer(IPAddress address)
    {
        if (IPAddress.IsLoopback(address) || address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any))
            return false;
        if (address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6)
            return address.IsIPv6LinkLocal || (address.GetAddressBytes()[0] & 0xfe) == 0xfc;
        var bytes = address.GetAddressBytes();
        return bytes[0] == 10 || (bytes[0] == 172 && bytes[1] is >= 16 and <= 31) ||
            (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254);
    }

    public void Dispose()
    {
        client.Dispose();
        publishing.Dispose();
    }

    private sealed class Subscriber(IPAddress address)
    {
        public IPAddress Address { get; } = address;
        public Uri Callback { get; } = new UriBuilder("http", address.ToString(), 80, "/text-source/update").Uri;
        public Dictionary<string, Subscription> Controls { get; } = new(StringComparer.Ordinal);
        public DateTimeOffset LastRegistered { get; set; }
        public DateTimeOffset RetryAt { get; set; }
        public int Failures { get; set; }
    }

    private sealed class Subscription(string id, string source)
    {
        public string Id { get; } = id;
        public string Source { get; } = source;
        public Signature? Delivered { get; set; }
        public DateTimeOffset DeliveredAt { get; set; }
    }

    private sealed record Signature(TextSourceResponse Response, string? Track);
    private sealed record Pending(Subscription Subscription, TextSourceResponse Response, Signature Signature);
}