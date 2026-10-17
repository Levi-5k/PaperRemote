using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Buffers.Binary;

namespace PaperGIF.Windows.Core.Models;

public sealed record DeviceRect(double X, double Y, double Width, double Height);
public sealed record DeviceInputGeometry(string Id, double X, double Y, double Width, double Height);
public sealed record DeviceLayout(double Width, double Height, DeviceRect? Screen = null, List<DeviceInputGeometry> Inputs = null!,
    [property: JsonPropertyName("artworkPNG"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? ArtworkPNG = null)
{
    public byte[]? DecodeArtwork()
    {
        if (ArtworkPNG is null) return null;
        if (ArtworkPNG.Length > 60_000)
            throw new JsonException("Board artwork exceeds 60,000 base64 characters.");
        byte[] data;
        try { data = Convert.FromBase64String(ArtworkPNG); }
        catch (FormatException exception) { throw new JsonException("Board artwork is not base64 PNG data.", exception); }
        if (Convert.ToBase64String(data) != ArtworkPNG ||
            data.Length < 33 || !data.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }) ||
            BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(8, 4)) != 13 ||
            !data.AsSpan(12, 4).SequenceEqual("IHDR"u8) ||
            BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(16, 4)) is < 1 or > 2048 ||
            BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(20, 4)) is < 1 or > 2048)
            throw new JsonException("Board artwork must be a PNG up to 2048 pixels per side.");
        var hasImageData = false;
        for (var offset = 8; offset <= data.Length - 12;)
        {
            var length = BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(offset, 4));
            if (length > data.Length - offset - 12)
                throw new JsonException("Board artwork has a truncated PNG chunk.");
            var type = data.AsSpan(offset + 4, 4);
            if (type.SequenceEqual("acTL"u8))
                throw new JsonException("Board artwork must not be animated.");
            hasImageData |= type.SequenceEqual("IDAT"u8) && length > 0;
            offset += (int)length + 12;
            if (type.SequenceEqual("IEND"u8))
            {
                if (length == 0 && hasImageData && offset == data.Length) return data;
                break;
            }
        }
        throw new JsonException("Board artwork is not a complete single-frame PNG.");
    }

    public static DeviceLayout Generated(DeviceDisplay? display, IReadOnlyList<DeviceInput> inputs)
    {
        if (inputs.Count > 128 || inputs.Any(input => input is null) ||
            display is { } dimensions && (dimensions.Width < 1 || dimensions.Height < 1))
            throw new JsonException("Invalid display/input data for generated layout.");
        var columns = Math.Max(1, Math.Min(4, inputs.Count));
        var rows = (inputs.Count + columns - 1) / columns;
        var screenHeight = display is null ? 0d : 240d;
        DeviceRect? screen = null;
        if (display is not null)
        {
            var scale = Math.Min(288d / display.Width, 208d / display.Height);
            var width = display.Width * scale;
            var height = display.Height * scale;
            screen = new((320 - width) / 2, 16, width, height);
        }
        return new(320, Math.Max(100, screenHeight + rows * 72 + 32), screen,
            inputs.Select((input, index) => new DeviceInputGeometry(input.Id,
                16 + index % columns * 72, screenHeight + 16 + index / columns * 72, 56, 56)).ToList());
    }
}
public sealed record DeviceDisplay(int Width, int Height, bool Touch, string PixelFormat, int Rotation);
public sealed record DeviceInput(string Id, string Name, string Kind, List<string> Events,
    double? Minimum = null, double? Maximum = null);
public sealed record DeviceCapabilities(List<int> ProfileVersions, bool Media, bool FirmwareUpdate,
    int MaxProfileBytes, int MaxControls, int MaxPages,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] List<string>? Transports = null);
