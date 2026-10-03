using System.Net;
using System.Net.Http.Json;
using Xunit;

namespace PaperGIF.Windows.Host.Tests;

public sealed class WindowsMediaUpdatePublisherTests
{
    [Fact]
    public async Task PushUsesAuthenticatedPeerAndFirmwarePayload()
    {
        using var fixture = new Fixture();
        fixture.Register("::ffff:192.168.50.142", new string('a', 48), "nowPlaying");

        await fixture.Push();

        var request = Assert.Single(fixture.Handler.Requests);
        Assert.Equal("http://192.168.50.142/text-source/update", request.Url.AbsoluteUri);
        Assert.Equal("Bearer test-token", request.Authorization);
        Assert.True(request.ContentLength > 0);
        var item = Assert.Single(request.Body.Items);
        Assert.Equal(new string('a', 40), item.Id);
        Assert.Equal("First track", item.Text);
        Assert.True(item.Playing);
        Assert.Equal(120_000, item.DurationMilliseconds);
    }

    [Fact]
    public async Task TrackChangePushesTitleAndTransportEvenWhenStillPlaying()
    {
        using var fixture = new Fixture();
        fixture.Register("192.168.50.142", "title", "nowPlaying");
        fixture.Register("192.168.50.142", "transport", "playbackState");
        await fixture.Push();
        fixture.Clock.Advance(1);

        await fixture.Push(Snapshot("Second track"));

        Assert.Equal(2, fixture.Handler.Requests.Count);
        var items = fixture.Handler.Requests.Last().Body.Items;
        Assert.Equal(["title", "transport"], items.Select(item => item.Id));
        Assert.Equal("Second track", items[0].Text);
        Assert.True(items[1].Playing);
    }

    [Fact]
    public async Task TransportOnlyPageResyncsOnTrackChange()
    {
        using var fixture = new Fixture();
        fixture.Register("192.168.50.142", "transport", "playbackState");
        await fixture.Push();
        await fixture.Push(Snapshot("Second track"));

        Assert.Equal(2, fixture.Handler.Requests.Count);
        Assert.Equal("transport", Assert.Single(fixture.Handler.Requests.Last().Body.Items).Id);
    }

    [Fact]
    public async Task SmoothProgressDoesNotFloodButTimelineHasRecoveryHeartbeat()
    {
        using var fixture = new Fixture();
        fixture.Register("192.168.50.142", "seek", "nowPlaying");
        await fixture.Push();
        fixture.Clock.Advance(1);
        await fixture.Push(Snapshot(elapsed: 2_000));
        Assert.Single(fixture.Handler.Requests);

        fixture.Clock.Advance(29);
        await fixture.Push(Snapshot(elapsed: 31_000));

        Assert.Equal(2, fixture.Handler.Requests.Count);
        Assert.Equal(31_000, fixture.Handler.Requests.Last().Body.Items[0].ElapsedMilliseconds);
    }

    [Theory]
    [InlineData(false, true, 120_000)]
    [InlineData(true, false, 120_000)]
    [InlineData(true, true, 150_000)]
    public async Task PlaybackAvailabilityAndDurationChangesAreDelivered(bool playing, bool available, long duration)
    {
        using var fixture = new Fixture();
        fixture.Register("192.168.50.142", "seek", "nowPlaying");
        await fixture.Push();

        await fixture.Push(Snapshot(playing: playing, available: available, duration: duration));

        Assert.Equal(2, fixture.Handler.Requests.Count);
    }

    [Fact]
    public async Task PartialRefreshRetainsOtherControlsAndPages()
    {
        using var fixture = new Fixture();
        fixture.Register("192.168.50.142", "page-one-title", "nowPlaying");
        fixture.Register("192.168.50.142", "page-two-title", "nowPlaying");
        fixture.Register("192.168.50.142", "volume", "outputVolume");
        await fixture.Push();
        fixture.Register("192.168.50.142", "volume", "outputVolume");

        await fixture.Push(Snapshot("Second track"));

        Assert.Equal(["page-one-title", "page-two-title"],
            fixture.Handler.Requests.Last().Body.Items.Select(item => item.Id));
    }

