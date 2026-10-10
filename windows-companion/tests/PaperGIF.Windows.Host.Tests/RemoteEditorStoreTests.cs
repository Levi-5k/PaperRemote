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
        var media = Control(RemoteActionType.ComputerMedia, "");
        var readout = Control(RemoteActionType.OpenBuilds, "127.0.0.1");
        readout.TextBox = new RemoteTextBox { Source = RemoteTextSource.OpenBuildsPosition, SourceText = "127.0.0.1|x|mm" };

        RemoteEditorStore.TargetOpenBuilds([.. loopback, explicitTarget, remoteHost, media, readout], local);

        Assert.All(loopback, control => Assert.Equal(local, control.Action.ComputerID));
        Assert.Equal("other", explicitTarget.Action.ComputerID);
        Assert.Null(remoteHost.Action.ComputerID);
        Assert.Null(media.Action.ComputerID);
        Assert.Equal(Guid.Parse(local), readout.TextBox.ComputerID);
    }

    [Fact]
    public void ModulePageControlsAlwaysTargetThisComputer()
    {
        const string local = "11111111-1111-1111-1111-111111111111";
        var remoteOpenBuilds = new RemoteControl
        {
            Action = new RemoteAction { Type = RemoteActionType.OpenBuilds, Host = "192.168.50.40:3000", ComputerID = "other" },
        };
        var media = new RemoteControl { Action = new RemoteAction { Type = RemoteActionType.ComputerMedia } };
        var lights = new RemoteControl { Action = new RemoteAction { Type = RemoteActionType.WledPower, Host = "lights.local" } };
        var readout = new RemoteControl
        {
            Kind = RemoteControlKind.TextBox,
            Action = new RemoteAction { Type = RemoteActionType.WledPower },
            TextBox = new RemoteTextBox
            {
                Source = RemoteTextSource.OpenBuildsPosition,
                SourceText = "192.168.50.40:3000|x|mm",
                TapAction = new RemoteAction { Type = RemoteActionType.ComputerKey },
            },
        };

        RemoteEditorStore.TargetComputer([remoteOpenBuilds, media, lights, readout], local);

        Assert.Equal(local, remoteOpenBuilds.Action.ComputerID);
        Assert.Equal(local, media.Action.ComputerID);
        Assert.Null(lights.Action.ComputerID);
        Assert.Null(readout.Action.ComputerID);
        Assert.Equal(Guid.Parse(local), readout.TextBox.ComputerID);
        Assert.Equal(local, readout.TextBox.TapAction.ComputerID);
    }

    [Fact]
    public void CatalogControlsKeepExplicitTargetsAndFillMissingOnes()
    {
        const string local = "11111111-1111-1111-1111-111111111111";
        var explicitTarget = new RemoteControl { Action = new RemoteAction { Type = RemoteActionType.ComputerKey, ComputerID = "other" } };
        var untargeted = new RemoteControl { Action = new RemoteAction { Type = RemoteActionType.ComputerOpen } };

        RemoteEditorStore.TargetComputer([explicitTarget, untargeted], local, replaceExisting: false);

        Assert.Equal("other", explicitTarget.Action.ComputerID);
        Assert.Equal(local, untargeted.Action.ComputerID);

        var matter = new RemoteControl { Action = new RemoteAction { Type = RemoteActionType.Module, Host = "matter-switch" } };
        RemoteEditorStore.TargetComputer([matter], local, replaceExisting: false, includeModuleActions: false);
        Assert.Null(matter.Action.ComputerID);
    }

    [Fact]
    public void ChangingActionTypeResetsPreviousCommandAndValues()
    {
        var control = new RemoteControl
        {
            Title = "Play / Pause",
            Kind = RemoteControlKind.Slider,
            IconBitmap = "00",
            Action = new RemoteAction { Type = RemoteActionType.ComputerMedia, Text = "volume", Value = 200, ComputerID = "pc" },
        };

        RemoteEditorStore.ApplyActionDefaults(control, RemoteActionType.ComputerOpen);

        Assert.Equal(RemoteActionType.ComputerOpen, control.Action.Type);
        Assert.Equal(string.Empty, control.Action.Text);
        Assert.Equal(0, control.Action.Value);
        Assert.Equal("pc", control.Action.ComputerID);
        Assert.Equal("Open App or URL", control.Title);
        Assert.Equal(RemoteControlKind.Button, control.Kind);
        Assert.Null(control.IconBitmap);

        RemoteEditorStore.ApplyActionDefaults(control, RemoteActionType.WledBrightness);
        Assert.Equal(128, control.Action.Value);
        Assert.Null(control.Action.ComputerID);
        Assert.Equal(RemoteControlKind.Slider, control.Kind);
    }

    [Theory]
    [InlineData("macMedia", "playPause", "Media: Play / Pause")]
    [InlineData("macOpen", @"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Notepad++.lnk", "Open app or URL: Notepad++")]
    [InlineData("macOpen", @"shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App", "Open app or URL: Microsoft.WindowsCalculator")]
    [InlineData("netHomeClimate", "", "netHomeClimate")]
    public void ActivityTextUsesReadableNames(string wireType, string text, string expected)
    {
        Assert.Equal(expected, ActionDescriptions.Describe(wireType, text));
    }
}