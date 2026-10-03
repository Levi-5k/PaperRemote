using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

namespace PaperGIF.Windows.Host;

internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly NotifyIcon notifyIcon;
    private readonly ToolStripMenuItem activityItem;
    private readonly CompanionActivity activity;
    private readonly CompanionConfiguration configuration;
    private readonly PairingApprovalService pairingApprovalService;
    private readonly StartupRegistration startupRegistration;
    private readonly RemoteEditorStore editorStore;
    private readonly RemoteEditorWindow window;
    private readonly Icon icon;
    private readonly UpdateService updateService = new();
    private readonly ToolStripMenuItem updateItem;
    private readonly System.Windows.Forms.Timer updateTimer = new() { Interval = 24 * 60 * 60 * 1000 };
    private bool updateBusy;

    public TrayApplicationContext(
        CompanionConfiguration configuration,
        CompanionActivity activity,
        PairingApprovalService pairingApprovalService,
        StartupRegistration startupRegistration,
        RemoteEditorStore editorStore,
        NetworkDiscoveryService discovery,
        NetHomeService netHomeService,
        ModuleCatalogService moduleCatalog)
    {
        this.configuration = configuration;
        this.activity = activity;
        this.pairingApprovalService = pairingApprovalService;
        this.startupRegistration = startupRegistration;
        this.editorStore = editorStore;
        icon = PaperGifIcon.Create(64);
        window = new RemoteEditorWindow(editorStore, activity, discovery, netHomeService, moduleCatalog, icon);
        var openItem = new ToolStripMenuItem(
            "Open paperGIF",
            null,
            (_, _) => window.ShowAndActivate());
        var statusItem = new ToolStripMenuItem($"Running on port {configuration.Port}")
        {
            Enabled = false,
        };
        activityItem = new ToolStripMenuItem("No actions received")
        {
            Enabled = false,
        };
        var settingsItem = new ToolStripMenuItem(
            "Companion settings...",
            null,
            (_, _) => ShowSettings());
        var forgetDevicesItem = new ToolStripMenuItem(
            "Forget paired devices...",
            null,
            (_, _) => ForgetPairedDevices());
        var startupItem = new ToolStripMenuItem("Launch at sign in")
        {
            Checked = startupRegistration.IsEnabled,
            CheckOnClick = true,
        };
        startupItem.CheckedChanged += (_, _) =>
        {
            if (!startupRegistration.SetEnabled(startupItem.Checked, out var error))
            {
                startupItem.Checked = startupRegistration.IsEnabled;
                MessageBox.Show(error, "paperGIF", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        };
        startupRegistration.Changed += (_, _) => startupItem.Checked = startupRegistration.IsEnabled;
        var exitItem = new ToolStripMenuItem("Exit", null, (_, _) => ExitThread());
        updateItem = new ToolStripMenuItem(
            "Check for updates...",
            null,
            async (_, _) => await CheckForUpdatesAsync(userInitiated: true));

        var menu = new ContextMenuStrip();
        menu.Items.Add(openItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(statusItem);
        menu.Items.Add(activityItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(startupItem);
        menu.Items.Add(settingsItem);
        menu.Items.Add(forgetDevicesItem);
        menu.Items.Add(updateItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(exitItem);

        notifyIcon = new NotifyIcon
        {
            ContextMenuStrip = menu,
            Icon = icon,
            Text = "paperGIF Windows Companion",
            Visible = true,
        };
        notifyIcon.DoubleClick += (_, _) => window.ShowAndActivate();
        notifyIcon.MouseClick += (_, eventArgs) =>
        {
            if (eventArgs.Button == MouseButtons.Left)
            {
                window.ShowAndActivate();
            }
        };
        activity.ActionRecorded += HandleActionRecorded;
        pairingApprovalService.ApprovalRequested += HandleApprovalRequested;
        _ = CheckForModuleUpdatesAsync(moduleCatalog);
        updateTimer.Tick += async (_, _) => await CheckForUpdatesAsync(userInitiated: false);
        updateTimer.Start();
        _ = CheckForUpdatesAfterStartupAsync();
        notifyIcon.ShowBalloonTip(
            3_000,
            "paperGIF",
            "Windows companion is running.",
            ToolTipIcon.Info);
    }

    private static async Task CheckForModuleUpdatesAsync(ModuleCatalogService moduleCatalog)
    {
        try
        {
            await moduleCatalog.RefreshAsync();
        }
        catch (Exception exception) when (exception is HttpRequestException or
            TaskCanceledException or System.Text.Json.JsonException or IOException)
        {
            // Startup refresh is best effort; the editor keeps its explicit retry action.
        }
    }

    private async Task CheckForUpdatesAfterStartupAsync()
    {
        await Task.Delay(TimeSpan.FromSeconds(15));
        await CheckForUpdatesAsync(userInitiated: false);
    }

    private async Task CheckForUpdatesAsync(bool userInitiated)
    {
        if (updateBusy)
        {
            return;
        }
        updateBusy = true;
        var installConfirmed = false;
        SetUpdateStatus("Checking for updates...");
        try
        {
            var release = await updateService.LatestAsync();
            var offeredUpdate = false;
            var currentVersion = UpdateService.CurrentVersion;
            if (release.Manifest.Windows is { } appAsset && SoftwareVersion.IsNewer(release.Version, currentVersion))
            {
                offeredUpdate = true;
                if (Confirm(
                    $"paperGIF {release.Version} is available",
                    $"You have {currentVersion}. paperGIF will download, verify, install, and restart.\n\n{release.Notes}",
                    "Install and restart?"))
                {
                    installConfirmed = true;
                    SetUpdateStatus($"Downloading paperGIF {release.Version}...");
                    var archive = await updateService.DownloadAsync(appAsset, release);
                    updateService.InstallAppAndExit(archive, release.Version, ExitThread);
                    return;
                }
            }

            var address = editorStore.DeviceAddress;
            var deviceVersion = await updateService.DeviceFirmwareVersionAsync(address);
            if (deviceVersion is not null && release.Manifest.Firmware is { } firmwareAsset &&
                SoftwareVersion.IsNewer(release.Version, deviceVersion))
            {
                offeredUpdate = true;
                if (deviceVersion == UpdateService.UsbOnlyFirmwareVersion)
                {
                    if (userInitiated)
                    {
                        MessageBox.Show(
                            $"This M5Paper's firmware is too old to update over Wi-Fi. Flash firmware {release.Version} over USB once; later updates install from here.",
                            "M5Paper needs a one-time USB update",
                            MessageBoxButtons.OK,
                            MessageBoxIcon.Information);
                    }
                }
                else if (Confirm(
                    $"M5Paper firmware {release.Version} is available",
                    $"The M5Paper has {deviceVersion}. Keep it awake and nearby; it restarts when the update finishes.",
                    "Update the M5Paper now?"))
                {
                    installConfirmed = true;
                    SetUpdateStatus($"Downloading M5Paper firmware {release.Version}...");
                    var firmware = await updateService.DownloadAsync(firmwareAsset, release);
                    try
                    {
                        SetUpdateStatus($"Installing M5Paper firmware {release.Version}...");
                        await updateService.InstallFirmwareAsync(firmware, release.Version, address, configuration.Token);
                    }
                    finally
                    {
                        File.Delete(firmware);
                    }
                    DiagnosticLog.Info($"M5Paper firmware updated to {release.Version}");
                    MessageBox.Show(
                        $"The M5Paper restarted with firmware {release.Version}.",
                        "paperGIF",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information);
                }
            }

            if (userInitiated && !offeredUpdate)
            {
                var firmwareLine = deviceVersion is null
                    ? "M5Paper not reachable, so its firmware was not checked"
                    : $"M5Paper firmware {deviceVersion}";
                MessageBox.Show(
                    $"paperGIF {currentVersion}\n{firmwareLine}\nLatest release: {release.Version}",
                    "paperGIF is up to date",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
        }
        catch (Exception exception) when (exception is UpdateException or HttpRequestException or
            TaskCanceledException or System.Text.Json.JsonException or IOException or
            InvalidDataException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            DiagnosticLog.Error("Update failed", exception);
            if (userInitiated || installConfirmed)
            {
                MessageBox.Show(exception.Message, "paperGIF update", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }
        finally
        {
            updateBusy = false;
            SetUpdateStatus(null);
        }
    }

    private void SetUpdateStatus(string? status)
    {
        updateItem.Text = status ?? "Check for updates...";
        updateItem.Enabled = status is null;
    }

    private static bool Confirm(string title, string message, string question) =>
        MessageBox.Show(
            $"{message}\n\n{question}",
            title,
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Information) == DialogResult.Yes;

    protected override void ExitThreadCore()
    {
        activity.ActionRecorded -= HandleActionRecorded;
        pairingApprovalService.ApprovalRequested -= HandleApprovalRequested;
        updateTimer.Dispose();
        updateService.Dispose();
        window.CloseForExit();
        window.Dispose();
        notifyIcon.Visible = false;
        notifyIcon.Dispose();
        icon.Dispose();
        base.ExitThreadCore();
    }

    private void HandleApprovalRequested(object? sender, string requester)
    {
        if (activityItem.Owner?.InvokeRequired == true)
        {
            activityItem.Owner.BeginInvoke(() => HandleApprovalRequested(sender, requester));
            return;
        }
        notifyIcon.ShowBalloonTip(
            10_000,
            "paperGIF pairing request",
            $"{requester} wants to pair with this PC. Approve or decline in the paperGIF dialog.",
            ToolTipIcon.Info);
    }

    private void HandleActionRecorded(object? sender, ActionSnapshot action)
    {
        if (activityItem.Owner?.InvokeRequired == true)
        {
            activityItem.Owner.BeginInvoke(() => HandleActionRecorded(sender, action));
            return;
        }
        var actionName = string.IsNullOrWhiteSpace(action.Text) ? action.Type : action.Text;
        activityItem.Text = $"{(action.Succeeded ? "Ran" : "Failed")}: {actionName}";
        var tooltip = $"paperGIF: {activityItem.Text}";
        notifyIcon.Text = tooltip[..Math.Min(tooltip.Length, 63)];
    }

    private void ShowSettings()
    {
        var previousToken = configuration.Token;
        if (!CompanionSettingsDialog.Edit(configuration, out var portChanged))
        {
            return;
        }
        editorStore.RefreshLocalCompanion(previousToken);
        if (!portChanged)
        {
            return;
        }
        var restart = MessageBox.Show(
            "Restart paperGIF now to use the new listener port?",
            "paperGIF",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Information);
        if (restart == DialogResult.Yes)
        {
            Application.Restart();
            ExitThread();
        }
    }

    private void ForgetPairedDevices()
    {
        var result = MessageBox.Show(
            "Existing paperGIF remotes will stop controlling this computer until they pair again.",
            "Forget all paired devices?",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning,
            MessageBoxDefaultButton.Button2);
        if (result != DialogResult.Yes)
        {
            return;
        }
        var previousToken = pairingApprovalService.ForgetAll();
        editorStore.RefreshLocalCompanion(previousToken);
        MessageBox.Show(
            "Pairings were cleared. Send the updated profile to M5Paper after pairing again.",
            "paperGIF",
            MessageBoxButtons.OK,
            MessageBoxIcon.Information);
    }
}