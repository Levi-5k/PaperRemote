using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using PaperGIF.Windows.Core.Models;
using PaperGIF.Windows.Core.Serialization;
using Xunit;

namespace PaperGIF.Windows.Core.Tests;

public sealed class CustomDeviceTests
{
    [Theory]
    [InlineData(RemoteActionType.ComputerMedia, "volume", 0, 100, true)]
    [InlineData(RemoteActionType.IPhoneMedia, "volume", 0, 101, false)]
    [InlineData(RemoteActionType.ComputerMedia, "volume", -1, 100, false)]
    [InlineData(RemoteActionType.ComputerMedia, "playPause", 0, 100, false)]
    [InlineData(RemoteActionType.WledBrightness, "", 0, 255, true)]
    [InlineData(RemoteActionType.WledBrightness, "", 0, 256, false)]
    [InlineData(RemoteActionType.NetHomeTemperature, "", -3276.8, 3276.7, true)]
    [InlineData(RemoteActionType.NetHomeTemperature, "", -3276.9, 3276.7, false)]
    [InlineData(RemoteActionType.NetHomeTemperature, "", -3276.8, 3276.8, false)]
    [InlineData(RemoteActionType.NetHomeFan, "", 0, 100, false)]
    public void AdjustmentActionRangesMatchFirmwarePreflight(RemoteActionType type, string text,
        double minimum, double maximum, bool allowed)
    {
        var binding = new HardwareBinding { InputID = "encoder-1", Event = "rotate", Mode = "relative",
            Minimum = minimum, Maximum = maximum, Step = 0.1, Action = new() { Type = type, Text = text } };
        Assert.Equal(allowed, binding.Validate(Device()) is null);
        var profile = new RemoteProfile { Version = 7, HardwareBindings = [binding] };
        if (allowed) _ = RemoteProfileJson.SerializeForDevice(profile, Device());
        else Assert.Throws<InvalidOperationException>(() => RemoteProfileJson.SerializeForDevice(profile, Device()));
    }

    [Theory]
    [InlineData("device-descriptor-v1-screenless.json", false)]
    [InlineData("device-descriptor-v1-landscape.json", true)]
    public void AbsentLayoutGeneratesUsableGeometryBeforeNativeDescriptorValidation(string fixture, bool hasScreen)
    {
        var node = JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", fixture)))!.AsObject();
        node.Remove("layout");
        var descriptor = DeviceDescriptor.Parse(node.ToJsonString());
        Assert.Equal(320, descriptor.Layout.Width);
        Assert.Equal(hasScreen, descriptor.Layout.Screen is not null);
        Assert.Equal(descriptor.Inputs.Select(input => input.Id), descriptor.Layout.Inputs.Select(input => input.Id));
        Assert.All(descriptor.Layout.Inputs, placement => Assert.Equal(56, placement.Width));
        descriptor.Validate();
        var roundTrip = DeviceDescriptor.Parse(Json(descriptor));
        Assert.Equal(descriptor.Layout.Width, roundTrip.Layout.Width);
        Assert.Equal(descriptor.Layout.Height, roundTrip.Layout.Height);
        if (hasScreen)
        {
            Assert.Equal(277.333333, descriptor.Layout.Screen!.Width, 6);
            Assert.Equal(208, descriptor.Layout.Screen.Height, 6);
        }
    }

    [Theory]
    [InlineData("null")]
    [InlineData("{}")]
    [InlineData("""{"width":-1,"height":100,"inputs":[]}""")]
    public void PresentMalformedLayoutNeverGeneratesFallback(string layout)
    {
        var node = JsonNode.Parse(Json(Device()))!.AsObject();
        node["layout"] = JsonNode.Parse(layout);
        Assert.Throws<JsonException>(() => DeviceDescriptor.Parse(node.ToJsonString()));
    }

    [Fact]
    public void GeneratedLayoutDoesNotMakeMissingDisplayValid()
    {
        var node = JsonNode.Parse(Json(Device()))!.AsObject();
        node.Remove("layout");
        node.Remove("display");
        Assert.Throws<JsonException>(() => DeviceDescriptor.Parse(node.ToJsonString()));
    }

