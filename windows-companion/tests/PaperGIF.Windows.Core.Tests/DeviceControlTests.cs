using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using PaperGIF.Windows.Core.Ble;
using PaperGIF.Windows.Core.Models;
using Xunit;

namespace PaperGIF.Windows.Core.Tests;

public sealed class DeviceControlTests
{
    private static string Fixture(string name) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", name));
    private static string ControlsDescriptor => Fixture("device-descriptor-v1-controls.json");

    private static string MutateDescriptor(Action<JsonObject> mutate)
    {
        var node = JsonNode.Parse(ControlsDescriptor)!.AsObject();
        mutate(node);
        return node.ToJsonString();
    }

    private static string MutateControl(int index, Action<JsonObject> mutate) =>
        MutateDescriptor(node => mutate(node["controls"]![index]!.AsObject()));

    private static DeviceControl Range(double minimum, double maximum, double step) =>
        new("level", "Level", DeviceControl.Range, Minimum: minimum, Maximum: maximum, Step: step);

    // Descriptor parsing and validation

    [Fact]
    public void ControlsFixtureParsesWithTransports()
    {
        var descriptor = DeviceDescriptor.Parse(ControlsDescriptor);
        Assert.Equal(["slideshow", "sleepDelay", "screenSaver", "battery", "restart"], descriptor.DeviceControls.Select(control => control.Id));
        var sleep = descriptor.DeviceControls[1];
        Assert.Equal((DeviceControl.Range, 30d, 3600d, 30d, "s", "Power"), (sleep.Kind, sleep.Minimum, sleep.Maximum, sleep.Step, sleep.Unit, sleep.Group));
        Assert.Equal(["media", "clock"], descriptor.DeviceControls[2].Options!.Select(option => option.Value));
        Assert.True(descriptor.DeviceControls[3].IsReadOnly);
        Assert.True(descriptor.DeviceControls[4].RequiresConfirmation);
        Assert.Equal(["http", "ble"], descriptor.EffectiveTransports());
        Assert.True(descriptor.SupportsTransport("ble"));
    }

    [Fact]
    public void ControlsAndTransportsRoundTripUnchanged()
    {
        var original = JsonNode.Parse(ControlsDescriptor)!.AsObject();
        var written = JsonSerializer.SerializeToNode(DeviceDescriptor.Parse(ControlsDescriptor), DeviceDescriptor.JsonOptions)!.AsObject();
        Assert.True(JsonNode.DeepEquals(original["controls"], written["controls"]), written["controls"]!.ToJsonString());
        Assert.True(JsonNode.DeepEquals(original["capabilities"], written["capabilities"]), written["capabilities"]!.ToJsonString());
        var reparsed = DeviceDescriptor.Parse(written.ToJsonString());
        Assert.Equal(5, reparsed.DeviceControls.Count);
    }

    [Fact]
    public void DescriptorsWithoutControlsOmitThemAndDefaultTransports()
    {
        var json = MutateDescriptor(node =>
        {
            node.Remove("controls");
            node["capabilities"]!.AsObject().Remove("transports");
        });
        var descriptor = DeviceDescriptor.Parse(json);
        Assert.Empty(descriptor.DeviceControls);
        Assert.Equal(["http"], descriptor.EffectiveTransports());
        Assert.Equal(["ble"], descriptor.EffectiveTransports("ble"));
        Assert.False(descriptor.SupportsTransport("ble"));
        var written = JsonSerializer.SerializeToNode(descriptor, DeviceDescriptor.JsonOptions)!.AsObject();
        Assert.False(written.ContainsKey("controls"));
        Assert.False(written["capabilities"]!.AsObject().ContainsKey("transports"));
    }

    public static TheoryData<string> InvalidDescriptors() => new()
    {
        MutateControl(1, control => control["id"] = "slideshow"),
        MutateControl(0, control => control["id"] = "has space"),
        MutateControl(0, control => control["id"] = ""),
        MutateControl(0, control => control["id"] = new string('a', 65)),
        MutateControl(0, control => control["kind"] = "dial"),
        MutateControl(0, control => control["name"] = ""),
        MutateControl(0, control => control["group"] = ""),
        MutateControl(0, control => control["extra"] = 1),
        MutateControl(1, control => control["minimum"] = 3600),
        MutateControl(1, control => control["minimum"] = 4000),
        MutateControl(1, control => control["step"] = 0),
        MutateControl(1, control => control["step"] = 4000),
        MutateControl(1, control => control.Remove("step")),
        MutateControl(1, control => control["unit"] = "seventeen-chars!!"),
        MutateControl(2, control => control.Remove("options")),
        MutateControl(2, control => control["options"] = new JsonArray()),
        MutateControl(2, control => control["options"] = new JsonArray(
            Enumerable.Range(0, 33).Select(index => (JsonNode)new JsonObject { ["value"] = $"v{index}", ["name"] = $"V{index}" }).ToArray())),
        MutateControl(2, control => control["options"]![1]!["value"] = "media"),
        MutateControl(2, control => control["options"]![0]!["value"] = ""),
        MutateControl(4, control => control["readOnly"] = false),
        MutateControl(4, control => control["minimum"] = 0),
        MutateControl(4, control => control["options"] = new JsonArray(new JsonObject { ["value"] = "a", ["name"] = "A" })),
        MutateDescriptor(node => node["controls"] = new JsonArray(Enumerable.Range(0, 65)
            .Select(index => (JsonNode)new JsonObject { ["id"] = $"c{index}", ["name"] = $"C{index}", ["kind"] = "toggle" }).ToArray())),
        MutateDescriptor(node => node["capabilities"]!["transports"] = new JsonArray()),
        MutateDescriptor(node => node["capabilities"]!["transports"] = new JsonArray("http", "usb")),
        MutateDescriptor(node => node["capabilities"]!["transports"] = new JsonArray("ble", "ble")),
    };

