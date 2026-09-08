using PaperGIF.Windows.Core.Models;
using System.Text.Json;

namespace PaperGIF.Windows.Host;

internal sealed class RemoteEditorWindow : Form
{
    private static readonly Color Ink = EditorTheme.Ink;
    private static readonly Color Muted = EditorTheme.Muted;
    private static readonly Color Canvas = EditorTheme.Canvas;
    private static readonly Color Forest = EditorTheme.Forest;
    private readonly RemoteEditorStore store;
    private readonly CompanionActivity activity;
    private readonly NetworkDiscoveryService discovery;
    private readonly NetHomeService netHomeService;
    private readonly ModuleCatalogService moduleCatalog;
    private readonly PageListBox pagesList = new();
    private readonly TextBox pageName = new();
    private readonly Label pageCount = new();
    private readonly RemotePreviewPanel preview = new();
    private readonly ModernTabControl inspectorTabs = new();
    private readonly CatalogListBox catalogList = new();
    private readonly TextBox catalogSearch = new();
    private readonly FlowLayoutPanel modulesPanel = new();
    private readonly Label moduleStatus = new();
    private readonly PropertyGrid controlProperties = new();
    private readonly ComboBox targetComputer = new();
    private readonly FlowLayoutPanel controlOptions = new();
    private readonly ComboBox mediaCommand = new();
    private readonly ComboBox keyCommand = new();
    private readonly ComboBox actionChoice = new();
    private readonly ComboBox targetPage = new();
    private readonly ComboBox referencedControl = new();
    private readonly ComboBox textComputer = new();
    private readonly Label emptyControlHint = new();
    private readonly TextBox actionHost = new();
    private readonly NumericUpDown actionValue = new();
    private readonly Label actionChoiceLabel = new();
    private readonly Label actionValueLabel = new();
    private readonly CheckBox controlModifier = new() { Text = "Ctrl", AutoSize = true };
    private readonly CheckBox altModifier = new() { Text = "Alt", AutoSize = true };
    private readonly CheckBox shiftModifier = new() { Text = "Shift", AutoSize = true };
    private readonly CheckBox windowsModifier = new() { Text = "Win", AutoSize = true };
    private readonly Control actionComputerRow;
    private readonly Control mediaCommandRow;
    private readonly Control keyCommandRow;
    private readonly Control modifierRow;
    private readonly Control actionHostRow;
    private readonly Control actionChoiceRow;
    private readonly Control actionValueRow;
    private readonly Control targetPageRow;
    private readonly Control referencedControlRow;
    private readonly Control textComputerRow;
    private readonly PropertyGrid profileProperties = new();
    private readonly ListBox computersList = new();
    private readonly ListBox discoveredList = new();
    private readonly ComboBox wifiNetworks = new();
    private readonly TextBox deviceAddress = new();
    private readonly Label syncStatus = new();
    private readonly Button sendButton = new();
    private readonly Label netHomeStatus = new();
    private readonly ComboBox netHomeUnits = new();
    private readonly SplitContainer pageSplit = new();
    private readonly SplitContainer editorSplit = new();
    private bool refreshing;
    private bool allowClose;
    private bool modulesLoaded;
    private string? automaticallyLoadedDevice;