    [Theory]
    [InlineData("m5stack.m5paper", "1.0", true, true)]
    [InlineData("m5stack.m5paper", "1.0", false, false)]
    [InlineData("m5stack.m5paper", "1", true, false)]
    [InlineData("m5paper-v1", "1.0", true, false)]
    [InlineData("paperremote.esp32-screenless-reference", "1", true, false)]
    public void FirmwareGateRequiresExactBoardRevisionAndAdvertisedCapability(string boardID, string revision, bool updates, bool allowed)
    {
        var descriptor = DeviceDescriptor.Legacy("device") with { BoardID = boardID, HardwareRevision = revision,
            Capabilities = DeviceDescriptor.Legacy("device").Capabilities with { FirmwareUpdate = updates } };
        Assert.Equal(allowed, FirmwareCompatibility.SupportsM5PaperUpdate(descriptor));
    }

    [Theory]
    [InlineData("binary-PGIFBOARD:m5stack.m5paper@1.0;-binary", true)]
    [InlineData("binary-PGIFBOARD:m5stack.m5paper@1;-binary", false)]
    [InlineData("binary-PGIFBOARD:paperremote.esp32-screenless-reference@1;-binary", false)]
    [InlineData("old-unmarked-firmware", false)]
    public void FirmwareMarkerMustMatchExactKnownBoardAndRevision(string firmware, bool allowed) =>
        Assert.Equal(allowed, FirmwareCompatibility.HasM5PaperMarker(Encoding.UTF8.GetBytes(firmware)));

