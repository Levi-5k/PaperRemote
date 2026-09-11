namespace PaperGIF.Windows.Host;

internal sealed class PairingRequest
{
    public string DeviceName { get; set; } = string.Empty;
}

internal sealed class RemoteRequest
{
    public string Type { get; set; } = string.Empty;
    public string? Host { get; set; }
    public string Text { get; set; } = string.Empty;
    public int Value { get; set; }
    public int? ValueTenths { get; set; }
    public List<string> Modifiers { get; set; } = [];
}

internal readonly record struct RemoteActionResult(bool Succeeded, bool Changed);

internal sealed class TextSourceBatchRequest
{
    public List<TextSourceRequest> Items { get; set; } = [];
}

internal sealed class TextSourceRequest
{
    public string Id { get; set; } = string.Empty;
    public string Source { get; set; } = string.Empty;
    public string SourceText { get; set; } = string.Empty;
    public string Placeholder { get; set; } = string.Empty;
}

internal sealed record TextSourceBatchResponse(IReadOnlyList<TextSourceResponse> Items);

internal sealed record TextSourceResponse(
    string Id,
    string Text,
    bool Available,
    int? Value = null,
    long? ElapsedMilliseconds = null,
    long? DurationMilliseconds = null,
    bool? Playing = null);