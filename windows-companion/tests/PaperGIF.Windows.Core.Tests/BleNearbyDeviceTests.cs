using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using PaperGIF.Windows.Core.Ble;
using PaperGIF.Windows.Core.Models;
using Xunit;

namespace PaperGIF.Windows.Core.Tests;

public sealed class BleNearbyDeviceTests
{
    private static string Descriptor(string deviceId = "fixture:controls:001", int padding = 0)
    {
        var node = JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "device-descriptor-v1-controls.json")))!
            .AsObject();
        node["deviceID"] = deviceId;
        return node.ToJsonString() + new string(' ', padding);
    }

    /// <summary>Simulates the firmware's descriptor characteristic: offset write, then page read.</summary>
    private sealed class FakeDescriptorCharacteristic(byte[] bytes)
    {
        private uint offset;
        public List<uint> Offsets { get; } = [];
        public int Reads { get; private set; }
        public Func<int, byte[]?>? Override { get; init; }

        public Task Write(byte[] frame, CancellationToken cancellationToken)
        {
            Assert.Equal(4, frame.Length);
            offset = BitConverter.ToUInt32(frame);
            Offsets.Add(offset);
            return Task.CompletedTask;
        }

        public Task<byte[]> Read(CancellationToken cancellationToken)
        {
            var read = Reads++;
            return Task.FromResult(Override?.Invoke(read) ??
                bytes.Skip((int)Math.Min(offset, (uint)bytes.Length)).Take(512).ToArray());
        }

        public Task<string> ReadAsync() => BleDescriptorPageReader.ReadAsync(Write, Read, CancellationToken.None);
    }

    // Page reader

    [Fact]
    public async Task PageReaderReadsMultiplePagesAndReleasesLeaseWithEofRead()
    {
        var json = Descriptor(padding: 1100);
        var bytes = Encoding.UTF8.GetBytes(json);
        var characteristic = new FakeDescriptorCharacteristic(bytes);

        var text = await characteristic.ReadAsync();

        Assert.Equal(json, text);
        var pages = bytes.Length / 512 + 1;
        // Every full page, the short final page, and one extra EOF read that releases the lease.
        Assert.Equal(pages + 1, characteristic.Reads);
        Assert.Equal([.. Enumerable.Range(0, pages).Select(page => (uint)(page * 512)), (uint)bytes.Length], characteristic.Offsets);
        Assert.Equal("fixture:controls:001", DeviceDescriptor.Parse(text).DeviceID);
    }

    [Fact]
    public async Task PageReaderTreatsEmptyPageAtBoundaryAsEof()
    {
        var json = Descriptor();
        var bytes = Encoding.UTF8.GetBytes(json + new string(' ', 1024 - Encoding.UTF8.GetByteCount(json) % 512));
        Assert.Equal(0, bytes.Length % 512);
        var characteristic = new FakeDescriptorCharacteristic(bytes);

        var text = await characteristic.ReadAsync();

        Assert.Equal(bytes.Length, Encoding.UTF8.GetByteCount(text));
        Assert.Equal((uint)bytes.Length, characteristic.Offsets[^1]);
        Assert.Equal(bytes.Length / 512 + 1, characteristic.Reads);
    }

    [Fact]
    public void PageReaderStateMachineMatchesFirmwareLease()
    {
        var reader = new BleDescriptorPageReader();
        Assert.Equal(0u, reader.NextOffset);
        Assert.False(reader.Append(new byte[512]));
        Assert.Equal(512u, reader.NextOffset);
        Assert.False(reader.Append("{}"u8));
        Assert.Equal(514u, reader.NextOffset);
        Assert.Throws<InvalidOperationException>(() => reader.Json);
        Assert.True(reader.Append([]));
        Assert.True(reader.IsComplete);
        Assert.Throws<BleProtocolException>(() => reader.Append([]));
    }

    [Fact]
    public void PageReaderRejectsDataAfterShortPage()
    {
        var reader = new BleDescriptorPageReader();
        Assert.False(reader.Append("{\"a\":1}"u8));
        Assert.Throws<BleProtocolException>(() => reader.Append("x"u8));
    }

    [Fact]
    public async Task PageReaderRejectsOversizedPagesAndDescriptors()
    {
        Assert.Throws<BleProtocolException>(() => new BleDescriptorPageReader().Append(new byte[513]));

        var reader = new BleDescriptorPageReader();
        for (var page = 0; page < 128; page++) Assert.False(reader.Append(new byte[512]));
        Assert.Equal(65_536u, reader.NextOffset);
        Assert.Throws<BleProtocolException>(() => reader.Append(new byte[1]));

        var endless = new FakeDescriptorCharacteristic([]) { Override = _ => new byte[512] };
        await Assert.ThrowsAsync<BleProtocolException>(endless.ReadAsync);
        Assert.Equal(129, endless.Reads);
    }

    [Fact]
    public async Task PageReaderRejectsInvalidJsonAndUtf8()
    {
        var invalid = new FakeDescriptorCharacteristic(Encoding.UTF8.GetBytes("{\"schemaVersion\":"));
        var text = await invalid.ReadAsync();
        Assert.ThrowsAny<JsonException>(() => DeviceDescriptor.Parse(text));

        var reader = new BleDescriptorPageReader();
        reader.Append("{\"deviceID\":"u8);
        reader.Append([]);
        Assert.ThrowsAny<JsonException>(reader.Decode);

        var notUtf8 = new BleDescriptorPageReader();
        notUtf8.Append([0xFF, 0xFE]);
        notUtf8.Append([]);
        Assert.Throws<BleProtocolException>(() => notUtf8.Json);

        var empty = new BleDescriptorPageReader();
        Assert.True(empty.Append([]));
        Assert.ThrowsAny<JsonException>(empty.Decode);
    }

    [Fact]
    public async Task CodecDelegatesToPageReader()
    {
        var json = Descriptor(padding: 600);
        var characteristic = new FakeDescriptorCharacteristic(Encoding.UTF8.GetBytes(json));
        Assert.Equal(json, await BleControlCodec.ReadDescriptorAsync(characteristic.Write, characteristic.Read, CancellationToken.None));
    }

    // Nearby tracker

    private sealed class ManualTime : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = new(2026, 10, 17, 12, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => Now;
    }

    [Fact]
    public void TrackerMergesScanResponseNamesAndExpiresUnseenDevices()
    {
        var time = new ManualTime();
        var tracker = new BleNearbyDeviceTracker(time);
        var changes = 0;
        tracker.Changed += (_, _) => changes++;

        tracker.Observe(new(0xA1, null, -60, true));
        tracker.Observe(new(0xA1, "paperGIF SuperMini S3", -58, false));
        tracker.Observe(new(0xB2, "Headphones", -40, false));
        tracker.Observe(new(0xA1, null, -55, true));

        var device = Assert.Single(tracker.Devices);
        Assert.Equal((0xA1ul, "paperGIF SuperMini S3", (short)-55), (device.Address, device.Name, device.Rssi));
        Assert.Equal(2, changes);

        time.Now += TimeSpan.FromSeconds(20);
        tracker.Observe(new(0xC3, "paperGIF", -70, true));
        time.Now += TimeSpan.FromSeconds(15);
        Assert.True(tracker.Prune());
        Assert.Equal([0xC3ul], tracker.Devices.Select(item => item.Address));
        Assert.False(tracker.Prune());
    }

    [Fact]
    public void TrackerAttachesRememberedIdentity()
    {
        var tracker = new BleNearbyDeviceTracker(new ManualTime());
        tracker.Observe(new(7, "paperGIF", -50, true));
        tracker.RememberIdentity(7, "esp32s3:abc");
        Assert.Equal("esp32s3:abc", Assert.Single(tracker.Devices).DeviceId);
    }

    // Picker merge

    private static BleNearbyDevice Ble(ulong address, string name, string? id = null, int secondsAgo = 0, short rssi = -60) =>
        new(address, name, rssi, new DateTimeOffset(2026, 10, 17, 12, 0, 0, TimeSpan.Zero).AddSeconds(-secondsAgo), id);

    [Fact]
    public void MergeListsLanFirstThenBluetoothOnlyDevices()
    {
        var entries = DevicePickerMerger.Merge(
            [new("192.168.1.20", "M5Paper", "m5:1")],
            [Ble(1, "paperGIF SuperMini S3"), Ble(2, "paperGIF")]);

        Assert.Equal(
            ["M5Paper", "paperGIF (Bluetooth)", "SuperMini S3 (Bluetooth)"],
            entries.Select(entry => entry.DisplayName));
        Assert.Equal(DevicePickerSource.Lan, entries[0].Source);
        Assert.All(entries.Skip(1), entry => Assert.Equal(DevicePickerSource.Bluetooth, entry.Source));
        Assert.Equal(1ul, entries[2].Bluetooth!.Address);
    }

    [Fact]
    public void MergePrefersLanWhenBluetoothDeviceIsIdentifiedAsSameDevice()
    {
        var entries = DevicePickerMerger.Merge(
            [new("192.168.1.30", "SuperMini S3", "esp32s3:abc"), new("192.168.1.31", "Unknown controller")],
            [Ble(1, "paperGIF SuperMini S3", "esp32s3:abc"), Ble(2, "paperGIF SuperMini S3")]);

        Assert.Equal(3, entries.Count);
        Assert.Equal(DevicePickerSource.Lan, entries.Single(entry => entry.DeviceId == "esp32s3:abc").Source);
        Assert.Equal(2ul, entries.Single(entry => entry.Source == DevicePickerSource.Bluetooth).Bluetooth!.Address);
    }

    [Fact]
    public void MergeCollapsesBluetoothAddressesOfOneDeviceAndLabelsNameCollisions()
    {
        var entries = DevicePickerMerger.Merge(
            [new("10.0.0.2", "A"), new("10.0.0.2", "A duplicate")],
            [
                Ble(0x0102, "paperGIF S3", "id:1", secondsAgo: 10),
                Ble(0x0103, "paperGIF S3", "id:1", secondsAgo: 1),
                Ble(0xAABB, "paperGIF S3"),
                Ble(0xCC, ""),
            ]);

        Assert.Single(entries, entry => entry.Source == DevicePickerSource.Lan);
        var bluetooth = entries.Where(entry => entry.Source == DevicePickerSource.Bluetooth).ToList();
        Assert.Equal(3, bluetooth.Count);
        Assert.Equal(0x0103ul, bluetooth.Single(entry => entry.DeviceId == "id:1").Bluetooth!.Address);
        Assert.Contains(bluetooth, entry => entry.DisplayName == "S3 [01:03] (Bluetooth)");
        Assert.Contains(bluetooth, entry => entry.DisplayName == "S3 [AA:BB] (Bluetooth)");
        Assert.Contains(bluetooth, entry => entry.DisplayName == "PaperRemote device (Bluetooth)");
    }

    // Selection / identification

    private sealed class DescriptorLink(BleCandidate candidate, string descriptor, bool fail) : IBleDeviceLink
    {
        public BleCandidate Candidate => candidate;
        public bool IsConnected => !Disposed;
        public bool Disposed { get; private set; }
        public event EventHandler<byte[]>? NotificationReceived { add { } remove { } }
        public event EventHandler? Disconnected { add { } remove { } }
        public Task WriteControlAsync(byte[] frame, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task<string> ReadDescriptorAsync(CancellationToken cancellationToken)
        {
            if (fail) throw new BleProtocolException("Descriptor did not end.");
            var characteristic = new FakeDescriptorCharacteristic(Encoding.UTF8.GetBytes(descriptor));
            return BleControlCodec.ReadDescriptorAsync(characteristic.Write, characteristic.Read, cancellationToken);
        }

        public ValueTask DisposeAsync()
        {
            Disposed = true;
            return ValueTask.CompletedTask;
        }
    }

    private sealed class DescriptorConnector(string descriptor, bool fail = false) : IBleDeviceConnector
    {
        public List<DescriptorLink> Links { get; } = [];
        public int Scans { get; private set; }

        public Task<IReadOnlyList<BleCandidate>> ScanAsync(TimeSpan duration, CancellationToken cancellationToken)
        {
            Scans++;
            return Task.FromResult<IReadOnlyList<BleCandidate>>([.. Links.Select(link => link.Candidate).Distinct()]);
        }

        public Task<IBleDeviceLink> ConnectAsync(BleCandidate candidate, CancellationToken cancellationToken)
        {
            var link = new DescriptorLink(candidate, descriptor, fail);
            Links.Add(link);
            return Task.FromResult<IBleDeviceLink>(link);
        }
    }

    [Fact]
    public async Task IdentifyReadsDescriptorDisconnectsAndRemembersIdentity()
    {
        var connector = new DescriptorConnector(Descriptor("esp32s3:abc", padding: 700));
        var tracker = new BleNearbyDeviceTracker(new ManualTime());
        tracker.Observe(new(42, "paperGIF SuperMini S3", -50, true));
        var pool = new BleSessionPool(connector, TimeSpan.Zero);

        var descriptor = await new BleDeviceIdentifier(connector, tracker, pool)
            .IdentifyAsync(Assert.Single(tracker.Devices), CancellationToken.None);

        Assert.Equal("esp32s3:abc", descriptor.DeviceID);
        Assert.True(Assert.Single(connector.Links).Disposed);
        Assert.Equal(42ul, connector.Links[0].Candidate.Address);
        Assert.Equal("esp32s3:abc", Assert.Single(tracker.Devices).DeviceId);
        // Once identified on the LAN as well, the Bluetooth entry disappears from the picker.
        Assert.DoesNotContain(
            DevicePickerMerger.Merge([new("10.0.0.5", "SuperMini S3", "esp32s3:abc")], tracker.Devices),
            entry => entry.Source == DevicePickerSource.Bluetooth);

        await using var lease = await pool.AcquireAsync("esp32s3:abc", null, CancellationToken.None);
        Assert.Equal(42ul, lease.Session.Link.Candidate.Address);
    }

    [Fact]
    public async Task IdentifyDisconnectsWhenDescriptorIsInvalid()
    {
        var invalid = new DescriptorConnector("{\"schemaVersion\":1}");
        await Assert.ThrowsAnyAsync<JsonException>(() =>
            new BleDeviceIdentifier(invalid).IdentifyAsync(Ble(1, "paperGIF"), CancellationToken.None));
        Assert.True(Assert.Single(invalid.Links).Disposed);

        var failing = new DescriptorConnector(Descriptor(), fail: true);
        var tracker = new BleNearbyDeviceTracker(new ManualTime());
        await Assert.ThrowsAsync<BleProtocolException>(() =>
            new BleDeviceIdentifier(failing, tracker).IdentifyAsync(Ble(1, "paperGIF"), CancellationToken.None));
        Assert.True(Assert.Single(failing.Links).Disposed);
        Assert.Empty(tracker.Devices);
    }
}
