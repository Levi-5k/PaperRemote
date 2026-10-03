using Xunit;

namespace PaperGIF.Windows.Host.Tests;

public sealed class WindowsMediaTransportTests
{
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