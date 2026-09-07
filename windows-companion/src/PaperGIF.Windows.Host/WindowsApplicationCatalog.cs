namespace PaperGIF.Windows.Host;

internal sealed class WindowsApplicationCatalog
{
    public IReadOnlyList<InstalledApplication> GetInstalledApplications()
    {
        var roots = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.StartMenu),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu),
        };
        var applications = new Dictionary<string, InstalledApplication>(
            StringComparer.OrdinalIgnoreCase);
        foreach (var root in roots.Where(Directory.Exists))
        {
            IEnumerable<string> paths;
            try
            {
                paths = Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)
                    .Where(path => Path.GetExtension(path) is ".lnk" or ".url")
                    .ToArray();
            }
            catch (Exception exception) when (
                exception is IOException or UnauthorizedAccessException)
            {
                continue;
            }
            foreach (var path in paths)
            {
                var name = Path.GetFileNameWithoutExtension(path);
                applications.TryAdd(name, new InstalledApplication(name, path, null));
            }
        }
        return applications.Values
            .OrderBy(application => application.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
    }
}

internal sealed record InstalledApplication(string Name, string Path, string? IconBitmap);