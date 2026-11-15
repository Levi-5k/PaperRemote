using System.Buffers.Binary;
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace PaperGIF.Windows.Core;

public sealed class DeviceImageClient(HttpClient client, Uri baseUri, string token)
{
    public async Task UploadButtonAsync(byte[] bytes, Guid id, CancellationToken cancellationToken = default)
    {
        if (bytes.Length is < 10 or > 329738 || !bytes.AsSpan(0, 4).SequenceEqual("PBGI"u8) ||
            bytes[4] is not (1 or 2) || bytes[5] != 0 || id == Guid.Empty || string.IsNullOrWhiteSpace(token))
            throw new InvalidOperationException("Invalid button image upload.");
        var width = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(6));
        var height = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(8));
        if (width is < 1 or > 540 || height is < 1 or > 540 ||
            bytes.Length != 10 + width * height * (bytes[4] == 2 ? 2 : 1))
            throw new InvalidOperationException("Invalid button image dimensions.");
        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(baseUri, "/images"));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.ConnectionClose = true;
        request.Headers.Add("X-Image-ID", id.ToString("D"));
        request.Headers.Add("X-Image-Kind", "button");
        request.Headers.Add("X-Image-Name", "Button image");
        request.Headers.Add("X-Image-CRC32", Checksum(bytes).ToString("X8"));
        request.Content = new ByteArrayContent(bytes);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        response.EnsureSuccessStatusCode();
        if (response.StatusCode is not (HttpStatusCode.OK or HttpStatusCode.Created))
            throw new InvalidOperationException("Device did not acknowledge image installation.");
        using var json = JsonDocument.Parse(await DeviceAdapters.ReadBoundedAsync(response.Content, 4096, cancellationToken));
        if (json.RootElement.ValueKind != JsonValueKind.Object ||
            !json.RootElement.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True ||
            !json.RootElement.TryGetProperty("id", out var installed) || installed.ValueKind != JsonValueKind.String ||
            !Guid.TryParse(installed.GetString(), out var installedId) || installedId != id)
            throw new InvalidOperationException("Device acknowledged a different or invalid image.");
    }

    public static uint Checksum(ReadOnlySpan<byte> bytes)
    {
        var checksum = uint.MaxValue;
        foreach (var value in bytes)
        {
            checksum ^= value;
            for (var bit = 0; bit < 8; bit++)
                checksum = (checksum >> 1) ^ ((checksum & 1) == 0 ? 0 : 0xEDB88320u);
        }
        return ~checksum;
    }
}