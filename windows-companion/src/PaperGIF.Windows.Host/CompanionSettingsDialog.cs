namespace PaperGIF.Windows.Host;

internal static class CompanionSettingsDialog
{
    public static bool Edit(CompanionConfiguration configuration, out bool portChanged)
    {
        using var form = new Form
        {
            Text = "paperGIF Companion Settings",
            ClientSize = new Size(520, 360),
            FormBorderStyle = FormBorderStyle.FixedDialog,
            MaximizeBox = false,
            MinimizeBox = false,
            StartPosition = FormStartPosition.CenterScreen,
        };
        var layout = new TableLayoutPanel
        {
            ColumnCount = 2,
            RowCount = 4,
            Dock = DockStyle.Fill,
            Padding = new Padding(16),
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 125));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var port = new NumericUpDown
        {
            Minimum = 1,
            Maximum = 65_535,
            Value = configuration.Port,
            Width = 110,
        };
        var scripts = new TextBox
        {
            AcceptsReturn = true,
            Dock = DockStyle.Fill,
            Multiline = true,
            ScrollBars = ScrollBars.Vertical,
            Text = string.Join(Environment.NewLine, configuration.AllowedScripts),
        };
        var explanation = new Label
        {
            AutoSize = true,
            ForeColor = SystemColors.GrayText,
            Padding = new Padding(0, 8, 0, 8),
            Text = "Enter one exact PowerShell script path per line. Port changes restart the companion.",
        };
        var buttons = new FlowLayoutPanel
        {
            AutoSize = true,
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.RightToLeft,
        };
        var save = new Button { Text = "Save", DialogResult = DialogResult.OK };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel };
        buttons.Controls.Add(save);
        buttons.Controls.Add(cancel);

        layout.Controls.Add(new Label { AutoSize = true, Text = "Listener port", Padding = new Padding(0, 5, 0, 0) }, 0, 0);
        layout.Controls.Add(port, 1, 0);
        layout.Controls.Add(new Label { AutoSize = true, Text = "Approved scripts", Padding = new Padding(0, 5, 0, 0) }, 0, 1);
        layout.Controls.Add(scripts, 1, 1);
        layout.Controls.Add(explanation, 1, 2);
        layout.Controls.Add(buttons, 1, 3);
        form.Controls.Add(layout);
        form.AcceptButton = save;
        form.CancelButton = cancel;

        if (form.ShowDialog() != DialogResult.OK)
        {
            portChanged = false;
            return false;
        }

        var previousPort = configuration.Port;
        configuration.Port = (int)port.Value;
        configuration.AllowedScripts = scripts.Lines
            .Select(line => line.Trim())
            .Where(line => line.Length > 0)
            .Distinct(StringComparer.Ordinal)
            .ToList();
        configuration.Save();
        portChanged = configuration.Port != previousPort;
        return true;
    }
}