using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace PaperGIF.Windows.Core.Models;

public sealed record DeviceControlOption(string Value, string Name);

/// <summary>A device-declared setting, sensor or command (descriptor <c>controls[]</c>).</summary>
public sealed record DeviceControl(
    string Id,
    string Name,
    string Kind,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Group = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] double? Minimum = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] double? Maximum = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] double? Step = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Unit = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] List<DeviceControlOption>? Options = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? ReadOnly = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? Confirm = null)
{
    public const string Toggle = "toggle";
    public const string Range = "range";
    public const string Select = "select";
    public const string Action = "action";
    public const int MaximumControls = 64;
    public const int MaximumOptions = 32;

    [JsonIgnore] public bool IsReadOnly => ReadOnly == true;
    [JsonIgnore] public bool RequiresConfirmation => Confirm == true;

    public static bool IsValidId(string? id) => id is not null && DeviceControlJson.IdPattern.IsMatch(id);

    public static void ValidateAll(IReadOnlyList<DeviceControl>? controls)
    {
        if (controls is null) return;
        if (controls.Count > MaximumControls)
            throw new JsonException($"A device declares at most {MaximumControls} controls.");
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var control in controls)
        {
            if (control is null) throw new JsonException("Device control entries cannot be null.");
            control.Validate();
            if (!ids.Add(control.Id)) throw new JsonException($"Duplicate device control ID '{control.Id}'.");
        }
    }

    public void Validate()
    {
        if (!IsValidId(Id)) throw new JsonException("Device control IDs must match [A-Za-z0-9._-]{1,64}.");
        if (!IsIdentity(Name)) throw new JsonException($"Device control '{Id}' has an invalid name.");
        if (Kind is not (Toggle or Range or Select or Action))
            throw new JsonException($"Device control '{Id}' has unsupported kind '{Kind}'.");
        if (Group is not null && Group.Length is < 1 or > 64)
            throw new JsonException($"Device control '{Id}' has an invalid group.");
        if (Unit is not null && Unit.Length is < 1 or > 16)
            throw new JsonException($"Device control '{Id}' has an invalid unit.");
        if (Minimum is { } min && !double.IsFinite(min) || Maximum is { } max && !double.IsFinite(max))
            throw new JsonException($"Device control '{Id}' has a non-finite range.");
        if (Step is { } step && (!double.IsFinite(step) || step <= 0))
            throw new JsonException($"Device control '{Id}' needs a positive step.");
        if (Options is not null)
        {
            if (Options.Count is < 1 or > MaximumOptions || Options.Any(option => option is null))
                throw new JsonException($"Device control '{Id}' needs 1 to {MaximumOptions} options.");
            foreach (var option in Options)
            {
                if (option.Value is not { Length: >= 1 and <= 64 } || !IsIdentity(option.Name))
                    throw new JsonException($"Device control '{Id}' has an invalid option.");
            }
            if (Options.Select(option => option.Value).Distinct(StringComparer.Ordinal).Count() != Options.Count)
                throw new JsonException($"Device control '{Id}' has duplicate option values.");
        }
        switch (Kind)
        {
            case Range:
                if (Minimum is not { } minimum || Maximum is not { } maximum || Step is not { } rangeStep)
                    throw new JsonException($"Range control '{Id}' requires minimum, maximum and step.");
                var span = maximum - minimum;
                if (minimum >= maximum || !double.IsFinite(span) || rangeStep > span)
                    throw new JsonException($"Range control '{Id}' needs minimum < maximum and 0 < step <= span.");
                break;
            case Select:
                if (Options is null) throw new JsonException($"Select control '{Id}' requires options.");
                break;
            case Action:
                if (ReadOnly is not null || Options is not null || Minimum is not null)
                    throw new JsonException($"Action control '{Id}' cannot declare readOnly, options or minimum.");
                break;
        }
    }

    internal static bool IsIdentity(string? value) =>
        value is { Length: >= 1 and <= 128 } && value.All(character => character >= 0x20 && character != 0x7F);

    /// <summary>Snaps a range value to the step grid anchored at minimum (half steps away from zero) and clamps it.</summary>
    public double Snap(double value)
    {
        if (Kind != Range || Minimum is not { } minimum || Maximum is not { } maximum || Step is not { } step)
            throw new InvalidOperationException($"Control '{Id}' is not a range.");
        if (!double.IsFinite(value)) throw new DeviceControlException(DeviceControlError.InvalidValue, "Range values must be finite.");
        var maximumSteps = Math.Floor((maximum - minimum) / step + 1e-9);
        var steps = Math.Clamp(Math.Round((value - minimum) / step, MidpointRounding.AwayFromZero), 0, maximumSteps);
        var snapped = Math.Round(minimum + steps * step, 10);
        return Math.Clamp(snapped, minimum, maximum);
    }

    /// <summary>Validates a value for a set request, snapping ranges. Returns null for actions.</summary>
    public JsonElement? Normalize(JsonElement? value)
    {
        if (IsReadOnly) throw new DeviceControlException(DeviceControlError.ReadOnly, $"'{Name}' is read-only.");
        switch (Kind)
        {
            case Action:
                if (value is { ValueKind: not (JsonValueKind.Undefined or JsonValueKind.Null) })
                    throw new DeviceControlException(DeviceControlError.InvalidValue, "Actions do not take a value.");
                return null;
            case Toggle when value is { ValueKind: JsonValueKind.True or JsonValueKind.False } flag:
                return flag;
            case Range when value is { ValueKind: JsonValueKind.Number } number && number.TryGetDouble(out var raw):
                return DeviceControlJson.Number(Snap(raw));
            case Select when value is { ValueKind: JsonValueKind.String } text &&
                Options!.Any(option => option.Value == text.GetString()):
                return text;
            default:
                throw new DeviceControlException(DeviceControlError.InvalidValue, $"Invalid value for '{Name}'.");
        }
    }

    /// <summary>True when a snapshot value has the type this control expects.</summary>
    public bool Accepts(JsonElement value) => Kind switch
    {
        Toggle => value.ValueKind is JsonValueKind.True or JsonValueKind.False,
        Range => value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number) && double.IsFinite(number),
        Select => value.ValueKind == JsonValueKind.String,
        _ => false,
    };
}

