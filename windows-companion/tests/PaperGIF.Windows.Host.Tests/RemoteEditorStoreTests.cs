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
}