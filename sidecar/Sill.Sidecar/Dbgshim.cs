using System.IO.Compression;

namespace Sill.Sidecar;

/// <summary>dbgshim, the native library the debug adapter starts and attaches to .NET processes with (M8): Microsoft's
/// package for this Mac, the newest stable on nuget.org, downloaded on the person's machine into a cache per version (the
/// app carries no native code), and offline the newest cached.</summary>
public static class Dbgshim
{
    public const string Library = "libdbgshim.dylib";

    public static async Task<DbgshimLibrary> Ensure(DbgshimParams asked, Action<RoslynProgress> progress, CancellationToken cancel)
    {
        string rid = asked.Rid.ToLowerInvariant();
        string id = "microsoft.diagnostics.dbgshim." + rid;
        string feed = asked.Feed ?? Roslyn.DefaultFeed;
        Directory.CreateDirectory(asked.CacheDirectory);
        string? latest;
        try
        {
            List<string> versions = [.. await Roslyn.Versions(feed, id, cancel)];
            latest = Roslyn.Newest(versions.Where(v => !v.Contains('-'))) ?? Roslyn.Newest(versions);
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or IOException)
        {
            latest = Roslyn.Newest(Directory.GetDirectories(asked.CacheDirectory).Select(Path.GetFileName).OfType<string>()
                .Where(v => File.Exists(Path.Combine(asked.CacheDirectory, v, Library))));
            return latest is null
                ? throw new InvalidOperationException($"dbgshim is not cached and the feed did not answer: {error.Message}")
                : new DbgshimLibrary(Path.Combine(asked.CacheDirectory, latest, Library), latest, false);
        }
        if (latest is null)
        {
            throw new InvalidOperationException($"the feed has no {id}");
        }
        string library = Path.Combine(asked.CacheDirectory, latest, Library);
        if (File.Exists(library))
        {
            return new DbgshimLibrary(library, latest, false);
        }
        string package = Path.Combine(asked.CacheDirectory, $"{latest}.nupkg.part");
        await Roslyn.Download(feed, id, latest, package, progress, cancel);
        string entryName = $"runtimes/{rid}/native/{Library}";
        string staging = Path.Combine(asked.CacheDirectory, $"{latest}.part");
        Directory.CreateDirectory(staging);
        using (ZipArchive zip = ZipFile.OpenRead(package))
        {
            ZipArchiveEntry entry = zip.Entries.FirstOrDefault(e => e.FullName.Replace('\\', '/').Equals(entryName, StringComparison.OrdinalIgnoreCase))
                ?? throw new InvalidOperationException($"the package has no {entryName}");
            entry.ExtractToFile(Path.Combine(staging, Library), true);
        }
        File.Delete(package);
        string final = Path.Combine(asked.CacheDirectory, latest);
        if (Directory.Exists(final))
        {
            Directory.Delete(final, true);
        }
        Directory.Move(staging, final);
        return new DbgshimLibrary(library, latest, true);
    }
}
