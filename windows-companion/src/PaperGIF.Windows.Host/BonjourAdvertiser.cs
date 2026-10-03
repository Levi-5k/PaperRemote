using Makaretu.Dns;

namespace PaperGIF.Windows.Host;

internal sealed class BonjourAdvertiser : IDisposable
{
    private readonly ServiceDiscovery serviceDiscovery = new();

    public BonjourAdvertiser(int port)
    {
        var profile = new ServiceProfile(
            Environment.MachineName,
            "_papergif._tcp",
            checked((ushort)port))
        {
            HostName = $"{Environment.MachineName}.local",
        };
        if (RemoteEditorStore.LocalIpv4Address() is { } host)
        {
            profile.AddProperty("host", host);
        }
        serviceDiscovery.Advertise(profile);
    }

    public void Dispose() => serviceDiscovery.Dispose();
}