public enum DeviceControlError
{
    /// <summary>No response reached us; another transport may be tried.</summary>
    Transport,
    Unauthorized,
    UnknownControl,
    InvalidValue,
    ReadOnly,
    Busy,
    /// <summary>The device answered with a malformed or unexpected message.</summary>
    Protocol,
    Unsupported,
}

public sealed class DeviceControlException(DeviceControlError error, string message, Exception? inner = null)
    : Exception(message, inner)
{
    public DeviceControlError Error { get; } = error;
    public bool IsTransportError => Error == DeviceControlError.Transport;

    public static DeviceControlError FromWire(string? error) => error switch
    {
        "unauthorized" => DeviceControlError.Unauthorized,
        "unknown_control" => DeviceControlError.UnknownControl,
        "invalid_value" => DeviceControlError.InvalidValue,
        "read_only" => DeviceControlError.ReadOnly,
        "busy" => DeviceControlError.Busy,
        _ => DeviceControlError.Protocol,
    };

    public static string Describe(DeviceControlError error) => error switch
    {
        DeviceControlError.Transport => "Device unreachable",
        DeviceControlError.Unauthorized => "Not authorized: pair this computer with the device",
        DeviceControlError.UnknownControl => "The device does not know this control",
        DeviceControlError.InvalidValue => "The device rejected the value",
        DeviceControlError.ReadOnly => "This control is read-only",
        DeviceControlError.Busy => "The device is busy; try again",
        DeviceControlError.Unsupported => "The device does not support controls on this transport",
        _ => "The device sent an invalid controls response",
    };
}

public sealed record DeviceControlSnapshot(IReadOnlyDictionary<string, JsonElement> Values)
{
    public static DeviceControlSnapshot Empty { get; } = new(new Dictionary<string, JsonElement>(StringComparer.Ordinal));
}

public sealed record DeviceControlSetRequest(string Id, JsonElement? Value)
{
    public string ToJson()
    {
        if (!DeviceControl.IsValidId(Id)) throw new DeviceControlException(DeviceControlError.InvalidValue, "Invalid control ID.");
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WriteString("id", Id);
            if (Value is { ValueKind: not (JsonValueKind.Undefined or JsonValueKind.Null) } value)
            {
                if (value.ValueKind is not (JsonValueKind.True or JsonValueKind.False or JsonValueKind.Number or JsonValueKind.String))
                    throw new DeviceControlException(DeviceControlError.InvalidValue, "Control values are boolean, number or string.");
                writer.WritePropertyName("value");
                value.WriteTo(writer);
            }
            writer.WriteEndObject();
        }
        return Encoding.UTF8.GetString(stream.ToArray());
    }

    public static DeviceControlSetRequest Parse(string json)
    {
        using var document = DeviceControlJson.ParseObject(json);
        var root = document.RootElement;
        DeviceControlJson.RequireOnly(root, "id", "value");
        if (!root.TryGetProperty("id", out var id) || id.ValueKind != JsonValueKind.String || !DeviceControl.IsValidId(id.GetString()))
            throw new JsonException("Set request requires a valid id.");
        JsonElement? value = null;
        if (root.TryGetProperty("value", out var raw))
        {
            if (!DeviceControlJson.IsScalar(raw)) throw new JsonException("Set request value must be boolean, number or string.");
            value = raw.Clone();
        }
        return new(id.GetString()!, value);
    }
}

public sealed record DeviceControlSetResponse(bool Ok, string? Error, DeviceControlSnapshot? Snapshot);

