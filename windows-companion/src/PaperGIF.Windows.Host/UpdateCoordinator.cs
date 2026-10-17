using System.Text.Json;

namespace PaperGIF.Windows.Host;

// Update state shared by the tray menu and the editor window.
internal sealed class UpdateCoordinator : IDisposable
{
    private readonly UpdateService service = new();
    private readonly RemoteEditorStore editorStore;
    private readonly CompanionConfiguration configuration;
    private SynchronizationContext? uiContext;
    private string? firmwareAddress;
    private string? deviceFirmware;

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
    public string? DeviceFirmware
    {
        get => editorStore.Descriptor is { FirmwareVersion: not "legacy" } descriptor
            ? descriptor.FirmwareVersion
            : firmwareAddress == editorStore.DeviceAddress ? deviceFirmware : null;
        private set { deviceFirmware = value; firmwareAddress = editorStore.DeviceAddress; }
    }
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
        editorStore.CanInstallM5Firmware &&
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
        var cancellationToken = editorStore.DeviceSessionCancellation;
        try
        {
            await editorStore.IdentifyDeviceAsync();
            var deviceID = editorStore.Descriptor?.DeviceID;
            var version = address == editorStore.DeviceAddress && editorStore.CanInstallM5Firmware
                ? await service.DeviceFirmwareVersionAsync(address, cancellationToken) : null;
            if (address != editorStore.DeviceAddress || cancellationToken.IsCancellationRequested ||
                deviceID != editorStore.Descriptor?.DeviceID) return;
            if (version is not null)
            {
                DeviceFirmware = version;
                RaiseChanged();
                return;
            }
        }
        catch (Exception exception) when (exception is HttpRequestException or OperationCanceledException or
            InvalidOperationException or JsonException)
        {
        }
        if (address != editorStore.DeviceAddress || cancellationToken.IsCancellationRequested) return;
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
        var deviceID = editorStore.Descriptor?.DeviceID;
        var cancellationToken = editorStore.DeviceSessionCancellation;
        SetActivity($"Downloading M5Paper firmware {release.Version}...");
        try
        {
            var firmware = await service.DownloadAsync(asset, release, cancellationToken);
            try
            {
                await editorStore.IdentifyDeviceAsync();
                if (editorStore.DeviceAddress != address || editorStore.Descriptor?.DeviceID != deviceID ||
                    !editorStore.CanInstallM5Firmware)
                    throw new UpdateException("Device changed or this board is incompatible with M5Paper firmware.");
                if (await service.DeviceFirmwareVersionAsync(address, cancellationToken) is not { } installed ||
                    !SoftwareVersion.IsNewer(release.Version, installed))
                    throw new UpdateException("Could not verify that this firmware is newer than the selected device.");
                cancellationToken.ThrowIfCancellationRequested();
                if (editorStore.DeviceAddress != address || editorStore.Descriptor?.DeviceID != deviceID)
                    throw new UpdateException("Device changed before firmware installation.");
                SetActivity($"Installing M5Paper firmware {release.Version}... the M5Paper shows progress and restarts when done.");
                await service.InstallFirmwareAsync(firmware, release.Version, address, configuration.Token, cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
                if (editorStore.DeviceAddress != address || editorStore.Descriptor?.DeviceID != deviceID)
                    throw new UpdateException("Device changed while waiting for firmware restart.");
                await editorStore.IdentifyDeviceAsync();
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
        exception is UpdateException or HttpRequestException or OperationCanceledException or JsonException or InvalidOperationException or
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
