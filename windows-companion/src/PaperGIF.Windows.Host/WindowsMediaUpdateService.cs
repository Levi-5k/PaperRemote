namespace PaperGIF.Windows.Host;

internal sealed class WindowsMediaUpdateService(
    WindowsTextSourceResolver resolver,
    WindowsMediaUpdatePublisher publisher) : BackgroundService
{
    private static readonly TextSourceBatchRequest SnapshotRequest = new()
    {
        Items = [
            new() { Id = "nowPlaying", Source = "nowPlaying" },
            new() { Id = "playbackState", Source = "playbackState" },
            new() { Id = "outputVolume", Source = "outputVolume" },
        ],
    };

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            if (!publisher.HasSubscribers) continue;
            try
            {
                using var reading = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
                reading.CancelAfter(TimeSpan.FromSeconds(3));
                // One GSMTC/volume read for all subscribed controls and devices.
                // Polling also catches players which omit GSMTC change notifications.
                var snapshot = await resolver.ResolveAsync(SnapshotRequest, reading.Token);
                await publisher.PublishAsync(snapshot, stoppingToken);
            }
            catch (OperationCanceledException) when (!stoppingToken.IsCancellationRequested)
            {
                DiagnosticLog.Info("Windows media observation timed out; will retry");
            }
            catch (Exception exception) when (!stoppingToken.IsCancellationRequested)
            {
                DiagnosticLog.Error("Windows media observation failed; will retry", exception);
            }
        }
    }
}