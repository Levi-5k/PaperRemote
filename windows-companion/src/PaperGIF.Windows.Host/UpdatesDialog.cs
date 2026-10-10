namespace PaperGIF.Windows.Host;

// Versions, update actions, and release notes for this PC and the selected M5Paper.
internal sealed class UpdatesDialog : Form
{
    private readonly UpdateCoordinator updates;
    private readonly Label lastChecked = new();
    private readonly Button checkButton = new();
    private readonly Panel messagePanel = new();
    private readonly Label messageText = new();
    private readonly UpdateCardPanel appCard;
    private readonly UpdateCardPanel firmwareCard;
    private readonly Label notesTitle = new();
    private readonly TextBox notes = new();
    private readonly LinkLabel releaseLink = new();

    public UpdatesDialog(UpdateCoordinator updates, Icon icon)
    {
        this.updates = updates;
        Text = "Software updates";
        Icon = (Icon)icon.Clone();
        ClientSize = new Size(620, 600);
        MinimumSize = new Size(520, 480);
        StartPosition = FormStartPosition.CenterParent;
        FluentWindow.Apply(this, WindowBackdrop.Acrylic, ambientCanvas: true);
        ShowInTaskbar = false;
        MinimizeBox = false;

        appCard = new UpdateCardPanel("paperGIF for Windows", async () => await updates.InstallAppAsync());
        firmwareCard = new UpdateCardPanel("M5Paper", async () =>
        {
            if (updates.DeviceFirmware is null)
            {
                await updates.RefreshDeviceAsync();
            }
            else
            {
                await updates.InstallFirmwareAsync();
            }
        });

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 6,
            Padding = new Padding(18, 14, 18, 14),
            BackColor = Color.Transparent,
        };
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.Controls.Add(BuildHeader(icon), 0, 0);
        layout.Controls.Add(BuildMessage(), 0, 1);
        appCard.Dock = DockStyle.Top;
        firmwareCard.Dock = DockStyle.Top;
        layout.Controls.Add(appCard, 0, 2);
        layout.Controls.Add(firmwareCard, 0, 3);
        layout.Controls.Add(BuildNotes(), 0, 4);
        layout.Controls.Add(BuildFooter(), 0, 5);
        Controls.Add(layout);