    [Theory]
    [MemberData(nameof(InvalidDescriptors))]
    public void InvalidControlsAreRejected(string json) =>
        Assert.ThrowsAny<JsonException>(() => DeviceDescriptor.Parse(json));

    [Fact]
    public void SixtyFourControlsAndThirtyTwoOptionsAreAccepted()
    {
        var json = MutateDescriptor(node =>
        {
            var controls = new JsonArray(Enumerable.Range(0, 63)
                .Select(index => (JsonNode)new JsonObject { ["id"] = $"c.{index}_-", ["name"] = $"C{index}", ["kind"] = "toggle" }).ToArray());
            controls.Add(new JsonObject
            {
                ["id"] = "mode", ["name"] = "Mode", ["kind"] = "select",
                ["options"] = new JsonArray(Enumerable.Range(0, 32)
                    .Select(index => (JsonNode)new JsonObject { ["value"] = $"v{index}", ["name"] = $"V{index}" }).ToArray()),
            });
            node["controls"] = controls;
        });
        Assert.Equal(64, DeviceDescriptor.Parse(json).DeviceControls.Count);
    }

    // Value snapping and validation

    [Theory]
    [InlineData(30, 3600, 30, 600, 600)]
    [InlineData(30, 3600, 30, 44, 30)]
    [InlineData(30, 3600, 30, 45, 60)]
    [InlineData(30, 3600, 30, -100, 30)]
    [InlineData(30, 3600, 30, 99999, 3600)]
    [InlineData(0, 10, 3, 10, 9)]
    [InlineData(0, 10, 3, 8, 9)]
    [InlineData(-1, 1, 0.1, 0.26, 0.3)]
    [InlineData(-1, 1, 0.1, -0.24, -0.2)]
    [InlineData(0.5, 2, 0.5, 1.2, 1)]
    public void RangeValuesSnapToStepFromMinimumAndClamp(double minimum, double maximum, double step, double input, double expected) =>
        Assert.Equal(expected, Range(minimum, maximum, step).Snap(input), 10);

    [Fact]
    public void NormalizeEnforcesKinds()
    {
        var controls = DeviceDescriptor.Parse(ControlsDescriptor).DeviceControls.ToDictionary(control => control.Id);
        Assert.True(controls["slideshow"].Normalize(DeviceControlJson.Value(true))!.Value.GetBoolean());
        Assert.Equal(630, controls["sleepDelay"].Normalize(DeviceControlJson.Value(620))!.Value.GetDouble());
        Assert.Equal("clock", controls["screenSaver"].Normalize(DeviceControlJson.Value("clock"))!.Value.GetString());
        Assert.Null(controls["restart"].Normalize(null));

        Assert.Equal(DeviceControlError.InvalidValue,
            Assert.Throws<DeviceControlException>(() => controls["slideshow"].Normalize(DeviceControlJson.Value(1))).Error);
        Assert.Equal(DeviceControlError.InvalidValue,
            Assert.Throws<DeviceControlException>(() => controls["sleepDelay"].Normalize(DeviceControlJson.Value("600"))).Error);
        Assert.Equal(DeviceControlError.InvalidValue,
            Assert.Throws<DeviceControlException>(() => controls["screenSaver"].Normalize(DeviceControlJson.Value("photo"))).Error);
        Assert.Equal(DeviceControlError.InvalidValue,
            Assert.Throws<DeviceControlException>(() => controls["restart"].Normalize(DeviceControlJson.Value(true))).Error);
        Assert.Equal(DeviceControlError.InvalidValue,
            Assert.Throws<DeviceControlException>(() => controls["slideshow"].Normalize(null)).Error);
        Assert.Equal(DeviceControlError.ReadOnly,
            Assert.Throws<DeviceControlException>(() => controls["battery"].Normalize(DeviceControlJson.Value(50))).Error);
        Assert.True(controls["battery"].Accepts(DeviceControlJson.Value(87)));
        Assert.False(controls["slideshow"].Accepts(DeviceControlJson.Value("yes")));
    }

