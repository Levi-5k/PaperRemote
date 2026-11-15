using Microsoft.Win32;
using System.Diagnostics;

namespace PaperGIF.Windows.Host;

internal sealed class StartupRegistration
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "OP Remote";
    private const string LegacyValueName = "paperGIF Windows Companion";
    private const string ScheduledTaskName = "OP Remote";
    private const string LegacyScheduledTaskName = "paperGIF Windows Companion";

    public event EventHandler? Changed;

    public bool IsEnabled => ScheduledTaskExists(ScheduledTaskName) || ScheduledTaskExists(LegacyScheduledTaskName);

    /// <summary>Moves a previously registered login task so Task Scheduler shows OP Remote.</summary>
    public void AdoptCurrentName()
    {
        DeleteLegacyRunValue();
        if (!ScheduledTaskExists(LegacyScheduledTaskName))
        {
            return;
        }
        if (!ScheduledTaskExists(ScheduledTaskName))
        {
            SetEnabled(true, out _);
        }
        if (ScheduledTaskExists(ScheduledTaskName))
        {
            RunScheduledTasks("/Delete", "/TN", LegacyScheduledTaskName, "/F");
        }
    }

    public bool SetEnabled(bool enabled, out string? error)
    {
        try
        {
            using var runKey = Registry.CurrentUser.CreateSubKey(RunKeyPath, true);
            runKey.DeleteValue(ValueName, false);
            runKey.DeleteValue(LegacyValueName, false);
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
                if (ScheduledTaskExists(LegacyScheduledTaskName))
                {
                    RunScheduledTasks("/Delete", "/TN", LegacyScheduledTaskName, "/F");
                }
            }
            else
            {
                if (ScheduledTaskExists(ScheduledTaskName) &&
                    RunScheduledTasks("/Delete", "/TN", ScheduledTaskName, "/F") != 0)
                {
                    throw new InvalidOperationException("The existing startup task could not be removed.");
                }
                if (ScheduledTaskExists(LegacyScheduledTaskName) &&
                    RunScheduledTasks("/Delete", "/TN", LegacyScheduledTaskName, "/F") != 0)
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

    private static void DeleteLegacyRunValue()
    {
        try
        {
            using var runKey = Registry.CurrentUser.CreateSubKey(RunKeyPath, true);
            runKey?.DeleteValue(LegacyValueName, false);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }
    }

    private static bool ScheduledTaskExists(string name) =>
        RunScheduledTasks("/Query", "/TN", name) == 0;

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