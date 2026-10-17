using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Core.Ble;

/// <summary>
/// Paged descriptor lease (protocol/ble-protocol.md): write a little-endian UInt32 offset, read a page of at most
/// 512 bytes. A short page ends the JSON, but the firmware keeps an exclusive lease until one more offset write and
/// read returns an empty page (EOF). An empty page at a 512-byte boundary is also EOF.
/// Mirrors paperGIF/PaperGIFDescriptorReader.swift.
/// </summary>
public sealed class BleDescriptorPageReader
{
    private readonly MemoryStream bytes = new();
    private bool awaitingEof;

    public bool IsComplete { get; private set; }

    /// <summary>Offset to write before the next read.</summary>
    public uint NextOffset => (uint)bytes.Length;

    /// <summary>Appends one page; returns true once the lease has been released with an empty EOF page.</summary>
    public bool Append(ReadOnlySpan<byte> page)
    {
        if (IsComplete) throw new BleProtocolException("Bluetooth descriptor was already complete.");
        if (page.Length > BleProtocol.DescriptorSliceBytes || bytes.Length + page.Length > BleProtocol.MaximumMessageBytes)
            throw new BleProtocolException("Device descriptor exceeds its paging or 64 KiB size limit.");
        if (awaitingEof)
        {
            if (!page.IsEmpty) throw new BleProtocolException("Bluetooth descriptor lease must end with an empty EOF read.");
            return IsComplete = true;
        }
        if (page.IsEmpty) return IsComplete = true;
        bytes.Write(page);
        if (page.Length < BleProtocol.DescriptorSliceBytes) awaitingEof = true;
        return false;
    }

    /// <summary>The descriptor text once complete.</summary>
    public string Json => IsComplete
        ? BleControlCodec.DecodeUtf8(bytes.ToArray())
        : throw new InvalidOperationException("The descriptor has not been fully read.");

    /// <summary>Decodes and validates the descriptor; throws <see cref="System.Text.Json.JsonException"/> when invalid.</summary>
    public DeviceDescriptor Decode() => DeviceDescriptor.Parse(Json);

    /// <summary>Runs the full lease. <paramref name="write"/> must write with response; <paramref name="read"/> must read uncached.</summary>
    public static async Task<string> ReadAsync(
        Func<byte[], CancellationToken, Task> write, Func<CancellationToken, Task<byte[]>> read, CancellationToken cancellationToken)
    {
        var reader = new BleDescriptorPageReader();
        do
        {
            await write(BleControlCodec.EncodeDescriptorOffset(reader.NextOffset), cancellationToken);
        }
        while (!reader.Append(await read(cancellationToken)));
        return reader.Json;
    }
}
