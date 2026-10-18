using System.Globalization;
using System.Text.Json;
using PaperGIF.Windows.Core;
using PaperGIF.Windows.Core.Ble;
using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Host;

/// <summary>Controls of one identified device over Wi-Fi, falling back to Bluetooth on transport errors.</summary>
internal sealed class DeviceControlSession : IAsyncDisposable
{
    private readonly DeviceControlClient? http;
    private readonly BleDeviceControlTransport? ble;
    private readonly FallbackDeviceControlTransport transport;

    public DeviceControlSession(DeviceDescriptor descriptor, DeviceControlClient? http, BleDeviceControlTransport? ble)
    {
        if (http is null && ble is null) throw new ArgumentException("At least one transport is required.");
        Descriptor = descriptor;
        this.http = http;
        this.ble = ble;
        transport = new FallbackDeviceControlTransport((IDeviceControlTransport?)http ?? ble!, http is null ? null : ble);
        if (ble is not null) ble.SnapshotReceived += ForwardSnapshot;
    }

    public DeviceDescriptor Descriptor { get; }
    public string TransportName => transport.Name;
    /// <summary>True while Bluetooth is in use; BLE pushes on-device changes, so polling only checks for Wi-Fi.</summary>
    public bool IsOnBluetooth => transport.LastUsed is BleDeviceControlTransport;
    public event EventHandler<DeviceControlSnapshot>? SnapshotReceived;

    public Task<DeviceControlSnapshot> GetSnapshotAsync(CancellationToken cancellationToken) =>
        AfterAsync(transport.GetSnapshotAsync(cancellationToken));

    public Task<DeviceControlSnapshot> SetAsync(string id, JsonElement? value, CancellationToken cancellationToken) =>
        AfterAsync(transport.SetAsync(id, value, cancellationToken));

    public async ValueTask DisposeAsync()
    {
        if (ble is null) return;
        ble.SnapshotReceived -= ForwardSnapshot;
        await ble.DisposeAsync();
    }

    private async Task<DeviceControlSnapshot> AfterAsync(Task<DeviceControlSnapshot> operation)
    {
        var snapshot = await operation;
        // Wi-Fi works again: release Bluetooth to save the device's battery and connection slots.
        if (ble is { IsConnected: true } && http is not null && ReferenceEquals(transport.LastUsed, http))
            _ = ble.ReleaseAsync();
        return snapshot;
    }

    private void ForwardSnapshot(object? sender, DeviceControlSnapshot snapshot) => SnapshotReceived?.Invoke(this, snapshot);
}

/// <summary>Auto-generated surface for the descriptor's <c>controls</c>, grouped by <c>group</c>.</summary>
internal sealed class DeviceControlsPanel : Panel
{
    private static readonly TimeSpan WifiPollInterval = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan BluetoothPollInterval = TimeSpan.FromSeconds(15);
    private readonly RemoteEditorStore store;
    private readonly FlowLayoutPanel rows = new()
    {
        Dock = DockStyle.Fill,
        FlowDirection = FlowDirection.TopDown,
        WrapContents = false,
        AutoScroll = true,
        BackColor = EditorTheme.Layer,
    };
    private readonly Label status = new()
    {
        Dock = DockStyle.Fill,
        AutoEllipsis = true,
        TextAlign = ContentAlignment.MiddleLeft,
        ForeColor = EditorTheme.Muted,
        Font = EditorTheme.BodyFont,
    };
    private readonly Button refreshButton = new() { Text = "Refresh", Dock = DockStyle.Right, Width = 92 };
    private readonly System.Windows.Forms.Timer pollTimer = new();
    private readonly Dictionary<string, Action<JsonElement?>> updaters = new(StringComparer.Ordinal);
    private DeviceControlSession? session;
    private CancellationTokenSource lifetime = new();
    private DeviceControlSnapshot snapshot = DeviceControlSnapshot.Empty;
    private string? boundKey;
    private int generation;
    private int pending;
    private bool applying;
    private DateTime lastPoll = DateTime.MinValue;
    private DialPositionControl? dial;

