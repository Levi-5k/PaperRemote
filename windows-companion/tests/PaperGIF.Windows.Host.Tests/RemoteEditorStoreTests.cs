using System.Net;
using PaperGIF.Windows.Core.Models;
using Xunit;

namespace PaperGIF.Windows.Host.Tests;

public sealed class RemoteEditorStoreTests
{
    [Fact]
    public void PreferredIpv4AddressUsesAdapterWithDefaultGateway()
    {
        var address = RemoteEditorStore.PreferredIpv4Address([
            (IPAddress.Parse("172.21.240.1"), false),
            (IPAddress.Parse("192.168.50.44"), true),
            (IPAddress.Parse("192.168.80.1"), false),
        ]);

        Assert.Equal("192.168.50.44", address);
    }

    [Fact]
    public void FlexibleGridPageUsesConfiguredCapacityDuringValidation()
    {
        var page = new RemotePage
        {
            Name = "Motion Control",
            GridColumns = 9,
            GridRows = 14,
            Controls =
            [
                .. Enumerable.Range(0, 3).Select(_ => new RemoteControl
                {
                    GridWidth = 3,
                    GridHeight = 2,
                }),
                .. Enumerable.Range(0, 8).Select(_ => new RemoteControl
                {
                    GridWidth = 2,
                    GridHeight = 2,
                }),
            ],
        };
        var profile = new RemoteProfile { Pages = [page] };

        Assert.Null(RemoteEditorStore.ValidateProfile(profile));

        page.GridColumns = 2;
        page.GridRows = 8;
        Assert.Equal(
            "A page has more controls than fit on the display.",
            RemoteEditorStore.ValidateProfile(profile));
    }

    [Fact]
    public void LoopbackOpenBuildsControlsTargetTheChosenComputer()
    {
        const string local = "11111111-1111-1111-1111-111111111111";
        RemoteControl Control(RemoteActionType type, string host, string? computerId = null) =>
            new() { Action = new RemoteAction { Type = type, Host = host, ComputerID = computerId } };
        var loopback = new[] { "127.0.0.1", "localhost", " ", "" }.Select(host => Control(RemoteActionType.OpenBuilds, host)).ToArray();
        var explicitTarget = Control(RemoteActionType.OpenBuilds, "127.0.0.1", "other");
        var remoteHost = Control(RemoteActionType.OpenBuilds, "192.168.50.40:3000");
        var media = Control(RemoteActionType.MacMedia, "");
        var readout = Control(RemoteActionType.OpenBuilds, "127.0.0.1");
        readout.TextBox = new RemoteTextBox { Source = RemoteTextSource.OpenBuildsPosition, SourceText = "127.0.0.1|x|mm" };

        RemoteEditorStore.TargetOpenBuilds([.. loopback, explicitTarget, remoteHost, media, readout], local);

        Assert.All(loopback, control => Assert.Equal(local, control.Action.ComputerID));
        Assert.Equal("other", explicitTarget.Action.ComputerID);
        Assert.Null(remoteHost.Action.ComputerID);
        Assert.Null(media.Action.ComputerID);
        Assert.Equal(Guid.Parse(local), readout.TextBox.ComputerID);
    }
}