using PaperGIF.Windows.Core.Models;

namespace PaperGIF.Windows.Core;

public static class FirmwareCompatibility
{
    public static bool SupportsM5PaperUpdate(DeviceDescriptor? descriptor) =>
        descriptor is { BoardID: "m5stack.m5paper", HardwareRevision: "1.0", Capabilities.FirmwareUpdate: true };

    public static bool HasM5PaperMarker(ReadOnlySpan<byte> firmware) =>
        firmware.IndexOf("PGIFBOARD:m5stack.m5paper@1.0;"u8) >= 0;
}