    [Fact]
    public async Task VolumeChangesDoNotRepublishUnchangedMetadata()
    {
        using var fixture = new Fixture();
        fixture.Register("192.168.50.142", "title", "nowPlaying");
        fixture.Register("192.168.50.142", "volume", "outputVolume");
        await fixture.Push();

        await fixture.Push(Snapshot(volume: 180));

        Assert.Equal("volume", Assert.Single(fixture.Handler.Requests.Last().Body.Items).Id);
    }

    [Fact]
    public async Task FailedDeliveryRetriesLatestSnapshotNotLostOrStaleTrack()
    {
        using var fixture = new Fixture();
        fixture.Register("192.168.50.142", "title", "nowPlaying");
        fixture.Handler.Status = HttpStatusCode.ServiceUnavailable;
        await fixture.Push();
        fixture.Handler.Status = HttpStatusCode.OK;
        fixture.Clock.Advance(1);
        await fixture.Push(Snapshot("Second track"));
        Assert.Single(fixture.Handler.Requests);
        fixture.Clock.Advance(1);

        await fixture.Push(Snapshot("Third track"));
        await fixture.Push(Snapshot("Third track"));

        Assert.Equal(2, fixture.Handler.Requests.Count);
        Assert.Equal("Third track", fixture.Handler.Requests.Last().Body.Items[0].Text);
    }

    [Fact]
    public async Task NewPollResetsOfflineBackoff()
    {
        using var fixture = new Fixture();
        fixture.Register("192.168.50.142", "title", "nowPlaying");
        fixture.Handler.Status = HttpStatusCode.ServiceUnavailable;
        await fixture.Push();
        fixture.Handler.Status = HttpStatusCode.OK;
        fixture.Register("192.168.50.142", "title", "nowPlaying");

        await fixture.Push();

        Assert.Equal(2, fixture.Handler.Requests.Count);
    }

    [Fact]
    public async Task NewDeviceGetsSnapshotEvenWhenAnotherAlreadyAcknowledgedIt()
    {
        using var fixture = new Fixture();
        fixture.Register("192.168.50.142", "one", "nowPlaying");
        await fixture.Push();
        fixture.Register("192.168.50.143", "two", "nowPlaying");

        await fixture.Push();

        Assert.Equal(2, fixture.Handler.Requests.Count);
        Assert.Equal("192.168.50.143", fixture.Handler.Requests.Last().Url.Host);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("127.0.0.1")]
    [InlineData("::1")]
    [InlineData("0.0.0.0")]
    [InlineData("8.8.8.8")]
    [InlineData("224.0.0.1")]
    public async Task UnsafeOrMissingPeerNeverReceivesBearerToken(string? address)
    {
        using var fixture = new Fixture();
        fixture.Register(address, "title", "nowPlaying");

        await fixture.Push();

        Assert.False(fixture.Publisher.HasSubscribers);
        Assert.Empty(fixture.Handler.Requests);
    }

    [Fact]
    public async Task ScriptSourcesAreNeverBackgroundSubscriptions()
    {
        using var fixture = new Fixture();
        fixture.Register("192.168.50.142", "script", "macScript");
        await fixture.Push();
        Assert.False(fixture.Publisher.HasSubscribers);
        fixture.Register("192.168.50.142", "title", "nowPlaying");
        fixture.Register("192.168.50.142", "title", "macScript");

        await fixture.Push();

        Assert.Empty(fixture.Handler.Requests);
    }

