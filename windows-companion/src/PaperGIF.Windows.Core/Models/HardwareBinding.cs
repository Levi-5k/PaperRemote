using System.Text.Json.Serialization;

namespace PaperGIF.Windows.Core.Models;

public sealed class HardwareBinding
{
    [JsonPropertyName("inputID")]
    public string InputID { get; set; } = string.Empty;
    public string Event { get; set; } = "press";
    public string Mode { get; set; } = "action";
    public string? Direction { get; set; }
    public RemoteAction Action { get; set; } = new();
    public double Minimum { get; set; }
    public double Maximum { get; set; } = 100;
    public double Step { get; set; } = 1;

    public string? Validate(DeviceDescriptor device)
    {
        if (ValidateShape() is { } error) return error;
        var input = device.Inputs.FirstOrDefault(input => input.Id == InputID);
        if (input is null || !input.Events.Contains(Event, StringComparer.Ordinal))
            return "Binding refers to an unavailable input/event.";
        if (Action.Type == RemoteActionType.OpenBuilds &&
            Action.Text.StartsWith("continuous", StringComparison.Ordinal))
            return "Continuous jogging is not supported by hardware bindings.";
        if (Mode == "absolute" && input.Minimum is null)
            return "Absolute inputs require a reported source range.";
        return null;
    }

    public string? ValidateShape()
    {
        if (string.IsNullOrWhiteSpace(InputID) || InputID.Length > 128 ||
            Event is not ("press" or "hold" or "release" or "rotate" or "change") ||
            Mode is not ("action" or "relative" or "absolute") ||
            Action is null || !Enum.IsDefined(Action.Type))
            return "Binding needs a supported input ID, event, mode and action.";
        if (Direction is not null &&
            (Direction is not ("negative" or "positive") || Event != "rotate" || Mode != "action"))
            return "Direction is negative/positive only for action-mode rotate; omit it for both directions.";
        if (!double.IsFinite(Minimum) || !double.IsFinite(Maximum) || !double.IsFinite(Step) ||
            Minimum >= Maximum || Minimum < int.MinValue || Maximum > int.MaxValue ||
            Step <= 0 || Step > Maximum - Minimum)
            return "Binding needs a valid range and step.";
        if (Mode == "relative" && Event != "rotate" || Mode == "absolute" && Event != "change" ||
            Mode == "action" && Event == "change")
            return "Binding mode is incompatible with its event.";
        if (Mode != "action")
        {
            if (!AcceptsValue(Action))
                return "This action cannot accept hardware value adjustments.";
            var (minimum, maximum) = Action.Type switch
            {
                RemoteActionType.WledBrightness => (0d, 255d),
                RemoteActionType.NetHomeTemperature => (-3276.8, 3276.7),
                _ => (0d, 100d),
            };
            if (Minimum < minimum || Maximum > maximum)
                return $"This hardware action requires an output range within {minimum} to {maximum}.";
        }
        return null;
    }

    public static bool AcceptsValue(RemoteAction action) =>
        action.Type is RemoteActionType.WledBrightness or RemoteActionType.NetHomeTemperature ||
        action.Type is RemoteActionType.ComputerMedia or RemoteActionType.IPhoneMedia && action.Text == "volume";

    public int Adjust(double current, double value, DeviceInput input)
    {
        if (!double.IsFinite(current) || !double.IsFinite(value))
            throw new ArgumentException("Hardware values must be finite.");
        var adjusted = Mode switch
        {
            "relative" => current + Math.Clamp(value, -100, 100) * Step,
            "absolute" when input.Minimum is { } min && input.Maximum is { } max && max > min =>
                Minimum + Math.Clamp((value - min) / (max - min), 0, 1) * (Maximum - Minimum),
            _ => throw new InvalidOperationException("Binding is not an adjustment."),
        };
        var snapped = Minimum + Math.Round((adjusted - Minimum) / Step, MidpointRounding.AwayFromZero) * Step;
        return checked((int)Math.Round(Math.Clamp(snapped, Minimum, Maximum), MidpointRounding.AwayFromZero));
    }
}