public sealed record DeviceRelayAction(string ComputerId, string BodyJson);

public static partial class DeviceControlJson
{
    public const int MaximumMessageBytes = 65_536;

    [GeneratedRegex("^[A-Za-z0-9._-]{1,64}$", RegexOptions.CultureInvariant)]
    internal static partial Regex IdRegex();
    internal static Regex IdPattern => IdRegex();

    internal static JsonDocument ParseObject(string json)
    {
        if (Encoding.UTF8.GetByteCount(json) > MaximumMessageBytes) throw new JsonException("Controls message exceeds 64 KiB.");
        var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 32 });
        if (document.RootElement.ValueKind != JsonValueKind.Object)
        {
            document.Dispose();
            throw new JsonException("Controls message must be a JSON object.");
        }
        return document;
    }

    internal static void RequireOnly(JsonElement element, params string[] names)
    {
        foreach (var property in element.EnumerateObject())
            if (!names.Contains(property.Name, StringComparer.Ordinal))
                throw new JsonException($"Unexpected property '{property.Name}'.");
    }

    internal static bool IsScalar(JsonElement value) =>
        value.ValueKind is JsonValueKind.True or JsonValueKind.False or JsonValueKind.String ||
        value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number) && double.IsFinite(number);

    internal static JsonElement Number(double value)
    {
        using var document = JsonDocument.Parse(value.ToString("R", CultureInfo.InvariantCulture));
        return document.RootElement.Clone();
    }

    public static JsonElement Value(bool value)
    {
        using var document = JsonDocument.Parse(value ? "true" : "false");
        return document.RootElement.Clone();
    }

    public static JsonElement Value(double value) => Number(value);
    public static JsonElement Value(string value) => JsonSerializer.SerializeToElement(value);

    internal static DeviceControlSnapshot ParseValues(JsonElement values)
    {
        if (values.ValueKind != JsonValueKind.Object) throw new JsonException("Control values must be an object.");
        var result = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var property in values.EnumerateObject())
        {
            if (!DeviceControl.IsValidId(property.Name)) throw new JsonException("Invalid control ID in values.");
            if (!IsScalar(property.Value)) throw new JsonException("Control values must be boolean, number or string.");
            if (!result.TryAdd(property.Name, property.Value.Clone())) throw new JsonException("Duplicate control value.");
            if (result.Count > DeviceControl.MaximumControls) throw new JsonException("Too many control values.");
        }
        return new(result);
    }

    public static DeviceControlSnapshot ParseSnapshot(string json)
    {
        using var document = ParseObject(json);
        RequireOnly(document.RootElement, "values");
        if (!document.RootElement.TryGetProperty("values", out var values)) throw new JsonException("Snapshot requires values.");
        return ParseValues(values);
    }

    public static string SerializeSnapshot(DeviceControlSnapshot snapshot)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WritePropertyName("values");
            writer.WriteStartObject();
            foreach (var (id, value) in snapshot.Values)
            {
                writer.WritePropertyName(id);
                value.WriteTo(writer);
            }
            writer.WriteEndObject();
            writer.WriteEndObject();
        }
        return Encoding.UTF8.GetString(stream.ToArray());
    }

    public static DeviceControlSetResponse ParseSetResponse(string json)
    {
        using var document = ParseObject(json);
        var root = document.RootElement;
        RequireOnly(root, "ok", "error", "values");
        if (!root.TryGetProperty("ok", out var ok) || ok.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            throw new JsonException("Set response requires boolean ok.");
        var hasError = root.TryGetProperty("error", out var error);
        if (hasError && error.ValueKind != JsonValueKind.String) throw new JsonException("Set response error must be a string.");
        var hasValues = root.TryGetProperty("values", out var values);
        if (ok.GetBoolean())
        {
            if (!hasValues || hasError) throw new JsonException("A successful set response requires values and no error.");
            return new(true, null, ParseValues(values));
        }
        if (!hasError) throw new JsonException("A failed set response requires an error.");
        var reason = error.GetString();
        if (reason is not ("unauthorized" or "unknown_control" or "invalid_value" or "read_only" or "busy"))
            throw new JsonException("Unknown set response error.");
        return new(false, reason, hasValues ? ParseValues(values) : null);
    }

    public static DeviceRelayAction ParseRelayAction(string json)
    {
        using var document = ParseObject(json);
        var root = document.RootElement;
        RequireOnly(root, "computerId", "body");
        if (!root.TryGetProperty("computerId", out var computer) || computer.ValueKind != JsonValueKind.String ||
            computer.GetString()!.Length > 64)
            throw new JsonException("Relay action requires a computerId of at most 64 characters.");
        if (!root.TryGetProperty("body", out var body) || body.ValueKind != JsonValueKind.Object)
            throw new JsonException("Relay action requires an object body.");
        return new(computer.GetString()!, body.GetRawText());
    }
}