    public DeviceControlsPanel(RemoteEditorStore store)
    {
        this.store = store;
        Dock = DockStyle.Fill;
        BackColor = EditorTheme.Layer;
        EditorTheme.StyleButton(refreshButton);
        refreshButton.Click += (_, _) => _ = LoadSnapshotAsync(manual: true);
        var header = new Panel { Dock = DockStyle.Top, Height = 36, Padding = new Padding(0, 0, 0, 6) };
        header.Controls.Add(status);
        header.Controls.Add(refreshButton);
        Controls.Add(rows);
        Controls.Add(header);
        rows.Resize += (_, _) => ResizeRows();
        pollTimer.Interval = 100;
        pollTimer.Tick += (_, _) => Poll();
        pollTimer.Start();
        VisibleChanged += (_, _) =>
        {
            if (Visible && session is not null) _ = LoadSnapshotAsync(manual: false);
        };
        ShowMessage("Connect to a device that declares controls.", error: false);
    }

    /// <summary>Rebuilds the surface when the selected device, its controls or its address changes.</summary>
    public void Bind()
    {
        var descriptor = store.Descriptor;
        var key = descriptor is null ? null : string.Join('\n', store.DeviceAddress, descriptor.DeviceID,
            JsonSerializer.Serialize(descriptor.Controls, DeviceDescriptor.JsonOptions),
            JsonSerializer.Serialize(descriptor.Capabilities.Transports, DeviceDescriptor.JsonOptions));
        if (key == boundKey) return;
        boundKey = key;
        generation++;
        lifetime.Cancel();
        lifetime.Dispose();
        lifetime = new CancellationTokenSource();
        ReleaseSession();
        snapshot = DeviceControlSnapshot.Empty;
        updaters.Clear();
        dial = null;
        rows.SuspendLayout();
        foreach (Control control in rows.Controls.Cast<Control>().ToArray()) control.Dispose();
        rows.Controls.Clear();
        try
        {
            if (descriptor is null)
            {
                ShowMessage("Connect to a device that declares controls.", error: false);
                return;
            }
            if (descriptor.DeviceControls.Count == 0)
            {
                ShowMessage($"{descriptor.Name} does not declare device controls.", error: false);
                return;
            }
            session = store.CreateDeviceControlSession();
            if (session is null)
            {
                ShowMessage("This device's controls are not reachable from this computer.", error: true);
                return;
            }
            session.SnapshotReceived += HandleLiveSnapshot;
            BuildRows(descriptor.DeviceControls);
        }
        finally
        {
            rows.ResumeLayout();
            ResizeRows();
            refreshButton.Enabled = session is not null;
        }
        _ = LoadSnapshotAsync(manual: true);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            pollTimer.Dispose();
            lifetime.Cancel();
            lifetime.Dispose();
            ReleaseSession();
        }
        base.Dispose(disposing);
    }

    private void ReleaseSession()
    {
        if (session is null) return;
        session.SnapshotReceived -= HandleLiveSnapshot;
        var released = session;
        session = null;
        _ = Task.Run(async () =>
        {
            try { await released.DisposeAsync(); }
            catch (Exception exception) when (exception is not OutOfMemoryException)
            {
                DiagnosticLog.Error("Could not release device controls session", exception);
            }
        });
    }

    private void Poll()
    {
        if (session is null || !Visible || pending > 0) return;
        var interval = session.IsOnBluetooth ? BluetoothPollInterval
            : dial is not null ? TimeSpan.FromMilliseconds(200) : WifiPollInterval;
        if (DateTime.UtcNow - lastPoll < interval) return;
        _ = LoadSnapshotAsync(manual: false);
    }

    private async Task LoadSnapshotAsync(bool manual)
    {
        if (session is not { } current) return;
        var expected = generation;
        lastPoll = DateTime.UtcNow;
        if (manual) ShowMessage("Reading device controls…", error: false);
        pending++;
        try
        {
            var result = await current.GetSnapshotAsync(lifetime.Token);
            if (expected != generation) return;
            ApplySnapshot(result);
            ShowMessage($"Live over {current.TransportName}", error: false);
        }
        catch (OperationCanceledException) { }
        catch (DeviceControlException exception)
        {
            if (expected == generation) ShowMessage(exception.Message, error: true);
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            if (expected == generation) ShowMessage($"Could not read device controls: {exception.Message}", error: true);
        }
        finally
        {
            pending--;
            lastPoll = DateTime.UtcNow;
        }
    }

    private async Task SetAsync(DeviceControl control, JsonElement? requested)
    {
        if (session is not { } current) return;
        var expected = generation;
        JsonElement? value;
        try { value = control.Normalize(requested); }
        catch (DeviceControlException exception)
        {
            ShowMessage(exception.Message, error: true);
            ApplySnapshot(snapshot);
            return;
        }
        ShowMessage(control.Kind == DeviceControl.Action ? $"Running {control.Name}…" : $"Updating {control.Name}…", error: false);
        pending++;
        try
        {
            var result = await current.SetAsync(control.Id, value, lifetime.Token);
            if (expected != generation) return;
            ApplySnapshot(result);
            ShowMessage(control.Kind == DeviceControl.Action
                ? $"{control.Name} sent over {current.TransportName}"
                : $"Live over {current.TransportName}", error: false);
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            if (expected != generation) return;
            ShowMessage($"{control.Name}: {exception.Message}", error: true);
            // Revert the editor to the last value the device reported.
            ApplySnapshot(snapshot);
        }
        finally
        {
            pending--;
            lastPoll = DateTime.UtcNow;
        }
    }

    private void HandleLiveSnapshot(object? sender, DeviceControlSnapshot live)
    {
        if (IsDisposed || !IsHandleCreated) return;
        var expected = generation;
        BeginInvoke(() =>
        {
            if (expected == generation && ReferenceEquals(sender, session)) ApplySnapshot(live);
        });
    }

    private void ApplySnapshot(DeviceControlSnapshot values)
    {
        snapshot = values;
        applying = true;
        try
        {
            dial?.UpdateSnapshot(values);
            foreach (var (id, update) in updaters)
                update(values.Values.TryGetValue(id, out var value) ? value : null);
        }
        finally { applying = false; }
    }

    private void ShowMessage(string text, bool error)
    {
        status.Text = text;
        status.ForeColor = error ? EditorTheme.Coral : EditorTheme.Muted;
    }

    private void BuildRows(IReadOnlyList<DeviceControl> controls)
    {
        if (DialPositionControl.Supports(controls))
        {
            dial = new DialPositionControl();
            dial.LimitChanged += (id, value) =>
            {
                var control = controls.First(item => item.Id == id);
                _ = SetAsync(control, DeviceControlJson.Value(value));
            };
            rows.Controls.Add(dial);
            rows.Controls.Add(new Label
            {
                Text = "Soft stops limit output, not physical rotation. Drag Start/End or enter exact values below; "
                    + "drag End past Start (or enter a negative end stop) to count counterclockwise. "
                    + "Multi-turn starts at zero after reboot. Continuous mode has no stops; revolutions set sensitivity. "
                    + "Output resolution is a percent of the assigned range; binding Step sets final output units.",
                Height = 90, ForeColor = EditorTheme.Muted, Font = EditorTheme.BodyFont,
            });
        }
        var groups = controls.GroupBy(control => control.Group ?? string.Empty).ToList();
        foreach (var group in groups)
        {
            if (group.Key.Length > 0 || groups.Count > 1)
            {
                rows.Controls.Add(new Label
                {
                    Text = group.Key.Length > 0 ? group.Key : "General",
                    Font = EditorTheme.StrongFont,
                    ForeColor = EditorTheme.Ink,
                    AutoSize = false,
                    Height = 30,
                    TextAlign = ContentAlignment.BottomLeft,
                    Margin = new Padding(0, 8, 0, 2),
                });
            }
            foreach (var control in group) rows.Controls.Add(BuildRow(control));
        }
    }

    private void ResizeRows()
    {
        var width = Math.Max(160, rows.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - 4);
        foreach (Control row in rows.Controls) row.Width = width;
    }

    private Control BuildRow(DeviceControl control)
    {
        var row = new TableLayoutPanel
        {
            ColumnCount = 2,
            RowCount = 1,
            Height = 36,
            Margin = new Padding(0, 2, 0, 2),
            BackColor = EditorTheme.Layer,
        };
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 40));
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 60));
        row.Controls.Add(new Label
        {
            Text = control.Name,
            Dock = DockStyle.Fill,
            AutoEllipsis = true,
            TextAlign = ContentAlignment.MiddleLeft,
            ForeColor = EditorTheme.Ink,
            Font = EditorTheme.BodyFont,
        }, 0, 0);
        row.Controls.Add(BuildEditor(control), 1, 0);
        return row;
    }

    private Control BuildEditor(DeviceControl control)
    {
        if (control.IsReadOnly) return BuildReadOnly(control);
        return control.Kind switch
        {
            DeviceControl.Toggle => BuildToggle(control),
            DeviceControl.Range => BuildRange(control),
            DeviceControl.Select => BuildSelect(control),
            _ => BuildAction(control),
        };
    }

    private Control BuildReadOnly(DeviceControl control)
    {
        var label = new Label
        {
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft,
            ForeColor = EditorTheme.ForestText,
            Font = EditorTheme.StrongFont,
            Text = "—",
        };
        updaters[control.Id] = value => label.Text = value is { } present && control.Accepts(present) ? Format(control, present) : "—";
        return label;
    }

    private Control BuildToggle(DeviceControl control)
    {
        var checkBox = new CheckBox { Dock = DockStyle.Fill, Text = string.Empty, ForeColor = EditorTheme.Ink, Enabled = false };
        updaters[control.Id] = value =>
        {
            checkBox.Enabled = value is { } present && control.Accepts(present);
            checkBox.Checked = value is { ValueKind: JsonValueKind.True };
        };
        checkBox.CheckedChanged += (_, _) =>
        {
            if (!applying) _ = SetAsync(control, DeviceControlJson.Value(checkBox.Checked));
        };
        return checkBox;
    }

    private Control BuildRange(DeviceControl control)
    {
        var minimum = control.Minimum!.Value;
        var maximum = control.Maximum!.Value;
        var step = control.Step!.Value;
        var steps = Math.Floor((maximum - minimum) / step + 1e-9);
        var panel = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 1, Margin = Padding.Empty };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 92));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var numeric = new NumericUpDown
        {
            Dock = DockStyle.Fill,
            Minimum = ToDecimal(minimum),
            Maximum = ToDecimal(maximum),
            Increment = Math.Max(ToDecimal(step), 0.000001m),
            DecimalPlaces = DecimalPlaces(step, minimum),
            Enabled = false,
        };
        EditorTheme.StyleInput(numeric);
        // TrackBar positions are whole steps from minimum; very fine ranges use the numeric box only.
        var slider = steps <= 10_000
            ? new TrackBar
            {
                Dock = DockStyle.Fill,
                Minimum = 0,
                Maximum = (int)steps,
                TickStyle = TickStyle.None,
                AutoSize = false,
                Height = 28,
                Enabled = false,
                LargeChange = Math.Max(1, (int)(steps / 10)),
            }
            : null;
        if (slider is not null) panel.Controls.Add(slider, 0, 0);
        panel.Controls.Add(numeric, slider is null ? 0 : 1, 0);
        if (slider is null) panel.SetColumnSpan(numeric, 2);
        if (control.Unit is { } unit)
            panel.Controls.Add(new Label
            {
                Text = unit,
                AutoSize = true,
                Anchor = AnchorStyles.Left,
                ForeColor = EditorTheme.Muted,
                Font = EditorTheme.BodyFont,
            }, 2, 0);

        var debounce = new System.Windows.Forms.Timer { Interval = 350 };
        panel.Disposed += (_, _) => debounce.Dispose();
        var syncing = false;
        void Show(double value)
        {
            syncing = true;
            try
            {
                numeric.Value = Math.Clamp(ToDecimal(value), numeric.Minimum, numeric.Maximum);
                if (slider is not null)
                    slider.Value = (int)Math.Clamp(Math.Round((value - minimum) / step), slider.Minimum, slider.Maximum);
            }
            finally { syncing = false; }
        }
        void Changed(double value)
        {
            if (applying || syncing) return;
            Show(control.Snap(value));
            debounce.Stop();
            debounce.Start();
        }
        debounce.Tick += (_, _) =>
        {
            debounce.Stop();
            _ = SetAsync(control, DeviceControlJson.Value((double)numeric.Value));
        };
        numeric.ValueChanged += (_, _) => Changed((double)numeric.Value);
        if (slider is not null) slider.ValueChanged += (_, _) => Changed(minimum + slider.Value * step);
        updaters[control.Id] = value =>
        {
            var known = value is { } present && control.Accepts(present);
            numeric.Enabled = known;
            if (slider is not null) slider.Enabled = known;
            // Don't overwrite a value the user is still adjusting.
            if (known && !debounce.Enabled) Show(value!.Value.GetDouble());
        };
        return panel;
    }

    private Control BuildSelect(DeviceControl control)
    {
        var options = control.Options!;
        var combo = new ComboBox { Dock = DockStyle.Fill, DropDownStyle = ComboBoxStyle.DropDownList, Enabled = false };
        EditorTheme.StyleInput(combo);
        combo.Items.AddRange(options.Select(option => (object)option.Name).ToArray());
        updaters[control.Id] = value =>
        {
            var index = value is { ValueKind: JsonValueKind.String } text
                ? options.ToList().FindIndex(option => option.Value == text.GetString())
                : -1;
            combo.Enabled = value is not null;
            combo.SelectedIndex = index;
        };
        combo.SelectedIndexChanged += (_, _) =>
        {
            if (!applying && combo.SelectedIndex >= 0)
                _ = SetAsync(control, DeviceControlJson.Value(options[combo.SelectedIndex].Value));
        };
        return combo;
    }

    private Control BuildAction(DeviceControl control)
    {
        var button = new Button { Text = control.Name, Dock = DockStyle.Left, Width = 140 };
        EditorTheme.StyleButton(button, prominent: !control.RequiresConfirmation);
        button.Click += (_, _) =>
        {
            if (control.RequiresConfirmation && MessageBox.Show(FindForm(),
                    $"Run \"{control.Name}\" on {session?.Descriptor.Name ?? "the device"}?",
                    "Confirm device action", MessageBoxButtons.YesNo, MessageBoxIcon.Warning,
                    MessageBoxDefaultButton.Button2) != DialogResult.Yes)
                return;
            _ = SetAsync(control, null);
        };
        return button;
    }

    private static string Format(DeviceControl control, JsonElement value) => control.Kind switch
    {
        DeviceControl.Toggle => value.GetBoolean() ? "On" : "Off",
        DeviceControl.Select => control.Options!.FirstOrDefault(option => option.Value == value.GetString())?.Name
            ?? value.GetString() ?? string.Empty,
        DeviceControl.Range => control.Unit is { } unit
            ? $"{value.GetDouble().ToString("G", CultureInfo.CurrentCulture)} {unit}"
            : value.GetDouble().ToString("G", CultureInfo.CurrentCulture),
        _ => value.ToString(),
    };

    private static decimal ToDecimal(double value) => (decimal)Math.Clamp(value, -1e15, 1e15);

    private static int DecimalPlaces(double step, double minimum)
    {
        static int Places(double value)
        {
            for (var places = 0; places < 6; places++)
                if (Math.Abs(value - Math.Round(value, places)) < 1e-9) return places;
            return 6;
        }
        return Math.Max(Places(step), Places(minimum));
    }
}
