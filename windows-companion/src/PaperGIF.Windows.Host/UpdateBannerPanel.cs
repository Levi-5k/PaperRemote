namespace PaperGIF.Windows.Host;

// Versions and update actions for this PC and the selected M5Paper, shown under the editor toolbar.
internal sealed class UpdateBannerPanel : Panel
{
    private readonly UpdateCoordinator updates;
    private readonly Label headline = new();
    private readonly Label versions = new();
    private readonly Button primaryButton = new();
    private readonly Button dismissButton = new();
    private readonly Button checkButton = new();

    public UpdateBannerPanel(UpdateCoordinator updates)
    {
        this.updates = updates;
        Dock = DockStyle.Top;
        Height = 46;
        Padding = new Padding(16, 4, 14, 4);
        Paint += (_, eventArgs) =>
        {
            using var border = new Pen(EditorTheme.Border);
            eventArgs.Graphics.DrawLine(border, 0, Height - 1, Width, Height - 1);
        };

        headline.AutoSize = false;
        headline.AutoEllipsis = true;
        headline.Dock = DockStyle.Top;
        headline.Height = 19;
        headline.ForeColor = EditorTheme.Ink;
        versions.AutoSize = false;
        versions.AutoEllipsis = true;
        versions.Dock = DockStyle.Top;
        versions.Height = 17;
        versions.ForeColor = EditorTheme.Muted;
        var text = new Panel { Dock = DockStyle.Fill };
        text.Controls.Add(versions);
        text.Controls.Add(headline);

        StyleButton(primaryButton, 150, prominent: true);
        primaryButton.Click += async (_, _) =>
        {
            if (updates.AppUpdate is not null)
            {
                await updates.InstallAppAsync();
            }
            else
            {
                await updates.InstallFirmwareAsync();
            }
        };
        StyleButton(dismissButton, 76, prominent: false);
        dismissButton.Text = "Dismiss";
        dismissButton.Click += (_, _) => updates.DismissMessages();
        StyleButton(checkButton, 76, prominent: false);
        checkButton.Text = "Check";
        checkButton.Click += async (_, _) => await updates.RefreshAsync();
        new ToolTip().SetToolTip(checkButton, "Check for paperGIF and M5Paper firmware updates");
        var actions = new FlowLayoutPanel
        {
            Dock = DockStyle.Right,
            AutoSize = true,
            WrapContents = false,
            FlowDirection = FlowDirection.LeftToRight,
            Controls = { dismissButton, primaryButton, checkButton },
        };

        Controls.Add(text);
        Controls.Add(actions);
        updates.Changed += HandleUpdatesChanged;
        Render();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            updates.Changed -= HandleUpdatesChanged;
        }
        base.Dispose(disposing);
    }

    private void HandleUpdatesChanged(object? sender, EventArgs eventArgs) => Render();

    private static void StyleButton(Button button, int width, bool prominent)
    {
        button.Width = width;
        button.Height = 30;
        button.Margin = new Padding(6, 3, 0, 3);
        button.FlatStyle = FlatStyle.Flat;
        button.UseVisualStyleBackColor = false;
        button.BackColor = prominent ? EditorTheme.Forest : EditorTheme.Surface;
        button.ForeColor = prominent ? Color.White : EditorTheme.Ink;
        button.FlatAppearance.BorderColor = EditorTheme.Border;
        button.FlatAppearance.BorderSize = prominent ? 0 : 1;
    }

    private void Render()
    {
        if (IsDisposed)
        {
            return;
        }
        var highlighted = updates.IsBusy || updates.Problem is not null || updates.Notice is not null ||
            updates.AppUpdate is not null || updates.FirmwareUpdate is not null;
        BackColor = highlighted ? EditorTheme.ForestSoft : EditorTheme.Canvas;
        headline.Font = highlighted ? EditorTheme.StrongFont : EditorTheme.BodyFont;
        headline.Text = Headline();
        var device = updates.DeviceFirmware is { } firmware ? $"M5Paper firmware {firmware}" : "M5Paper not found";
        var latest = updates.Release is { } release ? $"  ·  Latest release {release.Version}" : string.Empty;
        versions.Text = $"paperGIF {UpdateCoordinator.CurrentVersion}  ·  {device}{latest}";

        var idle = !updates.IsBusy;
        dismissButton.Visible = idle && (updates.Problem is not null || updates.Notice is not null);
        checkButton.Visible = idle;
        if (idle && updates.AppUpdate is not null)
        {
            primaryButton.Text = "Install and restart";
            primaryButton.Visible = true;
        }
        else if (idle && updates.FirmwareUpdate is not null && !updates.FirmwareNeedsUsb)
        {
            primaryButton.Text = "Update M5Paper";
            primaryButton.Visible = true;
        }
        else
        {
            primaryButton.Visible = false;
        }
    }

    private string Headline()
    {
        if (updates.Activity is { } activity)
        {
            return activity;
        }
        if (updates.Problem is { } problem)
        {
            return problem;
        }
        if (updates.Notice is { } notice)
        {
            return notice;
        }
        if (updates.AppUpdate is { } appUpdate)
        {
            return $"paperGIF {appUpdate.Version} is available.";
        }
        if (updates.FirmwareUpdate is { } firmwareUpdate)
        {
            return updates.FirmwareNeedsUsb
                ? $"This M5Paper's firmware is too old for Wi-Fi updates. Flash {firmwareUpdate.Version} over USB once."
                : $"M5Paper firmware {firmwareUpdate.Version} is available.";
        }
        if (updates.Release is null)
        {
            return "Updates not checked yet";
        }
        return updates.DeviceFirmware is null ? "paperGIF is up to date" : "Everything is up to date";
    }
}
