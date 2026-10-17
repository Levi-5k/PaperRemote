using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Core.Ble;

/// <summary>GATT identifiers and opcodes from protocol/ble-protocol.md and protocol/device-protocol.md.</summary>
public static class BleProtocol
{
    public static readonly Guid ServiceUuid = Guid.Parse("7A230001-7D2A-4C7B-9C42-504749460001");
    public static readonly Guid ControlCharacteristicUuid = Guid.Parse("7A230002-7D2A-4C7B-9C42-504749460001");
    public static readonly Guid DescriptorCharacteristicUuid = Guid.Parse("7A230004-7D2A-4C7B-9C42-504749460001");

    public const byte SnapshotRequest = 0x50;
    public const byte SnapshotFragment = 0x51;
    public const byte SetRequest = 0x52;
    public const byte SetStatus = 0x53;
    public const byte RelayRegister = 0x70;
    public const byte RelayRegistered = 0x71;
    public const byte RelayFrame = 0x72;
    public const byte RelayAck = 0x73;

    public const int MaximumWriteBytes = 240;
    public const int MaximumMessageBytes = 65_536;
    public const int DescriptorSliceBytes = 512;
}

public enum BleRelayRole : byte { Computer = 0, Forwarder = 1 }

public sealed record BleRelayRegistration(bool Registered, string ComputerId);

public sealed class BleProtocolException(string message) : Exception(message);

/// <summary>Pure encoders/decoders for device-control and relay frames.</summary>
public static class BleControlCodec
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public static byte[] EncodeSnapshotRequest() => [BleProtocol.SnapshotRequest];

    /// <summary>0x52 followed by the set-request JSON; the JSON alone may be at most 240 bytes.</summary>
    public static byte[] EncodeSetRequest(DeviceControlSetRequest request)
    {
        var json = Encoding.UTF8.GetBytes(request.ToJson());
        if (json.Length > BleProtocol.MaximumWriteBytes)
            throw new DeviceControlException(DeviceControlError.InvalidValue,
                $"Set request is {json.Length} bytes; BLE allows at most {BleProtocol.MaximumWriteBytes}.");
        return [BleProtocol.SetRequest, .. json];
    }

    /// <summary>Maps a 0x53 status frame; null on success, otherwise the device error.</summary>
    public static DeviceControlError? DecodeSetStatus(ReadOnlySpan<byte> frame)
    {
        if (frame.Length != 2 || frame[0] != BleProtocol.SetStatus) throw new BleProtocolException("Malformed set status frame.");
        return frame[1] switch
        {
            0 => null,
            1 => DeviceControlError.UnknownControl,
            2 => DeviceControlError.InvalidValue,
            3 => DeviceControlError.ReadOnly,
            4 => DeviceControlError.Busy,
            _ => DeviceControlError.Protocol,
        };
    }

    public static byte[] EncodeRelayRegistration(BleRelayRole role, string token)
    {
        if (string.IsNullOrEmpty(token)) throw new ArgumentException("A pairing token is required.", nameof(token));
        if (role is not (BleRelayRole.Computer or BleRelayRole.Forwarder)) throw new ArgumentOutOfRangeException(nameof(role));
        var bytes = Encoding.UTF8.GetBytes(token);
        if (bytes.Length + 2 > BleProtocol.MaximumWriteBytes) throw new ArgumentException("Pairing token is too long for BLE.", nameof(token));
        return [BleProtocol.RelayRegister, (byte)role, .. bytes];
    }

    public static BleRelayRegistration DecodeRelayRegistered(ReadOnlySpan<byte> frame)
    {
        if (frame.Length < 2 || frame[0] != BleProtocol.RelayRegistered || frame[1] > 1)
            throw new BleProtocolException("Malformed relay registration frame.");
        var computerId = DecodeUtf8(frame[2..].ToArray());
        if (computerId.Length > 64) throw new BleProtocolException("Relay computer ID is too long.");
        return new(frame[1] == 0, computerId);
    }

    public static byte[] EncodeRelayAck(byte sequence, bool delivered) =>
        [BleProtocol.RelayAck, sequence, delivered ? (byte)0 : (byte)1];

    public static byte[] EncodeDescriptorOffset(uint offset)
    {
        var bytes = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, offset);
        return bytes;
    }

    internal static string DecodeUtf8(byte[] bytes)
    {
        try { return StrictUtf8.GetString(bytes); }
        catch (DecoderFallbackException) { throw new BleProtocolException("BLE message is not valid UTF-8."); }
    }

    /// <summary>
    /// Reads the descriptor characteristic with the offset/page lease (see <see cref="BleDescriptorPageReader"/>).
    /// <paramref name="write"/> must write with response; <paramref name="read"/> must read uncached.
    /// </summary>
    public static Task<string> ReadDescriptorAsync(
        Func<byte[], CancellationToken, Task> write, Func<CancellationToken, Task<byte[]>> read, CancellationToken cancellationToken) =>
        BleDescriptorPageReader.ReadAsync(write, read, cancellationToken);
}

