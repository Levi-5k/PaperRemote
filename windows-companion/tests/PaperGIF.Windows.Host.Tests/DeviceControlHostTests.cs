using System.Net;
using System.Text;
using PaperGIF.Windows.Core;
using PaperGIF.Windows.Core.Models;
using PaperGIF.Windows.Host;
using Xunit;

public sealed class DeviceControlHostTests
{
    private static readonly string ControlsDescriptor = File.ReadAllText(Path.Combine(
        AppContext.BaseDirectory, "Fixtures", "device-descriptor-v1-controls.json"));

    [Theory]
    [InlineData("")]
    [InlineData("null")]
    [InlineData("{\"type\":")]
    [InlineData("[1,2]")]
    public void MalformedRelayedBodiesAreRejectedBeforeDispatch(string body)
    {
        // Malformed bodies must never reach the dispatcher, so it is safe to pass none here.
        Assert.False(RelayedActionHandler.Execute(null!, body));
    }

    [Fact]
    public async Task SessionReadsControlsOverWifiWithBearerToken()
    {
        var handler = new RecordingHandler("""{"values":{"slideshow":true,"sleepDelay":900,"screenSaver":"media","battery":87}}""");
        using var client = new HttpClient(handler);
        var descriptor = DeviceDescriptor.Parse(ControlsDescriptor);
        await using var session = new DeviceControlSession(
            descriptor, new DeviceControlClient(client, new Uri("http://192.168.1.40/remote"), "token-1"), ble: null);

        var snapshot = await session.GetSnapshotAsync(CancellationToken.None);

        Assert.Equal("Wi-Fi", session.TransportName);
        Assert.False(session.IsOnBluetooth);
        Assert.Equal(87, snapshot.Values["battery"].GetDouble());
        Assert.Equal("http://192.168.1.40/device/controls", handler.LastUri?.ToString());
        Assert.Equal("Bearer token-1", handler.LastAuthorization);
    }

    [Fact]
    public async Task SessionSurfacesTransportErrorsWithoutBluetooth()
    {
        using var client = new HttpClient(new FailingHandler());
        var descriptor = DeviceDescriptor.Parse(ControlsDescriptor);
        await using var session = new DeviceControlSession(
            descriptor, new DeviceControlClient(client, new Uri("http://192.168.1.40/"), "token-1"), ble: null);

        var exception = await Assert.ThrowsAsync<DeviceControlException>(() => session.GetSnapshotAsync(CancellationToken.None));
        Assert.True(exception.IsTransportError);
    }

    private sealed class RecordingHandler(string body) : HttpMessageHandler
    {
        public Uri? LastUri { get; private set; }
        public string? LastAuthorization { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            LastUri = request.RequestUri;
            LastAuthorization = request.Headers.Authorization?.ToString();
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            });
        }
    }

    private sealed class FailingHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            throw new HttpRequestException("Connection refused", null, HttpStatusCode.ServiceUnavailable);
    }
}
