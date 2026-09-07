using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

namespace PaperGIF.Windows.Host;

internal sealed class CompanionWindow : Form
{
    private static readonly Color Ink = Color.FromArgb(29, 38, 34);
    private static readonly Color Muted = Color.FromArgb(91, 102, 96);
    private static readonly Color Canvas = Color.FromArgb(245, 247, 244);
    private static readonly Color Forest = Color.FromArgb(31, 72, 61);
    private static readonly Color Success = Color.FromArgb(36, 130, 88);
    private readonly CompanionConfiguration configuration;
    private readonly CompanionActivity activity;
    private readonly PairingApprovalService pairingApprovalService;
    private readonly StartupRegistration startupRegistration;
    private readonly Label lastActionLabel;
    private readonly Label pairedDevicesLabel;
    private readonly ListBox pairedDevicesList;
    private readonly ListBox recentActionsList;
    private readonly CheckBox startupCheckBox;
    private bool updatingStartupControl;
    private bool allowClose;

    public CompanionWindow(
        CompanionConfiguration configuration,
        CompanionActivity activity,
        PairingApprovalService pairingApprovalService,
        StartupRegistration startupRegistration,
        Icon icon)
    {
        this.configuration = configuration;
        this.activity = activity;
        this.pairingApprovalService = pairingApprovalService;
        this.startupRegistration = startupRegistration;
        Text = "paperGIF Windows Companion";
        Icon = (Icon)icon.Clone();
        ClientSize = new Size(620, 520);
        MinimumSize = new Size(560, 480);
        BackColor = Canvas;
        Font = new Font("Segoe UI", 9F);
        StartPosition = FormStartPosition.CenterScreen;

        var header = new Panel
        {
            BackColor = Forest,
            Dock = DockStyle.Top,
            Height = 108,
            Padding = new Padding(24, 20, 24, 16),
        };
        var logo = new PictureBox
        {
            Image = icon.ToBitmap(),
            Location = new Point(24, 22),
            Size = new Size(56, 56),
            SizeMode = PictureBoxSizeMode.StretchImage,
        };
        var title = new Label
        {
            AutoSize = true,
            Font = new Font("Segoe UI Semibold", 20F),
            ForeColor = Color.White,
            Location = new Point(94, 20),
            Text = "paperGIF",
        };
        var subtitle = new Label
        {
            AutoSize = true,
            Font = new Font("Segoe UI", 9.5F),
            ForeColor = Color.FromArgb(211, 226, 219),
            Location = new Point(97, 62),
            Text = "Windows companion",
        };
        var running = new Label
        {
            Anchor = AnchorStyles.Top | AnchorStyles.Right,
            AutoSize = true,
            BackColor = Success,
            ForeColor = Color.White,
            Font = new Font("Segoe UI Semibold", 9F),
            Padding = new Padding(10, 6, 10, 6),
            Location = new Point(509, 35),
            Text = "Running",
        };
        header.Controls.AddRange([logo, title, subtitle, running]);

        var content = new TableLayoutPanel
        {
            ColumnCount = 2,
            Dock = DockStyle.Fill,
            Padding = new Padding(24, 20, 24, 20),
            RowCount = 8,
        };
        content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 45));
        content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 55));
        content.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        content.RowStyles.Add(new RowStyle(SizeType.Absolute, 54));
        content.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        content.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        content.RowStyles.Add(new RowStyle(SizeType.Absolute, 12));
        content.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        content.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        content.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var hostLabel = new Label
        {
            AutoSize = true,
            Font = new Font("Segoe UI Semibold", 11F),
            ForeColor = Ink,
            Text = $"{Environment.MachineName}  •  Port {configuration.Port}",
        };
        lastActionLabel = new Label
        {
            AutoEllipsis = true,
            Dock = DockStyle.Fill,
            ForeColor = Muted,
            Padding = new Padding(0, 8, 0, 8),
            TextAlign = ContentAlignment.MiddleLeft,
        };
        pairedDevicesLabel = SectionLabel("Paired devices");
        pairedDevicesList = new ListBox
        {
            BorderStyle = BorderStyle.FixedSingle,
            Dock = DockStyle.Fill,
            IntegralHeight = false,
            BackColor = Color.White,
            ForeColor = Ink,
        };
        var recentActionsLabel = SectionLabel("Recent activity");
        recentActionsList = new ListBox
        {
            BorderStyle = BorderStyle.FixedSingle,
            Dock = DockStyle.Fill,
            IntegralHeight = false,
            BackColor = Color.White,
            ForeColor = Ink,
            Margin = new Padding(12, 3, 0, 3),
        };
        var actionsLabel = SectionLabel("Companion controls");
        var actions = new FlowLayoutPanel
        {
            AutoSize = true,
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
        };
        startupCheckBox = new CheckBox
        {
            AutoSize = true,
            ForeColor = Ink,
            Margin = new Padding(0, 10, 16, 0),
            Text = "Launch at sign in",
        };
        startupCheckBox.CheckedChanged += HandleStartupChanged;
        actions.Controls.Add(startupCheckBox);
        actions.Controls.Add(CommandButton("Copy address", CopyAddress));
        actions.Controls.Add(CommandButton("Open configuration", OpenConfigurationFolder));
        var hint = new Label
        {
            AutoSize = true,
            ForeColor = Muted,
            Padding = new Padding(0, 8, 0, 0),
            Text = "Closing this window keeps the companion available in the notification area.",
        };

        content.Controls.Add(hostLabel, 0, 0);
        content.SetColumnSpan(hostLabel, 2);
        content.Controls.Add(lastActionLabel, 0, 1);
        content.SetColumnSpan(lastActionLabel, 2);
        content.Controls.Add(pairedDevicesLabel, 0, 2);
        content.Controls.Add(recentActionsLabel, 1, 2);
        content.Controls.Add(pairedDevicesList, 0, 3);
        content.Controls.Add(recentActionsList, 1, 3);
        content.Controls.Add(actionsLabel, 0, 5);
        content.SetColumnSpan(actionsLabel, 2);
        content.Controls.Add(actions, 0, 6);
        content.SetColumnSpan(actions, 2);
        content.Controls.Add(hint, 0, 7);
        content.SetColumnSpan(hint, 2);
        Controls.Add(content);
        Controls.Add(header);

        activity.ActionRecorded += HandleActionRecorded;
        pairingApprovalService.PairingChanged += HandlePairingChanged;
        startupRegistration.Changed += HandleStartupRegistrationChanged;
        RefreshContent();
    }

    public void ShowAndActivate()
    {
        Show();
        if (WindowState == FormWindowState.Minimized)
        {
            WindowState = FormWindowState.Normal;
        }
        Activate();
    }

    public void CloseForExit()
    {
        allowClose = true;
        Close();
    }

    protected override void OnFormClosing(FormClosingEventArgs eventArgs)
    {
        if (!allowClose && eventArgs.CloseReason == CloseReason.UserClosing)
        {
            eventArgs.Cancel = true;
            Hide();
        }
        base.OnFormClosing(eventArgs);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            activity.ActionRecorded -= HandleActionRecorded;
            pairingApprovalService.PairingChanged -= HandlePairingChanged;
            startupRegistration.Changed -= HandleStartupRegistrationChanged;
        }
        base.Dispose(disposing);
    }

    private void HandleActionRecorded(object? sender, ActionSnapshot action)
    {
        if (InvokeRequired)
        {
            BeginInvoke(() => HandleActionRecorded(sender, action));
            return;
        }
        lastActionLabel.Text = FormatAction(action);
        recentActionsList.Items.Insert(0, FormatAction(action));
        while (recentActionsList.Items.Count > 25)
        {
            recentActionsList.Items.RemoveAt(recentActionsList.Items.Count - 1);
        }
    }

    private void HandlePairingChanged(object? sender, EventArgs eventArgs)
    {
        if (InvokeRequired)
        {
            BeginInvoke(() => HandlePairingChanged(sender, eventArgs));
            return;
        }
        RefreshPairedDevices();
    }

    private void HandleStartupRegistrationChanged(object? sender, EventArgs eventArgs) =>
        RefreshStartupControl();

    private void RefreshContent()
    {
        RefreshPairedDevices();
        recentActionsList.Items.Clear();
        foreach (var recentAction in activity.RecentActions)
        {
            recentActionsList.Items.Add(FormatAction(recentAction));
        }
        if (recentActionsList.Items.Count == 0)
        {
            recentActionsList.Items.Add("No actions received yet");
        }
        RefreshStartupControl();
        lastActionLabel.Text = activity.LastAction is { } lastAction
            ? FormatAction(lastAction)
            : "Waiting for the first remote action";
    }

    private void RefreshPairedDevices()
    {
        pairedDevicesList.Items.Clear();
        foreach (var device in configuration.PairedDevices.Order(StringComparer.CurrentCultureIgnoreCase))
        {
            pairedDevicesList.Items.Add(device);
        }
        if (pairedDevicesList.Items.Count == 0)
        {
            pairedDevicesList.Items.Add("No devices paired yet");
        }
        pairedDevicesLabel.Text = $"Paired devices  ({configuration.PairedDevices.Count})";
    }

    private void RefreshStartupControl()
    {
        updatingStartupControl = true;
        startupCheckBox.Checked = startupRegistration.IsEnabled;
        updatingStartupControl = false;
    }

    private void HandleStartupChanged(object? sender, EventArgs eventArgs)
    {
        if (updatingStartupControl)
        {
            return;
        }
        if (!startupRegistration.SetEnabled(startupCheckBox.Checked, out var error))
        {
            MessageBox.Show(
                this,
                error ?? "The startup setting could not be changed.",
                "paperGIF",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
            RefreshStartupControl();
        }
    }

    private static string FormatAction(ActionSnapshot action)
    {
        var actionName = action.Type switch
        {
            "macMedia" => "Media",
            "macKey" => "Keyboard",
            "macOpen" => "Open",
            "macScript" => "Script",
            _ => action.Type,
        };
        var detail = string.IsNullOrWhiteSpace(action.Text) ? actionName : $"{actionName}: {action.Text}";
        return $"{(action.Succeeded ? "Last action" : "Last action failed")}  •  {detail}  •  {action.ReceivedAt.LocalDateTime:t}";
    }

    private static Label SectionLabel(string text) => new()
    {
        AutoSize = true,
        Font = new Font("Segoe UI Semibold", 10F),
        ForeColor = Ink,
        Padding = new Padding(0, 0, 0, 8),
        Text = text,
    };

    private static Button CommandButton(string text, EventHandler handler)
    {
        var button = new Button
        {
            AutoSize = true,
            BackColor = Color.White,
            FlatStyle = FlatStyle.Flat,
            ForeColor = Ink,
            Margin = new Padding(0, 0, 10, 0),
            Padding = new Padding(10, 5, 10, 5),
            Text = text,
            UseVisualStyleBackColor = false,
        };
        button.FlatAppearance.BorderColor = Color.FromArgb(199, 207, 202);
        button.Click += handler;
        return button;
    }

    private void CopyAddress(object? sender, EventArgs eventArgs) =>
        Clipboard.SetText($"http://{Environment.MachineName}:{configuration.Port}");

    private static void OpenConfigurationFolder(object? sender, EventArgs eventArgs)
    {
        var folder = Path.GetDirectoryName(CompanionConfiguration.ConfigurationPath);
        if (folder is null)
        {
            return;
        }
        Directory.CreateDirectory(folder);
        Process.Start(new ProcessStartInfo("explorer.exe", folder) { UseShellExecute = true });
    }
}