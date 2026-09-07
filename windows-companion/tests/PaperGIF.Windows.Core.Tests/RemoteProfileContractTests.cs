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