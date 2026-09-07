using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Host;

internal sealed class ScheduleEditorDialog : Form
{
    private readonly RemoteAction action;
    private readonly List<RemoteScheduleEntry> schedules;
    private readonly ListBox scheduleList = new();
    private readonly DateTimePicker time = new();
    private readonly CheckedListBox weekdays = new();
    private readonly ComboBox text = new();
    private readonly NumericUpDown value = new();
    private readonly NumericUpDown valueTenths = new();
    private readonly Label textLabel = new();
    private readonly Label valueLabel = new();
    private readonly Label valueTenthsLabel = new();
    private bool refreshing;

    private ScheduleEditorDialog(RemoteAction action)
    {
        this.action = action;
        schedules = (action.Schedules ?? []).Select(Clone).ToList();
        Text = "Schedules";
        ClientSize = new Size(620, 430);
        MinimumSize = new Size(560, 390);
        StartPosition = FormStartPosition.CenterParent;
        Font = new Font("Segoe UI", 9F);

        var split = new SplitContainer { Dock = DockStyle.Fill, SplitterDistance = 205, FixedPanel = FixedPanel.Panel1 };
        scheduleList.Dock = DockStyle.Fill;
        scheduleList.DisplayMember = nameof(RemoteScheduleEntry.Id);
        scheduleList.SelectedIndexChanged += (_, _) => LoadSelection();
        var listButtons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 44, Padding = new Padding(6) };
        var add = new Button { Text = "Add", Width = 70 };
        add.Click += (_, _) => AddSchedule(action);
        var remove = new Button { Text = "Remove", Width = 70 };
        remove.Click += (_, _) => RemoveSchedule();
        listButtons.Controls.Add(add);
        listButtons.Controls.Add(remove);
        split.Panel1.Controls.Add(scheduleList);
        split.Panel1.Controls.Add(listButtons);

