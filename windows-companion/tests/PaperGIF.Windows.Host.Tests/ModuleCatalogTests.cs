using System.Text.Json;
using PaperGIF.Windows.Core.Models;
using PaperGIF.Windows.Core.Serialization;
using PaperGIF.Windows.Host;
using Xunit;

namespace PaperGIF.Windows.Host.Tests;

public sealed class ModuleCatalogTests
{
    [Fact]
    public void ModuleVersionComparisonPreventsDowngrades()
    {
        Assert.True(ModuleCatalogService.IsVersion("1.5.0", newerThan: "1.4.0"));
        Assert.True(ModuleCatalogService.IsVersion("1.10.0", newerThan: "1.9.0"));
        Assert.False(ModuleCatalogService.IsVersion("1.4.0", newerThan: "1.4.0"));
        Assert.False(ModuleCatalogService.IsVersion("1.3.0", newerThan: "1.4.0"));
    }

    [Fact]
    public void CatalogDetectsAnInstalledModuleUpdate()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        Directory.CreateDirectory(directory);
        try
        {
            File.Copy(Path.Combine(AppContext.BaseDirectory, "media-controls.json"),
                Path.Combine(directory, "media-controls.json"));
            var catalog = new ModuleCatalogService(new Uri(ModuleCatalogService.DefaultIndexUrl), directory);
            var listing = new PaperModuleListing
            {
                Id = "media-controls",
                Name = "Media Controls",
                Version = "1.4.0",
                Manifest = "media-controls.json",
            };

            Assert.True(catalog.HasUpdate(listing));
        }
        finally
        {
            Directory.Delete(directory, true);
        }
    }

    [Fact]
    public void SharedModuleManifestCreatesControlsWithFreshIds()
    {
        var json = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "media-controls.json"));
        var module = JsonSerializer.Deserialize<PaperModuleManifest>(json, RemoteProfileJson.Options);

        Assert.NotNull(module);
        Assert.Equal(1, module.SchemaVersion);
        Assert.Equal("media-controls", module.Id);
        Assert.Equal(8, module.Controls.Count);
        var seek = module.Controls.Single(definition => definition.Id == "playback-position").Control;
        Assert.Equal("seek", seek.Action.Text);
        Assert.Equal(3, seek.SliderOutlineInsetPixels);
        Assert.Equal(PaperGIF.Windows.Core.Models.RemoteTextSource.NowPlaying, seek.TextBox?.Source);
        Assert.Equal(PaperGIF.Windows.Core.Models.RemoteTextSize.AutoFit, seek.TextBox?.TextSize);
        Assert.Equal(PaperGIF.Windows.Core.Models.RemoteTextHorizontalAlignment.Center, seek.TextBox?.HorizontalAlignment);
        Assert.Equal(PaperGIF.Windows.Core.Models.RemoteTextVerticalAlignment.Center, seek.TextBox?.VerticalAlignment);
        Assert.Equal(2, seek.GridWidth);

        var pageDefinition = Assert.Single(module.Pages);
        var page = ModuleCatalogService.ClonePage(pageDefinition, module.Id);
        Assert.Equal("media", pageDefinition.Id);
        Assert.Equal("Media", page.Name);
        Assert.Equal(3, page.GridColumns);
        Assert.Equal(8, page.GridRows);
        Assert.Equal(8, page.Controls.Count);
        Assert.All(page.Controls, control =>
            Assert.Equal(PaperGIF.Windows.Core.Models.RemoteActionType.MacMedia, control.Action.Type));
        Assert.Equal(0, page.Controls.Single(control => control.Action.Text == "seek").LayoutSlot);
        Assert.Equal(7, page.Controls.Single(control => control.Action.Text == "playPause").LayoutSlot);
        Assert.Equal(15, page.Controls.Single(control => control.Action.Text == "volume").LayoutSlot);
        Assert.Equal(19, page.Controls.Single(control => control.Action.Text == "mute").LayoutSlot);
        Assert.Equal(module.Id, page.ModuleID);
        Assert.NotEqual(pageDefinition.Page.Id, page.Id);
        Assert.All(page.Controls.Zip(pageDefinition.Page.Controls), pair => Assert.NotEqual(pair.First.Id, pair.Second.Id));

        var source = module.Controls[0].Control;
        var first = ModuleCatalogService.CloneControl(source);
        var second = ModuleCatalogService.CloneControl(source);

        Assert.NotEqual(source.Id, first.Id);
        Assert.NotEqual(first.Id, second.Id);
        Assert.Equal(source.Action.Type, first.Action.Type);
    }

    [Fact]
    public void OpenBuildsModuleContainsOnlyOpenBuildsActions()
    {
        var json = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "openbuilds-control.json"));
        var module = JsonSerializer.Deserialize<PaperModuleManifest>(json, RemoteProfileJson.Options);

        Assert.NotNull(module);
        Assert.Equal("openbuilds-control", module.Id);
        Assert.Equal(19, module.Controls.Count);
        Assert.All(module.Controls, definition =>
            Assert.Equal(PaperGIF.Windows.Core.Models.RemoteActionType.OpenBuilds, definition.Control.Action.Type));
        var definition = Assert.Single(module.Pages);
        var page = ModuleCatalogService.ClonePage(definition, module.Id);
        Assert.Equal(PaperGIF.Windows.Core.Models.RemotePageLayout.OpenBuildsController, page.Layout);
        Assert.Equal(9, page.GridColumns);
        Assert.Equal(14, page.GridRows);
        Assert.Equal(PaperGIF.Windows.Core.Models.RemoteJogMode.Incremental, page.OpenBuildsController?.JogMode);
        Assert.Equal(PaperGIF.Windows.Core.Models.OpenBuildsUnits.Mm, page.OpenBuildsController?.Units);
        Assert.Equal(1_000, page.OpenBuildsController?.JogDistanceThousandths);
        Assert.Equal(22, page.Controls.Count);
        Assert.Equal(3, page.Controls[0].GridWidth);
        Assert.Equal(2, page.Controls[0].GridHeight);
        Assert.Equal(18, page.Controls[3].LayoutSlot);
        Assert.Equal(3, page.Controls[3].GridWidth);
        Assert.Equal(1, page.Controls[3].GridHeight);
        Assert.Equal(47, page.Controls.Single(control => control.Title == "STOP").LayoutSlot);
        Assert.Equal(3, page.Controls.Count(control => control.Action.Text.StartsWith("zero")));
        Assert.Equal(module.Id, page.ModuleID);
        Assert.NotEqual(definition.Page.Id, page.Id);
        Assert.All(page.Controls.Zip(definition.Page.Controls), pair => Assert.NotEqual(pair.First.Id, pair.Second.Id));
    }

    [Fact]
    public void PresentationModuleProvidesCrossPlatformPage()
    {
        var json = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "presentation-controls.json"));
        var module = JsonSerializer.Deserialize<PaperModuleManifest>(json, RemoteProfileJson.Options)!;

        Assert.Equal(7, module.Controls.Count);
        Assert.All(module.Controls, definition => Assert.Equal(RemoteActionType.MacKey, definition.Control.Action.Type));
        var definition = Assert.Single(module.Pages);
        var page = ModuleCatalogService.ClonePage(definition, module.Id);
        Assert.Equal("Presentation", page.Name);
        Assert.Equal(3, page.GridColumns);
        Assert.Equal(8, page.GridRows);
        Assert.Equal(["f5", "left", "b", "right", "home", "escape", "end"], page.Controls.Select(control => control.Action.Text));
        Assert.Equal([0, 6, 7, 8, 15, 16, 17], page.Controls.Select(control => control.LayoutSlot));
        Assert.Equal(module.Id, page.ModuleID);
        Assert.All(page.Controls.Zip(definition.Page.Controls), pair => Assert.NotEqual(pair.First.Id, pair.Second.Id));
    }

    [Fact]
    public void WledScenesModuleProvidesPresetDashboard()
    {
        var json = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "wled-scenes.json"));
        var module = JsonSerializer.Deserialize<PaperModuleManifest>(json, RemoteProfileJson.Options)!;

        Assert.Equal(8, module.Controls.Count);
        var definition = Assert.Single(module.Pages);
        var page = ModuleCatalogService.ClonePage(definition, module.Id);
        Assert.Equal("WLED Scenes", page.Name);
        Assert.Equal(3, page.GridColumns);
        Assert.Equal(8, page.GridRows);
        Assert.Equal([1, 2, 3, 4, 5, 6], page.Controls
            .Where(control => control.Action.Type == RemoteActionType.WledPreset)
            .Select(control => control.Action.Value));
        Assert.All(page.Controls, control => Assert.Equal("wled.local", control.Action.Host));
        Assert.Equal(1, page.Controls.Single(control => control.Action.Type == RemoteActionType.WledBrightness).LayoutSlot);
        Assert.Equal(module.Id, page.ModuleID);
        Assert.All(page.Controls.Zip(definition.Page.Controls), pair => Assert.NotEqual(pair.First.Id, pair.Second.Id));
    }

    [Fact]
    public void UpdatingModulePagePreservesIdentitySettingsAndRouting()
    {
        var json = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "openbuilds-control.json"));
        var module = JsonSerializer.Deserialize<PaperModuleManifest>(json, RemoteProfileJson.Options)!;
        var definition = Assert.Single(module.Pages);
        var existing = ModuleCatalogService.ClonePage(definition, module.Id);
        var pageId = existing.Id;
        existing.Name = "Workshop CNC";
        existing.OpenBuildsController!.JogSpeed = 2_500;
        existing.Controls.RemoveAll(control => control.Title == "STOP");
        var textComputerId = Guid.NewGuid();
        foreach (var control in existing.Controls)
        {
            control.Action.ComputerID = "windows-computer";
            control.Action.Host = "10.0.0.25";
            if (control.TextBox?.Source == PaperGIF.Windows.Core.Models.RemoteTextSource.OpenBuildsPosition)
            {
                control.TextBox.ComputerID = textComputerId;
                var parts = control.TextBox.SourceText.Split('|');
                parts[0] = "10.0.0.25";
                control.TextBox.SourceText = string.Join('|', parts);
            }
        }

        var updated = ModuleCatalogService.UpdatedPage(existing, definition, module.Id);

        Assert.Equal(pageId, updated.Id);
        Assert.Equal("Workshop CNC", updated.Name);
        Assert.Equal(2_500, updated.OpenBuildsController?.JogSpeed);
        Assert.Equal(22, updated.Controls.Count);
        Assert.All(updated.Controls.Where(control => control.Action.Type == PaperGIF.Windows.Core.Models.RemoteActionType.OpenBuilds),
            control =>
            {
                Assert.Equal("windows-computer", control.Action.ComputerID);
                Assert.Equal("10.0.0.25", control.Action.Host);
            });
        Assert.All(updated.Controls.Where(control => control.TextBox?.Source == PaperGIF.Windows.Core.Models.RemoteTextSource.OpenBuildsPosition),
            control =>
            {
                Assert.Equal(textComputerId, control.TextBox?.ComputerID);
                Assert.StartsWith("10.0.0.25|", control.TextBox?.SourceText);
            });
    }
}