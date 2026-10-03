using System.Net;
using Xunit;

namespace PaperGIF.Windows.Host.Tests;

public sealed class NetworkDiscoveryServiceTests
{
    [Fact]
    public void RecognizesOnlyPaperGifStatusReplies()
    {
        Assert.True(NetworkDiscoveryService.IsPaperGifStatus(
            """{"device":"paperGIF","ready":true,"uploading":false,"ssid":"Home"}"""));
        Assert.False(NetworkDiscoveryService.IsPaperGifStatus("""{"device":"WLED"}"""));
        Assert.False(NetworkDiscoveryService.IsPaperGifStatus("<html>router</html>"));
        Assert.False(NetworkDiscoveryService.IsPaperGifStatus("""["paperGIF"]"""));
    }

    [Fact]
    public void SweepCoversSubnetExcludingSelfNetworkAndBroadcast()
    {
        var hosts = NetworkDiscoveryService.SweepHosts(
            IPAddress.Parse("192.168.50.44"),
            IPAddress.Parse("255.255.255.0")).ToArray();

        Assert.Equal(253, hosts.Length);
        Assert.Equal(IPAddress.Parse("192.168.50.1"), hosts[0]);
        Assert.Equal(IPAddress.Parse("192.168.50.254"), hosts[^1]);
        Assert.DoesNotContain(IPAddress.Parse("192.168.50.44"), hosts);
    }

    [Fact]
    public void SweepLimitsWideSubnetsToSurroundingSlash24()
    {
        var hosts = NetworkDiscoveryService.SweepHosts(
            IPAddress.Parse("172.21.240.1"),
            IPAddress.Parse("255.255.240.0")).ToArray();

        Assert.Equal(253, hosts.Length);
        Assert.All(hosts, host => Assert.StartsWith("172.21.240.", host.ToString()));
    }

    [Fact]
    public void SweepSkipsPointToPointMasks()
    {
        Assert.Empty(NetworkDiscoveryService.SweepHosts(IPAddress.Parse("10.0.0.1"), IPAddress.Parse("255.255.255.255")));
        Assert.Empty(NetworkDiscoveryService.SweepHosts(IPAddress.Parse("10.0.0.1"), IPAddress.Parse("255.255.255.254")));
    }
}