    [Fact]
    public void SharedReferenceFixturesRoundTripThroughWindowsWireModels()
    {
        var descriptor = DeviceDescriptor.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory,
            "Fixtures", "device-descriptor-v1-screenless.json")));
        var profile = RemoteProfileJson.Deserialize(File.ReadAllText(Path.Combine(AppContext.BaseDirectory,
            "Fixtures", "remote-profile-v7-screenless.json")));
        Assert.Null(descriptor.Display);
        Assert.Equal("paperremote.esp32-screenless-reference", descriptor.BoardID);
        var roundTripped = RemoteProfileJson.Deserialize(RemoteProfileJson.SerializeForDevice(profile, descriptor));
        Assert.Equal(7, roundTripped.Version);
        Assert.Equal(["button-1", "encoder-1", "slider-1"], roundTripped.HardwareBindings!.Select(binding => binding.InputID));
        Assert.Equal(RemoteActionType.ComputerMedia, roundTripped.HardwareBindings![1].Action.Type);
        Assert.Equal(2, roundTripped.HardwareBindings![1].Step);
    }

    [Fact]
    public void SharedBundledCatalogMatchesExactReferenceRevisionOffline()
    {
        var descriptor = DeviceDescriptor.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory,
            "Fixtures", "device-descriptor-v1-screenless.json")));
        using var client = Client(_ => throw new InvalidOperationException("Offline; no request expected."));
        var catalog = new BoardCatalog(client, Path.Combine("TestResults", "no-cache-" + Guid.NewGuid().ToString("N")));
        var bundled = catalog.Cached(descriptor);
        Assert.Contains("Bundled", bundled.Status);
        Assert.Equal(3, bundled.Layout.Inputs.Count);
        Assert.Contains("Device layout", catalog.Cached(descriptor with { HardwareRevision = "unknown" }).Status);
    }

    [Fact]
    public void SharedLandscapeFixtureUsesNormalizedGridAndMatchingControlHitGeometry()
    {
        var descriptor = DeviceDescriptor.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory,
            "Fixtures", "device-descriptor-v1-landscape.json")));
        Assert.Equal(320, descriptor.Display!.Width);
        Assert.Equal(240, descriptor.Display.Height);
        Assert.Equal("rgb565", descriptor.Display.PixelFormat);
        var grid = DevicePreviewGeometry.GenericGrid(new(0, 0, 320, 240));
        Assert.Equal(12.8, grid.X, 6);
        Assert.Equal(9.6, grid.Y, 6);
        Assert.Equal(294.4, grid.Width, 6);
        Assert.Equal(220.8, grid.Height, 6);
        var first = DevicePreviewGeometry.ControlFrame(grid, 2, 2, 0, 1, 1);
        var last = DevicePreviewGeometry.ControlFrame(grid, 2, 2, 3, 1, 1);
        Assert.Equal(13.8, first.X, 6);
        Assert.Equal(145.2, first.Width, 6);
        Assert.Equal(161, last.X, 6);
        Assert.Equal(121, last.Y, 6);
        var hitColumn = (int)((last.X + last.Width / 2 - grid.X) / (grid.Width / 2));
        var hitRow = (int)((last.Y + last.Height / 2 - grid.Y) / (grid.Height / 2));
        Assert.Equal(3, hitRow * 2 + hitColumn);
    }

    [Fact]
    public void OppositeRotaryActionsAreDistinctButWildcardOverlapIsRejected()
    {
        HardwareBinding Binding(string? direction) => new() { InputID = "encoder-1", Event = "rotate",
            Mode = "action", Direction = direction, Action = new() { Type = RemoteActionType.ComputerKey, Text = "space" } };
        var profile = new RemoteProfile { HardwareBindings = [Binding("negative"), Binding("positive")] };
        Assert.All(profile.HardwareBindings, binding => Assert.Null(binding.Validate(Device())));
        Assert.Contains("\"direction\":\"negative\"", RemoteProfileJson.SerializeForDevice(profile, Device()));
        profile.HardwareBindings.Add(Binding(null));
        Assert.Throws<InvalidOperationException>(() => RemoteProfileJson.SerializeForDevice(profile, Device()));
    }

    [Fact]
    public void RawDirectionalFixturePreservesOptionalDirectionAcrossAllSerializers()
    {
        var profile = RemoteProfileJson.Deserialize(File.ReadAllText(Path.Combine(AppContext.BaseDirectory,
            "Fixtures", "remote-profile-v7-directional.json")));
        var genericJson = RemoteProfileJson.Serialize(profile);
        var negotiatedJson = RemoteProfileJson.SerializeForDevice(profile, Device());
        foreach (var json in new[] { genericJson, negotiatedJson })
        {
            var restored = RemoteProfileJson.Deserialize(json);
            Assert.Equal(["negative", "positive"], restored.HardwareBindings!.Select(binding => binding.Direction));
        }
        profile.HardwareBindings!.Add(new() { InputID = "encoder-1", Event = "rotate", Mode = "action" });
        Assert.Throws<InvalidOperationException>(() => RemoteProfileJson.Serialize(profile));
        Assert.Throws<InvalidOperationException>(() => RemoteProfileJson.SerializeForDevice(profile, Device()));
        var invalidWire = JsonSerializer.Serialize(profile, RemoteProfileJson.Options);
        Assert.Throws<JsonException>(() => RemoteProfileJson.Deserialize(invalidWire));
    }

    [Theory]
    [InlineData("press", "action", null, true)]
    [InlineData("hold", "action", null, true)]
    [InlineData("release", "action", null, true)]
    [InlineData("rotate", "action", "negative", true)]
    [InlineData("rotate", "action", "positive", true)]
    [InlineData("rotate", "action", null, true)]
    [InlineData("rotate", "relative", null, true)]
    [InlineData("change", "absolute", null, true)]
    [InlineData("unknown", "action", null, false)]
    [InlineData("press", "action", "negative", false)]
    [InlineData("rotate", "relative", "positive", false)]
    [InlineData("rotate", "action", "left", false)]
    public void SupportedEventEnumAndOptionalDirectionAreCheckedAtSerializationBoundaries(
        string eventName, string mode, string? direction, bool valid)
    {
        var profile = new RemoteProfile { Version = 7, HardwareBindings =
            [new() { InputID = "input", Event = eventName, Mode = mode, Direction = direction,
                Action = new() { Type = RemoteActionType.WledBrightness } }] };
        if (valid)
            Assert.Equal(eventName, Assert.Single(RemoteProfileJson.Deserialize(RemoteProfileJson.Serialize(profile)).HardwareBindings!).Event);
        else
        {
            Assert.Throws<InvalidOperationException>(() => RemoteProfileJson.Serialize(profile));
            Assert.Throws<JsonException>(() => RemoteProfileJson.Deserialize(JsonSerializer.Serialize(profile, RemoteProfileJson.Options)));
        }
    }

    [Theory]
    [InlineData("""{"version":7,"pages":[]}""")]
    [InlineData("""{"version":7,"pages":[],"hardwareBindings":[{"inputID":"button-1","event":"press","mode":"action"}]}""")]
    [InlineData("""{"version":6,"pages":[],"hardwareBindings":[]}""")]
    [InlineData("""{"version":7,"pages":[null],"hardwareBindings":[]}""")]
    public void IncompleteV7OrNonRepresentableV6IsRejected(string json) =>
        Assert.Throws<JsonException>(() => RemoteProfileJson.Deserialize(json));

    [Theory]
    [InlineData("network")]
    [InlineData("invalid-json")]
    [InlineData("unsupported-version")]
    [InlineData("unsafe-path")]
    [InlineData("redirect")]
    public async Task CatalogFailureLeavesUsableDeviceLayout(string failure)
    {
        using var client = Client(request =>
        {
            if (failure == "network") throw new HttpRequestException("Offline.");
            var json = failure switch
            {
                "invalid-json" => "{",
                "unsupported-version" => """{"schemaVersion":2,"boards":[]}""",
                "unsafe-path" => JsonSerializer.Serialize(new BoardIndex(1,
                    [new(Device().BoardID, ["1"], 1, "../escape.json", new string('a', 64))]), DeviceDescriptor.JsonOptions),
                _ => """{"schemaVersion":1,"boards":[]}""",
            };
            var response = Response(json);
            if (failure == "redirect")
                response.RequestMessage = new HttpRequestMessage(HttpMethod.Get, "https://untrusted.invalid/index.json");
            return Task.FromResult(response);
        });
        var catalog = new BoardCatalog(client, Path.Combine("TestResults", "no-cache-" + Guid.NewGuid().ToString("N")));
        var result = await catalog.ResolveAsync(Device() with { BoardID = "test.no-bundle" });
        Assert.Equal(Device().Layout.Width, result.Layout.Width);
        Assert.Equal(Device().Layout.Inputs.Select(input => input.Id), result.Layout.Inputs.Select(input => input.Id));
        Assert.Contains("Catalog unavailable", result.Status);
    }

    [Fact]
    public async Task CatalogCancellationDoesNotApplyNewData()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        using var client = Client(_ => throw new InvalidOperationException("No request expected."));
        var catalog = new BoardCatalog(client, Path.Combine("TestResults", "no-cache-" + Guid.NewGuid().ToString("N")));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => catalog.ResolveAsync(Device(), cancellation.Token));
    }

    private static DeviceDescriptor Device() => new(1, 1, "device-a", "Reference", "PaperRemote",
        "paperremote.esp32-screenless-reference", "1", "1.0", null,
        [new("button-1", "Button", "button", ["press", "hold", "release"]),
         new("encoder-1", "Encoder", "encoder", ["rotate"]),
         new("slider-1", "Slider", "slider", ["change"], 0, 4095)],
        new(100, 50, null, [new("button-1", 5, 5, 20, 20), new("encoder-1", 35, 5, 20, 20),
            new("slider-1", 65, 5, 20, 30)]), new([6, 7], false, false, 65_536, 24, 8));

    private static string Json(DeviceDescriptor descriptor) =>
        JsonSerializer.Serialize(descriptor, DeviceDescriptor.JsonOptions);

    [Fact]
    public void ScreenlessDescriptorRoundTripsWithoutInventingDisplay()
    {
        var descriptor = DeviceDescriptor.Parse(Json(Device()));
        Assert.Null(descriptor.Display);
        Assert.Equal(3, descriptor.Inputs.Count);
        Assert.Equal("device-a", descriptor.DeviceID);
    }

    [Theory]
    [InlineData("schemaVersion", "2")]
    [InlineData("protocolVersion", "2")]
    [InlineData("layout", "null")]
    [InlineData("inputs", "null")]
    [InlineData("display", """{"width":0,"height":1,"touch":true,"pixelFormat":"gray4","rotation":0}""")]
    [InlineData("display", """{"width":4096,"height":4096,"touch":true,"pixelFormat":"gray4","rotation":0}""")]
    public void MalformedDescriptorIsRejected(string field, string value)
    {
        var node = JsonNode.Parse(Json(Device()))!.AsObject();
        node[field] = JsonNode.Parse(value);
        Assert.Throws<JsonException>(() => DeviceDescriptor.Parse(node.ToJsonString()));
    }

    [Theory]
    [InlineData(240, 320, 0)]
    [InlineData(320, 240, 90)]
    [InlineData(128, 128, 180)]
    [InlineData(16, 16, 270)]
    public void BoundedDisplaysAreAccepted(int width, int height, int rotation)
    {
        var device = Device() with
        {
            Display = new(width, height, true, "mono1", rotation),
            Layout = Device().Layout with { Screen = new(0, 30, 40, 15) },
        };
        Assert.Equal(width, DeviceDescriptor.Parse(Json(device)).Display!.Width);
    }

    [Fact]
    public void DuplicateInputIdsAndGeometryMismatchAreRejected()
    {
        var device = Device();
        Assert.Throws<JsonException>(() => (device with { Inputs = [device.Inputs[0], device.Inputs[0]] }).Validate());
        Assert.Throws<JsonException>(() => device.ValidateLayout(device.Layout with { Inputs = [] }));
        Assert.Throws<JsonException>(() => device.ValidateLayout(device.Layout with
            { Inputs = [new("button-1", double.NaN, 0, 10, 10), .. device.Layout.Inputs.Skip(1)] }));
    }

    [Fact]
    public void BindingsRoundTripSeparatelyAndLegacyCannotReceiveThem()
    {
        var profile = new RemoteProfile { Version = 7, HardwareBindings =
            [new() { InputID = "button-1", Event = "press", Action = new() { Type = RemoteActionType.ComputerKey, Text = "space" } }] };
        var json = RemoteProfileJson.SerializeForDevice(profile, Device());
        var loaded = RemoteProfileJson.Deserialize(json);
        Assert.Empty(loaded.Pages);
        Assert.Equal("button-1", Assert.Single(loaded.HardwareBindings!).InputID);
        Assert.Equal(7, loaded.Version);
        Assert.Throws<InvalidOperationException>(() =>
            RemoteProfileJson.SerializeForDevice(profile, DeviceDescriptor.Legacy("http://device")));
    }

    [Fact]
    public void V6WireOutputRemainsV6AndDoesNotContainBindingsField()
    {
        var profile = new RemoteProfile();
        using var json = JsonDocument.Parse(RemoteProfileJson.SerializeForDevice(profile, DeviceDescriptor.Legacy("device")));
        Assert.Equal(6, json.RootElement.GetProperty("version").GetInt32());
        Assert.False(json.RootElement.TryGetProperty("hardwareBindings", out _));
    }

    [Fact]
    public void UnsupportedTouchAndProfileCapacitiesBlockWrites()
    {
        var device = Device();
        var profile = new RemoteProfile { Pages = [new() { Controls = [new()] }] };
        Assert.Throws<InvalidOperationException>(() => RemoteProfileJson.SerializeForDevice(profile, device));
        profile.Pages[0].Controls.Clear();
        Assert.Throws<InvalidOperationException>(() =>
            RemoteProfileJson.SerializeForDevice(profile, device with { Capabilities = device.Capabilities with { MaxProfileBytes = 10 } }));
    }

    [Fact]
    public void AdjustmentValidationAndSignedClampingAreDeterministic()
    {
        var device = Device();
        var binding = new HardwareBinding { InputID = "encoder-1", Event = "rotate", Mode = "relative", Step = 5,
            Action = new() { Type = RemoteActionType.WledBrightness } };
        Assert.Null(binding.Validate(device));
        Assert.Equal(65, binding.Adjust(50, 3, device.Inputs[1]));
        Assert.Equal(35, binding.Adjust(50, -3, device.Inputs[1]));
        Assert.Equal(100, binding.Adjust(95, 10000, device.Inputs[1]));
        Assert.Equal(0, binding.Adjust(5, -10000, device.Inputs[1]));
        binding.Action.Type = RemoteActionType.ComputerKey;
        Assert.NotNull(binding.Validate(device));
        binding.Action.Type = RemoteActionType.WledBrightness;
        binding.InputID = "slider-1";
        binding.Event = "change";
        binding.Mode = "absolute";
        Assert.Null(binding.Validate(device));
        Assert.Equal(50, binding.Adjust(0, 2047.5, device.Inputs[2]));
        Assert.Equal(0, binding.Adjust(0, -1, device.Inputs[2]));
        Assert.Equal(100, binding.Adjust(0, 5000, device.Inputs[2]));
    }

    [Fact]
    public async Task NativeAdapterUsesDescriptorAndExistingRemoteEndpoint()
    {
        var posts = new List<string>();
        using var client = Client(async request =>
        {
            if (request.RequestUri!.AbsolutePath == "/device") return Response(Json(Device()));
            Assert.Equal("/remote", request.RequestUri.AbsolutePath);
            if (request.Method == HttpMethod.Post)
            {
                posts.Add(await request.Content!.ReadAsStringAsync());
                return Response("""{"ok":true}""");
            }
            return Response("""{"version":7,"pages":[],"hardwareBindings":[]}""");
        });
        var adapter = await DeviceAdapters.IdentifyAsync(client, new("http://device"), "token");
        Assert.False(adapter.IsLegacy);
        await adapter.WriteProfileAsync(new(), default);
        Assert.Contains("\"version\":7", Assert.Single(posts));
        Assert.Contains("\"version\":7", await adapter.ReadProfileAsync(default));
    }

    [Theory]
    [InlineData(200, """{"ok":true}""", true)]
    [InlineData(201, """{"ok":true}""", true)]
    [InlineData(200, """{"ok":false}""", false)]
    [InlineData(200, """{"ok":"true"}""", false)]
    [InlineData(200, "{}", false)]
    [InlineData(200, "", false)]
    [InlineData(200, "{", false)]
    [InlineData(202, """{"ok":true}""", false)]
    public async Task NativeAndLegacyProfilePostsRequirePositiveAcknowledgement(int status, string body, bool accepted)
    {
        foreach (var legacy in new[] { false, true })
        {
            var posts = 0;
            using var client = Client(request =>
            {
                if (request.RequestUri!.AbsolutePath == "/device")
                    return Task.FromResult(legacy ? Response("", HttpStatusCode.NotFound) : Response(Json(Device())));
                if (request.RequestUri.AbsolutePath == "/status")
                    return Task.FromResult(Response("""{"device":"paperGIF"}"""));
                Assert.Equal("/remote", request.RequestUri.AbsolutePath);
                Assert.Equal(HttpMethod.Post, request.Method);
                posts++;
                return Task.FromResult(Response(body, (HttpStatusCode)status));
            });
            var adapter = await DeviceAdapters.IdentifyAsync(client, new("http://device"), "token");
            if (accepted) await adapter.WriteProfileAsync(new(), default);
            else await Assert.ThrowsAsync<InvalidOperationException>(() => adapter.WriteProfileAsync(new(), default));
            Assert.Equal(1, posts);
        }
    }

    [Fact]
    public async Task UnsupportedPhysicalActionErrorIsVisibleWithoutRetryingAnotherProtocol()
    {
        var posts = 0;
        using var client = Client(request =>
        {
            if (request.RequestUri!.AbsolutePath == "/device") return Task.FromResult(Response(Json(Device())));
            Assert.Equal(HttpMethod.Post, request.Method);
            posts++;
            return Task.FromResult(Response("""{"error":"unsupported_action"}""", HttpStatusCode.BadRequest));
        });
        var adapter = await DeviceAdapters.IdentifyAsync(client, new("http://device"), "");
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => adapter.WriteProfileAsync(new(), default));
        Assert.Contains("unsupported_action", error.Message);
        Assert.Equal(1, posts);
    }

    [Fact]
    public void CustomDisplayImageConversionCannotBeSilentlyAssumed()
    {
        var descriptor = DeviceDescriptor.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory,
            "Fixtures", "device-descriptor-v1-landscape.json")));
        var profile = new RemoteProfile { ButtonTexture = new() { Kind = RemoteButtonTextureKind.Image } };
        Assert.Throws<InvalidOperationException>(() => RemoteProfileJson.SerializeForDevice(profile, descriptor));
    }

    [Theory]
    [InlineData(404, """{"device":"paperGIF"}""", true)]
    [InlineData(404, """{"device":"third-party"}""", false)]
    [InlineData(500, """{"device":"paperGIF"}""", false)]
    [InlineData(401, """{"device":"paperGIF"}""", false)]
    public async Task OnlyVerified404GetsLegacyAdapter(int status, string statusJson, bool legacy)
    {
        var statusRequested = false;
        using var client = Client(request =>
        {
            if (request.RequestUri!.AbsolutePath == "/device")
                return Task.FromResult(Response("", (HttpStatusCode)status));
            statusRequested = true;
            return Task.FromResult(Response(statusJson));
        });
        if (legacy) Assert.True((await DeviceAdapters.IdentifyAsync(client, new("http://device"), "")).IsLegacy);
        else await Assert.ThrowsAsync<InvalidOperationException>(() => DeviceAdapters.IdentifyAsync(client, new("http://device"), ""));
        Assert.Equal(status == 404, statusRequested);
    }

    [Fact]
    public async Task InvalidNativeDescriptorNeverFallsBackToLegacy()
    {
        using var client = Client(request =>
        {
            Assert.Equal("/device", request.RequestUri!.AbsolutePath);
            return Task.FromResult(Response("{}"));
        });
        await Assert.ThrowsAsync<JsonException>(() => DeviceAdapters.IdentifyAsync(client, new("http://device"), ""));
    }

    [Fact]
    public async Task BoundedResponseRejectsOversize()
    {
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            DeviceAdapters.ReadBoundedAsync(new StringContent(new string('x', 100)), 10, default));
    }

    [Fact]
    public async Task CatalogExactMatchCachesAndRetainsLastValidPackageOnDigestFailure()
    {
        var cache = Path.Combine("TestResults", "boards-" + Guid.NewGuid().ToString("N"));
        var package = JsonSerializer.Serialize(new BoardPackage(1, Device().BoardID, ["1"], 1, "Reference",
            Device().Layout), DeviceDescriptor.JsonOptions);
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(package)));
        var corrupt = false;
        using var client = Client(request =>
        {
            Assert.Equal("raw.githubusercontent.com", request.RequestUri!.Host);
            return Task.FromResult(Response(request.RequestUri.AbsolutePath.EndsWith("index.json", StringComparison.Ordinal)
                ? JsonSerializer.Serialize(new BoardIndex(1, [new(Device().BoardID, ["1"], 1, "reference.json",
                    corrupt ? new string('0', 64) : digest)]), DeviceDescriptor.JsonOptions)
                : package));
        });
        try
        {
            var catalog = new BoardCatalog(client, cache);
            Assert.False(catalog.Cached(Device()).FromCache);
            Assert.Contains("Catalog layout", (await catalog.ResolveAsync(Device())).Status);
            Assert.True(catalog.Cached(Device()).FromCache);
            corrupt = true;
            var failed = await catalog.ResolveAsync(Device());
            Assert.True(failed.FromCache);
            Assert.Contains("digest mismatch", failed.Status);
            var otherRevision = Device() with { HardwareRevision = "2" };
            Assert.Contains("No exact", (await catalog.ResolveAsync(otherRevision)).Status);
            Assert.False(catalog.Cached(otherRevision).FromCache);
        }
        finally { if (Directory.Exists(cache)) Directory.Delete(cache, true); }
    }

    [Fact]
    public void BoardPackagesCannotInventInputsOrCapabilities()
    {
        var package = new BoardPackage(1, Device().BoardID, ["1"], 1, "Board",
            Device().Layout with { Inputs = [new("unknown", 0, 0, 1, 1)] });
        Assert.Throws<JsonException>(() => package.ValidateFor(Device()));
        var json = JsonNode.Parse(JsonSerializer.Serialize(package, DeviceDescriptor.JsonOptions))!.AsObject();
        json["capabilities"] = new JsonObject();
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<BoardPackage>(json.ToJsonString(), DeviceDescriptor.JsonOptions));
    }

    private static HttpResponseMessage Response(string json, HttpStatusCode status = HttpStatusCode.OK) =>
        new(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
    private static HttpClient Client(Func<HttpRequestMessage, Task<HttpResponseMessage>> responder) =>
        new(new Handler(responder));
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> responder) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return RespondAsync(request);
        }
        private async Task<HttpResponseMessage> RespondAsync(HttpRequestMessage request)
        {
            var response = await responder(request);
            response.RequestMessage ??= request;
            return response;
        }
    }
}