public sealed record DeviceDescriptor(
    int SchemaVersion, int ProtocolVersion,
    [property: JsonPropertyName("deviceID")] string DeviceID,
    string Name, string Manufacturer,
    [property: JsonPropertyName("boardID")] string BoardID,
    string HardwareRevision, string FirmwareVersion, DeviceDisplay? Display,
    List<DeviceInput> Inputs, DeviceLayout Layout, DeviceCapabilities Capabilities,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] List<DeviceControl>? Controls = null)
{
    /// <summary>Device-declared controls; empty when the descriptor omits <c>controls</c>.</summary>
    [JsonIgnore] public IReadOnlyList<DeviceControl> DeviceControls => Controls ?? [];

    /// <summary>Advertised transports, or the identifying transport when <c>capabilities.transports</c> is absent.</summary>
    public IReadOnlyList<string> EffectiveTransports(string identifiedOver = "http") =>
        Capabilities.Transports is { Count: > 0 } transports ? transports : [identifiedOver];

    public bool SupportsTransport(string transport, string identifiedOver = "http") =>
        EffectiveTransports(identifiedOver).Contains(transport, StringComparer.Ordinal);

    public static JsonSerializerOptions JsonOptions { get; } = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        RespectRequiredConstructorParameters = true,
    };

    public static DeviceDescriptor Parse(string json)
    {
        if (System.Text.Encoding.UTF8.GetByteCount(json) > 65_536)
            throw new JsonException("Device descriptor exceeds 64 KiB.");
        using var document = JsonDocument.Parse(json);
        if (document.RootElement.ValueKind != JsonValueKind.Object)
            throw new JsonException("Device descriptor must be an object.");
        if (!document.RootElement.TryGetProperty("layout", out _))
        {
            if (!document.RootElement.TryGetProperty("display", out var displayElement) ||
                !document.RootElement.TryGetProperty("inputs", out var inputsElement) ||
                inputsElement.ValueKind != JsonValueKind.Array || inputsElement.GetArrayLength() > 128)
                throw new JsonException("Descriptor requires explicit display and bounded inputs.");
            var display = displayElement.Deserialize<DeviceDisplay>(JsonOptions);
            var inputs = inputsElement.Deserialize<List<DeviceInput>>(JsonOptions)
                ?? throw new JsonException("Descriptor inputs are missing.");
            var node = JsonNode.Parse(json)!.AsObject();
            node["layout"] = JsonSerializer.SerializeToNode(DeviceLayout.Generated(display, inputs), JsonOptions);
            json = node.ToJsonString();
        }
        var descriptor = JsonSerializer.Deserialize<DeviceDescriptor>(json, JsonOptions)
            ?? throw new JsonException("Device descriptor is empty.");
        descriptor.Validate();
        return descriptor;
    }

    public void Validate()
    {
        if (SchemaVersion != 1 || ProtocolVersion != 1)
            throw new JsonException("Unsupported device descriptor/protocol version.");
        if (new[] { DeviceID, Name, Manufacturer, BoardID, HardwareRevision, FirmwareVersion }
            .Any(value => string.IsNullOrWhiteSpace(value) || value.Length > 256))
            throw new JsonException("Device identity is missing or too long.");
        if (Capabilities is not { ProfileVersions.Count: > 0 } capabilities ||
            capabilities.ProfileVersions.Any(version => version is not (6 or 7)) ||
            capabilities.ProfileVersions.Distinct().Count() != capabilities.ProfileVersions.Count ||
            capabilities.MaxProfileBytes is < 1 or > 1_048_576 ||
            capabilities.MaxControls is < 0 or > 512 || capabilities.MaxPages is < 1 or > 64)
            throw new JsonException("Invalid device capacities.");
        if (capabilities.Transports is { } transportList &&
            (transportList.Count == 0 || transportList.Any(transport => transport is not ("http" or "ble")) ||
             transportList.Distinct(StringComparer.Ordinal).Count() != transportList.Count))
            throw new JsonException("Invalid device transports.");
        DeviceControl.ValidateAll(Controls);
        if (Display is { } display &&
            (display.Width is < 1 or > 4096 || display.Height is < 1 or > 4096 ||
             (long)display.Width * display.Height > 8_388_608 ||
             display.Rotation is not (0 or 90 or 180 or 270) ||
             display.PixelFormat is not ("mono1" or "gray4" or "rgb565")))
            throw new JsonException("Invalid display.");
        if (Display is null && capabilities.Media)
            throw new JsonException("Screenless devices cannot advertise display media.");
        if (Inputs is null || Inputs.Count > 128 || Inputs.Any(input => input is null) ||
            Inputs.Select(input => input.Id).Distinct(StringComparer.Ordinal).Count() != Inputs.Count)
            throw new JsonException("Invalid or duplicate input IDs.");
        foreach (var input in Inputs)
        {
            if (string.IsNullOrWhiteSpace(input.Id) || input.Id.Length > 128 ||
                string.IsNullOrWhiteSpace(input.Name) || input.Name.Length > 256 ||
                input.Kind is not ("button" or "encoder" or "dial" or "slider") ||
                input.Events is not { Count: > 0 } || input.Events.Count > 5 ||
                input.Events.Distinct(StringComparer.Ordinal).Count() != input.Events.Count ||
                input.Events.Any(value => value is not ("press" or "hold" or "release" or "rotate" or "change")) ||
                input.Minimum.HasValue != input.Maximum.HasValue ||
                input.Minimum is { } min && (!double.IsFinite(min) ||
                    input.Maximum is not { } max || !double.IsFinite(max) || min >= max))
                throw new JsonException("Invalid physical input.");
            if (input.Events.Contains("rotate") && input.Kind != "encoder" ||
                input.Events.Contains("change") && input.Kind is not ("dial" or "slider"))
                throw new JsonException("Input kind does not support its events.");
        }
        ValidateLayout(Layout);
    }

    public void ValidateLayout(DeviceLayout layout)
    {
        static bool Positive(double value) => double.IsFinite(value) && value > 0 && value <= 100_000;
        if (layout is null || !Positive(layout.Width) || !Positive(layout.Height) ||
            layout.Inputs is null || layout.Inputs.Any(input => input is null) || layout.Inputs.Count != Inputs.Count ||
            layout.Inputs.Select(input => input.Id).Distinct(StringComparer.Ordinal).Count() != Inputs.Count ||
            layout.Inputs.Any(input => !Inputs.Any(known => known.Id == input.Id)))
            throw new JsonException("Layout must describe exactly the device inputs.");
        _ = layout.DecodeArtwork();
        bool Inside(double x, double y, double width, double height) =>
            double.IsFinite(x) && double.IsFinite(y) && x >= 0 && y >= 0 &&
            Positive(width) && Positive(height) && x + width <= layout.Width && y + height <= layout.Height;
        if (layout.Inputs.Any(input => !Inside(input.X, input.Y, input.Width, input.Height)) ||
            (Display is null) != (layout.Screen is null) ||
            layout.Screen is { } screen && !Inside(screen.X, screen.Y, screen.Width, screen.Height))
            throw new JsonException("Layout geometry lies outside the board.");
    }

    public static DeviceDescriptor Legacy(string endpoint) => new(
        1, 1, $"legacy:{endpoint}", "M5Paper (legacy)", "M5Stack", "m5stack.m5paper", "1.0", "legacy",
        new(540, 960, true, "gray4", 0), [],
        new(540, 960, new(0, 0, 540, 960), []), new([6], true, true, 262_144, 24, 8));
}

public sealed record BoardPackage(int SchemaVersion,
    [property: JsonPropertyName("boardID")] string BoardID,
    List<string> HardwareRevisions, int Version, string Name, DeviceLayout Layout)
{
    public void ValidateFor(DeviceDescriptor device)
    {
        if (SchemaVersion != 1 || Version < 1 || BoardID != device.BoardID ||
            HardwareRevisions is null || !HardwareRevisions.Contains(device.HardwareRevision, StringComparer.Ordinal) ||
            string.IsNullOrWhiteSpace(Name) || Name.Length > 256)
            throw new JsonException("Board package does not match this exact board and revision.");
        device.ValidateLayout(Layout);
    }
}
