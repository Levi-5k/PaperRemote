using System.Text.Json;
using PaperGIF.Windows.Core.Models;
using PaperGIF.Windows.Core.Serialization;
using Xunit;

namespace PaperGIF.Windows.Core.Tests;

public sealed class RemoteProfileContractTests
{
    [Fact]
    public void CanonicalV6FixtureCoversEveryActionType()
    {
        var profile = LoadFixture("remote-profile-v6-all-actions.json");
        var actionTypes = profile.Pages
            .SelectMany(page => page.Controls)
            .Select(control => control.Action.Type)
            .ToHashSet();

        Assert.Equal(Enum.GetValues<RemoteActionType>().ToHashSet(), actionTypes);
        Assert.Equal(2, profile.Computers.Count);
        Assert.Equal(2, profile.Pages.Count);
        Assert.Equal(RemoteTextSource.NowPlaying, profile.Pages[0].Controls[5].TextBox?.Source);
        Assert.Equal(225, profile.Pages[1].Controls[4].Action.Schedules?[0].ValueTenths);
    }

    [Fact]
    public void CanonicalV6FixtureCoversEveryTextSource()
    {
        var profile = LoadFixture("remote-profile-v6-text-sources.json");
        var sources = profile.Pages
            .SelectMany(page => page.Controls)
            .Where(control => control.TextBox is not null)
            .Select(control => control.TextBox!.Source)
            .ToHashSet();

        Assert.Equal(Enum.GetValues<RemoteTextSource>().ToHashSet(), sources);
    }

    [Fact]
    public void LegacyProfileCreatesDefaultComputerAndUpgradesVersion()
    {
        const string json = """
            {
              "version": 1,
              "macHost": "legacy.local",
              "macPort": 43821,
              "macToken": "legacy-token",
              "pages": [{"id":"00000000-0000-0000-0000-000000000001","name":"Main","controls":[]}]
            }
            """;

        var profile = RemoteProfileJson.Deserialize(json);

        Assert.Equal(RemoteProfile.CurrentVersion, profile.Version);
        var computer = Assert.Single(profile.Computers);
        Assert.Equal("legacy.local", computer.Host);
        Assert.Equal("legacy-token", computer.Token);
    }

    [Fact]
    public void LegacyOpenBuildsPageMigratesToFlexibleGrid()
    {
        const string json = """
            {"version":6,"pages":[{"name":"Motion","layout":"openBuildsController","controls":[
              {"title":"X","kind":"textBox","action":{"type":"openBuilds"},"textBox":{"source":"openBuildsPosition","sourceText":"127.0.0.1|x"}},
              {"title":"Up Left","kind":"button","action":{"type":"openBuilds","text":"jogXNegativeYPositive"}}
            ]}]}
            """;

        var page = Assert.Single(RemoteProfileJson.Deserialize(json).Pages);

        Assert.Equal(9, page.GridColumns);
        Assert.Equal(14, page.GridRows);
        Assert.Equal(0, page.Controls[0].LayoutSlot);
        Assert.Equal(3, page.Controls[0].GridWidth);
        Assert.Equal(2, page.Controls[0].GridHeight);
        Assert.Equal(18, page.Controls[1].LayoutSlot);
        Assert.Equal(2, page.Controls[1].GridWidth);
        Assert.Equal(2, page.Controls[1].GridHeight);
    }

    [Fact]
    public void ExplicitOpenBuildsGridIsNotMigrated()
    {
        const string json = """
            {"version":6,"pages":[{"name":"Motion","gridColumns":4,"gridRows":5,"layout":"openBuildsController","controls":[]}]}
            """;

        var page = Assert.Single(RemoteProfileJson.Deserialize(json).Pages);

        Assert.Equal(4, page.GridColumns);
        Assert.Equal(5, page.GridRows);
    }

    [Fact]
    public void NewerProfileVersionIsRejected()
    {
        var error = Assert.Throws<JsonException>(() =>
            RemoteProfileJson.Deserialize("{\"version\":7,\"pages\":[]}"));

        Assert.Contains("Unsupported remote profile version 7", error.Message);
    }

    private static RemoteProfile LoadFixture(string name)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", name);
        return RemoteProfileJson.Deserialize(File.ReadAllText(path));
    }
}