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
    private readonly UpdateCoordinator updates;
    private readonly ToolStripMenuItem updateItem;
    private readonly System.Windows.Forms.Timer updateTimer = new() { Interval = 24 * 60 * 60 * 1000 };
    private bool updateBalloonShown;

    public TrayApplicationContext(
        CompanionConfiguration configuration,
        CompanionActivity activity,
        PairingApprovalService pairingApprovalService,
        StartupRegistration startupRegistration,
        RemoteEditorStore editorStore,
        NetworkDiscoveryService discovery,
        NetHomeService netHomeService,
        ModuleCatalogService moduleCatalog,
        HomeAccessoryCatalog homeAccessories)
    {
        this.configuration = configuration;
        this.activity = activity;
        this.pairingApprovalService = pairingApprovalService;
        this.startupRegistration = startupRegistration;
        this.editorStore = editorStore;
        icon = PaperGifIcon.Create(64);
        updates = new UpdateCoordinator(editorStore, configuration) { ExitApplication = ExitThread };
        window = new RemoteEditorWindow(editorStore, activity, discovery, netHomeService, moduleCatalog, homeAccessories, updates, icon);
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
            (_, _) => window.ShowUpdates(checkNow: true));

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
        updates.Changed += (_, _) => UpdateMenuItemText();
        notifyIcon.BalloonTipClicked += (_, _) =>
        {
            if (updateBalloonShown)
            {
                updateBalloonShown = false;
                window.ShowUpdates(checkNow: false);
            }
        };
        _ = CheckForModuleUpdatesAsync(moduleCatalog);
        updateTimer.Tick += async (_, _) => await RefreshQuietlyAsync();
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
        await RefreshQuietlyAsync();
    }

    private static string NotifiedVersionPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "paperGIF",
        "update-notified.txt");

    // Automatic checks never open dialogs: the tray item changes and a balloon appears once per version.
    private async Task RefreshQuietlyAsync()
    {
        await updates.RefreshAsync();
        var release = updates.AppUpdate ?? (updates.FirmwareNeedsUsb ? null : updates.FirmwareUpdate);
        if (release is null)
        {
            return;
        }
        try
        {
            if (File.Exists(NotifiedVersionPath) && File.ReadAllText(NotifiedVersionPath).Trim() == release.Version)
            {
                return;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(NotifiedVersionPath)!);
            File.WriteAllText(NotifiedVersionPath, release.Version);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            DiagnosticLog.Error("Could not record the update notification", exception);
        }
        updateBalloonShown = true;
        notifyIcon.ShowBalloonTip(
            10_000,
            "paperGIF update available",
            updates.AppUpdate is not null
                ? $"paperGIF {release.Version} is ready to install. Click to see the update."
                : $"M5Paper firmware {release.Version} is ready to install. Click to see the update.",
            ToolTipIcon.Info);
    }

    private void UpdateMenuItemText()
    {
        var available = updates.AppUpdate ?? updates.FirmwareUpdate;
        // Stays enabled while busy: it opens the Updates page, which shows progress.
        updateItem.Text = updates.Activity ?? (available is null
            ? "Check for updates..."
            : $"Install update {available.Version}...");
    }

    protected override void ExitThreadCore()
    {
        activity.ActionRecorded -= HandleActionRecorded;
        pairingApprovalService.ApprovalRequested -= HandleApprovalRequested;
        updateTimer.Dispose();
        updates.Dispose();
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
        var actionName = string.IsNullOrWhiteSpace(action.Text)
            ? ActionDescriptions.TypeName(action.Type)
            : ActionDescriptions.Detail(action.Text);
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