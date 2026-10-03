using System.Runtime.InteropServices;
using Windows.Media.Control;

namespace PaperGIF.Windows.Host;

internal interface IWindowsMediaTransportSession
{
    string SourceAppId { get; }
    Task<bool> TogglePlayPauseAsync();
    Task<bool> PreviousAsync();
    Task<bool> NextAsync();
}

internal static class WindowsMediaTransport
{
    internal static GlobalSystemMediaTransportControlsSession? SelectSession(
        GlobalSystemMediaTransportControlsSessionManager manager) =>
        manager.GetCurrentSession()
        ?? manager.GetSessions().FirstOrDefault(candidate =>
            candidate.GetPlaybackInfo().PlaybackStatus ==
                GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing)
        ?? manager.GetSessions().FirstOrDefault();

    public static async Task<bool> SendAsync(string command)
    {
        try
        {
            var manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            var session = SelectSession(manager);
            return await SendAsync(command, session is null ? null : new NativeSession(session));
        }
        catch (Exception exception) when (
            exception is COMException or InvalidOperationException or UnauthorizedAccessException)
        {
            DiagnosticLog.Error($"Windows media session unavailable for {command}", exception);
            return false;
        }
    }

    internal static async Task<bool> SendAsync(string command, IWindowsMediaTransportSession? session)
    {
        // Do not fall back to global media-key injection: keyboard-sharing
        // software can forward those keys to a different computer.
        if (session is null)
        {
            DiagnosticLog.Info($"Windows media {command}: no local media session; no key sent");
            return false;
        }
        var succeeded = command switch
        {
            "playPause" => await session.TogglePlayPauseAsync(),
            "previous" => await session.PreviousAsync(),
            "next" => await session.NextAsync(),
            _ => false,
        };
        DiagnosticLog.Info($"Windows media {command}: session={session.SourceAppId}, succeeded={succeeded}");
        return succeeded;
    }

    private sealed class NativeSession(GlobalSystemMediaTransportControlsSession session)
        : IWindowsMediaTransportSession
    {
        public string SourceAppId => session.SourceAppUserModelId;
        public Task<bool> TogglePlayPauseAsync() => session.TryTogglePlayPauseAsync().AsTask();
        public Task<bool> PreviousAsync() => session.TrySkipPreviousAsync().AsTask();
        public Task<bool> NextAsync() => session.TrySkipNextAsync().AsTask();
    }
}