        updates.Changed += HandleUpdatesChanged;
        Render();
    }

    protected override void OnFormClosed(FormClosedEventArgs eventArgs)
    {
        updates.Changed -= HandleUpdatesChanged;
        base.OnFormClosed(eventArgs);
    }

    private void HandleUpdatesChanged(object? sender, EventArgs eventArgs)
    {
        if (!IsDisposed)
        {
            Render();
        }
    }

    private Control BuildHeader(Icon icon)
    {
        var header = new Panel { Dock = DockStyle.Top, Height = 58 };
        var logo = new PictureBox
        {
            Image = icon.ToBitmap(),
            Location = new Point(0, 6),
            Size = new Size(40, 40),
            SizeMode = PictureBoxSizeMode.StretchImage,
        };
        var title = new Label
        {
            AutoSize = true,
            Font = new Font("Segoe UI Variable Display Semibold", 13F),
            ForeColor = EditorTheme.Ink,
            Location = new Point(50, 4),
            Text = "Software updates",
        };
        lastChecked.AutoSize = true;
        lastChecked.ForeColor = EditorTheme.Muted;
        lastChecked.Location = new Point(52, 31);
        UpdateCardPanel.StyleButton(checkButton, prominent: false);
        checkButton.Text = "Check now";
        checkButton.Width = 104;
        checkButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        checkButton.Location = new Point(header.Width - checkButton.Width, 12);
        checkButton.Click += async (_, _) => await updates.RefreshAsync();
        header.Controls.AddRange([logo, title, lastChecked, checkButton]);
        return header;
    }

    private Control BuildMessage()
    {
        messagePanel.Dock = DockStyle.Top;
        messagePanel.Height = 44;
        messagePanel.Margin = new Padding(0, 0, 0, 10);
        messagePanel.Padding = new Padding(12, 6, 8, 6);
        messageText.Dock = DockStyle.Fill;
        messageText.TextAlign = ContentAlignment.MiddleLeft;
        messageText.AutoEllipsis = true;
        var dismiss = new Button { Dock = DockStyle.Right, Text = "Dismiss", Width = 80 };
        UpdateCardPanel.StyleButton(dismiss, prominent: false);
        dismiss.Click += (_, _) => updates.DismissMessages();
        messagePanel.Controls.Add(messageText);
        messagePanel.Controls.Add(dismiss);
        return messagePanel;
    }

    private Control BuildNotes()
    {
        var panel = new Panel { Dock = DockStyle.Fill, Padding = new Padding(0, 8, 0, 0) };
        notesTitle.Dock = DockStyle.Top;
        notesTitle.Height = 24;
        notesTitle.Font = EditorTheme.StrongFont;
        notesTitle.ForeColor = EditorTheme.Ink;
        notes.Dock = DockStyle.Fill;
        notes.Multiline = true;
        notes.ReadOnly = true;
        notes.ScrollBars = ScrollBars.Vertical;
        notes.BorderStyle = BorderStyle.None;
        notes.BackColor = EditorTheme.Surface;
        notes.ForeColor = EditorTheme.Ink;
        panel.Controls.Add(notes);
        panel.Controls.Add(notesTitle);
        return panel;
    }

    private Control BuildFooter()
    {
        var footer = new Panel { Dock = DockStyle.Top, Height = 42 };
        releaseLink.AutoSize = true;
        releaseLink.Location = new Point(0, 14);
        releaseLink.Text = "View release on GitHub";
        releaseLink.LinkColor = EditorTheme.ForestText;
        releaseLink.ActiveLinkColor = EditorTheme.Ink;
        releaseLink.VisitedLinkColor = EditorTheme.ForestText;
        releaseLink.LinkClicked += (_, _) =>
        {
            if (updates.Release is { } release)
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(
                    $"https://github.com/{UpdateService.Repository}/releases/tag/v{release.Version}")
                {
                    UseShellExecute = true,
                });
            }
        };
        var done = new Button { Text = "Done", Width = 90, DialogResult = DialogResult.OK };
        UpdateCardPanel.StyleButton(done, prominent: false);
        done.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        done.Location = new Point(footer.Width - done.Width, 6);
        footer.Controls.AddRange([releaseLink, done]);
        AcceptButton = done;
        CancelButton = done;
        return footer;
    }

    private void Render()
    {
        var busy = updates.IsBusy;
        var checking = updates.Activity?.StartsWith("Checking", StringComparison.Ordinal) == true;
        checkButton.Enabled = !busy;
        checkButton.Text = checking ? "Checking..." : "Check now";
        lastChecked.Text = updates.LastChecked is { } checkedAt
            ? $"Last checked {checkedAt.ToLocalTime():g}"
            : checking ? "Checking..." : "Not checked yet";

        var message = updates.Problem ?? updates.Notice;
        messagePanel.Visible = message is not null;
        messagePanel.BackColor = updates.Problem is not null ? EditorTheme.CoralSoft : EditorTheme.GlassChip;
        messageText.ForeColor = updates.Problem is not null ? EditorTheme.Coral : EditorTheme.ForestText;
        messageText.Text = message ?? string.Empty;

        var latest = updates.Release?.Version;
        string VersionLine(string installed) =>
            latest is null ? $"Version {installed}" : $"Version {installed}  ·  Latest {latest}";

        var activity = updates.Activity;
        var firmwareActivity = activity is not null && activity.Contains("M5Paper", StringComparison.Ordinal);
        var appActivity = activity is not null && !checking && !firmwareActivity;

        if (appActivity)
        {
            appCard.Render(VersionLine(UpdateCoordinator.CurrentVersion), UpdateCardState.Working, activity, null);
        }
        else if (updates.AppUpdate is { } appUpdate)
        {
            appCard.Render(VersionLine(UpdateCoordinator.CurrentVersion), UpdateCardState.Available,
                $"Version {appUpdate.Version} is ready to install. paperGIF restarts when it finishes.",
                busy ? null : "Install and restart");
        }
        else
        {
            appCard.Render(VersionLine(UpdateCoordinator.CurrentVersion),
                updates.Release is null ? UpdateCardState.Unknown : UpdateCardState.UpToDate,
                updates.Release is null ? "Not checked yet." : null, null);
        }

        var firmwareDetail = updates.DeviceFirmware is { } firmware ? VersionLine(firmware) : "Firmware version unknown";
        if (firmwareActivity)
        {
            firmwareCard.Render(firmwareDetail, UpdateCardState.Working, activity, null);
        }
        else if (updates.DeviceFirmware is null)
        {
            firmwareCard.Render(firmwareDetail, UpdateCardState.Attention,
                "Not found on the network. Wake the M5Paper, then try again.", busy ? null : "Find M5Paper");
        }
        else if (updates.FirmwareUpdate is { } firmwareUpdate)
        {
            if (updates.FirmwareNeedsUsb)
            {
                firmwareCard.Render(firmwareDetail, UpdateCardState.Attention,
                    $"Too old for Wi-Fi updates. Flash {firmwareUpdate.Version} over USB once; later updates install from here.", null);
            }
            else
            {
                firmwareCard.Render(firmwareDetail, UpdateCardState.Available,
                    $"Firmware {firmwareUpdate.Version} is ready to install over Wi-Fi.", busy ? null : "Update M5Paper");
            }
        }
        else
        {
            firmwareCard.Render(firmwareDetail,
                updates.Release is null ? UpdateCardState.Unknown : UpdateCardState.UpToDate,
                updates.Release is null ? "Not checked yet." : null, null);
        }

        var releaseNotes = updates.Release?.Notes.Trim();
        notesTitle.Visible = notes.Visible = !string.IsNullOrEmpty(releaseNotes);
        notesTitle.Text = latest is null ? string.Empty : $"What's new in {latest}";
        notes.Text = (releaseNotes ?? string.Empty).Replace("\r\n", "\n").Replace("\n", Environment.NewLine);
        releaseLink.Visible = updates.Release is not null;
    }
}

