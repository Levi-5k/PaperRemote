using Microsoft.Win32;
using System.Diagnostics;

namespace PaperGIF.Windows.Host;

internal sealed class StartupRegistration
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "paperGIF Windows Companion";
    private const string ScheduledTaskName = "paperGIF Windows Companion";

    public event EventHandler? Changed;

    public bool IsEnabled => ScheduledTaskExists();

    public bool SetEnabled(bool enabled, out string? error)
    {
        try
        {
            using var runKey = Registry.CurrentUser.CreateSubKey(RunKeyPath, true);
            runKey.DeleteValue(ValueName, false);
            if (enabled)
            {
                var executablePath = Environment.ProcessPath
                    ?? throw new InvalidOperationException("The application path is unavailable.");
                if (RunScheduledTasks(
                    "/Create",
                    "/TN", ScheduledTaskName,
                    "/TR", $"\"{executablePath}\"",
                    "/SC", "ONLOGON",
                    "/RL", "LIMITED",
                    "/IT",
                    "/F") != 0)
                {
                    throw new InvalidOperationException("The startup task could not be created.");
                }
            }
            else
            {
                if (ScheduledTaskExists() && RunScheduledTasks("/Delete", "/TN", ScheduledTaskName, "/F") != 0)
                {
                    throw new InvalidOperationException("The existing startup task could not be removed.");
                }
            }
            error = null;
            Changed?.Invoke(this, EventArgs.Empty);
            return true;
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            error = exception.Message;
            return false;
        }
    }

    private static bool ScheduledTaskExists() =>
        RunScheduledTasks("/Query", "/TN", ScheduledTaskName) == 0;

    private static int RunScheduledTasks(params string[] arguments)
    {
        var startInfo = new ProcessStartInfo("schtasks.exe")
        {
            CreateNoWindow = true,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }
        using var process = Process.Start(startInfo);
        if (process is null)
        {
            return -1;
        }
        process.WaitForExit(3_000);
        return process.HasExited ? process.ExitCode : -1;
    }
}