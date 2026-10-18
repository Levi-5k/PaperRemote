using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace PaperGIF.Windows.Core;

/// <summary>One low-latency dial value a device sends over UDP to the companion's action port.</summary>
public sealed record DialStreamDatagram(uint Boot, uint Seq, string ActionJson)
{
    public const int MaximumSize = 2048;

    public static DialStreamDatagram? Parse(ReadOnlySpan<byte> data, string token)
    {
        if (data.Length > MaximumSize || string.IsNullOrEmpty(token)) return null;
        try
        {
            using var document = JsonDocument.Parse(data.ToArray());
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("type", out var type) || type.ValueKind != JsonValueKind.String ||
                type.GetString() != "paperGIF.dialStream" ||
                !root.TryGetProperty("version", out var version) || !version.TryGetInt32(out var v) || v != 1 ||
                !root.TryGetProperty("boot", out var boot) || !boot.TryGetUInt32(out var bootValue) ||
                !root.TryGetProperty("seq", out var seq) || !seq.TryGetUInt32(out var seqValue) ||
                !root.TryGetProperty("token", out var supplied) || supplied.ValueKind != JsonValueKind.String ||
                !root.TryGetProperty("action", out var action) || action.ValueKind != JsonValueKind.Object)
            {
                return null;
            }
            var suppliedBytes = Encoding.UTF8.GetBytes(supplied.GetString() ?? string.Empty);
            var expectedBytes = Encoding.UTF8.GetBytes(token);
            if (suppliedBytes.Length != expectedBytes.Length ||
                !CryptographicOperations.FixedTimeEquals(suppliedBytes, expectedBytes))
            {
                return null;
            }
            return new DialStreamDatagram(bootValue, seqValue, action.GetRawText());
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// <summary>Drops duplicate and out-of-order datagrams per sender; a new boot ID restarts the sequence.</summary>
public sealed class DialStreamOrdering
{
    private readonly Dictionary<string, (uint Boot, uint Seq)> latest = [];

    public bool Accept(string sender, uint boot, uint seq)
    {
        if (latest.TryGetValue(sender, out var previous) && previous.Boot == boot)
        {
            var advance = unchecked(seq - previous.Seq);
            if (advance == 0 || advance > uint.MaxValue / 2) return false;
        }
        latest[sender] = (boot, seq);
        return true;
    }
}

/// <summary>
/// Keeps only the newest pending value per key, so a slow action (such as a system volume change)
/// never builds a backlog of stale dial positions.
/// </summary>
public sealed class LatestValueQueue<T>
{
    private readonly object gate = new();
    private readonly Dictionary<string, T> pending = [];
    private readonly Queue<string> order = new();

    /// <summary>Stores <paramref name="value"/>; returns true when the key was not already waiting.</summary>
    public bool Offer(string key, T value)
    {
        lock (gate)
        {
            var added = !pending.ContainsKey(key);
            pending[key] = value;
            if (added) order.Enqueue(key);
            return added;
        }
    }

    public bool TryTake(out T value)
    {
        lock (gate)
        {
            while (order.TryDequeue(out var key))
            {
                if (pending.Remove(key, out value!)) return true;
            }
            value = default!;
            return false;
        }
    }
}
