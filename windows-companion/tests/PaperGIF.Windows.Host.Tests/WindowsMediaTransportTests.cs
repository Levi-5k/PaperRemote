using Xunit;

namespace PaperGIF.Windows.Host.Tests;

public sealed class WindowsMediaTransportTests
{
    [Fact]
    public void RepeatedCachedPlayingSampleAdvancesInsteadOfResettingRemoteClock()
    {
        var sampledAt = new DateTimeOffset(2026, 11, 1, 12, 0, 0, TimeSpan.Zero);
        for (var seconds = 0; seconds <= 5; ++seconds)
            Assert.Equal(60000 + seconds * 1000,
                WindowsTextSourceResolver.PlaybackElapsedMilliseconds(TimeSpan.FromSeconds(60),
                    TimeSpan.FromSeconds(240), true, sampledAt, sampledAt.AddSeconds(seconds)));
        Assert.Equal(20000, WindowsTextSourceResolver.PlaybackElapsedMilliseconds(TimeSpan.FromSeconds(20),
            TimeSpan.FromSeconds(240), true, sampledAt.AddSeconds(6), sampledAt.AddSeconds(6)));
        Assert.Equal(1000, WindowsTextSourceResolver.PlaybackElapsedMilliseconds(TimeSpan.Zero,
            TimeSpan.FromSeconds(180), true, sampledAt.AddSeconds(6), sampledAt.AddSeconds(7)));
    }

    [Theory]
    [InlineData(false, 60, 240, 5, 60000)]
    [InlineData(true, 60, 240, -5, 60000)]
    [InlineData(true, 238, 240, 5, 240000)]
    [InlineData(false, -1, 240, 5, 0)]
    [InlineData(true, 60, 0, 5, 0)]
    public void PlaybackClockRespectsPauseTimestampAndDuration(bool playing, int position, int duration,
        int age, long expected)
    {
        var sampledAt = new DateTimeOffset(2026, 11, 1, 12, 0, 0, TimeSpan.Zero);
        Assert.Equal(expected, WindowsTextSourceResolver.PlaybackElapsedMilliseconds(TimeSpan.FromSeconds(position),
            TimeSpan.FromSeconds(duration), playing, sampledAt, sampledAt.AddSeconds(age)));
    }

    [Fact]
    public void MissingMediaTimestampDoesNotAdvanceFromTheBeginningOfTime()
    {
        Assert.Equal(60000, WindowsTextSourceResolver.PlaybackElapsedMilliseconds(TimeSpan.FromSeconds(60),
            TimeSpan.FromSeconds(240), true, default, DateTimeOffset.UtcNow));
    }

    [Theory]
    [InlineData("playPause")]
    [InlineData("previous")]
    [InlineData("next")]
    public async Task TransportCommandsUseOnlyTheSelectedSession(string command)
    {
        var selected = new FakeSession();
        var other = new FakeSession();

        Assert.True(await WindowsMediaTransport.SendAsync(command, selected));

        Assert.Equal([command], selected.Commands);
        Assert.Empty(other.Commands);
    }

    [Theory]
    [InlineData("playPause")]
    [InlineData("previous")]
    [InlineData("next")]
    public async Task NoLocalSessionFailsInsteadOfBroadcastingAKey(string command)
    {
        Assert.False(await WindowsMediaTransport.SendAsync(command, null));
    }

    [Theory]
    [InlineData("playPause")]
    [InlineData("previous")]
    [InlineData("next")]
    public async Task SessionRejectionDoesNotRetryOrChooseAnotherPlayer(string command)
    {
        var session = new FakeSession { Succeeds = false };

        Assert.False(await WindowsMediaTransport.SendAsync(command, session));
        Assert.Equal([command], session.Commands);
    }

    [Theory]
    [InlineData("")]
    [InlineData("unsupported")]
    [InlineData("volume")]
    public async Task OtherCommandsDoNotInvokeTransport(string command)
    {
        var session = new FakeSession();

        Assert.False(await WindowsMediaTransport.SendAsync(command, session));
        Assert.Empty(session.Commands);
    }

    private sealed class FakeSession : IWindowsMediaTransportSession
    {
        public string SourceAppId => "Test.LocalPlayer";
        public bool Succeeds { get; init; } = true;
        public List<string> Commands { get; } = [];

        public Task<bool> TogglePlayPauseAsync() => Record("playPause");
        public Task<bool> PreviousAsync() => Record("previous");
        public Task<bool> NextAsync() => Record("next");

        private Task<bool> Record(string command)
        {
            Commands.Add(command);
            return Task.FromResult(Succeeds);
        }
    }
}