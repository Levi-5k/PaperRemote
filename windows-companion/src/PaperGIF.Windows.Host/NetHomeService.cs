using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;

namespace PaperGIF.Windows.Host;

internal sealed record NetHomeUnit(string Id, string Name);
internal readonly record struct NetHomeActionResult(bool Succeeded, bool Changed);

internal sealed class NetHomeService
{
    private const string PackageVersion = "0.10.7";
    private readonly SemaphoreSlim operationLock = new(1, 1);

    public bool IsSignedIn => LoadCredentials() is not null;
    public string? Account => LoadCredentials()?.Account;

    public async Task<IReadOnlyList<NetHomeUnit>> SignInAsync(
        string account,
        string password,
        CancellationToken cancellationToken = default)
    {
        var credentials = new NetHomeCredentials(account.Trim(), password);
        if (credentials.Account.Length == 0 || credentials.Password.Length == 0)
        {
            throw new InvalidOperationException("Enter both your NetHome account and password.");
        }
        var units = await ListUnitsAsync(credentials, cancellationToken);
        if (units.Count == 0)
        {
            throw new InvalidOperationException("The NetHome account has no supported air conditioners.");
        }
        SaveCredentials(credentials);
        return units;
    }

    public Task<IReadOnlyList<NetHomeUnit>> ListUnitsAsync(CancellationToken cancellationToken = default)
    {
        var credentials = LoadCredentials()
            ?? throw new InvalidOperationException("Connect NetHome Plus in the Windows companion first.");
        return ListUnitsAsync(credentials, cancellationToken);
    }

    public void SignOut()
    {
        if (File.Exists(CredentialsPath))
        {
            File.Delete(CredentialsPath);
        }
    }

    public NetHomeActionResult Perform(RemoteRequest request)
    {
        var credentials = LoadCredentials();
        if (credentials is null || string.IsNullOrWhiteSpace(request.Host))
        {
            return new(false, false);
        }
        var arguments = request.Type switch
        {
            "netHomePower" => new[] { "set", request.Host, "power", request.Text },
            "netHomeTemperature" => new[]
            {
                "set", request.Host, "temperature",
                (Math.Clamp(request.ValueTenths ?? request.Value * 10, 160, 300) / 10.0).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture),
            },
            "netHomeMode" => new[] { "set", request.Host, "mode", request.Text },
            "netHomeFan" => new[] { "set", request.Host, "fan", Math.Clamp(request.Value, 20, 100).ToString() },
            "netHomeClimate" => new[]
            {
                "set", request.Host, "climate", request.Text,
                (Math.Clamp(request.ValueTenths ?? 220, 160, 300) / 10.0).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture),
                Math.Clamp(request.Value, 20, 100).ToString(),
            },
            _ => [],
        };
        if (arguments.Length == 0)
        {
            return new(false, false);
        }
        try
        {
            var response = RunBridgeAsync(arguments, credentials, CancellationToken.None).GetAwaiter().GetResult();
            return new(response.Ok, response.Ok && (response.Changed ?? true));
        }
        catch
        {
            return new(false, false);
        }
    }

    private async Task<IReadOnlyList<NetHomeUnit>> ListUnitsAsync(
        NetHomeCredentials credentials,
        CancellationToken cancellationToken)
    {
        var response = await RunBridgeAsync(["list"], credentials, cancellationToken);
        if (!response.Ok)
        {
            throw new InvalidOperationException(response.Error ?? "NetHome login failed.");
        }
        return response.Devices ?? [];
    }

    private async Task<NetHomeBridgeResponse> RunBridgeAsync(
        IReadOnlyCollection<string> arguments,
        NetHomeCredentials credentials,
        CancellationToken cancellationToken)
    {
        await operationLock.WaitAsync(cancellationToken);
        try
        {
            await EnsureDependencyAsync(cancellationToken);
            var script = Path.Combine(AppContext.BaseDirectory, "net_home_bridge.py");
            if (!File.Exists(script))
            {
                throw new InvalidOperationException("The NetHome bridge resource is missing.");
            }
            var result = await RunPythonAsync([script, .. arguments], credentials, TimeSpan.FromSeconds(30), cancellationToken);
            var response = JsonSerializer.Deserialize<NetHomeBridgeResponse>(result.Output, JsonOptions)
                ?? throw new InvalidOperationException("NetHome returned an invalid response.");
            if (result.ExitCode != 0 && string.IsNullOrWhiteSpace(response.Error))
            {
                throw new InvalidOperationException(result.Error.Trim());
            }
            return response;
        }
        finally
        {
            operationLock.Release();
        }
    }

    private async Task EnsureDependencyAsync(CancellationToken cancellationToken)
    {
        if (File.Exists(Path.Combine(PythonPackagesPath, "midea_beautiful", "__init__.py")))
        {
            return;
        }
        Directory.CreateDirectory(PythonPackagesPath);
        var result = await RunPythonAsync(
            ["-m", "pip", "install", "--disable-pip-version-check", "--quiet", "--target", PythonPackagesPath,
             $"midea-beautiful-air=={PackageVersion}", "urllib3<2"],
            null,
            TimeSpan.FromMinutes(2),
            cancellationToken);
        if (result.ExitCode != 0)
        {
            throw new InvalidOperationException("Could not install NetHome support: " + result.Error.Trim());
        }
    }

    private static async Task<ProcessResult> RunPythonAsync(
        IReadOnlyCollection<string> arguments,
        NetHomeCredentials? credentials,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo("python.exe")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }
        startInfo.Environment["PYTHONPATH"] = PythonPackagesPath;
        if (credentials is not null)
        {
            startInfo.Environment["PAPERGIF_NETHOME_ACCOUNT"] = credentials.Account;
            startInfo.Environment["PAPERGIF_NETHOME_PASSWORD"] = credentials.Password;
        }
        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("Python could not be started.");
        var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);
        try
        {
            await process.WaitForExitAsync(timeoutSource.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            process.Kill(true);
            throw new TimeoutException("NetHome did not respond in time.");
        }
        return new(process.ExitCode, await outputTask, await errorTask);
    }

    private static NetHomeCredentials? LoadCredentials()
    {
        try
        {
            if (!File.Exists(CredentialsPath))
            {
                return null;
            }
            var protectedData = File.ReadAllBytes(CredentialsPath);
            var data = ProtectedData.Unprotect(protectedData, null, DataProtectionScope.CurrentUser);
            return JsonSerializer.Deserialize<NetHomeCredentials>(data, JsonOptions);
        }
        catch (CryptographicException)
        {
            return null;
        }
    }

    private static void SaveCredentials(NetHomeCredentials credentials)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(CredentialsPath)!);
        var data = JsonSerializer.SerializeToUtf8Bytes(credentials, JsonOptions);
        File.WriteAllBytes(CredentialsPath, ProtectedData.Protect(data, null, DataProtectionScope.CurrentUser));
    }

    private static string PythonPackagesPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "paperGIF", "Python");

    private static string CredentialsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "paperGIF", "nethome.credentials");

    private static JsonSerializerOptions JsonOptions { get; } = new(JsonSerializerDefaults.Web);
    private sealed record NetHomeCredentials(string Account, string Password);
    private sealed record NetHomeBridgeResponse(bool Ok, bool? Changed, string? Error, List<NetHomeUnit>? Devices);
    private sealed record ProcessResult(int ExitCode, string Output, string Error);
}