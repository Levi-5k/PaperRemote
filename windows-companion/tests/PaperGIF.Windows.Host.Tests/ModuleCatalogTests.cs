using System.Text.Json;
using PaperGIF.Windows.Core.Serialization;
using PaperGIF.Windows.Host;
using Xunit;

namespace PaperGIF.Windows.Host.Tests;

public sealed class ModuleCatalogTests
{
    [Fact]
    public void SharedModuleManifestCreatesControlsWithFreshIds()
    {
        var json = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "media-controls.json"));
        var module = JsonSerializer.Deserialize<PaperModuleManifest>(json, RemoteProfileJson.Options);

        Assert.NotNull(module);
        Assert.Equal(1, module.SchemaVersion);
        Assert.Equal("media-controls", module.Id);
        Assert.Equal(6, module.Controls.Count);

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
        Assert.Equal(16, module.Controls.Count);
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
        Assert.Equal(12, page.Controls.Count);
        Assert.Equal(3, page.Controls[0].GridWidth);
        Assert.Equal(2, page.Controls[0].GridHeight);
        Assert.Equal(18, page.Controls[3].LayoutSlot);
        Assert.Equal(2, page.Controls[3].GridWidth);
        Assert.Equal(2, page.Controls[3].GridHeight);
        Assert.Equal(38, page.Controls.Single(control => control.Title == "STOP").LayoutSlot);
        Assert.Equal(module.Id, page.ModuleID);
        Assert.NotEqual(definition.Page.Id, page.Id);
        Assert.All(page.Controls.Zip(definition.Page.Controls), pair => Assert.NotEqual(pair.First.Id, pair.Second.Id));
    }
}