namespace PaperGIF.Windows.Host;

internal sealed class ApplicationPickerDialog : Form
{
    private readonly IReadOnlyList<RemoteApplication> applications;
    private readonly TextBox search = new();
    private readonly ListBox list = new();

    private ApplicationPickerDialog(IReadOnlyList<RemoteApplication> applications)
    {
        this.applications = applications;
        Text = "Choose Application";
        ClientSize = new Size(520, 560);
        MinimumSize = new Size(420, 420);
        StartPosition = FormStartPosition.CenterParent;
        Font = new Font("Segoe UI", 9F);

        search.Dock = DockStyle.Top;
        search.PlaceholderText = "Search applications";
        search.Margin = new Padding(12);
        search.TextChanged += (_, _) => RefreshList();
        list.Dock = DockStyle.Fill;
        list.BorderStyle = BorderStyle.FixedSingle;
        list.DisplayMember = nameof(RemoteApplication.Name);
        list.DoubleClick += (_, _) => AcceptSelection();
        var controls = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            FlowDirection = FlowDirection.RightToLeft,
            Height = 48,
            Padding = new Padding(8),
        };
        var choose = new Button { Text = "Choose", Width = 80 };
        choose.Click += (_, _) => AcceptSelection();
        var cancel = new Button { Text = "Cancel", Width = 80, DialogResult = DialogResult.Cancel };
        controls.Controls.Add(choose);
        controls.Controls.Add(cancel);
        Controls.Add(list);
        Controls.Add(controls);
        Controls.Add(search);
        CancelButton = cancel;
        RefreshList();
    }

    public RemoteApplication? SelectedApplication { get; private set; }

    public static RemoteApplication? Choose(
        IWin32Window owner,
        IReadOnlyList<RemoteApplication> applications)
    {
        using var dialog = new ApplicationPickerDialog(applications);
        return dialog.ShowDialog(owner) == DialogResult.OK
            ? dialog.SelectedApplication
            : null;
    }

    private void RefreshList()
    {
        var query = search.Text.Trim();
        list.DataSource = null;
        list.DataSource = applications
            .Where(application =>
                query.Length == 0 || application.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase))
            .OrderBy(application => application.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
        list.DisplayMember = nameof(RemoteApplication.Name);
    }

    private void AcceptSelection()
    {
        if (list.SelectedItem is not RemoteApplication application)
        {
            return;
        }
        SelectedApplication = application;
        DialogResult = DialogResult.OK;
        Close();
    }
}