    // Controls messages

    [Fact]
    public void ControlsMessageFixturesParse()
    {
        var snapshot = DeviceControlJson.ParseSnapshot(Fixture("device-controls-v1-snapshot.json"));
        Assert.Equal(900, snapshot.Values["sleepDelay"].GetDouble());
        Assert.True(snapshot.Values["slideshow"].GetBoolean());
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse(Fixture("device-controls-v1-snapshot.json")),
            JsonNode.Parse(DeviceControlJson.SerializeSnapshot(snapshot))));

        var set = DeviceControlSetRequest.Parse(Fixture("device-controls-v1-set.json"));
        Assert.Equal(("sleepDelay", 600d), (set.Id, set.Value!.Value.GetDouble()));
        Assert.Equal("{\"id\":\"sleepDelay\",\"value\":600}", set.ToJson());
        Assert.Equal("{\"id\":\"restart\"}", new DeviceControlSetRequest("restart", null).ToJson());

        var response = DeviceControlJson.ParseSetResponse(Fixture("device-controls-v1-set-response.json"));
        Assert.True(response.Ok);
        Assert.Equal(87, response.Snapshot!.Values["battery"].GetDouble());

        var relay = DeviceControlJson.ParseRelayAction(Fixture("device-controls-v1-relay.json"));
        Assert.Equal("fixture-mac", relay.ComputerId);
        Assert.Equal("macMedia", JsonNode.Parse(relay.BodyJson)!["type"]!.GetValue<string>());
    }

    [Theory]
    [InlineData("{\"ok\":true}")]
    [InlineData("{\"ok\":true,\"values\":{},\"error\":\"busy\"}")]
    [InlineData("{\"ok\":false}")]
    [InlineData("{\"ok\":false,\"error\":\"exploded\"}")]
    [InlineData("{\"ok\":\"yes\",\"values\":{}}")]
    [InlineData("{\"ok\":true,\"values\":{\"a\":[1]}}")]
    [InlineData("{\"ok\":true,\"values\":{\"bad id\":1}}")]
    [InlineData("{\"ok\":true,\"values\":{},\"more\":1}")]
    [InlineData("[]")]
    public void MalformedSetResponsesAreRejected(string json) =>
        Assert.ThrowsAny<JsonException>(() => DeviceControlJson.ParseSetResponse(json));

    [Theory]
    [InlineData("{\"values\":{},\"extra\":true}")]
    [InlineData("{}")]
    [InlineData("{\"values\":{\"a\":null}}")]
    [InlineData("{\"values\":{\"a\":1,\"a\":2}}")]
    public void MalformedSnapshotsAreRejected(string json) =>
        Assert.ThrowsAny<JsonException>(() => DeviceControlJson.ParseSnapshot(json));

    [Theory]
    [InlineData("{\"computerId\":\"x\"}")]
    [InlineData("{\"computerId\":\"x\",\"body\":[]}")]
    [InlineData("{\"computerId\":1,\"body\":{}}")]
    [InlineData("{\"computerId\":\"x\",\"body\":{},\"extra\":1}")]
    public void MalformedRelayActionsAreRejected(string json) =>
        Assert.ThrowsAny<JsonException>(() => DeviceControlJson.ParseRelayAction(json));

    // HTTP client

    private sealed class FakeHandler(Func<HttpRequestMessage, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        public List<(HttpMethod Method, Uri Uri, string? Authorization, string? Body)> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add((request.Method, request.RequestUri!, request.Headers.Authorization?.ToString(),
                request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken)));
            return await respond(request).WaitAsync(cancellationToken);
        }
    }

    private static HttpResponseMessage Json(HttpStatusCode status, string body) =>
        new(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

    private static (DeviceControlClient Client, FakeHandler Handler) Client(Func<HttpRequestMessage, Task<HttpResponseMessage>> respond,
        TimeSpan? timeout = null)
    {
        var handler = new FakeHandler(respond);
        return (new DeviceControlClient(new HttpClient(handler), new Uri("http://192.0.2.5:8080/remote"), "secret-token", timeout), handler);
    }

    [Fact]
    public async Task HttpClientReadsAndSetsWithBearerToken()
    {
        var (client, handler) = Client(request => Task.FromResult(request.Method == HttpMethod.Get
            ? Json(HttpStatusCode.OK, Fixture("device-controls-v1-snapshot.json"))
            : Json(HttpStatusCode.OK, Fixture("device-controls-v1-set-response.json"))));
        var snapshot = await client.GetSnapshotAsync(CancellationToken.None);
        Assert.Equal(900, snapshot.Values["sleepDelay"].GetDouble());
        var updated = await client.SetAsync("sleepDelay", DeviceControlJson.Value(600), CancellationToken.None);
        Assert.Equal(600, updated.Values["sleepDelay"].GetDouble());
        Assert.All(handler.Requests, request =>
        {
            Assert.Equal("http://192.0.2.5:8080/device/controls", request.Uri.ToString());
            Assert.Equal("Bearer secret-token", request.Authorization);
        });
        Assert.Equal("{\"id\":\"sleepDelay\",\"value\":600}", handler.Requests[1].Body);
    }

    [Theory]
    [InlineData(401, "{\"ok\":false,\"error\":\"unauthorized\"}", DeviceControlError.Unauthorized)]
    [InlineData(404, "{\"ok\":false,\"error\":\"unknown_control\"}", DeviceControlError.UnknownControl)]
    [InlineData(400, "{\"ok\":false,\"error\":\"invalid_value\"}", DeviceControlError.InvalidValue)]
    [InlineData(400, "{\"ok\":false,\"error\":\"read_only\"}", DeviceControlError.ReadOnly)]
    [InlineData(409, "{\"ok\":false,\"error\":\"busy\"}", DeviceControlError.Busy)]
    [InlineData(401, "", DeviceControlError.Unauthorized)]
    [InlineData(404, "not found", DeviceControlError.Unsupported)]
    [InlineData(500, "oops", DeviceControlError.Protocol)]
    [InlineData(200, "{\"ok\":true}", DeviceControlError.Protocol)]
    [InlineData(200, "{\"values\":{}}", DeviceControlError.Protocol)]
    [InlineData(200, "{\"ok\":false,\"error\":\"busy\"}", DeviceControlError.Busy)]
    [InlineData(302, "", DeviceControlError.Protocol)]
    public async Task HttpErrorsMapToDeviceErrors(int status, string body, DeviceControlError expected)
    {
        var (client, _) = Client(_ => Task.FromResult(Json((HttpStatusCode)status, body)));
        var error = await Assert.ThrowsAsync<DeviceControlException>(() =>
            client.SetAsync("sleepDelay", DeviceControlJson.Value(600), CancellationToken.None));
        Assert.Equal(expected, error.Error);
        Assert.False(error.IsTransportError);
    }

    [Fact]
    public async Task OversizedResponsesAreRejected()
    {
        var body = "{\"values\":{\"a\":\"" + new string('x', 70_000) + "\"}}";
        var (client, _) = Client(_ => Task.FromResult(Json(HttpStatusCode.OK, body)));
        var error = await Assert.ThrowsAsync<DeviceControlException>(() => client.GetSnapshotAsync(CancellationToken.None));
        Assert.Equal(DeviceControlError.Protocol, error.Error);
    }

    [Fact]
    public async Task ConnectionFailuresAndTimeoutsAreTransportErrors()
    {
        var (refused, _) = Client(_ => throw new HttpRequestException("refused"));
        Assert.True((await Assert.ThrowsAsync<DeviceControlException>(() => refused.GetSnapshotAsync(CancellationToken.None))).IsTransportError);

        var (slow, _) = Client(async _ =>
        {
            await Task.Delay(Timeout.Infinite);
            return Json(HttpStatusCode.OK, "{}");
        }, TimeSpan.FromMilliseconds(50));
        Assert.True((await Assert.ThrowsAsync<DeviceControlException>(() => slow.GetSnapshotAsync(CancellationToken.None))).IsTransportError);

        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => slow.GetSnapshotAsync(cancelled.Token));
    }

    private sealed class FakeTransport(string name, Func<DeviceControlSnapshot> result) : IDeviceControlTransport
    {
        public int Calls { get; private set; }
        public string Name => name;

        public Task<DeviceControlSnapshot> GetSnapshotAsync(CancellationToken cancellationToken)
        {
            Calls++;
            return Task.FromResult(result());
        }

        public Task<DeviceControlSnapshot> SetAsync(string id, JsonElement? value, CancellationToken cancellationToken) =>
            GetSnapshotAsync(cancellationToken);
    }

    [Fact]
    public async Task FallbackOnlyOnTransportErrors()
    {
        var ble = new FakeTransport("Bluetooth", () => DeviceControlSnapshot.Empty);
        var unreachable = new FallbackDeviceControlTransport(
            new FakeTransport("Wi-Fi", () => throw new DeviceControlException(DeviceControlError.Transport, "down")), ble);
        await unreachable.GetSnapshotAsync(CancellationToken.None);
        Assert.Equal(1, ble.Calls);
        Assert.Equal("Bluetooth", unreachable.Name);

        foreach (var rejection in new[] { DeviceControlError.Unauthorized, DeviceControlError.InvalidValue, DeviceControlError.Busy, DeviceControlError.Protocol })
        {
            var rejecting = new FallbackDeviceControlTransport(
                new FakeTransport("Wi-Fi", () => throw new DeviceControlException(rejection, "no")), ble);
            Assert.Equal(rejection, (await Assert.ThrowsAsync<DeviceControlException>(() =>
                rejecting.SetAsync("a", null, CancellationToken.None))).Error);
        }
        Assert.Equal(1, ble.Calls);
    }

    // BLE codec

    private static byte[] Frame(byte opcode, params byte[] header) => [opcode, .. header];
    private static byte[] Frame(byte opcode, byte[] header, string text) => [opcode, .. header, .. Encoding.UTF8.GetBytes(text)];

    [Fact]
    public void SnapshotFragmentsReassembleInOrder()
    {
        var json = Fixture("device-controls-v1-snapshot.json");
        var assembler = new BleSnapshotAssembler();
        Assert.Null(assembler.Append(Frame(0x51, [0], json[..20])));
        Assert.Null(assembler.Append(Frame(0x51, [0], json[20..40])));
        var snapshot = assembler.Append(Frame(0x51, [1], json[40..]));
        Assert.Equal(900, snapshot!.Values["sleepDelay"].GetDouble());
        Assert.NotNull(assembler.Append(Frame(0x51, [1], "{\"values\":{}}")));
    }

    [Fact]
    public void SnapshotAssemblerIsBounded()
    {
        var assembler = new BleSnapshotAssembler();
        var chunk = Frame(0x51, [0], new string(' ', 237));
        Assert.Throws<BleProtocolException>(() =>
        {
            for (var index = 0; index < 300; index++) assembler.Append(chunk);
        });
        Assert.NotNull(assembler.Append(Frame(0x51, [1], "{\"values\":{}}")));
        Assert.Throws<BleProtocolException>(() => assembler.Append([0x51]));
        Assert.Throws<BleProtocolException>(() => assembler.Append(Frame(0x51, [1], "{\"values\":")));
    }

    [Fact]
    public void SetRequestsFitOneWrite()
    {
        Assert.Equal(Frame(0x52, [], "{\"id\":\"sleepDelay\",\"value\":600}"),
            BleControlCodec.EncodeSetRequest(new DeviceControlSetRequest("sleepDelay", DeviceControlJson.Value(600))));
        var exactly240 = new string('x', 240 - "{\"id\":\"a\",\"value\":\"\"}".Length);
        Assert.Equal(241, BleControlCodec.EncodeSetRequest(new DeviceControlSetRequest("a", DeviceControlJson.Value(exactly240))).Length);
        Assert.Equal(DeviceControlError.InvalidValue, Assert.Throws<DeviceControlException>(() =>
            BleControlCodec.EncodeSetRequest(new DeviceControlSetRequest("a", DeviceControlJson.Value(exactly240 + "x")))).Error);
    }

    [Theory]
    [InlineData(0, null)]
    [InlineData(1, DeviceControlError.UnknownControl)]
    [InlineData(2, DeviceControlError.InvalidValue)]
    [InlineData(3, DeviceControlError.ReadOnly)]
    [InlineData(4, DeviceControlError.Busy)]
    [InlineData(9, DeviceControlError.Protocol)]
    public void SetStatusesMap(byte status, DeviceControlError? expected) =>
        Assert.Equal(expected, BleControlCodec.DecodeSetStatus([0x53, status]));

    [Fact]
    public void RelayRegistrationFramesEncodeAndDecode()
    {
        Assert.Equal(Frame(0x70, [0], "token-1"), BleControlCodec.EncodeRelayRegistration(BleRelayRole.Computer, "token-1"));
        Assert.Equal(Frame(0x70, [1], "token-1"), BleControlCodec.EncodeRelayRegistration(BleRelayRole.Forwarder, "token-1"));
        Assert.Throws<ArgumentException>(() => BleControlCodec.EncodeRelayRegistration(BleRelayRole.Computer, new string('t', 239)));
        Assert.Equal(new BleRelayRegistration(true, "fixture-mac"), BleControlCodec.DecodeRelayRegistered(Frame(0x71, [0], "fixture-mac")));
        Assert.Equal(new BleRelayRegistration(false, ""), BleControlCodec.DecodeRelayRegistered([0x71, 1]));
        Assert.Throws<BleProtocolException>(() => BleControlCodec.DecodeRelayRegistered([0x71, 2]));
        Assert.Throws<BleProtocolException>(() => BleControlCodec.DecodeRelayRegistered([0x71, 0, 0xFF]));
        Assert.Equal(new byte[] { 0x73, 7, 0 }, BleControlCodec.EncodeRelayAck(7, true));
        Assert.Equal(new byte[] { 0x73, 7, 1 }, BleControlCodec.EncodeRelayAck(7, false));
        Assert.Throws<BleProtocolException>(() => BleControlCodec.DecodeSetStatus([0x53]));
    }

    [Fact]
    public void RelayFramesReassemblePerSequence()
    {
        var json = Fixture("device-controls-v1-relay.json");
        var assembler = new BleRelayAssembler();
        Assert.Null(assembler.Append(Frame(0x72, [1, 0], json[..30])));
        Assert.Null(assembler.Append(Frame(0x72, [2, 0], json[..50])));
        var first = assembler.Append(Frame(0x72, [1, 1], json[30..]));
        Assert.Equal((byte)1, first!.Sequence);
        Assert.Equal("fixture-mac", first.Action!.ComputerId);
        var second = assembler.Append(Frame(0x72, [2, 1], json[50..]));
        Assert.Equal("playPause", JsonNode.Parse(second!.Action!.BodyJson)!["text"]!.GetValue<string>());
        Assert.Equal(0, assembler.PendingCount);

        var invalid = assembler.Append(Frame(0x72, [3, 1], "{\"computerId\":\"x\"}"));
        Assert.Equal((byte)3, invalid!.Sequence);
        Assert.Null(invalid.Action);
        Assert.NotNull(invalid.Error);
    }

    [Fact]
    public void RelayAssemblerIsBounded()
    {
        var assembler = new BleRelayAssembler();
        var chunk = Frame(0x72, [9, 0], new string(' ', 236));
        BleRelayFrameResult? result = null;
        for (var index = 0; index < 300 && result is null; index++) result = assembler.Append(chunk);
        Assert.Equal((byte)9, result!.Sequence);
        Assert.NotNull(result.Error);
        Assert.Equal(0, assembler.PendingCount);

        for (byte sequence = 0; sequence < BleRelayAssembler.MaximumPendingSequences; sequence++)
            Assert.Null(assembler.Append(Frame(0x72, [sequence, 0], "{")));
        Assert.Null(assembler.Append(Frame(0x72, [100, 0], "{")));
        Assert.NotNull(assembler.Append(Frame(0x72, [100, 1], "}"))!.Error);
    }

    [Fact]
    public async Task DescriptorReaderFollowsOffsets()
    {
        var descriptor = ControlsDescriptor + new string(' ', 1200);
        var bytes = Encoding.UTF8.GetBytes(descriptor);
        uint offset = 0;
        var offsets = new List<uint>();
        var text = await BleControlCodec.ReadDescriptorAsync(
            (frame, _) =>
            {
                offset = BitConverter.ToUInt32(frame);
                offsets.Add(offset);
                return Task.CompletedTask;
            },
            _ => Task.FromResult(bytes.Skip((int)offset).Take(512).ToArray()),
            CancellationToken.None);
        Assert.Equal(descriptor, text);
        Assert.Equal(0u, offsets[0]);
        Assert.Equal(512u, offsets[1]);
        Assert.Equal((uint)bytes.Length, offsets[^1]);
    }

    // BLE session and relay coordinator with fakes

    private sealed class FakeLink(BleCandidate candidate, string descriptor) : IBleDeviceLink
    {
        public BleCandidate Candidate => candidate;
        public bool IsConnected { get; private set; } = true;
        public bool Disposed { get; private set; }
        public List<byte[]> Writes { get; } = [];
        public Func<byte[], IEnumerable<byte[]>> Respond { get; set; } = _ => [];
        public event EventHandler<byte[]>? NotificationReceived;
        public event EventHandler? Disconnected;

        public Task WriteControlAsync(byte[] frame, CancellationToken cancellationToken)
        {
            lock (Writes) Writes.Add(frame);
            foreach (var reply in Respond(frame)) Notify(reply);
            return Task.CompletedTask;
        }

        public Task<string> ReadDescriptorAsync(CancellationToken cancellationToken) => Task.FromResult(descriptor);
        public void Notify(byte[] frame) => NotificationReceived?.Invoke(this, frame);

        public void Drop()
        {
            IsConnected = false;
            Disconnected?.Invoke(this, EventArgs.Empty);
        }

        public ValueTask DisposeAsync()
        {
            IsConnected = false;
            Disposed = true;
            return ValueTask.CompletedTask;
        }
    }

    private sealed class FakeConnector(params (BleCandidate Candidate, string DeviceId)[] devices) : IBleDeviceConnector
    {
        public List<FakeLink> Links { get; } = [];
        public Func<byte[], IEnumerable<byte[]>> Respond { get; set; } = _ => [];

        public Task<IReadOnlyList<BleCandidate>> ScanAsync(TimeSpan duration, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<BleCandidate>>(devices.Select(device => device.Candidate).ToList());

        public Task<IBleDeviceLink> ConnectAsync(BleCandidate candidate, CancellationToken cancellationToken)
        {
            var deviceId = devices.Single(device => device.Candidate == candidate).DeviceId;
            var descriptor = MutateDescriptor(node => node["deviceID"] = deviceId);
            var link = new FakeLink(candidate, descriptor) { Respond = frame => Respond(frame) };
            Links.Add(link);
            return Task.FromResult<IBleDeviceLink>(link);
        }
    }

    private static IEnumerable<byte[]> SnapshotFrames(string json) =>
    [
        Frame(0x51, [0], json[..10]),
        Frame(0x51, [1], json[10..]),
    ];

    [Fact]
    public async Task BleTransportVerifiesDeviceAndRunsSnapshotAndSet()
    {
        var connector = new FakeConnector(
            (new BleCandidate(1, "Other"), "fixture:other"),
            (new BleCandidate(2, "Controllable panel"), "fixture:controls:001"));
        connector.Respond = frame => frame[0] switch
        {
            0x50 => SnapshotFrames(Fixture("device-controls-v1-snapshot.json")),
            0x52 when frame.AsSpan(1).SequenceEqual(Encoding.UTF8.GetBytes("{\"id\":\"battery\",\"value\":1}")) => [new byte[] { 0x53, 3 }],
            0x52 => [new byte[] { 0x53, 0 }, .. SnapshotFrames("{\"values\":{\"sleepDelay\":600}}")],
            _ => [],
        };
        var pool = new BleSessionPool(connector, TimeSpan.Zero, TimeSpan.FromSeconds(2));
        await using var transport = new BleDeviceControlTransport(pool, "fixture:controls:001", "Controllable panel");
        var live = new List<DeviceControlSnapshot>();
        transport.SnapshotReceived += (_, snapshot) => live.Add(snapshot);

        var snapshot = await transport.GetSnapshotAsync(CancellationToken.None);
        Assert.Equal(900, snapshot.Values["sleepDelay"].GetDouble());
        // The connector tried the name-matching candidate first and never needed the other device.
        var link = Assert.Single(connector.Links);
        Assert.Equal(2ul, link.Candidate.Address);

        var updated = await transport.SetAsync("sleepDelay", DeviceControlJson.Value(600), CancellationToken.None);
        Assert.Equal(600, updated.Values["sleepDelay"].GetDouble());
        Assert.Equal(DeviceControlError.ReadOnly, (await Assert.ThrowsAsync<DeviceControlException>(() =>
            transport.SetAsync("battery", DeviceControlJson.Value(1), CancellationToken.None))).Error);

        link.Notify(SnapshotFrames("{\"values\":{\"slideshow\":false}}").First());
        link.Notify(SnapshotFrames("{\"values\":{\"slideshow\":false}}").Last());
        Assert.False(live[^1].Values["slideshow"].GetBoolean());

        link.Drop();
        Assert.False(transport.IsConnected);
        await transport.ReleaseAsync();
        Assert.True(link.Disposed);
    }

    [Fact]
    public async Task BleTransportReportsMissingDeviceAsTransportError()
    {
        var pool = new BleSessionPool(new FakeConnector((new BleCandidate(1, "Other"), "fixture:other")), TimeSpan.Zero);
        await using var transport = new BleDeviceControlTransport(pool, "fixture:controls:001", null);
        Assert.True((await Assert.ThrowsAsync<DeviceControlException>(() => transport.GetSnapshotAsync(CancellationToken.None))).IsTransportError);
    }

    [Fact]
    public async Task BleSetTimesOutAsTransportError()
    {
        var pool = new BleSessionPool(new FakeConnector((new BleCandidate(1, "P"), "fixture:controls:001")), TimeSpan.Zero,
            TimeSpan.FromMilliseconds(50));
        await using var transport = new BleDeviceControlTransport(pool, "fixture:controls:001", null);
        Assert.True((await Assert.ThrowsAsync<DeviceControlException>(() =>
            transport.SetAsync("restart", null, CancellationToken.None))).IsTransportError);
    }

    private sealed class ManualTime : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = new(2025, 1, 1, 0, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => Now;
    }

    [Fact]
    public async Task RelayConnectsOnlyAfterLanGraceAndDisconnectsWhenLanReturns()
    {
        var connector = new FakeConnector((new BleCandidate(7, "Controllable panel"), "fixture:controls:001"));
        connector.Respond = frame => frame[0] == 0x70 ? [Frame(0x71, [0], "fixture-mac")] : [];
        var time = new ManualTime();
        var lanUp = true;
        var executed = new List<string>();
        await using var relay = new BleRelayCoordinator(new BleSessionPool(connector, TimeSpan.Zero, TimeSpan.FromSeconds(2)),
            _ => Task.FromResult(lanUp), (body, _) =>
            {
                executed.Add(body);
                return Task.FromResult(!body.Contains("fail"));
            }, time) { GracePeriod = TimeSpan.FromSeconds(20) };
        var target = new BleRelayTarget("fixture:controls:001", "Controllable panel", "windows-token");

        await relay.TickAsync(target, CancellationToken.None);
        Assert.Equal(BleRelayState.LanReachable, relay.State);
        lanUp = false;
        await relay.TickAsync(target, CancellationToken.None);
        time.Now += TimeSpan.FromSeconds(10);
        await relay.TickAsync(target, CancellationToken.None);
        Assert.Equal(BleRelayState.WaitingForGrace, relay.State);
        Assert.Empty(connector.Links);

        time.Now += TimeSpan.FromSeconds(11);
        await relay.TickAsync(target, CancellationToken.None);
        Assert.Equal(BleRelayState.Registered, relay.State);
        var link = Assert.Single(connector.Links);
        Assert.Equal(Frame(0x70, [0], "windows-token"), link.Writes[0]);

        var deliveries = new List<BleRelayDelivery>();
        var handled = new SemaphoreSlim(0);
        relay.RelayHandled += (_, delivery) =>
        {
            lock (deliveries) deliveries.Add(delivery);
            handled.Release();
        };
        var json = Fixture("device-controls-v1-relay.json");
        link.Notify(Frame(0x72, [5, 0], json[..25]));
        link.Notify(Frame(0x72, [5, 1], json[25..]));
        link.Notify(Frame(0x72, [6, 1], "{\"computerId\":\"someone-else\",\"body\":{\"type\":\"macMedia\"}}"));
        link.Notify(Frame(0x72, [8, 1], "{\"computerId\":\"fixture-mac\",\"body\":{\"type\":\"fail\"}}"));
        for (var index = 0; index < 3; index++) Assert.True(await handled.WaitAsync(TimeSpan.FromSeconds(5)));

        Assert.Equal(2, executed.Count);
        Assert.Equal("macMedia", JsonNode.Parse(executed[0])!["type"]!.GetValue<string>());
        lock (deliveries)
        {
            Assert.True(deliveries.Single(delivery => delivery.Sequence == 5).Delivered);
            Assert.False(deliveries.Single(delivery => delivery.Sequence == 6).Delivered);
            Assert.False(deliveries.Single(delivery => delivery.Sequence == 8).Delivered);
        }
        lock (link.Writes)
        {
            Assert.Contains(link.Writes, write => write.SequenceEqual(new byte[] { 0x73, 5, 0 }));
            Assert.Contains(link.Writes, write => write.SequenceEqual(new byte[] { 0x73, 6, 1 }));
            Assert.Contains(link.Writes, write => write.SequenceEqual(new byte[] { 0x73, 8, 1 }));
        }

        await relay.TickAsync(target, CancellationToken.None);
        Assert.Single(connector.Links);
        lanUp = true;
        await relay.TickAsync(target, CancellationToken.None);
        Assert.Equal(BleRelayState.LanReachable, relay.State);
        Assert.True(link.Disposed);
        Assert.False(relay.IsRegistered);
    }

    [Fact]
    public async Task RelayBacksOffWhenTokenIsRejectedAndReconnectsAfterDrop()
    {
        var connector = new FakeConnector((new BleCandidate(7, "P"), "fixture:controls:001"));
        var accept = false;
        connector.Respond = frame => frame[0] == 0x70 ? [accept ? Frame(0x71, [0], "pc") : new byte[] { 0x71, 1 }] : [];
        var time = new ManualTime();
        await using var relay = new BleRelayCoordinator(new BleSessionPool(connector, TimeSpan.Zero, TimeSpan.FromSeconds(2)),
            _ => throw new HttpRequestException("down"), (_, _) => Task.FromResult(true), time) { GracePeriod = TimeSpan.Zero };
        var target = new BleRelayTarget("fixture:controls:001", null, "token");

        await relay.TickAsync(target, CancellationToken.None);
        Assert.Equal(BleRelayState.Rejected, relay.State);
        Assert.True(connector.Links[0].Disposed);
        await relay.TickAsync(target, CancellationToken.None);
        Assert.Single(connector.Links);

        accept = true;
        time.Now += relay.RejectedBackoff;
        await relay.TickAsync(target, CancellationToken.None);
        Assert.Equal(BleRelayState.Registered, relay.State);

        connector.Links[^1].Drop();
        Assert.False(relay.IsRegistered);
        await relay.TickAsync(target, CancellationToken.None);
        Assert.Equal(3, connector.Links.Count);
        Assert.True(relay.IsRegistered);

        await relay.TickAsync(null, CancellationToken.None);
        Assert.Equal(BleRelayState.Idle, relay.State);
        Assert.True(connector.Links[^1].Disposed);
    }
}
