using PaperGIF.Windows.Host;
using Xunit;

namespace PaperGIF.Windows.Host.Tests;

public sealed class OpenBuildsControlServiceTests
{
    [Fact]
    public void MapsApprovedCommandsToOpenBuildsEvents()
    {
        Assert.Equal(
            new OpenBuildsEmission("jog", OpenBuildsPayloadKind.String, StringValue: "X,-1,1000"),
            OpenBuildsCommandMapper.Create("jogXNegative", 1));
        Assert.Equal(
            new OpenBuildsEmission("stop", OpenBuildsPayloadKind.Stop,
                StopValue: new OpenBuildsStopPayload(false, false, true)),
            OpenBuildsCommandMapper.Create("abort", 0));
        Assert.Equal(
            new OpenBuildsEmission("runCommand", OpenBuildsPayloadKind.String, StringValue: "$H\n"),
            OpenBuildsCommandMapper.Create("home", 0));
        Assert.Equal(
            new OpenBuildsEmission("runCommand", OpenBuildsPayloadKind.String, StringValue: "G10 L20 P1 X0\n"),
            OpenBuildsCommandMapper.Create("zeroX", 0));
        Assert.Equal(
            new OpenBuildsEmission("runCommand", OpenBuildsPayloadKind.String, StringValue: "G10 L20 P1 Y0\n"),
            OpenBuildsCommandMapper.Create("zeroY", 0));
        Assert.Equal(
            new OpenBuildsEmission("runCommand", OpenBuildsPayloadKind.String, StringValue: "G10 L20 P1 Z0\n"),
            OpenBuildsCommandMapper.Create("zeroZ", 0));
        Assert.Equal(
            new OpenBuildsEmission("jogXY", OpenBuildsPayloadKind.JogXY,
                JogXYValue: new OpenBuildsJogXYPayload(-2, 2, 1_000)),
            OpenBuildsCommandMapper.Create("jogXNegativeYPositive", 2));
        Assert.Equal(
            new OpenBuildsEmission("jogXY", OpenBuildsPayloadKind.JogXY,
                JogXYValue: new OpenBuildsJogXYPayload(0.1, -0.1, 2_400)),
            OpenBuildsCommandMapper.Create("jogXPositiveYNegative", 0, 1, ["feed=2400"]));
        Assert.Equal(
            new OpenBuildsEmission("runCommand", OpenBuildsPayloadKind.String,
                StringValue: "$J=G91 G21 X-1000 Y1000 F3200\n"),
            OpenBuildsCommandMapper.Create("continuousJogXNegativeYPositive", 3_200));
        Assert.Equal(
            new OpenBuildsEmission("stop", OpenBuildsPayloadKind.Stop,
                StopValue: new OpenBuildsStopPayload(false, true, false)),
            OpenBuildsCommandMapper.Create("cancelJog", 0));
    }

    [Fact]
    public void RejectsUnknownCommandsAndUnsafeJogDistances()
    {
        Assert.Null(OpenBuildsCommandMapper.Create("runCommand", 1));
        Assert.Null(OpenBuildsCommandMapper.Create("jogXPositive", 0));
        Assert.Null(OpenBuildsCommandMapper.Create("jogXPositive", 101));
        Assert.Null(OpenBuildsCommandMapper.Create("jogXPositiveYPositive", 101));
        Assert.Null(OpenBuildsCommandMapper.Create("continuousJogXPositive", 99));
    }

    [Fact]
    public void ConvertsInchJogDistanceAndFeedToMillimeters()
    {
        Assert.Equal(
            new OpenBuildsEmission("jog", OpenBuildsPayloadKind.String,
                StringValue: "X,0.0254,254"),
            OpenBuildsCommandMapper.Create(
                "jogXPositive", 0, modifiers: ["feed=10", "units=in", "dist=1"]));
        Assert.Equal(
            new OpenBuildsEmission("runCommand", OpenBuildsPayloadKind.String,
                StringValue: "$J=G91 G21 Y1000 F508\n"),
            OpenBuildsCommandMapper.Create("continuousJogYPositive", 20, modifiers: ["units=in"]));
    }

    [Fact]
    public void BuildsOnlyLocalNetworkTargets()
    {
        Assert.Equal(4, OpenBuildsControlService.Endpoints(string.Empty).Count);
        Assert.Equal(3020, OpenBuildsControlService.Endpoints("192.168.50.44:3020")[0].Port);
        Assert.Empty(OpenBuildsControlService.Endpoints("8.8.8.8"));
        Assert.Empty(OpenBuildsControlService.Endpoints("example.com"));
        Assert.Empty(OpenBuildsControlService.Endpoints("localhost/path"));
    }

    [Fact]
    public void ParsesWorkPositionFromStatusPayload()
    {
        using var document = System.Text.Json.JsonDocument.Parse(
            """{"machine":{"position":{"work":{"x":12.5,"y":"-3.25","z":0}}}}""");

        Assert.Equal(
            new OpenBuildsPosition(12.5, -3.25, 0),
            OpenBuildsControlService.ParsePosition(document.RootElement));
    }

    [Fact]
    public void ParsesGrblRunStatusFromStatusPayload()
    {
        using var document = System.Text.Json.JsonDocument.Parse(
            """{"comms":{"runStatus":"Hold:0"}}""");

        Assert.Equal("Hold:0", OpenBuildsControlService.ParseRunStatus(document.RootElement));
    }

    [Theory]
    [InlineData("jogXPositive", "Idle", true)]
    [InlineData("jogXPositive", "Run", false)]
    [InlineData("zeroX", "Hold:0", false)]
    [InlineData("home", "Alarm", true)]
    [InlineData("home", "Run", false)]
    [InlineData("unlock", "Alarm", true)]
    [InlineData("unlock", "Idle", false)]
    [InlineData("pause", "Run", true)]
    [InlineData("resume", "Hold:0", true)]
    [InlineData("resume", "Door:0", true)]
    [InlineData("resume", "Run", false)]
    [InlineData("stop", null, true)]
    [InlineData("abort", "Run", true)]
    [InlineData("cancelJog", "Jog", true)]
    public void AllowsCommandsOnlyInCompatibleGrblStates(string command, string? runStatus, bool expected)
    {
        Assert.Equal(expected, OpenBuildsCommandPolicy.Allows(command, runStatus));
    }
}