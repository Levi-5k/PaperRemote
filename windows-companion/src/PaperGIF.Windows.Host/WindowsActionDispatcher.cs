using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Windows.Media.Control;

namespace PaperGIF.Windows.Host;

internal sealed class WindowsActionDispatcher(
    CompanionConfiguration configuration,
    CompanionActivity activity,
    NetHomeService netHomeService,
    OpenBuildsControlService openBuildsService)
{
    private const uint KeyEventKeyUp = 0x0002;
    private const byte VirtualKeyControl = 0x11;
    private const byte VirtualKeyMenu = 0x12;
    private const byte VirtualKeyShift = 0x10;
    private const byte VirtualKeyLeftWindows = 0x5B;

    public RemoteActionResult Perform(RemoteRequest request)
    {
        if (request.Type.StartsWith("netHome", StringComparison.Ordinal))
        {
            var netHomeResult = netHomeService.Perform(request);
            var netHomeDispatchResult = new RemoteActionResult(netHomeResult.Succeeded, netHomeResult.Changed);
            activity.Record(request, netHomeDispatchResult);
            return netHomeDispatchResult;
        }
        var succeeded = request.Type switch
        {
            "macMedia" => SendMediaCommand(request),
            "macKey" => SendKey(request.Text, request.Modifiers),
            "macOpen" => Open(request.Text),
            "macScript" => RunApprovedScript(request.Text),
            "macShortcut" => false,
            "openBuilds" => openBuildsService.Perform(request),
            _ => false,
        };
        var result = new RemoteActionResult(succeeded, succeeded);
        activity.Record(request, result);
        return result;
    }

    private static bool SendMediaCommand(RemoteRequest request)
    {
        if (request.Text == "volumeUp")
        {
            return WindowsTextSourceResolver.AudioEndpointVolume.TryAdjust(5);
        }
        if (request.Text == "volumeDown")
        {
            return WindowsTextSourceResolver.AudioEndpointVolume.TryAdjust(-5);
        }
        if (request.Text == "volume")
        {
            return WindowsTextSourceResolver.AudioEndpointVolume.TrySet(request.Value);
        }
        if (request.Text == "mute")
        {
            return WindowsTextSourceResolver.AudioEndpointVolume.TryToggleMute();
        }
        if (request.Text == "seek")
        {
            return TrySeek(request.Value);
        }

        byte virtualKey = request.Text switch
        {
            "playPause" => 0xB3,
            "previous" => 0xB1,
            "next" => 0xB0,
            _ => 0,
        };
        if (virtualKey == 0)
        {
            return false;
        }

        PressAndRelease(virtualKey);
        return true;
    }

    private static bool TrySeek(int value)
    {
        try
        {
            var manager = GlobalSystemMediaTransportControlsSessionManager
                .RequestAsync()
                .AsTask()
                .GetAwaiter()
                .GetResult();
            var sessions = manager.GetSessions();
            var session = manager.GetCurrentSession()
                ?? sessions.FirstOrDefault(candidate =>
                    candidate.GetPlaybackInfo().PlaybackStatus ==
                        GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing)
                ?? sessions.FirstOrDefault();
            if (session is null)
            {
                return false;
            }
            var timeline = session.GetTimelineProperties();
            var duration = timeline.EndTime - timeline.StartTime;
            if (duration <= TimeSpan.Zero)
            {
                return false;
            }
            var fraction = Math.Clamp(value, 0, 255) / 255d;
            var position = timeline.StartTime + TimeSpan.FromTicks(
                (long)(duration.Ticks * fraction));
            return session.TryChangePlaybackPositionAsync(position.Ticks)
                .AsTask()
                .GetAwaiter()
                .GetResult();
        }
        catch (Exception exception) when (
            exception is COMException or InvalidOperationException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static bool SendKey(string key, IReadOnlyCollection<string> modifiers)
    {
        var translated = TranslateKey(key);
        if (translated < 0)
        {
            return false;
        }

        var modifierKeys = modifiers.Select(modifier => modifier.ToLowerInvariant() switch
        {
            "control" => VirtualKeyControl,
            "option" or "alt" => VirtualKeyMenu,
            "shift" => VirtualKeyShift,
            "command" or "windows" => VirtualKeyLeftWindows,
            _ => (byte)0,
        }).Where(value => value != 0).ToArray();

        foreach (var modifierKey in modifierKeys)
        {
            KeyDown(modifierKey);
        }
        PressAndRelease((byte)translated);
        foreach (var modifierKey in modifierKeys.Reverse())
        {
            KeyUp(modifierKey);
        }
        return true;
    }

    internal static int TranslateKey(string key)
    {
        var normalized = key.ToLowerInvariant();
        var translated = normalized switch
        {
            "tab" => 0x09,
            "return" or "enter" => 0x0D,
            "escape" => 0x1B,
            "space" => 0x20,
            "delete" => 0x08,
            "forwarddelete" => 0x2E,
            "home" => 0x24,
            "end" => 0x23,
            "pageup" => 0x21,
            "pagedown" => 0x22,
            "left" => 0x25,
            "up" => 0x26,
            "right" => 0x27,
            "down" => 0x28,
            _ when key.Length == 1 => VkKeyScan(key[0]) & 0xff,
            _ => -1,
        };
        if (translated >= 0)
        {
            return translated;
        }
        return normalized.Length is 2 or 3 && normalized[0] == 'f' &&
            int.TryParse(normalized[1..], out var functionNumber) && functionNumber is >= 1 and <= 20
                ? 0x6F + functionNumber
                : -1;
    }

    private static bool Open(string target)
    {
        if (string.IsNullOrWhiteSpace(target))
        {
            return false;
        }
        try
        {
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
            return true;
        }
        catch (Exception exception) when (exception is Win32Exception or InvalidOperationException)
        {
            return false;
        }
    }

    private bool RunApprovedScript(string script)
    {
        if (!configuration.AllowedScripts.Contains(script, StringComparer.Ordinal))
        {
            return false;
        }
        try
        {
            Process.Start(new ProcessStartInfo("powershell.exe")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                ArgumentList = { "-NoProfile", "-NonInteractive", "-File", script },
            });
            return true;
        }
        catch (Exception exception) when (exception is Win32Exception or InvalidOperationException)
        {
            return false;
        }
    }

    private static void PressAndRelease(byte virtualKey)
    {
        KeyDown(virtualKey);
        KeyUp(virtualKey);
    }

    private static void KeyDown(byte virtualKey) =>
        keybd_event(virtualKey, 0, 0, UIntPtr.Zero);

    private static void KeyUp(byte virtualKey) =>
        keybd_event(virtualKey, 0, KeyEventKeyUp, UIntPtr.Zero);

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern short VkKeyScan(char character);
}