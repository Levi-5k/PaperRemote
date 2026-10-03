using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PaperGIF.Windows.Host;

internal sealed record ReleaseAsset(string Name, string Sha256, long Size);

internal sealed record ReleaseManifest(
    string Version,
    ReleaseAsset? Mac,
    ReleaseAsset? Windows,
    ReleaseAsset? Firmware);

internal sealed record AvailableRelease(
    string Version,
    string Notes,
    ReleaseManifest Manifest,
    IReadOnlyDictionary<string, Uri> Downloads);

internal sealed class UpdateException(string message) : Exception(message);

internal static class SoftwareVersion
{
    public static int[] Components(string version)
    {
        var trimmed = version.Trim().TrimStart('v', 'V');
        return trimmed.Split('.').Select(part =>
        {
            var digits = new string(part.TakeWhile(char.IsAsciiDigit).ToArray());
            return int.TryParse(digits, out var value) ? value : 0;
        }).ToArray();
    }

    public static bool IsNewer(string candidate, string current)
    {
        var left = Components(candidate);
        var right = Components(current);
        for (var index = 0; index < Math.Max(left.Length, right.Length); index++)
        {
            var leftValue = index < left.Length ? left[index] : 0;
            var rightValue = index < right.Length ? right[index] : 0;
            if (leftValue != rightValue)
            {
                return leftValue > rightValue;
            }
        }
        return false;
    }

    public static bool AreEqual(string left, string right) =>
        !IsNewer(left, right) && !IsNewer(right, left);
}

internal sealed class UpdateService : IDisposable
{
    public const string Repository = "Levi-5k/PaperRemote";
    public const string ManifestName = "papergif-release.json";
    private const string TaskName = "paperGIF Windows Companion";
    private static readonly JsonSerializerOptions ManifestOptions = new() { PropertyNameCaseInsensitive = true };
    private readonly HttpClient github = new() { Timeout = TimeSpan.FromSeconds(60) };
    private readonly HttpClient device = new(new SocketsHttpHandler { AllowAutoRedirect = false, UseProxy = false })
    {
        Timeout = TimeSpan.FromSeconds(180),
    };

    public UpdateService()
    {
        github.DefaultRequestHeaders.UserAgent.ParseAdd("paperGIF-Windows");
        github.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
    }

