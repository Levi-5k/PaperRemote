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
}