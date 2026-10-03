using System.Text;
using Xunit;

namespace PaperGIF.Windows.Host.Tests;

public sealed class UpdateServiceTests
{
    [Theory]
    [InlineData("1.10.0", "1.9.9", true)]
    [InlineData("v1.0.1", "1.0", true)]
    [InlineData("1.0.0", "0.0.0", true)]
    [InlineData("1.0", "1.0.0", false)]
    [InlineData("1.0.0", "1.0.1", false)]
    [InlineData("2.0.0", "2.0.0", false)]
    public void VersionComparisonIsNumericAndPadsMissingComponents(string candidate, string current, bool expected)
    {
        Assert.Equal(expected, SoftwareVersion.IsNewer(candidate, current));
    }

    [Fact]
    public void ParsesReleaseAndKeepsOnlyGitHubHttpsDownloads()
    {
        const string json = """
            {
              "tag_name": "v1.2.0",
              "body": "Notes",
              "assets": [
                {"name": "papergif-release.json", "browser_download_url": "https://github.com/Levi-5k/PaperRemote/releases/download/v1.2.0/papergif-release.json"},
                {"name": "evil.zip", "browser_download_url": "http://github.com/evil.zip"},
                {"name": "other.zip", "browser_download_url": "https://example.com/other.zip"}
              ]
            }
            """;

        var (tag, notes, downloads) = UpdateService.ParseRelease(json);

        Assert.Equal("v1.2.0", tag);
        Assert.Equal("Notes", notes);
        Assert.Equal(["papergif-release.json"], downloads.Keys);
    }

    [Fact]
    public void ManifestRejectsMalformedChecksumsAndPathNames()
    {
        var checksum = new string('a', 64);
        var manifest = UpdateService.DecodeManifest(
            "{\"version\":\"1.2.0\",\"firmware\":{\"name\":\"fw.bin\",\"sha256\":\"" + checksum + "\",\"size\":10}}");
        Assert.Equal(10, manifest.Firmware?.Size);

        Assert.Throws<UpdateException>(() => UpdateService.DecodeManifest(
            """{"version":"1.2.0","windows":{"name":"a.zip","sha256":"abc","size":10}}"""));
        Assert.Throws<UpdateException>(() => UpdateService.DecodeManifest(
            "{\"version\":\"1.2.0\",\"windows\":{\"name\":\"..\\\\a.zip\",\"sha256\":\"" + checksum + "\",\"size\":10}}"));
    }

    [Fact]
    public void FirmwareMultipartBodyWrapsImageInOneFilePart()
    {
        byte[] firmware = [0xE9, 0x00, 0xFF];
        var body = UpdateService.MultipartBody(firmware, "B");
        var prefix = Encoding.ASCII.GetBytes(
            "--B\r\nContent-Disposition: form-data; name=\"firmware\"; filename=\"firmware.bin\"\r\n" +
            "Content-Type: application/octet-stream\r\n\r\n");

        Assert.Equal([.. prefix, .. firmware, .. Encoding.ASCII.GetBytes("\r\n--B--\r\n")], body);
    }

    [Fact]
    public void DeviceUriAcceptsHostsAndRejectsOtherSchemes()
    {
        Assert.Equal("http://192.168.50.142/firmware", UpdateService.DeviceUri("192.168.50.142", "/firmware").ToString());
        Assert.Equal("http://papergif.local/status", UpdateService.DeviceUri("http://papergif.local/remote?x=1", "/status").ToString());
        Assert.Throws<UpdateException>(() => UpdateService.DeviceUri("https://papergif.local", "/firmware"));
    }
}
