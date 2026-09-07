using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Windows.Media.Control;

namespace PaperGIF.Windows.Host;

internal sealed class WindowsTextSourceResolver(CompanionConfiguration configuration)
{
    private const int MaximumControlIdCharacters = 40;
    private const int MaximumTextBytes = 192;

    public async Task<TextSourceBatchResponse> ResolveAsync(
        TextSourceBatchRequest request,
        CancellationToken cancellationToken)
    {
        var needsMediaSession = request.Items.Any(item =>
            item.Source is "nowPlaying" or "playbackState");
        var media = needsMediaSession
            ? await ReadMediaSessionAsync(cancellationToken)
            : null;
        var responses = new List<TextSourceResponse>(request.Items.Count);
        foreach (var item in request.Items)
        {
            responses.Add(await ResolveAsync(item, media, cancellationToken));
        }
        return new TextSourceBatchResponse(responses);
    }

    private async Task<TextSourceResponse> ResolveAsync(
        TextSourceRequest request,
        MediaSessionState? media,
        CancellationToken cancellationToken)
    {
        var id = request.Id[..Math.Min(request.Id.Length, MaximumControlIdCharacters)];
        if (request.Source == "playbackState")
        {
            return new TextSourceResponse(
                id,
                string.Empty,
                media is not null,
                media is null ? null : media.IsPlaying ? 1 : 0);
        }
        if (request.Source == "outputVolume")
        {
            var value = AudioEndpointVolume.TryGetPercent();
            return new TextSourceResponse(id, string.Empty, value.HasValue, value);
        }

        string? text = request.Source switch
        {
            "nowPlaying" => media?.Description,
            "macScript" when configuration.AllowedScripts.Contains(
                request.SourceText,
                StringComparer.Ordinal) => await RunScriptAsync(request.SourceText, cancellationToken),
            _ => null,
        };
        text = text?.Trim();
        var available = !string.IsNullOrEmpty(text);
        return new TextSourceResponse(
            id,
            BoundUtf8(available ? text! : request.Placeholder, MaximumTextBytes),
            available);
    }

