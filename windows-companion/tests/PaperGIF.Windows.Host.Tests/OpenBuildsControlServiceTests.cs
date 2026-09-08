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
            new OpenBuildsEmission("jogXY", OpenBuildsPayloadKind.JogXY,
                JogXYValue: new OpenBuildsJogXYPayload(-2, 2, 1_000)),
            OpenBuildsCommandMapper.Create("jogXNegativeYPositive", 2));
    }

    [Fact]
    public void RejectsUnknownCommandsAndUnsafeJogDistances()
    {
        Assert.Null(OpenBuildsCommandMapper.Create("runCommand", 1));
        Assert.Null(OpenBuildsCommandMapper.Create("jogXPositive", 0));
        Assert.Null(OpenBuildsCommandMapper.Create("jogXPositive", 101));
        Assert.Null(OpenBuildsCommandMapper.Create("jogXPositiveYPositive", 101));
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
}