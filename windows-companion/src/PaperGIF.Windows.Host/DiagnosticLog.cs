using System.Text;

namespace PaperGIF.Windows.Host;

internal sealed record DeviceLogBatch(string DeviceName, IReadOnlyList<DeviceLogEntry> Entries);
internal sealed record DeviceLogEntry(string Timestamp, string Severity, string Message);

internal static class DiagnosticLog
{
    private const long MaximumBytes = 1_048_576;
    private static readonly object Gate = new();

    public static string DirectoryPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "paperGIF",
        "logs");

    public static void Info(string message) => AppendProgram("INFO", message);

    public static void Error(string message, Exception? exception = null) =>
        AppendProgram("ERROR", exception is null ? message : $"{message}: {exception}");

    public static void AppendDeviceBatch(DeviceLogBatch batch)
    {
        if (batch.Entries.Count > 32)
        {
            throw new InvalidDataException("A device log batch can contain at most 32 entries.");
        }
        var name = SanitizeFileComponent(batch.DeviceName);
        var receivedAt = DateTimeOffset.UtcNow.ToString("O");
        var lines = batch.Entries.Select(entry =>
            $"[{receivedAt}] [device {entry.Timestamp}] [{entry.Severity.ToUpperInvariant()}] {entry.Message}");
        Append(Path.Combine(DirectoryPath, $"device-{name}.log"), lines);
    }

    private static void AppendProgram(string level, string message)
    {
        try
        {
            Append(
                Path.Combine(DirectoryPath, "program-errors.log"),
                [$"[{DateTimeOffset.UtcNow:O}] [{level}] {message}"]);
        }
        catch
        {
            // Diagnostics must never take down the companion.
        }
    }

    private static void Append(string path, IEnumerable<string> lines)
    {
        lock (Gate)
        {
            Directory.CreateDirectory(DirectoryPath);
            if (File.Exists(path) && new FileInfo(path).Length >= MaximumBytes)
            {
                var previous = path + ".previous";
                File.Delete(previous);
                File.Move(path, previous);
            }
            File.AppendAllLines(path, lines, Encoding.UTF8);
        }
    }

    private static string SanitizeFileComponent(string value)
    {
        var sanitized = new string(value
            .Take(64)
            .Select(character => char.IsLetterOrDigit(character) || character is '-' or '_'
                ? character
                : '-')
            .ToArray())
            .Trim('-');
        return string.IsNullOrEmpty(sanitized) ? "unknown" : sanitized;
    }
}