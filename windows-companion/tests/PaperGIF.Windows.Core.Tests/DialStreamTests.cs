using System.Text;
using System.Text.Json;
using Xunit;

namespace PaperGIF.Windows.Core.Tests;

public sealed class DialStreamTests
{
    private static byte[] Datagram(string token = "secret", long seq = 1, string type = "paperGIF.dialStream") =>
        Encoding.UTF8.GetBytes(
            $"{{\"type\":\"{type}\",\"version\":1,\"boot\":7,\"seq\":{seq},\"token\":\"{token}\"," +
            "\"action\":{\"type\":\"windowsMedia\",\"text\":\"volume\",\"value\":128,\"modifiers\":[]}}");

    [Fact]
    public void ParsesAuthorizedDatagram()
    {
        var parsed = DialStreamDatagram.Parse(Datagram(), "secret");
        Assert.NotNull(parsed);
        Assert.Equal(7u, parsed.Boot);
        Assert.Equal(1u, parsed.Seq);
        using var action = JsonDocument.Parse(parsed.ActionJson);
        Assert.Equal(128, action.RootElement.GetProperty("value").GetInt32());
    }

    [Fact]
    public void RejectsWrongTokenTypeOrMalformedDatagrams()
    {
        Assert.Null(DialStreamDatagram.Parse(Datagram(token: "nope"), "secret"));
        Assert.Null(DialStreamDatagram.Parse(Datagram(), ""));
        Assert.Null(DialStreamDatagram.Parse(Datagram(type: "other"), "secret"));
        Assert.Null(DialStreamDatagram.Parse(Datagram(seq: -1), "secret"));
        Assert.Null(DialStreamDatagram.Parse(Encoding.UTF8.GetBytes("{"), "secret"));
        Assert.Null(DialStreamDatagram.Parse(new byte[4096], "secret"));
    }

    [Fact]
    public void OrderingDropsStaleValuesAndResetsOnReboot()
    {
        var ordering = new DialStreamOrdering();
        Assert.True(ordering.Accept("a", 1, 10));
        Assert.False(ordering.Accept("a", 1, 10));
        Assert.False(ordering.Accept("a", 1, 9));
        Assert.True(ordering.Accept("a", 1, 12));
        Assert.True(ordering.Accept("b", 1, 1));
        Assert.True(ordering.Accept("a", 2, 1));
        Assert.True(ordering.Accept("w", 1, uint.MaxValue));
        Assert.True(ordering.Accept("w", 1, 0));
    }

    [Fact]
    public void LatestValueQueueKeepsOnlyNewestPerKey()
    {
        var queue = new LatestValueQueue<int>();
        Assert.True(queue.Offer("volume", 1));
        Assert.False(queue.Offer("volume", 2));
        Assert.True(queue.Offer("seek", 5));
        Assert.True(queue.TryTake(out var first));
        Assert.Equal(2, first);
        Assert.True(queue.TryTake(out var second));
        Assert.Equal(5, second);
        Assert.False(queue.TryTake(out _));
    }
}