/// <summary>Reassembles 0x51 snapshot fragments: <c>[0x51, flags, fragment...]</c>, flags bit 0 = final.</summary>
public sealed class BleSnapshotAssembler
{
    private readonly MemoryStream buffer = new();

    /// <summary>Returns the snapshot when the final fragment arrives, otherwise null.</summary>
    public DeviceControlSnapshot? Append(ReadOnlySpan<byte> frame)
    {
        if (frame.Length < 2 || frame[0] != BleProtocol.SnapshotFragment)
            throw new BleProtocolException("Malformed snapshot fragment.");
        if (buffer.Length + frame.Length - 2 > BleProtocol.MaximumMessageBytes)
        {
            Reset();
            throw new BleProtocolException("Controls snapshot exceeds 64 KiB.");
        }
        buffer.Write(frame[2..]);
        if ((frame[1] & 1) == 0) return null;
        var bytes = buffer.ToArray();
        Reset();
        try { return DeviceControlJson.ParseSnapshot(BleControlCodec.DecodeUtf8(bytes)); }
        catch (JsonException exception) { throw new BleProtocolException($"Invalid controls snapshot: {exception.Message}"); }
    }

    public void Reset() => buffer.SetLength(0);
}

public sealed record BleRelayFrameResult(byte Sequence, DeviceRelayAction? Action, string? Error);

/// <summary>Reassembles 0x72 relay frames per sequence: <c>[0x72, sequence, flags, fragment...]</c>.</summary>
public sealed class BleRelayAssembler
{
    public const int MaximumPendingSequences = 8;
    private readonly Dictionary<byte, MemoryStream> pending = [];

    /// <summary>Returns a result when a sequence completes (or fails); null while more fragments are expected.</summary>
    public BleRelayFrameResult? Append(ReadOnlySpan<byte> frame)
    {
        if (frame.Length < 3 || frame[0] != BleProtocol.RelayFrame) throw new BleProtocolException("Malformed relay frame.");
        var sequence = frame[1];
        if (!pending.TryGetValue(sequence, out var buffer))
        {
            // Reject once, on the final fragment, so the device receives a single failed ack.
            if (pending.Count >= MaximumPendingSequences)
                return (frame[2] & 1) != 0 ? new(sequence, null, "Too many concurrent relay messages.") : null;
            pending[sequence] = buffer = new MemoryStream();
        }
        if (buffer.Length + frame.Length - 3 > BleProtocol.MaximumMessageBytes)
        {
            Drop(sequence);
            return new(sequence, null, "Relay message exceeds 64 KiB.");
        }
        buffer.Write(frame[3..]);
        if ((frame[2] & 1) == 0) return null;
        var bytes = buffer.ToArray();
        Drop(sequence);
        try { return new(sequence, DeviceControlJson.ParseRelayAction(BleControlCodec.DecodeUtf8(bytes)), null); }
        catch (Exception exception) when (exception is JsonException or BleProtocolException)
        {
            return new(sequence, null, $"Invalid relay message: {exception.Message}");
        }
    }

    public int PendingCount => pending.Count;

    public void Reset()
    {
        foreach (var buffer in pending.Values) buffer.Dispose();
        pending.Clear();
    }

    private void Drop(byte sequence)
    {
        if (pending.Remove(sequence, out var buffer)) buffer.Dispose();
    }
}
