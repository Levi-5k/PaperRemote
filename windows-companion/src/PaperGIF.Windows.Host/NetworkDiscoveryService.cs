using System.Buffers.Binary;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;
using Makaretu.Dns;

namespace PaperGIF.Windows.Host;

internal enum DiscoveredServiceKind
{
    M5Paper,
    Companion,
    Wled,
}

internal sealed record DiscoveredEndpoint(
    string Name,
    string Host,
    int Port,
    DiscoveredServiceKind Kind)
{
    public string DisplayName => $"{Name}  -  {KindLabel}  ({Host}:{Port})";

    private string KindLabel => Kind switch
    {
        DiscoveredServiceKind.M5Paper => "M5Paper",
        DiscoveredServiceKind.Companion => "Computer",
        DiscoveredServiceKind.Wled => "WLED",
        _ => "Device",
    };
}

internal sealed class NetworkDiscoveryService : IDisposable
{
    private static readonly DomainName CompanionService = new("_papergif._tcp");
    private static readonly DomainName DeviceService = new("_papergif-device._tcp");
    private static readonly DomainName WledService = new("_wled._tcp");
    private const int MaximumConcurrentProbes = 64;
    private const int MaximumSweepHosts = 1_024;
    private static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(2);
    private static readonly HttpClient ProbeClient = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        ConnectTimeout = TimeSpan.FromSeconds(1.5),
        UseProxy = false,
    })
    {
        MaxResponseContentBufferSize = 4_096,
        Timeout = Timeout.InfiniteTimeSpan,
    };
    private readonly object gate = new();
    private readonly MulticastService multicast = new();
    private readonly ServiceDiscovery discovery;
    private readonly List<DiscoveredEndpoint> endpoints = [];
    private readonly HashSet<string> probedDeviceHosts = new(StringComparer.OrdinalIgnoreCase);
    private CancellationTokenSource? scanCancellation;

    public NetworkDiscoveryService()
    {
        discovery = new ServiceDiscovery(multicast) { AnswersContainsAdditionalRecords = true };
        multicast.NetworkInterfaceDiscovered += HandleNetworkInterfaceDiscovered;
        discovery.ServiceInstanceDiscovered += HandleServiceInstanceDiscovered;
        discovery.ServiceInstanceShutdown += HandleServiceInstanceShutdown;
        multicast.Start();
    }

    public event EventHandler? Changed;

    public IReadOnlyList<DiscoveredEndpoint> Endpoints
    {
        get
        {
            lock (gate)
            {
                return endpoints.ToArray();
            }
        }
    }

    public void Scan()
    {
        discovery.QueryServiceInstances(CompanionService);
        discovery.QueryServiceInstances(DeviceService);
        discovery.QueryServiceInstances(WledService);
    }

    public bool IsScanning
    {
        get
        {
            lock (gate)
            {
                return scanCancellation is not null;
            }
        }
    }

    // Re-queries mDNS and probes the saved address plus local subnets for a paperGIF /status reply.
    public async Task ScanDevicesAsync(string? preferredAddress)
    {
        var cancellation = new CancellationTokenSource();
        lock (gate)
        {
            scanCancellation?.Cancel();
            scanCancellation = cancellation;
        }
        Changed?.Invoke(this, EventArgs.Empty);
        Scan();
        IReadOnlyList<DiscoveredEndpoint> found;
        try
        {
            found = await ProbeNetworkAsync(preferredAddress, cancellation.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        lock (gate)
        {
            if (scanCancellation != cancellation)
            {
                return;
            }
            scanCancellation = null;
            endpoints.RemoveAll(endpoint =>
                endpoint.Kind == DiscoveredServiceKind.M5Paper &&
                probedDeviceHosts.Contains(endpoint.Host) &&
                !found.Any(device => device.Host.Equals(endpoint.Host, StringComparison.OrdinalIgnoreCase)));
            probedDeviceHosts.Clear();
            foreach (var device in found)
            {
                if (endpoints.Any(endpoint =>
                    endpoint.Kind == DiscoveredServiceKind.M5Paper &&
                    endpoint.Host.Equals(device.Host, StringComparison.OrdinalIgnoreCase)))
                {
                    continue;
                }
                endpoints.Add(device);
                probedDeviceHosts.Add(device.Host);
            }
            endpoints.Sort((left, right) => string.Compare(left.DisplayName, right.DisplayName, StringComparison.CurrentCultureIgnoreCase));
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    internal static bool IsPaperGifStatus(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            return document.RootElement.ValueKind == JsonValueKind.Object &&
                document.RootElement.TryGetProperty("device", out var device) &&
                device.ValueKind == JsonValueKind.String &&
                device.GetString() == "paperGIF";
        }
        catch (JsonException)
        {
            return false;
        }
    }

    // Limits wide subnets to the /24 surrounding the interface address.
    internal static IEnumerable<IPAddress> SweepHosts(IPAddress address, IPAddress netmask)
    {
        var host = BinaryPrimitives.ReadUInt32BigEndian(address.GetAddressBytes());
        var mask = BinaryPrimitives.ReadUInt32BigEndian(netmask.GetAddressBytes()) | 0xFFFF_FF00;
        var network = host & mask;
        var broadcast = network | ~mask;
        if (broadcast - network < 2)
        {
            yield break;
        }
        for (var candidate = network + 1; candidate < broadcast; candidate++)
        {
            if (candidate == host)
            {
                continue;
            }
            var bytes = new byte[4];
            BinaryPrimitives.WriteUInt32BigEndian(bytes, candidate);
            yield return new IPAddress(bytes);
        }
    }

    private static async Task<IReadOnlyList<DiscoveredEndpoint>> ProbeNetworkAsync(
        string? preferredAddress,
        CancellationToken cancellationToken)
    {
        var candidates = new List<IPAddress>();
        if (await PreferredAddressAsync(preferredAddress, cancellationToken).ConfigureAwait(false) is { } preferred)
        {
            candidates.Add(preferred);
        }
        foreach (var host in LocalSweepHosts())
        {
            if (!candidates.Contains(host))
            {
                candidates.Add(host);
            }
        }
        using var limiter = new SemaphoreSlim(MaximumConcurrentProbes);
        var probes = candidates.Select(async candidate =>
        {
            await limiter.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                return await ProbeAsync(candidate, cancellationToken).ConfigureAwait(false)
                    ? new DiscoveredEndpoint($"M5Paper {candidate}", candidate.ToString(), 80, DiscoveredServiceKind.M5Paper)
                    : null;
            }
            finally
            {
                limiter.Release();
            }
        });
        var results = await Task.WhenAll(probes).ConfigureAwait(false);
        return results.OfType<DiscoveredEndpoint>().ToArray();
    }

    private static async Task<IPAddress?> PreferredAddressAsync(string? address, CancellationToken cancellationToken)
    {
        var trimmed = address?.Trim() ?? string.Empty;
        if (trimmed.Length == 0)
        {
            return null;
        }
        if (!trimmed.Contains("://", StringComparison.Ordinal))
        {
            trimmed = $"http://{trimmed}";
        }
        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host))
        {
            return null;
        }
        if (IPAddress.TryParse(uri.Host, out var literal))
        {
            return literal.AddressFamily == AddressFamily.InterNetwork ? literal : null;
        }
        try
        {
            var resolved = await Dns.GetHostAddressesAsync(uri.Host, AddressFamily.InterNetwork, cancellationToken)
                .ConfigureAwait(false);
            return resolved.FirstOrDefault();
        }
        catch (SocketException)
        {
            return null;
        }
    }

    private static IEnumerable<IPAddress> LocalSweepHosts()
    {
        var interfaces = NetworkInterface.GetAllNetworkInterfaces()
            .Where(network => network.OperationalStatus == OperationalStatus.Up &&
                network.NetworkInterfaceType is not (NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel or NetworkInterfaceType.Ppp))
            .Select(network => network.GetIPProperties())
            .OrderByDescending(properties => properties.GatewayAddresses.Any(gateway =>
                gateway.Address.AddressFamily == AddressFamily.InterNetwork &&
                !gateway.Address.Equals(IPAddress.Any)));
        return interfaces
            .SelectMany(properties => properties.UnicastAddresses)
            .Where(unicast => unicast.Address.AddressFamily == AddressFamily.InterNetwork &&
                unicast.IPv4Mask is not null &&
                !IPAddress.IsLoopback(unicast.Address) &&
                !unicast.Address.GetAddressBytes().Take(2).SequenceEqual(new byte[] { 169, 254 }))
            .SelectMany(unicast => SweepHosts(unicast.Address, unicast.IPv4Mask))
            .Distinct()
            .Take(MaximumSweepHosts)
            .ToArray();
    }

    private static async Task<bool> ProbeAsync(IPAddress address, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(ProbeTimeout);
        try
        {
            var uri = new UriBuilder(Uri.UriSchemeHttp, address.ToString(), 80, "/status").Uri;
            using var response = await ProbeClient.GetAsync(uri, timeout.Token).ConfigureAwait(false);
            return response.IsSuccessStatusCode &&
                IsPaperGifStatus(await response.Content.ReadAsStringAsync(timeout.Token).ConfigureAwait(false));
        }
        catch (HttpRequestException)
        {
            return false;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return false;
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            scanCancellation?.Cancel();
            scanCancellation = null;
        }
        multicast.NetworkInterfaceDiscovered -= HandleNetworkInterfaceDiscovered;
        discovery.ServiceInstanceDiscovered -= HandleServiceInstanceDiscovered;
        discovery.ServiceInstanceShutdown -= HandleServiceInstanceShutdown;
        discovery.Dispose();
        multicast.Stop();
        multicast.Dispose();
    }

    private void HandleNetworkInterfaceDiscovered(object? sender, NetworkInterfaceEventArgs eventArgs) => Scan();

    private void HandleServiceInstanceDiscovered(object? sender, ServiceInstanceDiscoveryEventArgs eventArgs)
    {
        var instanceName = eventArgs.ServiceInstanceName.ToString();
        var kind = KindFromName(instanceName);
        if (kind is null)
        {
            return;
        }
        var records = eventArgs.Message.Answers.Concat(eventArgs.Message.AdditionalRecords).ToArray();
        var service = records.OfType<SRVRecord>()
            .FirstOrDefault(record => record.Name == eventArgs.ServiceInstanceName);
        if (service is null)
        {
            multicast.SendQuery(eventArgs.ServiceInstanceName, type: DnsType.SRV);
            return;
        }
        var address = records.OfType<ARecord>()
            .FirstOrDefault(record => record.Name == service.Target)
            ?.Address;
        var host = address?.ToString() ?? service.Target.ToString().TrimEnd('.');
        var name = instanceName.Split('.')[0];
        var endpoint = new DiscoveredEndpoint(name, host, service.Port, kind.Value);
        lock (gate)
        {
            endpoints.RemoveAll(candidate =>
                candidate.Kind == endpoint.Kind &&
                (candidate.Name.Equals(endpoint.Name, StringComparison.OrdinalIgnoreCase) ||
                 candidate.Host.Equals(endpoint.Host, StringComparison.OrdinalIgnoreCase)));
            endpoints.Add(endpoint);
            if (endpoint.Kind == DiscoveredServiceKind.M5Paper)
            {
                probedDeviceHosts.Remove(endpoint.Host);
            }
            endpoints.Sort((left, right) => string.Compare(left.DisplayName, right.DisplayName, StringComparison.CurrentCultureIgnoreCase));
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void HandleServiceInstanceShutdown(object? sender, ServiceInstanceShutdownEventArgs eventArgs)
    {
        var name = eventArgs.ServiceInstanceName.ToString().Split('.')[0];
        lock (gate)
        {
            endpoints.RemoveAll(endpoint => endpoint.Name.Equals(name, StringComparison.OrdinalIgnoreCase));
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private static DiscoveredServiceKind? KindFromName(string name)
    {
        if (name.Contains("._papergif-device._tcp.", StringComparison.OrdinalIgnoreCase))
        {
            return DiscoveredServiceKind.M5Paper;
        }
        if (name.Contains("._papergif._tcp.", StringComparison.OrdinalIgnoreCase))
        {
            return DiscoveredServiceKind.Companion;
        }
        if (name.Contains("._wled._tcp.", StringComparison.OrdinalIgnoreCase))
        {
            return DiscoveredServiceKind.Wled;
        }
        return null;
    }
}