    private static async Task<MediaSessionState?> ReadMediaSessionAsync(
        CancellationToken cancellationToken)
    {
        try
        {
            var manager = await GlobalSystemMediaTransportControlsSessionManager
                .RequestAsync()
                .AsTask(cancellationToken);
            var sessions = manager.GetSessions();
            var session = manager.GetCurrentSession()
                ?? sessions.FirstOrDefault(candidate =>
                    candidate.GetPlaybackInfo().PlaybackStatus ==
                        GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing)
                ?? sessions.FirstOrDefault();
            if (session is null)
            {
                return null;
            }
            var properties = await session.TryGetMediaPropertiesAsync().AsTask(cancellationToken);
            var description = string.Join(
                " — ",
                new[] { properties.Title, properties.Artist }
                    .Where(value => !string.IsNullOrWhiteSpace(value)));
            var isPlaying = session.GetPlaybackInfo().PlaybackStatus ==
                GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
            return new MediaSessionState(description, isPlaying);
        }
        catch (Exception exception) when (
            exception is COMException or InvalidOperationException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static async Task<string?> RunScriptAsync(
        string script,
        CancellationToken cancellationToken)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo("powershell.exe")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                ArgumentList = { "-NoProfile", "-NonInteractive", "-File", script },
            });
            if (process is null)
            {
                return null;
            }
            var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken);
            return process.ExitCode == 0 ? await outputTask : null;
        }
        catch (Exception exception) when (
            exception is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return null;
        }
    }

    private static string BoundUtf8(string value, int maximumBytes)
    {
        if (Encoding.UTF8.GetByteCount(value) <= maximumBytes)
        {
            return value;
        }
        var characters = value.AsSpan();
        while (characters.Length > 0 && Encoding.UTF8.GetByteCount(characters) > maximumBytes)
        {
            characters = characters[..^1];
        }
        return characters.ToString();
    }

    private sealed record MediaSessionState(string Description, bool IsPlaying);

    internal static class AudioEndpointVolume
    {
        private const int ClsctxAll = 23;

        public static int? TryGetPercent()
        {
            IMMDeviceEnumerator? enumerator = null;
            IMMDevice? device = null;
            IAudioEndpointVolume? endpoint = null;
            try
            {
                var enumeratorType = Type.GetTypeFromCLSID(
                    new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"));
                if (enumeratorType is null)
                {
                    return null;
                }
                enumerator = (IMMDeviceEnumerator)Activator.CreateInstance(enumeratorType)!;
                Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0, 1, out device));
                var interfaceId = typeof(IAudioEndpointVolume).GUID;
                Marshal.ThrowExceptionForHR(device.Activate(
                    ref interfaceId,
                    ClsctxAll,
                    IntPtr.Zero,
                    out var endpointObject));
                endpoint = (IAudioEndpointVolume)endpointObject;
                Marshal.ThrowExceptionForHR(endpoint.GetMasterVolumeLevelScalar(out var volume));
                return Math.Clamp((int)Math.Round(volume * 255), 0, 255);
            }
            catch (Exception exception) when (
                exception is COMException or InvalidCastException or UnauthorizedAccessException)
            {
                return null;
            }
            finally
            {
                Release(endpoint);
                Release(device);
                Release(enumerator);
            }
        }

        public static bool TryAdjust(int percentagePoints)
        {
            return TryUseEndpoint(endpoint =>
            {
                Marshal.ThrowExceptionForHR(endpoint.GetMasterVolumeLevelScalar(out var volume));
                var nextVolume = Math.Clamp(volume + percentagePoints / 100f, 0f, 1f);
                Marshal.ThrowExceptionForHR(endpoint.SetMasterVolumeLevelScalar(nextVolume, IntPtr.Zero));
            });
        }

        public static bool TrySet(int value)
        {
            return TryUseEndpoint(endpoint =>
                Marshal.ThrowExceptionForHR(endpoint.SetMasterVolumeLevelScalar(
                    Math.Clamp(value, 0, 255) / 255f,
                    IntPtr.Zero)));
        }

        public static bool TryToggleMute()
        {
            return TryUseEndpoint(endpoint =>
            {
                Marshal.ThrowExceptionForHR(endpoint.GetMute(out var muted));
                Marshal.ThrowExceptionForHR(endpoint.SetMute(!muted, IntPtr.Zero));
            });
        }

        private static bool TryUseEndpoint(Action<IAudioEndpointVolume> action)
        {
            IMMDeviceEnumerator? enumerator = null;
            IMMDevice? device = null;
            IAudioEndpointVolume? endpoint = null;
            try
            {
                var enumeratorType = Type.GetTypeFromCLSID(
                    new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"));
                if (enumeratorType is null)
                {
                    return false;
                }
                enumerator = (IMMDeviceEnumerator)Activator.CreateInstance(enumeratorType)!;
                Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0, 1, out device));
                var interfaceId = typeof(IAudioEndpointVolume).GUID;
                Marshal.ThrowExceptionForHR(device.Activate(
                    ref interfaceId,
                    ClsctxAll,
                    IntPtr.Zero,
                    out var endpointObject));
                endpoint = (IAudioEndpointVolume)endpointObject;
                action(endpoint);
                return true;
            }
            catch (Exception exception) when (
                exception is COMException or InvalidCastException or UnauthorizedAccessException)
            {
                return false;
            }
            finally
            {
                Release(endpoint);
                Release(device);
                Release(enumerator);
            }
        }

        private static void Release(object? value)
        {
            if (value is not null && Marshal.IsComObject(value))
            {
                Marshal.ReleaseComObject(value);
            }
        }

        [ComImport]
        [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDeviceEnumerator
        {
            [PreserveSig] int EnumAudioEndpoints(int dataFlow, uint stateMask, out IntPtr devices);
            [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        }

        [ComImport]
        [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDevice
        {
            [PreserveSig]
            int Activate(
                ref Guid interfaceId,
                int classContext,
                IntPtr activationParameters,
                [MarshalAs(UnmanagedType.IUnknown)] out object instance);
        }

        [ComImport]
        [Guid("5CDF2C82-841E-4546-9722-0CF74078229A")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IAudioEndpointVolume
        {
            [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
            [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
            [PreserveSig] int GetChannelCount(out uint channelCount);
            [PreserveSig] int SetMasterVolumeLevel(float levelDb, IntPtr eventContext);
            [PreserveSig] int SetMasterVolumeLevelScalar(float level, IntPtr eventContext);
            [PreserveSig] int GetMasterVolumeLevel(out float levelDb);
            [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
            [PreserveSig] int SetChannelVolumeLevel(uint channel, float levelDb, IntPtr eventContext);
            [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, IntPtr eventContext);
            [PreserveSig] int GetChannelVolumeLevel(uint channel, out float levelDb);
            [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
            [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool muted, IntPtr eventContext);
            [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool muted);
        }
    }
}