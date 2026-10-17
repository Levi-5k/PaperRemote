using System.Buffers.Binary;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using PaperGIF.Windows.Core.Models;
using Xunit;

namespace PaperGIF.Windows.Core.Tests;

public sealed class BoardArtworkTests
{
    [Fact]
    public void BundledKnobBoardIncludesArtworkAndAlignedControls()
    {
        var descriptor = DeviceDescriptor.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory,
            "Fixtures", "device-descriptor-v1-screenless.json"))) with
        {
            BoardID = "paperremote.supermini-s3-mt6701",
            Inputs = [
                new("button-1", "Left", "button", ["press"]),
                new("button-2", "Right", "button", ["press"]),
                new("dial-1", "Knob", "dial", ["change"], 0, 16383)
            ]
        };
        descriptor = descriptor with { Layout = DeviceLayout.Generated(null, descriptor.Inputs) };
        using var client = new HttpClient();
        var catalog = new BoardCatalog(client, Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N")));
        var result = catalog.Cached(descriptor);
        Assert.Contains("Bundled", result.Status);
        Assert.Equal(768, result.Layout.Width);
        Assert.Equal(768, result.Layout.Height);
        Assert.Equal(["button-1", "button-2", "dial-1"], result.Layout.Inputs.Select(input => input.Id));
        var dial = result.Layout.Inputs.Single(input => input.Id == "dial-1");
        Assert.Equal(332, dial.X + dial.Width / 2);
        Assert.Equal(300, dial.Y + dial.Height / 2);
        Assert.All(result.Layout.Inputs.Take(2), button => Assert.True(button.Y > dial.Y + dial.Height));
        var data = Assert.IsType<byte[]>(result.Layout.DecodeArtwork());
        Assert.Equal(384u, BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(16, 4)));
        Assert.Equal(384u, BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(20, 4)));
        var roundTrip = JsonSerializer.Deserialize<DeviceLayout>(
            JsonSerializer.Serialize(result.Layout, DeviceDescriptor.JsonOptions), DeviceDescriptor.JsonOptions)!;
        Assert.Equal(result.Layout.ArtworkPNG, roundTrip.ArtworkPNG);
        descriptor.ValidateLayout(roundTrip);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not PNG data")]
    [InlineData("bm90IGEgUE5H")]
    public void InvalidArtworkIsRejected(string artwork) =>
        Assert.Throws<JsonException>(() => new DeviceLayout(100, 100, Inputs: [], ArtworkPNG: artwork).DecodeArtwork());

    [Fact]
    public void OversizedArtworkIsRejected() =>
        Assert.Throws<JsonException>(() =>
            new DeviceLayout(100, 100, Inputs: [], ArtworkPNG: new string('A', 60_004)).DecodeArtwork());

    [Fact]
    public void OldLayoutsDoNotRequireArtwork()
    {
        var layout = JsonSerializer.Deserialize<DeviceLayout>(
            """{"width":100,"height":100,"inputs":[]}""", DeviceDescriptor.JsonOptions)!;
        Assert.Null(layout.ArtworkPNG);
        Assert.Null(layout.DecodeArtwork());
    }

    [Theory]
    [InlineData(2, true)]
    [InlineData(3, false)]
    public async Task DownloadsVersionedArtworkAndChecksPackageVersion(int catalogVersion, bool succeeds)
    {
        using var stream = typeof(BoardCatalog).Assembly.GetManifestResourceStream("Boards/supermini-s3-mt6701.json")!;
        using var reader = new StreamReader(stream);
        var json = await reader.ReadToEndAsync();
        var package = JsonSerializer.Deserialize<BoardPackage>(json, DeviceDescriptor.JsonOptions)!;
        var descriptor = DeviceDescriptor.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory,
            "Fixtures", "device-descriptor-v1-screenless.json"))) with
        {
            BoardID = package.BoardID,
            Inputs = [
                new("button-1", "Left", "button", ["press"]),
                new("button-2", "Right", "button", ["press"]),
                new("dial-1", "Knob", "dial", ["change"], 0, 16383)
            ],
            Layout = package.Layout
        };
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(json))).ToLowerInvariant();
        var index = new BoardIndex(1, [new(package.BoardID, ["1"], catalogVersion, "supermini-s3-mt6701.json", digest)]);
        using var client = new HttpClient(new CatalogHandler(JsonSerializer.Serialize(index, DeviceDescriptor.JsonOptions), json));
        var directory = Path.Combine(Path.GetTempPath(), "paperremote-artwork-" + Guid.NewGuid().ToString("N"));
        try
        {
            var result = await new BoardCatalog(client, directory).ResolveAsync(descriptor);
            Assert.Equal(package.Layout.ArtworkPNG, result.Layout.ArtworkPNG);
            Assert.Contains(succeeds ? "(v2)" : "version does not match", result.Status);
            Assert.Equal(succeeds, Directory.Exists(directory));
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    private sealed class CatalogHandler(string index, string board) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                RequestMessage = request,
                Content = new StringContent(request.RequestUri == BoardCatalog.IndexUri ? index : board)
            });
    }
}
