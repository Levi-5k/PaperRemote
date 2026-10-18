using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Threading.Channels;
using PaperGIF.Windows.Core;

namespace PaperGIF.Windows.Host;

/// <summary>
/// Receives low-latency dial datagrams on the action port (UDP) and applies only the newest
/// value per action.
/// </summary>
internal sealed class DialStreamService(
    CompanionConfiguration configuration,
    WindowsActionDispatcher dispatcher) : BackgroundService
{
    private static readonly JsonSerializerOptions BindingOptions = new(JsonSerializerDefaults.Web);
    private readonly LatestValueQueue<RemoteRequest> pending = new();
    private readonly Channel<bool> wake = Channel.CreateBounded<bool>(
        new BoundedChannelOptions(1) { FullMode = BoundedChannelFullMode.DropWrite });

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        UdpClient client;
        try
        {
            client = new UdpClient(new IPEndPoint(IPAddress.Any, configuration.Port));
        }
        catch (SocketException exception)
        {
            DiagnosticLog.Info($"Dial stream listener failed to start: {exception.Message}");
            return;
        }
        using (client)
        {
            var apply = Task.Run(() => ApplyAsync(stoppingToken), stoppingToken);
            var ordering = new DialStreamOrdering();
            while (!stoppingToken.IsCancellationRequested)
            {
                UdpReceiveResult received;
                try { received = await client.ReceiveAsync(stoppingToken); }
                catch (OperationCanceledException) { break; }
                catch (SocketException) { continue; }
                var datagram = DialStreamDatagram.Parse(received.Buffer, configuration.Token);
                if (datagram is null ||
                    !ordering.Accept(received.RemoteEndPoint.Address.ToString(), datagram.Boot, datagram.Seq))
                {
                    continue;
                }
                RemoteRequest? request;
                try { request = JsonSerializer.Deserialize<RemoteRequest>(datagram.ActionJson, BindingOptions); }
                catch (JsonException) { continue; }
                if (request is null) continue;
                pending.Offer($"{request.Type}|{request.Text}|{request.Host}", request);
                wake.Writer.TryWrite(true);
            }
            try { await apply; } catch (OperationCanceledException) { }
        }
    }

    private async Task ApplyAsync(CancellationToken stoppingToken)
    {
        while (await wake.Reader.WaitToReadAsync(stoppingToken))
        {
            wake.Reader.TryRead(out _);
            while (pending.TryTake(out var request))
            {
                try { RelayedActionHandler.Perform(dispatcher, request); }
                catch (Exception exception) { DiagnosticLog.Info($"Dial stream action failed: {exception.Message}"); }
            }
        }
    }
}
