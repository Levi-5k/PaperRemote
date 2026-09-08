using PaperGIF.Windows.Core.Models;
using Xunit;

namespace PaperGIF.Windows.Host.Tests;

public sealed class RemoteEditorStoreTests
{
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