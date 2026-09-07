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

        var menu = new ContextMenuStrip();
        menu.Items.Add(openItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(statusItem);
        menu.Items.Add(activityItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(startupItem);
        menu.Items.Add(settingsItem);
        menu.Items.Add(forgetDevicesItem);
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
        notifyIcon.ShowBalloonTip(
            3_000,
            "paperGIF",
            "Windows companion is running.",
            ToolTipIcon.Info);
    }

    protected override void ExitThreadCore()
    {
        activity.ActionRecorded -= HandleActionRecorded;
        window.CloseForExit();
        window.Dispose();
        notifyIcon.Visible = false;
        notifyIcon.Dispose();
        icon.Dispose();
        base.ExitThreadCore();
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