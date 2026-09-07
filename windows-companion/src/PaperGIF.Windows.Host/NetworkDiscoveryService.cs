using System.Net;
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
    private readonly object gate = new();
    private readonly MulticastService multicast = new();
    private readonly ServiceDiscovery discovery;
    private readonly List<DiscoveredEndpoint> endpoints = [];

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

    public void Dispose()
    {
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