internal enum UpdateCardState
{
    UpToDate,
    Available,
    Working,
    Attention,
    Unknown,
}

internal sealed class UpdateCardPanel : CardPanel
{
    private readonly Label title = new();
    private readonly Label chip = new();
    private readonly Label detail = new();
    private readonly Label status = new();
    private readonly Button action = new();

    public UpdateCardPanel(string titleText, Func<Task> onAction)
    {
        Height = 104;
        Margin = new Padding(0, 0, 0, 10);
        Fill = EditorTheme.Glass;
        title.AutoSize = true;
        title.Font = new Font("Segoe UI Variable Text Semibold", 10.5F);
        title.ForeColor = EditorTheme.Ink;
        title.Location = new Point(16, 14);
        title.Text = titleText;
        chip.AutoSize = true;
        chip.Font = EditorTheme.StrongFont;
        chip.Padding = new Padding(6, 2, 6, 2);
        detail.AutoSize = true;
        detail.ForeColor = EditorTheme.Muted;
        detail.Location = new Point(16, 40);
        status.AutoSize = false;
        status.AutoEllipsis = true;
        status.ForeColor = EditorTheme.Ink;
        status.Location = new Point(16, 64);
        status.Height = 32;
        StyleButton(action, prominent: true);
        action.Width = 150;
        action.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        action.Click += async (_, _) => await onAction();
        Controls.AddRange([title, chip, detail, status, action]);
        Resize += (_, _) => LayoutChildren();
        LayoutChildren();
    }

    public static void StyleButton(Button button, bool prominent)
    {
        EditorTheme.StyleButton(button, prominent);
        button.Height = 32;
    }

    public void Render(string detailText, UpdateCardState state, string? statusText, string? actionText)
    {
        detail.Text = detailText;
        status.Text = statusText ?? string.Empty;
        status.Visible = statusText is not null;
        (chip.Text, chip.ForeColor, chip.BackColor) = state switch
        {
            UpdateCardState.UpToDate => ("Up to date", EditorTheme.ForestText, EditorTheme.GlassChip),
            UpdateCardState.Available => ("Update available", Color.White, EditorTheme.Forest),
            UpdateCardState.Working => ("In progress", EditorTheme.ForestText, EditorTheme.GlassChip),
            UpdateCardState.Attention => ("Needs attention", EditorTheme.Coral, EditorTheme.CoralSoft),
            _ => ("Unknown", EditorTheme.Muted, EditorTheme.GlassButton),
        };
        action.Visible = actionText is not null;
        action.Text = actionText ?? string.Empty;
        LayoutChildren();
    }

    private void LayoutChildren()
    {
        chip.Location = new Point(title.Right + 10, title.Top + 2);
        action.Location = new Point(Width - action.Width - 16, 14);
        status.Width = Math.Max(120, Width - 32);
    }
}
