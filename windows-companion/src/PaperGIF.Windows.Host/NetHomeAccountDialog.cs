namespace PaperGIF.Windows.Host;

internal sealed class NetHomeAccountDialog : Form
{
    private readonly TextBox account = new();
    private readonly TextBox password = new();

    public string Account => account.Text.Trim();
    public string Password => password.Text;

    public NetHomeAccountDialog(string? currentAccount)
    {
        Text = "Connect NetHome Plus";
        ClientSize = new Size(390, 180);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterParent;
        Font = new Font("Segoe UI", 9F);
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(16),
            ColumnCount = 2,
            RowCount = 4,
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 80));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        account.Text = currentAccount ?? string.Empty;
        password.UseSystemPasswordChar = true;
        AddField(layout, "Account", account, 0);
        AddField(layout, "Password", password, 1);
        layout.Controls.Add(new Label
        {
            AutoSize = true,
            ForeColor = Color.DimGray,
            Text = "Credentials are encrypted for your Windows account.",
        }, 1, 2);
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft };
        var connect = new Button { Text = "Connect", DialogResult = DialogResult.OK };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel };
        buttons.Controls.Add(connect);
        buttons.Controls.Add(cancel);
        layout.Controls.Add(buttons, 1, 3);
        Controls.Add(layout);
        AcceptButton = connect;
        CancelButton = cancel;
    }

    private static void AddField(TableLayoutPanel layout, string label, Control field, int row)
    {
        layout.Controls.Add(new Label { Text = label, AutoSize = true, Padding = new Padding(0, 5, 0, 0) }, 0, row);
        field.Dock = DockStyle.Fill;
        layout.Controls.Add(field, 1, row);
    }
}