    public static string CurrentVersion
    {
        get
        {
            var version = Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0, 0, 0);
            return $"{version.Major}.{version.Minor}.{Math.Max(0, version.Build)}";
        }
    }

    public async Task<AvailableRelease> LatestAsync(CancellationToken cancellationToken = default)
    {
        using var response = await github.GetAsync(
            $"https://api.github.com/repos/{Repository}/releases/latest",
            cancellationToken);
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            throw new UpdateException("No paperGIF releases have been published yet.");
        }
        if (!response.IsSuccessStatusCode)
        {
            throw new UpdateException($"Could not read the release list (HTTP {(int)response.StatusCode}).");
        }
        var (tag, notes, downloads) = ParseRelease(await response.Content.ReadAsStringAsync(cancellationToken));
        if (!downloads.TryGetValue(ManifestName, out var manifestUri))
        {
            throw new UpdateException($"The latest release is missing {ManifestName}.");
        }
        var manifest = DecodeManifest(await github.GetStringAsync(manifestUri, cancellationToken));
        if (!SoftwareVersion.AreEqual(manifest.Version, tag))
        {
            throw new UpdateException($"Release tag {tag} does not match manifest version {manifest.Version}.");
        }
        return new AvailableRelease(manifest.Version, notes, manifest, downloads);
    }

    internal static (string Tag, string Notes, Dictionary<string, Uri> Downloads) ParseRelease(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        var downloads = new Dictionary<string, Uri>(StringComparer.Ordinal);
        if (root.TryGetProperty("assets", out var assets) && assets.ValueKind == JsonValueKind.Array)
        {
            foreach (var asset in assets.EnumerateArray())
            {
                var name = asset.TryGetProperty("name", out var nameValue) ? nameValue.GetString() : null;
                var url = asset.TryGetProperty("browser_download_url", out var urlValue) ? urlValue.GetString() : null;
                if (name is not null && Uri.TryCreate(url, UriKind.Absolute, out var uri) && IsTrustedDownload(uri))
                {
                    downloads[name] = uri;
                }
            }
        }
        var tag = root.TryGetProperty("tag_name", out var tagValue) ? tagValue.GetString() ?? string.Empty : string.Empty;
        var notes = root.TryGetProperty("body", out var bodyValue) ? bodyValue.GetString() ?? string.Empty : string.Empty;
        return (tag, notes, downloads);
    }

    internal static ReleaseManifest DecodeManifest(string json)
    {
        var manifest = JsonSerializer.Deserialize<ReleaseManifest>(json, ManifestOptions)
            ?? throw new UpdateException("The release manifest is empty.");
        foreach (var asset in new[] { manifest.Mac, manifest.Windows, manifest.Firmware }.OfType<ReleaseAsset>())
        {
            if (asset.Sha256.Length != 64 || !asset.Sha256.All(Uri.IsHexDigit) || asset.Size <= 0 ||
                asset.Name.Contains('/') || asset.Name.Contains('\\'))
            {
                throw new UpdateException($"Release asset {asset.Name} has an invalid checksum or size.");
            }
        }
        return manifest;
    }

    internal static bool IsTrustedDownload(Uri uri) =>
        uri.Scheme == Uri.UriSchemeHttps && uri.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase);

    // Downloads an asset and verifies its manifest size and SHA-256 before returning the file path.
    public async Task<string> DownloadAsync(
        ReleaseAsset asset,
        AvailableRelease release,
        CancellationToken cancellationToken = default)
    {
        if (!release.Downloads.TryGetValue(asset.Name, out var uri))
        {
            throw new UpdateException($"{asset.Name} is not attached to the release.");
        }
        var path = Path.Combine(Path.GetTempPath(), $"paperGIF-{Guid.NewGuid():N}-{asset.Name}");
        try
        {
            using (var response = await github.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, cancellationToken))
            {
                response.EnsureSuccessStatusCode();
                await using var source = await response.Content.ReadAsStreamAsync(cancellationToken);
                await using var destination = File.Create(path);
                await source.CopyToAsync(destination, cancellationToken);
            }
            await using var file = File.OpenRead(path);
            var hash = Convert.ToHexString(await SHA256.HashDataAsync(file, cancellationToken));
            if (file.Length != asset.Size || !hash.Equals(asset.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                throw new UpdateException($"{asset.Name} failed its checksum and was discarded.");
            }
            return path;
        }
        catch
        {
            File.Delete(path);
            throw;
        }
    }

    public void InstallAppAndExit(string archivePath, string version, Action exit)
    {
        var staging = Path.Combine(Path.GetTempPath(), $"paperGIF-update-{Guid.NewGuid():N}");
        try
        {
            ZipFile.ExtractToDirectory(archivePath, staging);
            var stagedAssembly = Path.Combine(staging, "PaperGIF.Windows.Host.dll");
            if (!File.Exists(Path.Combine(staging, "PaperGIF.Windows.Host.exe")) || !File.Exists(stagedAssembly))
            {
                throw new UpdateException("The update archive does not contain paperGIF.");
            }
            var stagedVersion = AssemblyName.GetAssemblyName(stagedAssembly).Version?.ToString(3) ?? string.Empty;
            if (!SoftwareVersion.AreEqual(stagedVersion, version))
            {
                throw new UpdateException($"The update archive contains version {stagedVersion}, not {version}.");
            }
            var target = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            var executable = Environment.ProcessPath ?? Path.Combine(target, "PaperGIF.Windows.Host.exe");
            var script = Path.Combine(Path.GetTempPath(), $"paperGIF-updater-{Guid.NewGuid():N}.ps1");
            File.WriteAllText(script, UpdaterScript, Encoding.UTF8);
            var startInfo = new ProcessStartInfo("powershell.exe")
            {
                CreateNoWindow = true,
                UseShellExecute = false,
                WindowStyle = ProcessWindowStyle.Hidden,
            };
            foreach (var argument in new[]
            {
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", script,
                "-ProcessId", Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture),
                "-Source", staging, "-Target", target, "-Executable", executable, "-TaskName", TaskName,
            })
            {
                startInfo.ArgumentList.Add(argument);
            }
            Process.Start(startInfo)?.Dispose();
        }
        catch
        {
            if (Directory.Exists(staging))
            {
                Directory.Delete(staging, true);
            }
            throw;
        }
        finally
        {
            File.Delete(archivePath);
        }
        DiagnosticLog.Info($"Installing paperGIF Windows {version} and restarting");
        exit();
    }

    // Firmware without version reporting predates the /firmware endpoint and can only be updated over USB.
    public const string UsbOnlyFirmwareVersion = "0.0.0";

    // Returns null when unreachable.
    public async Task<string?> DeviceFirmwareVersionAsync(string address, CancellationToken cancellationToken = default)
    {
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(4));
            using var response = await device.GetAsync(DeviceUri(address, "/status"), timeout.Token);
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }
            using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync(timeout.Token));
            var root = document.RootElement;
            if (!root.TryGetProperty("device", out var deviceName) || deviceName.GetString() != "paperGIF")
            {
                return null;
            }
            return root.TryGetProperty("firmware", out var firmware)
                ? firmware.GetString() ?? UsbOnlyFirmwareVersion
                : UsbOnlyFirmwareVersion;
        }
        catch (Exception exception) when (exception is HttpRequestException or OperationCanceledException or
            JsonException or InvalidOperationException)
        {
            return null;
        }
    }

    public async Task InstallFirmwareAsync(
        string firmwarePath,
        string version,
        string address,
        string token,
        CancellationToken cancellationToken = default)
    {
        var firmware = await File.ReadAllBytesAsync(firmwarePath, cancellationToken);
        var boundary = $"paperGIF-{Guid.NewGuid():N}";
        using var request = new HttpRequestMessage(HttpMethod.Post, DeviceUri(address, "/firmware"))
        {
            Content = new ByteArrayContent(MultipartBody(firmware, boundary)),
        };
        request.Content.Headers.TryAddWithoutValidation("Content-Type", $"multipart/form-data; boundary={boundary}");
        request.Headers.Authorization = new("Bearer", token);
        request.Headers.Add("X-PGIF-Size", firmware.Length.ToString(System.Globalization.CultureInfo.InvariantCulture));
        request.Headers.Add("X-PGIF-MD5", Convert.ToHexString(MD5.HashData(firmware)).ToLowerInvariant());
        HttpResponseMessage response;
        try
        {
            response = await device.SendAsync(request, cancellationToken);
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException)
        {
            throw new UpdateException("Could not reach the M5Paper. Wake it and make sure it is on this computer's network.");
        }
        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                var detail = response.StatusCode == System.Net.HttpStatusCode.Unauthorized
                    ? "this computer is not paired with it"
                    : DeviceError(await response.Content.ReadAsStringAsync(cancellationToken)) ?? $"HTTP {(int)response.StatusCode}";
                throw new UpdateException($"The M5Paper rejected the firmware: {detail}");
            }
        }
        var deadline = DateTime.UtcNow.AddSeconds(90);
        await Task.Delay(TimeSpan.FromSeconds(4), cancellationToken);
        while (DateTime.UtcNow < deadline)
        {
            if (await DeviceFirmwareVersionAsync(address, cancellationToken) is { } installed &&
                !SoftwareVersion.IsNewer(version, installed))
            {
                return;
            }
            await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
        }
        throw new UpdateException("The firmware was sent, but the M5Paper did not come back with the new version.");
    }

    internal static byte[] MultipartBody(byte[] firmware, string boundary)
    {
        var header = Encoding.ASCII.GetBytes(
            $"--{boundary}\r\nContent-Disposition: form-data; name=\"firmware\"; filename=\"firmware.bin\"\r\n" +
            "Content-Type: application/octet-stream\r\n\r\n");
        var footer = Encoding.ASCII.GetBytes($"\r\n--{boundary}--\r\n");
        return [.. header, .. firmware, .. footer];
    }

    internal static Uri DeviceUri(string address, string path)
    {
        var trimmed = address.Trim();
        if (!trimmed.Contains("://", StringComparison.Ordinal))
        {
            trimmed = $"http://{trimmed}";
        }
        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var baseUri) || baseUri.Scheme != Uri.UriSchemeHttp)
        {
            throw new UpdateException("The M5Paper address is invalid.");
        }
        return new UriBuilder(baseUri) { Path = path, Query = string.Empty }.Uri;
    }

    public void Dispose()
    {
        github.Dispose();
        device.Dispose();
    }

    private static string? DeviceError(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            return document.RootElement.TryGetProperty("error", out var error) ? error.GetString() : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private const string UpdaterScript = """
        param([int]$ProcessId, [string]$Source, [string]$Target, [string]$Executable, [string]$TaskName)
        $ErrorActionPreference = 'Stop'
        Wait-Process -Id $ProcessId -Timeout 60 -ErrorAction SilentlyContinue
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                Copy-Item (Join-Path $Source '*') $Target -Recurse -Force
                break
            } catch {
                if ($attempt -eq 5) { throw }
                Start-Sleep -Seconds 1
            }
        }
        Remove-Item $Source -Recurse -Force -ErrorAction SilentlyContinue
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task -and $task.Actions[0].Execute -eq $Executable) {
            Start-ScheduledTask -TaskName $TaskName
        } else {
            Start-Process -FilePath $Executable -WorkingDirectory $Target
        }
        Remove-Item $PSCommandPath -Force -ErrorAction SilentlyContinue
        """;
}