    public RemoteEditorWindow(
        RemoteEditorStore store,
        CompanionActivity activity,
        NetworkDiscoveryService discovery,
        NetHomeService netHomeService,
        ModuleCatalogService moduleCatalog,
        Icon icon)
    {
        this.store = store;
        this.activity = activity;
        this.discovery = discovery;
        this.netHomeService = netHomeService;
        this.moduleCatalog = moduleCatalog;
        actionComputerRow = BuildOptionRow("Action computer", targetComputer);
        mediaCommandRow = BuildOptionRow("Media command", mediaCommand);
        keyCommandRow = BuildOptionRow("Key", keyCommand);
        modifierRow = BuildOptionRow("Modifiers", BuildModifierOptions());
        actionHostRow = BuildOptionRow("Device", actionHost);
        actionChoiceRow = BuildOptionRow(actionChoiceLabel, actionChoice);
        actionValueRow = BuildOptionRow(actionValueLabel, actionValue);
        targetPageRow = BuildOptionRow("Destination page", targetPage);
        referencedControlRow = BuildOptionRow("Value from", referencedControl);
        textComputerRow = BuildOptionRow("Text computer", textComputer);
        Text = "paperGIF Controls";
        Icon = (Icon)icon.Clone();
        ClientSize = new Size(1000, 720);
        MinimumSize = new Size(900, 640);
        BackColor = Canvas;
        Font = EditorTheme.BodyFont;
        StartPosition = FormStartPosition.CenterScreen;

        Controls.Add(BuildWorkspace());
        Controls.Add(BuildSendBar(icon));
        EditorTheme.StyleInput(this);
        store.Changed += HandleStoreChanged;
        store.StatusChanged += HandleStatusChanged;
        discovery.Changed += HandleDiscoveryChanged;
        discovery.Scan();
        RefreshAll();
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

    protected override void OnShown(EventArgs eventArgs)
    {
        base.OnShown(eventArgs);
        pageSplit.SplitterDistance = Math.Clamp(160, pageSplit.Panel1MinSize, pageSplit.Width - 500);
        editorSplit.SplitterDistance = Math.Clamp(
            editorSplit.Width - 440,
            340,
            editorSplit.Width - 300);
        if (!modulesLoaded)
        {
            modulesLoaded = true;
            _ = RefreshModulesAsync();
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            store.Changed -= HandleStoreChanged;
            store.StatusChanged -= HandleStatusChanged;
            discovery.Changed -= HandleDiscoveryChanged;
        }
        base.Dispose(disposing);
    }

    private Control BuildSendBar(Icon icon)
    {
        var bar = new Panel { Dock = DockStyle.Top, Height = 74, BackColor = EditorTheme.Surface };
        bar.Paint += (_, eventArgs) =>
        {
            using var border = new Pen(EditorTheme.Border);
            eventArgs.Graphics.DrawLine(border, 0, bar.Height - 1, bar.Width, bar.Height - 1);
        };
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 5,
            Padding = new Padding(14, 10, 14, 10),
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 300));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 158));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 78));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 128));
        var brand = new Panel { Dock = DockStyle.Fill };
        var logo = new PictureBox
        {
            Image = icon.ToBitmap(),
            Location = new Point(0, 2),
            Size = new Size(40, 40),
            SizeMode = PictureBoxSizeMode.StretchImage,
        };
        var title = new Label
        {
            AutoSize = true,
            Font = new Font("Segoe UI Variable Display Semibold", 12.5F),
            ForeColor = Ink,
            Location = new Point(50, 1),
            Text = "paperGIF Studio",
        };
        var subtitle = new Label
        {
            AutoSize = true,
            ForeColor = Muted,
            Location = new Point(52, 27),
            Text = "M5Paper control workspace",
        };
        brand.Controls.AddRange([logo, title, subtitle]);
        syncStatus.AutoEllipsis = true;
        syncStatus.Dock = DockStyle.Fill;
        syncStatus.ForeColor = Muted;
        syncStatus.TextAlign = ContentAlignment.MiddleRight;
        syncStatus.Margin = new Padding(8, 0, 10, 0);
        deviceAddress.Dock = DockStyle.Fill;
        deviceAddress.Margin = new Padding(4, 7, 8, 7);
        deviceAddress.PlaceholderText = "M5Paper address";
        deviceAddress.Leave += (_, _) => { store.DeviceAddress = deviceAddress.Text; store.Commit(); };
        var loadButton = Button("Reload", async (_, _) => await RunDeviceOperation(store.LoadFromDeviceAsync));
        loadButton.Dock = DockStyle.Fill;
        loadButton.Margin = new Padding(0, 6, 8, 6);
        sendButton.Text = "Send";
        sendButton.BackColor = Forest;
        sendButton.ForeColor = Color.White;
        sendButton.FlatStyle = FlatStyle.Flat;
        sendButton.FlatAppearance.BorderSize = 0;
        sendButton.Dock = DockStyle.Fill;
        sendButton.Margin = new Padding(0, 6, 0, 6);
        sendButton.Font = EditorTheme.StrongFont;
        sendButton.Click += async (_, _) => await RunDeviceOperation(store.SendToDeviceAsync);
        layout.Controls.Add(brand, 0, 0);
        layout.Controls.Add(syncStatus, 1, 0);
        layout.Controls.Add(deviceAddress, 2, 0);
        layout.Controls.Add(loadButton, 3, 0);
        layout.Controls.Add(sendButton, 4, 0);
        bar.Controls.Add(layout);
        return bar;
    }

    private Control BuildWorkspace()
    {
        pageSplit.Dock = DockStyle.Fill;
        pageSplit.FixedPanel = FixedPanel.Panel1;
        pageSplit.SplitterWidth = 1;
        pageSplit.BackColor = EditorTheme.Border;
        pageSplit.Panel1.Controls.Add(BuildPageSidebar());
        editorSplit.Dock = DockStyle.Fill;
        editorSplit.FixedPanel = FixedPanel.Panel2;
        editorSplit.SplitterWidth = 1;
        editorSplit.BackColor = EditorTheme.Border;
        editorSplit.Panel1.Controls.Add(BuildPreview());
        editorSplit.Panel2.Controls.Add(BuildInspector());
        pageSplit.Panel2.Controls.Add(editorSplit);
        return pageSplit;
    }

    private Control BuildPageSidebar()
    {
        var panel = new Panel { Dock = DockStyle.Fill, BackColor = EditorTheme.SurfaceMuted };
        var heading = new Label
        {
            Dock = DockStyle.Top,
            Height = 46,
            Padding = new Padding(14, 16, 0, 0),
            Font = EditorTheme.StrongFont,
            ForeColor = Muted,
            Text = "PAGES",
        };
        var controls = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            Height = 50,
            Padding = new Padding(8, 9, 8, 8),
            WrapContents = false,
            BackColor = EditorTheme.SurfaceMuted,
        };
        controls.Controls.Add(Button("+", (_, _) => store.AddPage(), 34));
        controls.Controls.Add(Button("Delete", (_, _) => store.DeleteSelectedPage(), 58));
        controls.Controls.Add(Button("Up", (_, _) => store.MoveSelectedPage(-1), 42));
        controls.Controls.Add(Button("Down", (_, _) => store.MoveSelectedPage(1), 50));
        pagesList.Dock = DockStyle.Fill;
        pagesList.BackColor = EditorTheme.SurfaceMuted;
        pagesList.Font = EditorTheme.BodyFont;
        pagesList.SelectedIndexChanged += (_, _) =>
        {
            if (refreshing || pagesList.SelectedItem is not RemotePage page)
            {
                return;
            }
            store.SelectedPageId = page.Id;
            store.SelectedControlId = null;
            RefreshAll();
        };
        panel.Controls.Add(pagesList);
        panel.Controls.Add(controls);
        panel.Controls.Add(heading);
        return panel;
    }

    private Control BuildPreview()
    {
        var panel = new Panel { Dock = DockStyle.Fill, BackColor = Canvas };
        var header = new Panel { Dock = DockStyle.Top, Height = 64, Padding = new Padding(18, 14, 18, 10), BackColor = Canvas };
        var headerLayout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            Margin = Padding.Empty,
        };
        headerLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        headerLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 92));
        pageName.BorderStyle = BorderStyle.FixedSingle;
        pageName.Font = new Font("Segoe UI Variable Display Semibold", 11F);
        pageName.Dock = DockStyle.Fill;
        pageName.Margin = new Padding(0, 0, 12, 0);
        pageName.Leave += (_, _) =>
        {
            if (!refreshing && store.SelectedPage is { } page && !string.IsNullOrWhiteSpace(pageName.Text))
            {
                page.Name = pageName.Text.Trim();
                store.Commit();
            }
        };
        pageCount.Dock = DockStyle.Fill;
        pageCount.ForeColor = Muted;
        pageCount.TextAlign = ContentAlignment.MiddleRight;
        headerLayout.Controls.Add(pageName, 0, 0);
        headerLayout.Controls.Add(pageCount, 1, 0);
        header.Controls.Add(headerLayout);
        preview.Dock = DockStyle.Fill;
        preview.ControlSelected += (_, id) =>
        {
            store.SelectedControlId = id;
            inspectorTabs.SelectedIndex = 1;
            RefreshAll();
        };
        preview.ControlMoved += (_, move) => store.MoveControlToSlot(move.ControlId, move.Slot);
        panel.Controls.Add(preview);
        panel.Controls.Add(header);
        return panel;
    }

    private Control BuildInspector()
    {
        inspectorTabs.Dock = DockStyle.Fill;
        inspectorTabs.Padding = new Point(14, 7);
        inspectorTabs.TabPages.Add(BuildCatalogTab());
        inspectorTabs.TabPages.Add(BuildControlTab());
        inspectorTabs.TabPages.Add(BuildModulesTab());
        inspectorTabs.TabPages.Add(BuildConnectionsTab());
        inspectorTabs.SelectedIndexChanged += (_, _) =>
        {
            if (inspectorTabs.SelectedIndex == 0)
            {
                RefreshCatalog();
            }
            else if (inspectorTabs.SelectedTab?.Text == "Modules" && moduleCatalog.AvailableModules.Count == 0)
            {
                _ = RefreshModulesAsync();
            }
        };
        RefreshCatalog();
        return inspectorTabs;
    }

    private TabPage BuildCatalogTab()
    {
        var tab = new TabPage("Add Controls") { BackColor = EditorTheme.SurfaceMuted, Padding = new Padding(12) };
        var searchPanel = new Panel { Dock = DockStyle.Top, Height = 46, Padding = new Padding(0, 4, 0, 10) };
        catalogSearch.Dock = DockStyle.Fill;
        catalogSearch.PlaceholderText = "Search controls";
        catalogSearch.TextChanged += (_, _) => RefreshCatalog();
        searchPanel.Controls.Add(catalogSearch);
        catalogList.Dock = DockStyle.Fill;
        catalogList.BackColor = EditorTheme.SurfaceMuted;
        catalogList.DoubleClick += (_, _) => AddSelectedTemplate();
        var addButton = Button("Add selected control", (_, _) => AddSelectedTemplate());
        addButton.Dock = DockStyle.Bottom;
        addButton.Height = 40;
        addButton.BackColor = EditorTheme.Forest;
        addButton.ForeColor = Color.White;
        addButton.FlatAppearance.BorderSize = 0;
        addButton.Font = EditorTheme.StrongFont;
        tab.Controls.Add(catalogList);
        tab.Controls.Add(addButton);
        tab.Controls.Add(searchPanel);
        return tab;
    }

    private TabPage BuildModulesTab()
    {
        var tab = new TabPage("Modules") { BackColor = EditorTheme.SurfaceMuted, Padding = new Padding(12) };
        var header = new Panel { Dock = DockStyle.Top, Height = 68 };
        var title = new Label
        {
            AutoSize = true,
            Font = new Font("Segoe UI Variable Display Semibold", 11F),
            ForeColor = EditorTheme.Ink,
            Location = new Point(0, 3),
            Text = "GitHub modules",
        };
        moduleStatus.AutoEllipsis = true;
        moduleStatus.ForeColor = EditorTheme.Muted;
        moduleStatus.Location = new Point(0, 29);
        moduleStatus.Size = new Size(260, 31);
        moduleStatus.Text = "Loading the module catalog...";
        var refresh = Button("Refresh", async (_, _) => await RefreshModulesAsync(), 76);
        refresh.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        refresh.Location = new Point(324, 8);
        header.Resize += (_, _) => refresh.Left = Math.Max(0, header.ClientSize.Width - refresh.Width);
        header.Controls.AddRange([title, moduleStatus, refresh]);

        modulesPanel.Dock = DockStyle.Fill;
        modulesPanel.AutoScroll = true;
        modulesPanel.FlowDirection = FlowDirection.TopDown;
        modulesPanel.WrapContents = false;
        modulesPanel.Padding = new Padding(0, 4, 0, 4);
        modulesPanel.Resize += (_, _) => ResizeModuleCards();
        tab.Controls.Add(modulesPanel);
        tab.Controls.Add(header);
        return tab;
    }

    private async Task RefreshModulesAsync()
    {
        moduleStatus.Text = "Loading the module catalog...";
        try
        {
            await moduleCatalog.RefreshAsync();
            moduleStatus.Text = $"{moduleCatalog.AvailableModules.Count} module(s) available";
            RenderModules();
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or JsonException or InvalidDataException)
        {
            moduleStatus.Text = $"Catalog unavailable: {exception.Message}";
            RenderModules();
        }
    }

    private void RenderModules()
    {
        modulesPanel.SuspendLayout();
        modulesPanel.Controls.Clear();
        foreach (var module in moduleCatalog.AvailableModules)
        {
            modulesPanel.Controls.Add(BuildModuleCard(module));
        }
        if (moduleCatalog.AvailableModules.Count == 0)
        {
            modulesPanel.Controls.Add(new Label
            {
                AutoSize = false,
                ForeColor = EditorTheme.Muted,
                Size = new Size(330, 70),
                Text = moduleCatalog.InstalledModules.Count == 0
                    ? "No modules are currently available."
                    : "Installed module controls remain available in Add Controls.",
                TextAlign = ContentAlignment.MiddleCenter,
            });
        }
        ResizeModuleCards();
        modulesPanel.ResumeLayout();
    }

    private Control BuildModuleCard(PaperModuleListing module)
    {
        var installed = moduleCatalog.IsInstalled(module.Id, module.Version);
        var pageTemplate = installed
            ? moduleCatalog.GetInstalled(module.Id)?.Pages.FirstOrDefault()
            : null;
        var card = new Panel
        {
            Height = pageTemplate is null ? 112 : 150,
            Margin = new Padding(0, 0, 0, 9),
            BackColor = EditorTheme.Surface,
            Tag = "module-card",
        };
        card.Paint += (_, eventArgs) =>
        {
            using var border = new Pen(EditorTheme.Border);
            EditorTheme.DrawRoundedRectangle(eventArgs.Graphics, border, new Rectangle(0, 0, card.Width - 1, card.Height - 1), 6);
        };
        var name = new Label
        {
            AutoEllipsis = true,
            Font = EditorTheme.StrongFont,
            ForeColor = EditorTheme.Ink,
            Location = new Point(14, 12),
            Size = new Size(240, 21),
            Text = module.Name,
        };
        var details = new Label
        {
            AutoEllipsis = true,
            ForeColor = EditorTheme.Muted,
            Location = new Point(14, 35),
            Size = new Size(340, 36),
            Text = module.Summary,
        };
        var metadata = new Label
        {
            AutoSize = true,
            ForeColor = EditorTheme.Muted,
            Location = new Point(14, 82),
            Text = $"v{module.Version}  ·  {module.Author}",
        };
        var action = Button(installed ? "Installed" : "Install", async (_, _) =>
        {
            await InstallModuleAsync(module);
        }, installed ? 88 : 76);
        action.Enabled = !installed;
        action.Anchor = AnchorStyles.Right | AnchorStyles.Bottom;
        action.Location = new Point(220, pageTemplate is null ? 74 : 112);
        Button? addPage = null;
        if (pageTemplate is not null)
        {
            addPage = Button("Add Page", (_, _) =>
            {
                store.AddPage(ModuleCatalogService.ClonePage(pageTemplate, module.Id));
                moduleStatus.Text = $"Added {pageTemplate.Page.Name}.";
            }, 92);
            addPage.Anchor = AnchorStyles.Left | AnchorStyles.Bottom;
            addPage.Location = new Point(14, 112);
            addPage.Enabled = store.Profile.Pages.Count < 8;
        }
        card.Resize += (_, _) =>
        {
            name.Width = Math.Max(100, card.ClientSize.Width - 28);
            details.Width = Math.Max(100, card.ClientSize.Width - 28);
            action.Left = Math.Max(14, card.ClientSize.Width - action.Width - 14);
        };
        card.Controls.AddRange([name, details, metadata, action]);
        if (addPage is not null)
        {
            card.Controls.Add(addPage);
        }
        return card;
    }

    private async Task InstallModuleAsync(PaperModuleListing listing)
    {
        moduleStatus.Text = $"Installing {listing.Name}...";
        try
        {
            var module = await moduleCatalog.InstallAsync(listing);
            moduleStatus.Text = module.Pages.Count > 0
                ? $"Installed {module.Name}. Add its page here or use individual controls."
                : $"Installed {module.Name}. Its controls are now in Add Controls.";
            RefreshCatalog();
            RenderModules();
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or JsonException or IOException)
        {
            moduleStatus.Text = $"Install failed: {exception.Message}";
        }
    }

    private void ResizeModuleCards()
    {
        var width = Math.Max(280, modulesPanel.ClientSize.Width - 22);
        foreach (Control control in modulesPanel.Controls)
        {
            control.Width = width;
        }
    }

    private TabPage BuildControlTab()
    {
        var tab = new TabPage("Control") { BackColor = EditorTheme.Surface, Padding = new Padding(10) };
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 3,
        };
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var toolbar = new FlowLayoutPanel
        {
            AutoSize = true,
            Dock = DockStyle.Fill,
            WrapContents = true,
        };
        toolbar.Controls.Add(Button("Up", (_, _) => store.MoveSelectedControl(-1), 46));
        toolbar.Controls.Add(Button("Down", (_, _) => store.MoveSelectedControl(1), 52));
        toolbar.Controls.Add(Button("Duplicate", (_, _) => store.DuplicateSelectedControl(), 72));
        toolbar.Controls.Add(Button("Delete", (_, _) => store.DeleteSelectedControl(), 58));
        toolbar.Controls.Add(Button("Choose app", async (_, _) => await ChooseApplicationAsync(), 82));
        toolbar.Controls.Add(Button("Schedules", (_, _) => EditSchedules(), 76));
        targetComputer.Width = 130;
        targetComputer.DropDownStyle = ComboBoxStyle.DropDownList;
        targetComputer.DisplayMember = nameof(ComputerChoice.DisplayName);
        targetComputer.SelectedIndexChanged += (_, _) =>
        {
            if (!refreshing && targetComputer.SelectedItem is ComputerChoice choice && store.SelectedControl is { } control)
            {
                control.Action.ComputerID = choice.ComputerId?.ToString();
                store.Commit();
            }
        };
        ConfigureControlOption(mediaCommand, choice =>
        {
            if (store.SelectedControl is { } control)
            {
                control.Action.Text = choice.Value ?? string.Empty;
            }
        });
        keyCommand.DropDownStyle = ComboBoxStyle.DropDown;
        keyCommand.Items.AddRange([
            "return", "tab", "space", "delete", "forwardDelete", "escape",
            "left", "right", "up", "down", "home", "end", "pageUp", "pageDown",
            .. Enumerable.Range(1, 20).Select(number => $"f{number}").ToArray(),
        ]);
        keyCommand.Width = 210;
        keyCommand.SelectionChangeCommitted += (_, _) => SaveKeyCommand();
        keyCommand.Leave += (_, _) => SaveKeyCommand();
        ConfigureControlOption(actionChoice, choice =>
        {
            if (store.SelectedControl is { } control)
            {
                control.Action.Text = choice.Value ?? string.Empty;
            }
        });
        actionHost.Width = 210;
        actionHost.Leave += (_, _) =>
        {
            if (!refreshing && store.SelectedControl is { } control)
            {
                control.Action.Host = actionHost.Text.Trim();
                store.Commit();
            }
        };
        actionValue.Width = 110;
        actionValue.ValueChanged += (_, _) => SaveActionValue();
        ConfigureControlOption(targetPage, choice =>
        {
            if (store.SelectedControl is { } control)
            {
                control.Action.Text = choice.Value ?? string.Empty;
            }
        });
        ConfigureControlOption(referencedControl, choice =>
        {
            if (store.SelectedControl?.TextBox is { } textBox)
            {
                textBox.ReferencedControlID = Guid.TryParse(choice.Value, out var id) ? id : null;
            }
        });
        ConfigureControlOption(textComputer, choice =>
        {
            if (store.SelectedControl?.TextBox is { } textBox)
            {
                textBox.ComputerID = Guid.TryParse(choice.Value, out var id) ? id : null;
            }
        });
        controlOptions.Dock = DockStyle.Top;
        controlOptions.AutoSize = true;
        controlOptions.FlowDirection = FlowDirection.TopDown;
        controlOptions.WrapContents = false;
        controlOptions.Padding = new Padding(0, 4, 0, 5);
        controlOptions.Controls.AddRange([
            actionComputerRow,
            mediaCommandRow,
            keyCommandRow,
            modifierRow,
            actionHostRow,
            actionChoiceRow,
            actionValueRow,
            targetPageRow,
            referencedControlRow,
            textComputerRow,
        ]);
        controlProperties.Dock = DockStyle.Fill;
        controlProperties.HelpVisible = true;
        controlProperties.ToolbarVisible = false;
        controlProperties.PropertySort = PropertySort.Categorized;
        controlProperties.ViewBackColor = EditorTheme.Surface;
        controlProperties.ViewForeColor = EditorTheme.Ink;
        controlProperties.CategoryForeColor = EditorTheme.Forest;
        controlProperties.HelpBackColor = EditorTheme.SurfaceMuted;
        controlProperties.HelpForeColor = EditorTheme.Muted;
        controlProperties.LineColor = EditorTheme.Border;
        emptyControlHint.Dock = DockStyle.Fill;
        emptyControlHint.ForeColor = Muted;
        emptyControlHint.Text = "Select a control in the preview to edit it.";
        emptyControlHint.TextAlign = ContentAlignment.MiddleCenter;
        var propertyPanel = new Panel { Dock = DockStyle.Fill };
        propertyPanel.Controls.Add(controlProperties);
        propertyPanel.Controls.Add(emptyControlHint);
        layout.Controls.Add(toolbar, 0, 0);
        layout.Controls.Add(controlOptions, 0, 1);
        layout.Controls.Add(propertyPanel, 0, 2);
        tab.Controls.Add(layout);
        return tab;
    }

    private TabPage BuildConnectionsTab()
    {
        var tab = new TabPage("Connections") { BackColor = EditorTheme.Surface, Padding = new Padding(10) };
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 11, ColumnCount = 1 };
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 40));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 20));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 20));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        profileProperties.Dock = DockStyle.Fill;
        profileProperties.ToolbarVisible = false;
        profileProperties.HelpVisible = true;
        var wifiControls = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, WrapContents = false };
        wifiNetworks.Width = 230;
        wifiNetworks.DropDownStyle = ComboBoxStyle.DropDownList;
        wifiNetworks.DisplayMember = nameof(DeviceWifiNetwork.DisplayName);
        wifiNetworks.SelectedIndexChanged += (_, _) =>
        {
            if (!refreshing && wifiNetworks.SelectedItem is DeviceWifiNetwork network)
            {
                store.Profile.WifiSSID = network.Ssid;
                if (!network.Secure)
                {
                    store.Profile.WifiPassword = string.Empty;
                }
                store.Commit();
            }
        };
        wifiControls.Controls.Add(Button("Scan Wi-Fi", async (_, _) => await store.ScanWifiNetworksAsync(), 82));
        wifiControls.Controls.Add(wifiNetworks);
        computersList.Dock = DockStyle.Fill;
        computersList.DisplayMember = nameof(RemoteComputer.Name);
        var computerButtons = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill };
        computerButtons.Controls.Add(Button("Add", (_, _) => AddComputer(), 48));
        computerButtons.Controls.Add(Button("Edit", (_, _) => EditComputer(), 48));
        computerButtons.Controls.Add(Button("Remove", (_, _) => RemoveComputer(), 62));
        computerButtons.Controls.Add(Button("Test", async (_, _) => await TestComputerAsync(), 48));
        var discoveryButtons = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill };
        discoveryButtons.Controls.Add(Button("Scan", (_, _) => discovery.Scan(), 52));
        discoveryButtons.Controls.Add(Button("Use selected", async (_, _) => await UseDiscoveredAsync(), 92));
        discoveredList.Dock = DockStyle.Fill;
        discoveredList.DisplayMember = nameof(DiscoveredEndpoint.DisplayName);
        var wledButton = Button("Add WLED page", (_, _) => AddWledPage(), 110);
        var netHomeControls = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill };
        netHomeStatus.AutoSize = true;
        netHomeStatus.Padding = new Padding(2, 7, 4, 0);
        netHomeUnits.Width = 130;
        netHomeUnits.DropDownStyle = ComboBoxStyle.DropDownList;
        netHomeUnits.DisplayMember = nameof(NetHomeUnit.Name);
        netHomeUnits.SelectedIndexChanged += (_, _) =>
        {
            if (!refreshing &&
                netHomeUnits.SelectedItem is NetHomeUnit unit &&
                store.SelectedControl is { } selectedControl &&
                IsNetHomeAction(selectedControl.Action.Type))
            {
                selectedControl.Action.Host = unit.Name;
                store.Commit();
            }
        };
        netHomeControls.Controls.Add(netHomeStatus);
        netHomeControls.Controls.Add(Button("Sign in", async (_, _) => await ConnectNetHomeAsync(), 58));
        netHomeControls.Controls.Add(Button("Refresh", async (_, _) => await RefreshNetHomeUnitsAsync(), 62));
        netHomeControls.Controls.Add(Button("Sign out", (_, _) => SignOutNetHome(), 64));
        netHomeControls.Controls.Add(netHomeUnits);
        netHomeControls.Controls.Add(Button("Add thermostat", (_, _) => AddNetHomePage(), 102));
        var startupHint = new Label
        {
            AutoSize = true,
            ForeColor = Muted,
            Padding = new Padding(2, 8, 0, 0),
            Text = "Computer pairing and discovery use the same companion API as macOS.",
        };
        layout.Controls.Add(wifiControls, 0, 0);
        layout.Controls.Add(profileProperties, 0, 1);
        layout.Controls.Add(new Label { AutoSize = true, Text = "Computers", Font = new Font("Segoe UI Semibold", 9F), Padding = new Padding(2, 8, 0, 4) }, 0, 2);
        layout.Controls.Add(computersList, 0, 3);
        layout.Controls.Add(computerButtons, 0, 4);
        layout.Controls.Add(new Label { AutoSize = true, Text = "Discovered", Font = new Font("Segoe UI Semibold", 9F), Padding = new Padding(2, 8, 0, 4) }, 0, 5);
        layout.Controls.Add(discoveredList, 0, 6);
        layout.Controls.Add(discoveryButtons, 0, 7);
        layout.Controls.Add(new FlowLayoutPanel { AutoSize = true, Controls = { wledButton, startupHint } }, 0, 8);
        layout.Controls.Add(new Label { AutoSize = true, Text = "NetHome Plus", Font = new Font("Segoe UI Semibold", 9F), Padding = new Padding(2, 8, 0, 2) }, 0, 9);
        layout.Controls.Add(netHomeControls, 0, 10);
        tab.Controls.Add(layout);
        return tab;
    }

    private void RefreshAll()
    {
        if (InvokeRequired)
        {
            BeginInvoke(RefreshAll);
            return;
        }
        refreshing = true;
        var selectedPageId = store.SelectedPageId;
        pagesList.DataSource = null;
        pagesList.DataSource = store.Profile.Pages;
        pagesList.DisplayMember = nameof(RemotePage.Name);
        pagesList.SelectedItem = store.Profile.Pages.FirstOrDefault(page => page.Id == selectedPageId);
        pageName.Text = store.SelectedPage?.Name ?? string.Empty;
        pageCount.Text = store.SelectedPage is { } page ? $"{page.Controls.Count} / 16" : string.Empty;
        preview.Page = store.SelectedPage;
        preview.PageIndex = Math.Max(0, store.Profile.Pages.FindIndex(page => page.Id == store.SelectedPageId));
        preview.PageCount = store.Profile.Pages.Count;
        preview.SelectedControlId = store.SelectedControlId;
        var selectedControl = store.SelectedControl;
        controlProperties.SelectedObject = selectedControl is { } control && store.SelectedPage is { } selectedPage
            ? new ControlProperties(control, selectedPage, store)
            : null;
        controlProperties.Visible = selectedControl is not null;
        emptyControlHint.Visible = selectedControl is null;
        var computerChoices = new List<ComputerChoice> { new(null, "Default computer") };
        computerChoices.AddRange(store.Profile.Computers.Select(computer => new ComputerChoice(computer.Id, computer.Name)));
        targetComputer.DataSource = null;
        targetComputer.DataSource = computerChoices;
        targetComputer.DisplayMember = nameof(ComputerChoice.DisplayName);
        var selectedComputerId = Guid.TryParse(store.SelectedControl?.Action.ComputerID, out var parsedComputerId)
            ? parsedComputerId
            : (Guid?)null;
        targetComputer.SelectedItem = computerChoices.First(choice => choice.ComputerId == selectedComputerId);
        RefreshControlOptions();
        profileProperties.SelectedObject = new ProfileProperties(store);
        var selectedComputer = computersList.SelectedItem as RemoteComputer;
        computersList.DataSource = null;
        computersList.DataSource = store.Profile.Computers;
        computersList.DisplayMember = nameof(RemoteComputer.Name);
        if (selectedComputer is not null)
        {
            computersList.SelectedItem = store.Profile.Computers.FirstOrDefault(item => item.Id == selectedComputer.Id);
        }
        var selectedEndpoint = discoveredList.SelectedItem as DiscoveredEndpoint;
        discoveredList.DataSource = null;
        discoveredList.DataSource = discovery.Endpoints;
        discoveredList.DisplayMember = nameof(DiscoveredEndpoint.DisplayName);
        if (selectedEndpoint is not null)
        {
            discoveredList.SelectedItem = discovery.Endpoints.FirstOrDefault(endpoint => endpoint == selectedEndpoint);
        }
        var selectedNetwork = wifiNetworks.SelectedItem as DeviceWifiNetwork;
        wifiNetworks.DataSource = null;
        wifiNetworks.DataSource = store.WifiNetworks;
        wifiNetworks.DisplayMember = nameof(DeviceWifiNetwork.DisplayName);
        wifiNetworks.SelectedItem = store.WifiNetworks.FirstOrDefault(network =>
            network.Ssid == (selectedNetwork?.Ssid ?? store.Profile.WifiSSID));
        deviceAddress.Text = store.DeviceAddress;
        syncStatus.Text = store.ValidationMessage ?? store.Status;
        netHomeStatus.Text = netHomeService.IsSignedIn ? $"Connected: {netHomeService.Account}" : "Not connected";
        sendButton.Enabled = !store.IsBusy && store.ValidationMessage is null;
        refreshing = false;
        preview.Invalidate();
    }

    private void RefreshControlOptions()
    {
        var control = store.SelectedControl;
        var showActionComputer = control is not null && IsComputerAction(control.Action.Type);
        var showMediaCommand = control?.Action.Type == RemoteActionType.MacMedia;
        var showKeyCommand = control?.Action.Type == RemoteActionType.MacKey;
        var showActionHost = control is not null && IsDeviceAction(control.Action.Type);
        var showActionChoice = control?.Action.Type is RemoteActionType.WledPower or
            RemoteActionType.NetHomePower or RemoteActionType.NetHomeMode or RemoteActionType.NetHomeAuto or
            RemoteActionType.OpenBuilds;
        var showActionValue = control is not null && UsesActionValue(control.Action);
        var showTargetPage = control?.Action.Type == RemoteActionType.Page;
        var showReferencedControl = control?.Kind == RemoteControlKind.TextBox &&
            control.TextBox?.Source == RemoteTextSource.ControlValue;
        var showTextComputer = control?.Kind == RemoteControlKind.TextBox &&
            control.TextBox?.Source is RemoteTextSource.MacScript or
                RemoteTextSource.MacShortcut or RemoteTextSource.NowPlaying;
        actionComputerRow.Visible = showActionComputer;
        mediaCommandRow.Visible = showMediaCommand;
        keyCommandRow.Visible = modifierRow.Visible = showKeyCommand;
        actionHostRow.Visible = showActionHost;
        actionChoiceRow.Visible = showActionChoice;
        actionValueRow.Visible = showActionValue;
        targetPageRow.Visible = showTargetPage;
        referencedControlRow.Visible = showReferencedControl;
        textComputerRow.Visible = showTextComputer;
        controlOptions.Visible = showActionComputer || showMediaCommand || showKeyCommand ||
            showActionHost || showActionChoice || showActionValue || showTargetPage ||
            showReferencedControl || showTextComputer;

        SetControlOptions(mediaCommand,
        [
            new("previous", "Previous"),
            new("playPause", "Play / Pause"),
            new("next", "Next"),
            new("volumeDown", "Volume Down"),
            new("volume", "Set Volume"),
            new("mute", "Mute"),
            new("volumeUp", "Volume Up"),
        ], control?.Action.Text);
        keyCommand.Text = control?.Action.Text ?? string.Empty;
        controlModifier.Checked = control?.Action.Modifiers.Contains("control", StringComparer.OrdinalIgnoreCase) == true;
        altModifier.Checked = control?.Action.Modifiers.Any(value =>
            value.Equals("option", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("alt", StringComparison.OrdinalIgnoreCase)) == true;
        shiftModifier.Checked = control?.Action.Modifiers.Contains("shift", StringComparer.OrdinalIgnoreCase) == true;
        windowsModifier.Checked = control?.Action.Modifiers.Any(value =>
            value.Equals("command", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("windows", StringComparison.OrdinalIgnoreCase)) == true;
        actionHost.Text = control?.Action.Host ?? string.Empty;
        var actionChoices = control?.Action.Type switch
        {
            RemoteActionType.WledPower or RemoteActionType.NetHomePower =>
                new[] { new EditorChoice("toggle", "Toggle"), new("on", "On"), new("off", "Off") },
            RemoteActionType.NetHomeMode =>
                [new("auto", "Auto"), new("cool", "Cool"), new("heat", "Heat"), new("dry", "Dry"), new("fan", "Fan")],
            RemoteActionType.NetHomeAuto => [new("cool", "Cooling"), new("heat", "Heating")],
            RemoteActionType.OpenBuilds =>
            [
                new("jogXNegative", "Jog X -"), new("jogXPositive", "Jog X +"),
                new("jogYNegative", "Jog Y -"), new("jogYPositive", "Jog Y +"),
                new("jogZNegative", "Jog Z -"), new("jogZPositive", "Jog Z +"),
                new("jogXNegativeYNegative", "Jog X-/Y-"),
                new("jogXNegativeYPositive", "Jog X-/Y+"),
                new("jogXPositiveYNegative", "Jog X+/Y-"),
                new("jogXPositiveYPositive", "Jog X+/Y+"),
                new("pause", "Pause job"), new("resume", "Resume job"),
                new("stop", "Stop job"), new("abort", "Abort / reset"),
                new("unlock", "Unlock alarm"), new("home", "Home machine"),
            ],
            _ => [],
        };
        actionChoiceLabel.Text = control?.Action.Type == RemoteActionType.NetHomeMode ? "Mode" :
            control?.Action.Type == RemoteActionType.NetHomeAuto ? "Control" :
            control?.Action.Type == RemoteActionType.OpenBuilds ? "Command" : "Power";
        SetControlOptions(actionChoice, actionChoices, control?.Action.Text);
        ConfigureActionValue(control);
        SetControlOptions(targetPage,
            [new(null, "Choose a page"), .. store.Profile.Pages.Select(page =>
                new EditorChoice(page.Id.ToString(), page.Name))],
            control?.Action.Text);
        SetControlOptions(referencedControl,
            [new(null, "Choose a control"), .. (store.SelectedPage?.Controls ?? [])
                .Where(candidate => candidate.Id != control?.Id)
                .Select(candidate => new EditorChoice(
                    candidate.Id.ToString(),
                    string.IsNullOrWhiteSpace(candidate.Title) ? "Untitled control" : candidate.Title))],
            control?.TextBox?.ReferencedControlID?.ToString());
        SetControlOptions(textComputer,
            [new(null, "Default computer"), .. store.Profile.Computers.Select(computer =>
                new EditorChoice(computer.Id.ToString(), computer.Name))],
            control?.TextBox?.ComputerID?.ToString());
    }

    private void ConfigureActionValue(RemoteControl? control)
    {
        if (control is null || !UsesActionValue(control.Action))
        {
            return;
        }
        actionValue.DecimalPlaces = 0;
        actionValue.Increment = 1;
        decimal displayedValue = control.Action.Value;
        switch (control.Action.Type)
        {
            case RemoteActionType.MacMedia:
                actionValueLabel.Text = "Volume percent";
                actionValue.Minimum = 0;
                actionValue.Maximum = 100;
                displayedValue = Math.Round(control.Action.Value * 100m / 255m);
                break;
            case RemoteActionType.WledPreset:
                actionValueLabel.Text = "Preset";
                actionValue.Minimum = 1;
                actionValue.Maximum = 250;
                break;
            case RemoteActionType.WledBrightness:
                actionValueLabel.Text = "Brightness";
                actionValue.Minimum = 0;
                actionValue.Maximum = 255;
                break;
            case RemoteActionType.NetHomeTemperature:
                var fahrenheit = store.Profile.TemperatureUnit == TemperatureUnit.Fahrenheit;
                actionValueLabel.Text = fahrenheit ? "Setpoint (F)" : "Setpoint (C)";
                actionValue.Minimum = fahrenheit ? 61 : 16;
                actionValue.Maximum = fahrenheit ? 86 : 30;
                displayedValue = (control.Action.ValueTenths ?? control.Action.Value * 10) / 10m;
                if (fahrenheit)
                {
                    displayedValue = Math.Round(displayedValue * 9m / 5m + 32m);
                }
                break;
            case RemoteActionType.NetHomeTemperatureStep:
                actionValueLabel.Text = "Adjustment";
                actionValue.Minimum = -1;
                actionValue.Maximum = 1;
                actionValue.Increment = 2;
                break;
            case RemoteActionType.NetHomeFan:
                actionValueLabel.Text = "Fan percent";
                actionValue.Minimum = 20;
                actionValue.Maximum = 100;
                actionValue.Increment = 20;
                break;
            case RemoteActionType.OpenBuilds:
                actionValueLabel.Text = "Distance (mm)";
                actionValue.Minimum = 1;
                actionValue.Maximum = 100;
                break;
        }
        actionValue.Value = Math.Clamp(displayedValue, actionValue.Minimum, actionValue.Maximum);
    }

    private void SaveActionValue()
    {
        if (refreshing || store.SelectedControl is not { } control)
        {
            return;
        }
        if (control.Action.Type == RemoteActionType.NetHomeTemperature)
        {
            var celsius = store.Profile.TemperatureUnit == TemperatureUnit.Fahrenheit
                ? (actionValue.Value - 32m) * 5m / 9m
                : actionValue.Value;
            control.Action.ValueTenths = (int)Math.Round(celsius * 10m);
            control.Action.Value = (int)Math.Round(celsius);
        }
        else if (control.Action.Type == RemoteActionType.MacMedia)
        {
            control.Action.Value = (int)Math.Round(actionValue.Value * 255m / 100m);
        }
        else
        {
            control.Action.Value = (int)actionValue.Value;
        }
        store.Commit();
    }

    private void SaveKeyCommand()
    {
        if (!refreshing && store.SelectedControl is { Action.Type: RemoteActionType.MacKey } control)
        {
            control.Action.Text = keyCommand.Text.Trim();
            store.Commit();
        }
    }

    private Control BuildModifierOptions()
    {
        var panel = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        foreach (var checkBox in new[] { controlModifier, altModifier, shiftModifier, windowsModifier })
        {
            checkBox.Margin = new Padding(0, 5, 8, 0);
            checkBox.CheckedChanged += (_, _) => SaveModifiers();
            panel.Controls.Add(checkBox);
        }
        return panel;
    }

    private void SaveModifiers()
    {
        if (refreshing || store.SelectedControl is not { Action.Type: RemoteActionType.MacKey } control)
        {
            return;
        }
        control.Action.Modifiers =
        [
            .. controlModifier.Checked ? ["control"] : Array.Empty<string>(),
            .. altModifier.Checked ? ["alt"] : Array.Empty<string>(),
            .. shiftModifier.Checked ? ["shift"] : Array.Empty<string>(),
            .. windowsModifier.Checked ? ["windows"] : Array.Empty<string>(),
        ];
        store.Commit();
    }

    private void ConfigureControlOption(ComboBox comboBox, Action<EditorChoice> apply)
    {
        comboBox.DropDownStyle = ComboBoxStyle.DropDownList;
        comboBox.DisplayMember = nameof(EditorChoice.DisplayName);
        comboBox.Width = 210;
        comboBox.SelectedIndexChanged += (_, _) =>
        {
            if (!refreshing && comboBox.SelectedItem is EditorChoice choice)
            {
                apply(choice);
                store.Commit();
            }
        };
    }

    private static Control BuildOptionRow(string label, Control input) =>
        BuildOptionRow(new Label { Text = label }, input);

    private static Control BuildOptionRow(Label label, Control input)
    {
        var row = new FlowLayoutPanel
        {
            AutoSize = true,
            FlowDirection = FlowDirection.LeftToRight,
            Margin = Padding.Empty,
            WrapContents = false,
        };
        label.AutoSize = false;
        label.Size = new Size(105, 28);
        label.TextAlign = ContentAlignment.MiddleLeft;
        row.Controls.Add(label);
        row.Controls.Add(input);
        return row;
    }

    private static void SetControlOptions(
        ComboBox comboBox,
        IReadOnlyList<EditorChoice> choices,
        string? selectedValue)
    {
        comboBox.DataSource = null;
        if (choices.Count == 0)
        {
            return;
        }
        comboBox.DataSource = choices.ToList();
        comboBox.DisplayMember = nameof(EditorChoice.DisplayName);
        comboBox.SelectedItem = choices.FirstOrDefault(choice => choice.Value == selectedValue) ?? choices[0];
    }

    private void RefreshCatalog()
    {
        var query = catalogSearch.Text.Trim();
        catalogList.BeginUpdate();
        catalogList.Items.Clear();
        foreach (var template in RemoteControlCatalog.All.Concat(moduleCatalog.InstalledTemplates).Where(template =>
            query.Length == 0 || new[] { template.Title, template.Detail, template.Category }
                .Any(value => value.Contains(query, StringComparison.CurrentCultureIgnoreCase))))
        {
            catalogList.Items.Add(template);
        }
        catalogList.EndUpdate();
    }

    private void AddSelectedTemplate()
    {
        if (catalogList.SelectedItem is not RemoteControlTemplate template)
        {
            return;
        }
        if (store.AddControl(template.Factory()))
        {
            inspectorTabs.SelectedIndex = 1;
        }
        else
        {
            MessageBox.Show(this, "This page does not have room for that control.", "paperGIF", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
    }

    private async Task RunDeviceOperation(Func<Task> operation)
    {
        store.DeviceAddress = deviceAddress.Text;
        await operation();
        RefreshAll();
    }

    private void HandleStoreChanged(object? sender, EventArgs eventArgs) => RefreshAll();
    private void HandleStatusChanged(object? sender, EventArgs eventArgs) => RefreshAll();
    private void HandleDiscoveryChanged(object? sender, EventArgs eventArgs)
    {
        if (InvokeRequired)
        {
            BeginInvoke(() => HandleDiscoveryChanged(sender, eventArgs));
            return;
        }
        RefreshAll();
        var device = discovery.Endpoints.FirstOrDefault(endpoint => endpoint.Kind == DiscoveredServiceKind.M5Paper);
        if (device is not null && !store.HasLoadedDeviceProfile && automaticallyLoadedDevice != device.Host)
        {
            automaticallyLoadedDevice = device.Host;
            store.DeviceAddress = device.Host;
            deviceAddress.Text = device.Host;
            _ = store.LoadFromDeviceAsync();
        }
    }

    private async Task UseDiscoveredAsync()
    {
        if (discoveredList.SelectedItem is not DiscoveredEndpoint endpoint)
        {
            return;
        }
        try
        {
            switch (endpoint.Kind)
            {
                case DiscoveredServiceKind.M5Paper:
                    store.DeviceAddress = endpoint.Host;
                    deviceAddress.Text = endpoint.Host;
                    await store.LoadFromDeviceAsync();
                    break;
                case DiscoveredServiceKind.Companion:
                    var pairingResult = await store.PairComputerAsync(endpoint.Name, endpoint.Host, endpoint.Port);
                    MessageBox.Show(this, pairingResult, "paperGIF");
                    break;
                case DiscoveredServiceKind.Wled:
                    AddWledPage(endpoint.Host, endpoint.Name);
                    break;
            }
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or InvalidOperationException)
        {
            MessageBox.Show(this, exception.Message, "paperGIF", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        RefreshAll();
    }

    private void AddComputer()
    {
        if (store.Profile.Computers.Count >= 8)
        {
            return;
        }
        var computer = new RemoteComputer { Name = "Computer", Port = 43_821 };
        if (ComputerDialog.Edit(this, computer))
        {
            store.Profile.Computers.Add(computer);
            store.Commit();
        }
    }

    private void EditComputer()
    {
        if (computersList.SelectedItem is RemoteComputer computer && ComputerDialog.Edit(this, computer))
        {
            store.Commit();
        }
    }

    private void RemoveComputer()
    {
        if (computersList.SelectedItem is not RemoteComputer computer)
        {
            return;
        }
        store.Profile.Computers.Remove(computer);
        foreach (var control in store.Profile.Pages.SelectMany(page => page.Controls))
        {
            if (control.Action.ComputerID == computer.Id.ToString())
            {
                control.Action.ComputerID = null;
            }
        }
        store.Commit();
    }

    private async Task TestComputerAsync()
    {
        if (computersList.SelectedItem is not RemoteComputer computer)
        {
            return;
        }
        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
            client.DefaultRequestHeaders.Authorization = new("Bearer", computer.Token);
            using var response = await client.GetAsync($"http://{computer.Host}:{computer.Port}/status");
            MessageBox.Show(this, response.IsSuccessStatusCode ? $"Connected to {computer.Name}." : $"{computer.Name} rejected the saved pairing.", "paperGIF");
        }
        catch (HttpRequestException)
        {
            MessageBox.Show(this, $"Could not reach {computer.Name}.", "paperGIF", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private async Task ChooseApplicationAsync()
    {
        var control = store.SelectedControl;
        if (control is null)
        {
            return;
        }
        var computer = Guid.TryParse(control.Action.ComputerID, out var computerId)
            ? store.Profile.Computers.FirstOrDefault(candidate => candidate.Id == computerId)
            : store.Profile.Computers.FirstOrDefault();
        if (computer is null)
        {
            MessageBox.Show(this, "Add or pair a computer first.", "paperGIF", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        try
        {
            var applications = await store.LoadApplicationsAsync(computer);
            var selected = ApplicationPickerDialog.Choose(this, applications);
            if (selected is null)
            {
                return;
            }
            control.Action.Type = RemoteActionType.MacOpen;
            control.Action.Text = selected.Path;
            control.Action.ComputerID = computer.Id.ToString();
            control.IconBitmap = selected.IconBitmap;
            if (string.IsNullOrWhiteSpace(control.Title) || control.Title == "Open App or URL")
            {
                control.Title = selected.Name;
            }
            store.Commit();
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or JsonException)
        {
            MessageBox.Show(this, $"Could not load applications from {computer.Name}: {exception.Message}", "paperGIF", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private void EditSchedules()
    {
        if (store.SelectedControl is { } control && ScheduleEditorDialog.Edit(this, control.Action))
        {
            store.Commit();
        }
    }

    private async Task ConnectNetHomeAsync()
    {
        using var dialog = new NetHomeAccountDialog(netHomeService.Account);
        if (dialog.ShowDialog(this) != DialogResult.OK)
        {
            return;
        }
        try
        {
            netHomeStatus.Text = "Connecting...";
            SetNetHomeUnits(await netHomeService.SignInAsync(dialog.Account, dialog.Password));
            RefreshAll();
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "NetHome Plus", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            RefreshAll();
        }
    }

    private async Task RefreshNetHomeUnitsAsync()
    {
        try
        {
            SetNetHomeUnits(await netHomeService.ListUnitsAsync());
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "NetHome Plus", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private void SignOutNetHome()
    {
        netHomeService.SignOut();
        SetNetHomeUnits([]);
        RefreshAll();
    }

    private void SetNetHomeUnits(IReadOnlyList<NetHomeUnit> units)
    {
        refreshing = true;
        netHomeUnits.DataSource = null;
        netHomeUnits.DataSource = units.ToList();
        netHomeUnits.DisplayMember = nameof(NetHomeUnit.Name);
        if (store.SelectedControl is { } control)
        {
            netHomeUnits.SelectedItem = units.FirstOrDefault(unit =>
                unit.Name.Equals(control.Action.Host, StringComparison.OrdinalIgnoreCase));
        }
        refreshing = false;
    }

    private static bool IsNetHomeAction(RemoteActionType type) => type is
        RemoteActionType.NetHomePower or
        RemoteActionType.NetHomeTemperature or
        RemoteActionType.NetHomeTemperatureStep or
        RemoteActionType.NetHomeMode or
        RemoteActionType.NetHomeFan or
        RemoteActionType.NetHomeAuto;

    private static bool IsComputerAction(RemoteActionType type) => type is
        RemoteActionType.MacMedia or RemoteActionType.MacKey or RemoteActionType.MacOpen or
        RemoteActionType.MacShortcut or RemoteActionType.MacScript or RemoteActionType.OpenBuilds ||
        IsNetHomeAction(type);

    private static bool IsDeviceAction(RemoteActionType type) => type is
        RemoteActionType.WledPower or RemoteActionType.WledPreset or RemoteActionType.WledBrightness or
        RemoteActionType.OpenBuilds ||
        IsNetHomeAction(type);

    private static bool UsesActionValue(RemoteAction action) =>
        action.Type is RemoteActionType.WledPreset or RemoteActionType.WledBrightness or
            RemoteActionType.NetHomeTemperature or RemoteActionType.NetHomeTemperatureStep or
            RemoteActionType.NetHomeFan ||
        action.Type == RemoteActionType.OpenBuilds && action.Text.StartsWith("jog", StringComparison.Ordinal) ||
        action.Type == RemoteActionType.MacMedia && action.Text == "volume";

    private void AddNetHomePage()
    {
        if (netHomeUnits.SelectedItem is not NetHomeUnit unit || store.Profile.Pages.Count >= 8)
        {
            return;
        }
        var computerId = store.Profile.Computers
            .FirstOrDefault(computer => computer.Name.Equals(Environment.MachineName, StringComparison.OrdinalIgnoreCase))
            ?.Id.ToString();
        var setpointId = Guid.NewGuid();
        var fanId = Guid.NewGuid();
        var page = new RemotePage
        {
            Name = unit.Name,
            Controls =
            [
                NetHomeControl("Power", RemoteActionType.NetHomePower, unit.Name, 0, "toggle", computerId, 0, isToggle: true),
                NetHomeControl("Auto", RemoteActionType.NetHomeAuto, unit.Name, 22, "cool", computerId, 1, isToggle: true),
                new RemoteControl
                {
                    Id = setpointId,
                    Title = "Setpoint",
                    Kind = RemoteControlKind.TextBox,
                    TintHex = "197278",
                    LayoutSlot = 4,
                    Action = new RemoteAction { Type = RemoteActionType.NetHomeTemperature, Host = unit.Name, Value = 22, ValueTenths = 220, ComputerID = computerId },
                    TextBox = ValueTextBox(setpointId, 2),
                },
                NetHomeControl("Down", RemoteActionType.NetHomeTemperatureStep, unit.Name, -1, "", computerId, 6, buttonHeight: 1),
                NetHomeControl("Up", RemoteActionType.NetHomeTemperatureStep, unit.Name, 1, "", computerId, 7, buttonHeight: 1),
                new RemoteControl
                {
                    Id = fanId,
                    Title = "Fan Speed",
                    Kind = RemoteControlKind.Slider,
                    TintHex = "197278",
                    LayoutSlot = 8,
                    Action = new RemoteAction { Type = RemoteActionType.NetHomeFan, Host = unit.Name, Value = 40, ComputerID = computerId },
                },
                new RemoteControl
                {
                    Title = "Fan",
                    Kind = RemoteControlKind.TextBox,
                    TintHex = "197278",
                    LayoutSlot = 9,
                    Action = new RemoteAction { Type = RemoteActionType.NetHomeFan, Host = unit.Name, Value = 40, ComputerID = computerId },
                    TextBox = ValueTextBox(fanId, 1),
                },
                NetHomeControl("Cool", RemoteActionType.NetHomeMode, unit.Name, 0, "cool", computerId, 10, buttonHeight: 1),
                NetHomeControl("Heat", RemoteActionType.NetHomeMode, unit.Name, 0, "heat", computerId, 11, buttonHeight: 1),
                NetHomeControl("Dry", RemoteActionType.NetHomeMode, unit.Name, 0, "dry", computerId, 12, buttonHeight: 1),
                NetHomeControl("Fan Only", RemoteActionType.NetHomeMode, unit.Name, 0, "fan", computerId, 13, buttonHeight: 1),
            ],
        };
        page.Controls[1].Action.DeadbandTenths = 10;
        page.Controls[1].Action.HumidityThreshold = 65;
        page.Controls[1].Action.MinimumCycleMinutes = 10;
        store.Profile.Pages.Add(page);
        store.SelectedPageId = page.Id;
        store.SelectedControlId = null;
        store.Commit();
    }

    private static RemoteControl NetHomeControl(
        string title,
        RemoteActionType type,
        string host,
        int value,
        string text,
        string? computerId,
        int slot,
        bool? isToggle = null,
        int buttonHeight = 2) => new()
    {
        Title = title,
        Kind = RemoteControlKind.Button,
        TintHex = "197278",
        IsToggle = isToggle,
        ButtonHeight = buttonHeight,
        LayoutSlot = slot,
        Action = new RemoteAction { Type = type, Host = host, Text = text, Value = value, ComputerID = computerId },
    };

    private static RemoteTextBox ValueTextBox(Guid referencedControlId, int width) => new()
    {
        Source = RemoteTextSource.ControlValue,
        ReferencedControlID = referencedControlId,
        Placeholder = "--",
        GridWidth = width,
        TextSize = RemoteTextSize.ExtraLarge,
        HorizontalAlignment = RemoteTextHorizontalAlignment.Center,
        VerticalAlignment = RemoteTextVerticalAlignment.Center,
    };

    private void AddWledPage()
    {
        var host = PromptDialog.Show(this, "Add WLED Page", "WLED hostname or IP address");
        if (string.IsNullOrWhiteSpace(host))
        {
            return;
        }
        AddWledPage(host, "WLED");
    }

    private void AddWledPage(string host, string name)
    {
        if (store.Profile.Pages.Count >= 8)
        {
            return;
        }
        var page = new RemotePage
        {
            Name = name,
            Controls =
            [
                WledControl("Power", RemoteActionType.WledPower, host, "toggle"),
                WledControl("Brightness", RemoteActionType.WledBrightness, host, value: 128, kind: RemoteControlKind.Slider),
                WledControl("Preset 1", RemoteActionType.WledPreset, host, value: 1),
            ],
        };
        store.Profile.Pages.Add(page);
        store.SelectedPageId = page.Id;
        store.Commit();
    }

    private static RemoteControl WledControl(
        string title,
        RemoteActionType type,
        string host,
        string text = "",
        int value = 0,
        RemoteControlKind kind = RemoteControlKind.Button) => new()
    {
        Title = title,
        Kind = kind,
        TintHex = "F2C14E",
        Action = new RemoteAction { Type = type, Host = host.Trim(), Text = text, Value = value },
    };

    private static Button Button(string text, EventHandler onClick, int width = 90)
    {
        var button = new Button
        {
            BackColor = EditorTheme.Surface,
            FlatStyle = FlatStyle.Flat,
            ForeColor = Ink,
            Margin = new Padding(3),
            Size = new Size(width, 28),
            Text = text,
            UseVisualStyleBackColor = false,
        };
        button.FlatAppearance.BorderColor = EditorTheme.Border;
        button.FlatAppearance.MouseOverBackColor = EditorTheme.ForestSoft;
        button.FlatAppearance.MouseDownBackColor = Color.FromArgb(204, 229, 216);
        button.Click += onClick;
        return button;
    }
}

internal sealed record ComputerChoice(Guid? ComputerId, string DisplayName);
internal sealed record EditorChoice(string? Value, string DisplayName);

internal static class ComputerDialog
{
    public static bool Edit(IWin32Window owner, RemoteComputer computer)
    {
        using var form = new Form
        {
            Text = string.IsNullOrWhiteSpace(computer.Host) ? "Add Computer" : "Edit Computer",
            ClientSize = new Size(420, 255),
            FormBorderStyle = FormBorderStyle.FixedDialog,
            MaximizeBox = false,
            MinimizeBox = false,
            StartPosition = FormStartPosition.CenterParent,
        };
        var fields = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(14), ColumnCount = 2, RowCount = 5 };
        fields.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 90));
        fields.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        var name = AddField(fields, "Name", computer.Name, 0);
        var host = AddField(fields, "Host", computer.Host, 1);
        var port = new NumericUpDown { Minimum = 1, Maximum = 65_535, Value = computer.Port, Dock = DockStyle.Fill };
        fields.Controls.Add(new Label { Text = "Port", AutoSize = true }, 0, 2);
        fields.Controls.Add(port, 1, 2);
        var token = AddField(fields, "Token", computer.Token, 3);
        token.UseSystemPasswordChar = true;
        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Fill };
        var save = new Button { Text = "Save", DialogResult = DialogResult.OK };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel };
        buttons.Controls.Add(save);
        buttons.Controls.Add(cancel);
        fields.Controls.Add(buttons, 1, 4);
        form.Controls.Add(fields);
        form.AcceptButton = save;
        form.CancelButton = cancel;
        if (form.ShowDialog(owner) != DialogResult.OK || string.IsNullOrWhiteSpace(name.Text) || string.IsNullOrWhiteSpace(host.Text))
        {
            return false;
        }
        computer.Name = name.Text.Trim();
        computer.Host = host.Text.Trim();
        computer.Port = (int)port.Value;
        computer.Token = token.Text;
        return true;
    }

    private static TextBox AddField(TableLayoutPanel fields, string label, string value, int row)
    {
        fields.Controls.Add(new Label { Text = label, AutoSize = true }, 0, row);
        var input = new TextBox { Text = value, Dock = DockStyle.Fill };
        fields.Controls.Add(input, 1, row);
        return input;
    }
}

internal static class PromptDialog
{
    public static string? Show(IWin32Window owner, string title, string label)
    {
        using var form = new Form
        {
            Text = title,
            ClientSize = new Size(400, 125),
            FormBorderStyle = FormBorderStyle.FixedDialog,
            MaximizeBox = false,
            MinimizeBox = false,
            StartPosition = FormStartPosition.CenterParent,
        };
        var prompt = new Label { Text = label, AutoSize = true, Location = new Point(14, 14) };
        var input = new TextBox { Location = new Point(14, 40), Width = 370 };
        var ok = new Button { Text = "Add", DialogResult = DialogResult.OK, Location = new Point(228, 80) };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Location = new Point(309, 80) };
        form.Controls.AddRange([prompt, input, ok, cancel]);
        form.AcceptButton = ok;
        form.CancelButton = cancel;
        return form.ShowDialog(owner) == DialogResult.OK ? input.Text : null;
    }
}