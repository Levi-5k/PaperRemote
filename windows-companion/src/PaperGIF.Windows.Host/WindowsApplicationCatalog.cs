using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Microsoft.CSharp.RuntimeBinder;

namespace PaperGIF.Windows.Host;

internal sealed partial class WindowsApplicationCatalog
{
    private readonly object cacheLock = new();
    private (DateTime LoadedAt, IReadOnlyList<InstalledApplication> Applications)? cache;

    // Rendering every shortcut icon is slow, and each editor inspector asks again.
    public IReadOnlyList<InstalledApplication> GetInstalledApplications()
    {
        lock (cacheLock)
        {
            if (cache is { } cached && DateTime.UtcNow - cached.LoadedAt < TimeSpan.FromSeconds(60))
            {
                return cached.Applications;
            }
            var applications = ScanInstalledApplications();
            cache = (DateTime.UtcNow, applications);
            return applications;
        }
    }

    private static IReadOnlyList<InstalledApplication> ScanInstalledApplications()
    {
        var roots = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.StartMenu),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu),
        };
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            MatchCasing = MatchCasing.CaseInsensitive,
        };
        Dictionary<string, InstalledApplication> applications = [with(StringComparer.OrdinalIgnoreCase)];
        foreach (var root in roots.Where(Directory.Exists))
        {
            foreach (var path in Directory.EnumerateFiles(root, "*", options))
            {
                var extension = Path.GetExtension(path);
                var isShortcut = extension.Equals(".lnk", StringComparison.OrdinalIgnoreCase);
                if (!isShortcut && !(extension.Equals(".url", StringComparison.OrdinalIgnoreCase) && !IsWebLink(path)))
                {
                    continue;
                }
                var name = Path.GetFileNameWithoutExtension(path);
                if (NonApplicationName().IsMatch(name) || applications.ContainsKey(name))
                {
                    continue;
                }
                applications[name] = new InstalledApplication(name, path, MonochromeIconBitmap(path));
            }
        }
        foreach (var application in PackagedApplications())
        {
            applications.TryAdd(application.Name, application);
        }
        return applications.Values
            .OrderBy(application => application.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
    }

    [GeneratedRegex(@"^(uninstall|remove)\b|\b(readme|read me|help|documentation|manual|license|website|web site|release notes|changelog)\b",
        RegexOptions.IgnoreCase)]
    private static partial Regex NonApplicationName();

    // Internet shortcuts to web pages are not apps; launcher links such as steam:// are kept.
    private static bool IsWebLink(string path)
    {
        try
        {
            var target = File.ReadLines(path)
                .FirstOrDefault(line => line.StartsWith("URL=", StringComparison.OrdinalIgnoreCase))?[4..].Trim();
            return target is null ||
                target.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
                target.StartsWith("https://", StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return true;
        }
    }

    // Store apps have no Start Menu shortcut; shell:AppsFolder\<AUMID> launches them through ShellExecute.
    private static IReadOnlyList<InstalledApplication> PackagedApplications()
    {
        var applications = new List<InstalledApplication>();
        var thread = new Thread(() =>
        {
            try
            {
                var shellType = Type.GetTypeFromProgID("Shell.Application");
                if (shellType is null)
                {
                    return;
                }
                dynamic shell = Activator.CreateInstance(shellType)!;
                dynamic folder = shell.NameSpace("shell:AppsFolder");
                foreach (dynamic item in folder.Items())
                {
                    string name = item.Name;
                    string identifier = item.Path;
                    if (identifier.Contains('!') && !NonApplicationName().IsMatch(name))
                    {
                        applications.Add(new InstalledApplication(name, $@"shell:AppsFolder\{identifier}", null));
                    }
                }
            }
            catch (Exception exception) when (exception is COMException or RuntimeBinderException or InvalidCastException)
            {
                DiagnosticLog.Info($"Could not list Store apps: {exception.Message}");
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join(TimeSpan.FromSeconds(10));
        return thread.IsAlive ? [] : applications;
    }

    // Same 64x64 ordered-dither encoding the Mac companion uses for app icons.
    private static string? MonochromeIconBitmap(string path)
    {
        const int dimension = 64;
        try
        {
            using var icon = Icon.ExtractAssociatedIcon(path);
            if (icon is null)
            {
                return null;
            }
            using var source = icon.ToBitmap();
            using var canvas = new Bitmap(dimension, dimension);
            using (var graphics = Graphics.FromImage(canvas))
            {
                graphics.Clear(Color.White);
                graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                graphics.DrawImage(source, new Rectangle(0, 0, dimension, dimension));
            }
            byte[] thresholds = [8, 136, 40, 168, 200, 72, 232, 104, 56, 184, 24, 152, 248, 120, 216, 88];
            var bitmap = new byte[dimension * dimension / 8];
            for (var y = 0; y < dimension; y++)
            {
                for (var x = 0; x < dimension; x++)
                {
                    var pixel = canvas.GetPixel(x, y);
                    var gray = (pixel.R * 299 + pixel.G * 587 + pixel.B * 114) / 1000;
                    if (gray < thresholds[(y % 4) * 4 + x % 4])
                    {
                        bitmap[y * dimension / 8 + x / 8] |= (byte)(0x80 >> (x % 8));
                    }
                }
            }
            return Convert.ToHexString(bitmap);
        }
        catch (Exception exception) when (exception is ArgumentException or IOException or ExternalException)
        {
            return null;
        }
    }
}

internal sealed record InstalledApplication(string Name, string Path, string? IconBitmap);