    [Fact]
    public async Task ControlsAreBoundedAndUpdatesChunkedToFirmwareLimit()
    {
        using var fixture = new Fixture();
        for (var index = 0; index < WindowsMediaUpdatePublisher.MaximumControls + 1; index++)
            fixture.Register("192.168.50.142", $"control-{index}", "nowPlaying");

        await fixture.Push();

        Assert.Equal(8, fixture.Handler.Requests.Count);
        Assert.All(fixture.Handler.Requests, request => Assert.Equal(16, request.Body.Items.Count));
        Assert.DoesNotContain(fixture.Handler.Requests.SelectMany(request => request.Body.Items),
            item => item.Id == "control-0");
    }

    [Fact]
    public async Task DeviceCountIsBounded()
    {
        using var fixture = new Fixture();
        for (var index = 1; index <= WindowsMediaUpdatePublisher.MaximumDevices + 1; index++)
        {
            fixture.Register($"192.168.50.{index}", "title", "nowPlaying");
            fixture.Clock.Advance(1);
        }

        await fixture.Push();

        Assert.Equal(WindowsMediaUpdatePublisher.MaximumDevices, fixture.Handler.Requests.Count);
        Assert.DoesNotContain(fixture.Handler.Requests, request => request.Url.Host == "192.168.50.1");
    }

    [Fact]
    public async Task InFlightDeliveryCannotAcknowledgeReplacedSource()
    {
        using var fixture = new Fixture();
        fixture.Register("192.168.50.142", "control", "nowPlaying");
        fixture.Handler.OnSend = () => fixture.Register("192.168.50.142", "control", "outputVolume");
        await fixture.Push();
        fixture.Handler.OnSend = null;

        await fixture.Push();

        Assert.Equal(2, fixture.Handler.Requests.Count);
        Assert.Equal(128, fixture.Handler.Requests.Last().Body.Items[0].Value);
        Assert.Equal("", fixture.Handler.Requests.Last().Body.Items[0].Text);
    }

    private static TextSourceBatchResponse Snapshot(
        string title = "First track", bool playing = true, bool available = true,
        long elapsed = 1_000, long duration = 120_000, int volume = 128) => new([
            new("nowPlaying", available ? title : "", available, (int)(elapsed * 255 / duration),
                elapsed, duration, playing),
            new("playbackState", "", available, playing ? 1 : 0, elapsed, duration, playing),
            new("outputVolume", "", true, volume),
        ]);

    private sealed class Fixture : IDisposable
    {
        public RecordingHandler Handler { get; } = new();
        public TestClock Clock { get; } = new();
        public WindowsMediaUpdatePublisher Publisher { get; }

        public Fixture() => Publisher = new WindowsMediaUpdatePublisher(
            new CompanionConfiguration { Token = "test-token" }, new HttpClient(Handler), Clock);

        public void Register(string? address, string id, string source) => Publisher.Register(
            address is null ? null : IPAddress.Parse(address),
            new TextSourceBatchRequest { Items = [new() { Id = id, Source = source }] });

        public Task Push(TextSourceBatchResponse? snapshot = null) =>
            Publisher.PublishAsync(snapshot ?? Snapshot(), CancellationToken.None);

        public void Dispose() => Publisher.Dispose();
    }

    private sealed class TestClock : TimeProvider
    {
        private DateTimeOffset now = DateTimeOffset.UnixEpoch;
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(int seconds) => now += TimeSpan.FromSeconds(seconds);
    }

    private sealed record CapturedRequest(
        Uri Url, string? Authorization, TextSourceBatchResponse Body, long? ContentLength);

    private sealed class RecordingHandler : HttpMessageHandler
    {
        public List<CapturedRequest> Requests { get; } = [];
        public HttpStatusCode Status { get; set; } = HttpStatusCode.OK;
        public Action? OnSend { get; set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var contentLength = request.Content!.Headers.ContentLength;
            var body = await request.Content!.ReadFromJsonAsync<TextSourceBatchResponse>(cancellationToken);
            lock (Requests) Requests.Add(new CapturedRequest(
                request.RequestUri!, request.Headers.Authorization?.ToString(), body!, contentLength));
            OnSend?.Invoke();
            return new HttpResponseMessage(Status);
        }
    }
}