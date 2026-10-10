using System.Text.Json;

namespace PaperGIF.Windows.Host;

// Update state shared by the tray menu and the editor window.
internal sealed class UpdateCoordinator : IDisposable
{
    private readonly UpdateService service = new();
    private readonly RemoteEditorStore editorStore;
    private readonly CompanionConfiguration configuration;
    private SynchronizationContext? uiContext;

    public UpdateCoordinator(RemoteEditorStore editorStore, CompanionConfiguration configuration)
    {
        this.editorStore = editorStore;
        this.configuration = configuration;
    }

    public event EventHandler? Changed;

    // Set by the tray so an app install can close paperGIF before the installer replaces it.
    public Action? ExitApplication { get; set; }

    public AvailableRelease? Release { get; private set; }
    // Null when the M5Paper could not be reached.
    public string? DeviceFirmware { get; private set; }
    public string? Activity { get; private set; }
    public string? Problem { get; private set; }
    public string? Notice { get; private set; }
    public DateTime? LastChecked { get; private set; }

    public bool HasUpdate => AppUpdate is not null || FirmwareUpdate is not null;

    public static string CurrentVersion => UpdateService.CurrentVersion;

    public AvailableRelease? AppUpdate =>
        Release is { Manifest.Windows: not null } release && SoftwareVersion.IsNewer(release.Version, CurrentVersion)
            ? release
            : null;

    public AvailableRelease? FirmwareUpdate =>
        Release is { Manifest.Firmware: not null } release && DeviceFirmware is { } firmware &&
        SoftwareVersion.IsNewer(release.Version, firmware)
            ? release
            : null;

    public bool FirmwareNeedsUsb =>
        FirmwareUpdate is not null && DeviceFirmware == UpdateService.UsbOnlyFirmwareVersion;

    public bool IsBusy => Activity is not null;

    // Checks GitHub and the M5Paper without interrupting; results show in the tray menu and editor.
    public async Task RefreshAsync()
    {
        uiContext ??= SynchronizationContext.Current;
        if (IsBusy)
        {
            return;
        }
        SetActivity("Checking for updates...");
        try
        {
            try
            {
                Release = await service.LatestAsync();
                LastChecked = DateTime.UtcNow;
                Problem = null;
            }
            catch (Exception exception) when (IsUpdateFailure(exception))
            {
                DiagnosticLog.Error("Update check failed", exception);
                if (Release is null)
                {
                    Problem = $"Could not check for updates: {exception.Message}";
                }
            }
            await RefreshDeviceAsync();
        }
        finally
        {
            SetActivity(null);
        }
    }

    public async Task RefreshDeviceAsync()
    {
        var address = editorStore.DeviceAddress;
        if (await service.DeviceFirmwareVersionAsync(address) is { } version)
        {
            DeviceFirmware = version;
            RaiseChanged();
            return;
        }
        // The saved address goes stale when the M5Paper gets a new IP; find it again.
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            foreach (var device in await NetworkDiscoveryService.ProbeNetworkAsync(address, timeout.Token))
            {
                if (await service.DeviceFirmwareVersionAsync(device.Host) is { } found)
                {
                    Post(() => editorStore.DeviceAddress = device.Host);
                    DeviceFirmware = found;
                    RaiseChanged();
                    return;
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
        DeviceFirmware = null;
        RaiseChanged();
    }

    public void DismissMessages()
    {
        Problem = null;
        Notice = null;
        RaiseChanged();
    }

    public async Task InstallAppAsync()
    {
        uiContext ??= SynchronizationContext.Current;
        if (IsBusy || AppUpdate is not { Manifest.Windows: { } asset } release)
        {
            return;
        }
        Problem = null;
        Notice = null;
        SetActivity($"Downloading paperGIF {release.Version}...");
        try
        {
            var archive = await service.DownloadAsync(asset, release);
            SetActivity($"Installing paperGIF {release.Version}...");
            service.InstallAppAndExit(archive, release.Version, ExitApplication ?? System.Windows.Forms.Application.Exit);
        }
        catch (Exception exception) when (IsUpdateFailure(exception))
        {
            DiagnosticLog.Error("App update failed", exception);
            Problem = exception.Message;
            SetActivity(null);
        }
    }

    public async Task InstallFirmwareAsync()
    {
        uiContext ??= SynchronizationContext.Current;
        if (IsBusy || FirmwareNeedsUsb || FirmwareUpdate is not { Manifest.Firmware: { } asset } release)
        {
            return;
        }
        Problem = null;
        Notice = null;
        var address = editorStore.DeviceAddress;
        SetActivity($"Downloading M5Paper firmware {release.Version}...");
        try
        {
            var firmware = await service.DownloadAsync(asset, release);
            try
            {
                SetActivity($"Installing M5Paper firmware {release.Version}... the M5Paper shows progress and restarts when done.");
                await service.InstallFirmwareAsync(firmware, release.Version, address, configuration.Token);
            }
            finally
            {
                File.Delete(firmware);
            }
            DiagnosticLog.Info($"M5Paper firmware updated to {release.Version}");
            DeviceFirmware = release.Version;
            Notice = $"The M5Paper restarted with firmware {release.Version}.";
        }
        catch (Exception exception) when (IsUpdateFailure(exception))
        {
            DiagnosticLog.Error("Firmware update failed", exception);
            Problem = exception.Message;
        }
        finally
        {
            SetActivity(null);
        }
    }

    public void Dispose() => service.Dispose();

    private static bool IsUpdateFailure(Exception exception) =>
        exception is UpdateException or HttpRequestException or TaskCanceledException or JsonException or
            IOException or InvalidDataException or UnauthorizedAccessException or
            System.ComponentModel.Win32Exception;

    private void SetActivity(string? activity)
    {
        Activity = activity;
        RaiseChanged();
    }

    private void RaiseChanged() => Post(() => Changed?.Invoke(this, EventArgs.Empty));

    private void Post(Action action)
    {
        if (uiContext is null || SynchronizationContext.Current == uiContext)
        {
            action();
        }
        else
        {
            uiContext.Post(_ => action(), null);
        }
    }
}