        var fields = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(14),
            ColumnCount = 2,
            RowCount = 7,
        };
        fields.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 90));
        fields.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        time.Format = DateTimePickerFormat.Time;
        time.ShowUpDown = true;
        time.ValueChanged += (_, _) => SaveSelection();
        weekdays.Items.AddRange(["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]);
        weekdays.CheckOnClick = true;
        weekdays.Height = 120;
        weekdays.ItemCheck += (_, _) => BeginInvoke(SaveSelection);
        text.DropDownStyle = ComboBoxStyle.DropDownList;
        text.SelectedIndexChanged += (_, _) =>
        {
            ConfigureValueFields();
            SaveSelection();
        };
        value.Minimum = -10_000;
        value.Maximum = 10_000;
        value.ValueChanged += (_, _) => SaveSelection();
        valueTenths.Minimum = -100_000;
        valueTenths.Maximum = 100_000;
        valueTenths.ValueChanged += (_, _) => SaveSelection();
        AddField(fields, "Time", time, 0);
        AddField(fields, "Weekdays", weekdays, 1);
        AddField(fields, textLabel, text, 2);
        AddField(fields, valueLabel, value, 3);
        AddField(fields, valueTenthsLabel, valueTenths, 4);
        var hint = new Label
        {
            AutoSize = true,
            ForeColor = Color.DimGray,
            Text = "Each schedule runs the selected action with the values shown above.",
        };
        fields.Controls.Add(hint, 1, 5);
        var dialogButtons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Fill };
        var save = new Button { Text = "Save", DialogResult = DialogResult.OK };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel };
        dialogButtons.Controls.Add(save);
        dialogButtons.Controls.Add(cancel);
        fields.Controls.Add(dialogButtons, 1, 6);
        split.Panel2.Controls.Add(fields);
        Controls.Add(split);
        AcceptButton = save;
        CancelButton = cancel;

        ConfigureActionFields();
        RefreshList();
        if (schedules.Count > 0)
        {
            scheduleList.SelectedIndex = 0;
        }
    }

    public static bool Edit(IWin32Window owner, RemoteAction action)
    {
        using var dialog = new ScheduleEditorDialog(action);
        if (dialog.ShowDialog(owner) != DialogResult.OK)
        {
            return false;
        }
        dialog.SaveSelection();
        action.Schedules = dialog.schedules.Count == 0 ? null : dialog.schedules;
        action.ScheduleEnabled = dialog.schedules.Count > 0;
        action.ScheduleHour = dialog.schedules.FirstOrDefault()?.Hour;
        action.ScheduleMinute = dialog.schedules.FirstOrDefault()?.Minute;
        return true;
    }

    private void AddSchedule(RemoteAction action)
    {
        if (schedules.Count >= 8)
        {
            return;
        }
        SaveSelection();
        schedules.Add(new RemoteScheduleEntry
        {
            Hour = schedules.LastOrDefault()?.Hour ?? action.ScheduleHour ?? 8,
            Minute = schedules.LastOrDefault()?.Minute ?? action.ScheduleMinute ?? 0,
            Text = action.Text,
            Value = action.Value,
            ValueTenths = action.ValueTenths,
        });
        RefreshList();
        scheduleList.SelectedIndex = schedules.Count - 1;
    }

    private void RemoveSchedule()
    {
        if (scheduleList.SelectedIndex < 0)
        {
            return;
        }
        var index = scheduleList.SelectedIndex;
        schedules.RemoveAt(index);
        RefreshList();
        if (schedules.Count > 0)
        {
            scheduleList.SelectedIndex = Math.Min(index, schedules.Count - 1);
        }
    }

    private void LoadSelection()
    {
        if (scheduleList.SelectedItem is not RemoteScheduleEntry entry)
        {
            return;
        }
        refreshing = true;
        time.Value = DateTime.Today.AddHours(entry.Hour).AddMinutes(entry.Minute);
        for (var index = 0; index < weekdays.Items.Count; index++)
        {
            weekdays.SetItemChecked(index, entry.Weekdays.Contains(index + 1));
        }
        text.Text = entry.Text ?? string.Empty;
        value.Value = Math.Clamp(entry.Value ?? 0, (int)value.Minimum, (int)value.Maximum);
        valueTenths.Value = Math.Clamp(entry.ValueTenths ?? 0, (int)valueTenths.Minimum, (int)valueTenths.Maximum);
        ConfigureValueFields();
        refreshing = false;
    }

    private void SaveSelection()
    {
        if (refreshing || scheduleList.SelectedItem is not RemoteScheduleEntry entry)
        {
            return;
        }
        entry.Hour = time.Value.Hour;
        entry.Minute = time.Value.Minute;
        entry.Weekdays = weekdays.CheckedIndices.Cast<int>().Select(index => index + 1).ToList();
        entry.Text = UsesText(action.Type) && !string.IsNullOrWhiteSpace(text.Text) ? text.Text : null;
        entry.Value = UsesValue(action.Type, text.Text) ? (int)value.Value : null;
        entry.ValueTenths = action.Type == RemoteActionType.NetHomeTemperature
            ? (int)valueTenths.Value : null;
        RefreshList(entry.Id);
    }

    private void ConfigureActionFields()
    {
        var choices = action.Type switch
        {
            RemoteActionType.MacMedia => new[]
            {
                new EditorChoice("previous", "Previous"),
                new EditorChoice("playPause", "Play / Pause"),
                new EditorChoice("next", "Next"),
                new EditorChoice("volumeDown", "Volume Down"),
                new EditorChoice("volume", "Set Volume"),
                new EditorChoice("mute", "Mute"),
                new EditorChoice("volumeUp", "Volume Up"),
            },
            RemoteActionType.WledPower or RemoteActionType.NetHomePower =>
            [new("toggle", "Toggle"), new("on", "On"), new("off", "Off")],
            RemoteActionType.NetHomeMode =>
            [new("auto", "Auto"), new("cool", "Cool"), new("heat", "Heat"), new("dry", "Dry"), new("fan", "Fan")],
            RemoteActionType.NetHomeAuto =>
            [new("cool", "Cooling"), new("heat", "Heating")],
            _ => [],
        };
        textLabel.Text = action.Type == RemoteActionType.MacMedia ? "Command" :
            action.Type is RemoteActionType.WledPower or RemoteActionType.NetHomePower ? "Power" :
            action.Type == RemoteActionType.NetHomeMode ? "Mode" : "Control";
        text.DataSource = choices;
        text.DisplayMember = nameof(EditorChoice.DisplayName);
        text.ValueMember = nameof(EditorChoice.Value);
        text.SelectedValue = action.Text;
        textLabel.Visible = text.Visible = UsesText(action.Type);

        value.DecimalPlaces = 0;
        value.Increment = 1;
        switch (action.Type)
        {
            case RemoteActionType.WledPreset:
                valueLabel.Text = "Preset";
                value.Minimum = 1;
                value.Maximum = 250;
                break;
            case RemoteActionType.WledBrightness:
                valueLabel.Text = "Brightness";
                value.Minimum = 0;
                value.Maximum = 255;
                break;
            case RemoteActionType.NetHomeTemperatureStep:
                valueLabel.Text = "Adjustment";
                value.Minimum = -1;
                value.Maximum = 1;
                break;
            case RemoteActionType.NetHomeFan:
                valueLabel.Text = "Fan percent";
                value.Minimum = 20;
                value.Maximum = 100;
                value.Increment = 20;
                break;
            default:
                valueLabel.Text = "Level (0-255)";
                value.Minimum = 0;
                value.Maximum = 255;
                break;
        }
        valueTenthsLabel.Text = "Setpoint (C x10)";
        valueTenths.Minimum = 160;
        valueTenths.Maximum = 300;
        ConfigureValueFields();
    }

    private void ConfigureValueFields()
    {
        valueLabel.Visible = value.Visible = UsesValue(action.Type, text.Text);
        valueTenthsLabel.Visible = valueTenths.Visible =
            action.Type == RemoteActionType.NetHomeTemperature;
    }

    private static bool UsesText(RemoteActionType type) => type is
        RemoteActionType.MacMedia or RemoteActionType.WledPower or
        RemoteActionType.NetHomePower or RemoteActionType.NetHomeMode or
        RemoteActionType.NetHomeAuto;

    private static bool UsesValue(RemoteActionType type, string command) =>
        type is RemoteActionType.WledPreset or RemoteActionType.WledBrightness or
            RemoteActionType.NetHomeTemperatureStep or RemoteActionType.NetHomeFan ||
        type == RemoteActionType.MacMedia && command == "volume";

    private void RefreshList(Guid? selectedId = null)
    {
        refreshing = true;
        selectedId ??= (scheduleList.SelectedItem as RemoteScheduleEntry)?.Id;
        scheduleList.DataSource = null;
        scheduleList.DataSource = schedules;
        scheduleList.Format += FormatSchedule;
        if (selectedId is not null)
        {
            scheduleList.SelectedItem = schedules.FirstOrDefault(entry => entry.Id == selectedId);
        }
        refreshing = false;
    }

    private static void FormatSchedule(object? sender, ListControlConvertEventArgs eventArgs)
    {
        if (eventArgs.ListItem is RemoteScheduleEntry entry)
        {
            eventArgs.Value = $"{entry.Hour:00}:{entry.Minute:00}  -  {entry.Weekdays.Count} day{(entry.Weekdays.Count == 1 ? "" : "s")}";
        }
    }

    private static void AddField(TableLayoutPanel fields, string label, Control control, int row)
    {
        AddField(fields, new Label { Text = label }, control, row);
    }

    private static void AddField(TableLayoutPanel fields, Label label, Control control, int row)
    {
        label.AutoSize = true;
        label.Padding = new Padding(0, 5, 0, 0);
        fields.Controls.Add(label, 0, row);
        control.Dock = DockStyle.Fill;
        fields.Controls.Add(control, 1, row);
    }

    private static RemoteScheduleEntry Clone(RemoteScheduleEntry entry) => new()
    {
        Id = entry.Id,
        Weekdays = [.. entry.Weekdays],
        Hour = entry.Hour,
        Minute = entry.Minute,
        Text = entry.Text,
        Value = entry.Value,
        ValueTenths = entry.ValueTenths,
    };
}