using System.IO.Compression;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Sill.Sidecar;

/// <summary>Roslyn's language server, provisioned on the user's machine (plan §5: downloaded, never shipped): the newest
/// stable <c>roslyn-language-server.&lt;rid&gt;</c> on nuget.org (MIT, built in the Roslyn repo, Razor cohosted in it),
/// cached per version. Four assemblies in it are under Visual Studio's terms and loaded on no path sill takes; as
/// Passenger does, they are left out. Offline, the newest one already cached.</summary>
public static partial class Roslyn
{
    public const string DefaultFeed = "https://api.nuget.org/v3/index.json";

    /// <summary>Visual Studio's ServiceHub client, debugger and RPC contracts, and remote settings client: not open source,
    /// and not needed outside Visual Studio. Left out with their satellite resources.</summary>
    public static readonly string[] LeftOut =
    [
        "Microsoft.ServiceHub.Client", "Microsoft.VisualStudio.Debugger.Contracts", "Microsoft.VisualStudio.RemoteControl",
        "Microsoft.VisualStudio.RpcContracts",
    ];

    public static async Task<RoslynServer> Ensure(RoslynParams asked, Action<RoslynProgress> progress, CancellationToken cancel)
    {
        string id = "roslyn-language-server." + asked.Rid.ToLowerInvariant();
        string feed = asked.Feed ?? DefaultFeed;
        Directory.CreateDirectory(asked.CacheDirectory);
        string? latest;
        try
        {
            List<string> versions = [.. await Versions(feed, id, cancel)];
            latest = Newest(versions.Where(v => !v.Contains('-'))) ?? Newest(versions);
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or IOException)
        {
            // Offline: whatever is cached.
            latest = Newest(Directory.GetDirectories(asked.CacheDirectory).Select(Path.GetFileName).OfType<string>()
                .Where(v => File.Exists(DllIn(asked.CacheDirectory, v))));
            if (latest is null)
            {
                throw new InvalidOperationException($"Roslyn's language server is not cached and the feed did not answer: {error.Message}");
            }
            return new RoslynServer(DllIn(asked.CacheDirectory, latest), latest, false);
        }
        if (latest is null)
        {
            throw new InvalidOperationException($"the feed has no {id}");
        }
        string dll = DllIn(asked.CacheDirectory, latest);
        if (File.Exists(dll))
        {
            return new RoslynServer(dll, latest, false);
        }

        string package = Path.Combine(asked.CacheDirectory, $"{latest}.nupkg.part");
        await Download(feed, id, latest, package, progress, cancel);
        progress(new RoslynProgress("extracting", 0, 0));
        string staging = Path.Combine(asked.CacheDirectory, $"{latest}.part");
        if (Directory.Exists(staging))
        {
            Directory.Delete(staging, true);
        }
        // tools/<the .NET it is built for>/<rid>/, whichever .NET that is.
        Regex prefix = new($"^tools/[^/]+/{Regex.Escape(asked.Rid)}/", RegexOptions.IgnoreCase);
        using (ZipArchive zip = ZipFile.OpenRead(package))
        {
            foreach (ZipArchiveEntry entry in zip.Entries)
            {
                string name = entry.FullName.Replace('\\', '/');
                Match at = prefix.Match(name);
                if (!at.Success || name.EndsWith('/') || LeftOut.Any(n => entry.Name.StartsWith(n + ".", StringComparison.Ordinal)))
                {
                    continue;
                }
                string target = Path.GetFullPath(Path.Combine(staging, name[at.Length..]));
                if (!target.StartsWith(Path.GetFullPath(staging) + Path.DirectorySeparatorChar, StringComparison.Ordinal))
                {
                    continue; // A path that climbs out of the folder.
                }
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                entry.ExtractToFile(target, true);
            }
        }
        File.Delete(package);
        string final = Path.Combine(asked.CacheDirectory, latest);
        if (!File.Exists(Path.Combine(staging, DllName)))
        {
            throw new InvalidOperationException($"the package has no tools/*/{asked.Rid}/{DllName}");
        }
        if (Directory.Exists(final))
        {
            Directory.Delete(final, true);
        }
        Directory.Move(staging, final);
        return new RoslynServer(dll, latest, true);
    }

    private const string DllName = "Microsoft.CodeAnalysis.LanguageServer.dll";

    private static string DllIn(string cache, string version) => Path.Combine(cache, version, DllName);

    private static readonly HttpClient http = new() { Timeout = TimeSpan.FromMinutes(10) };

    /// <summary>A feed is NuGet v3 (its index names the flat container), or for tests a local folder laid out as one.</summary>
    private static async Task<string> FlatContainer(string feed, CancellationToken cancel)
    {
        if (Directory.Exists(feed))
        {
            return feed.TrimEnd('/') + "/";
        }
        JsonElement index = await http.GetFromJsonAsync<JsonElement>(feed, cancel);
        foreach (JsonElement resource in index.GetProperty("resources").EnumerateArray())
        {
            if (resource.GetProperty("@type").GetString()?.StartsWith("PackageBaseAddress", StringComparison.Ordinal) == true)
            {
                return resource.GetProperty("@id").GetString()!;
            }
        }
        throw new InvalidOperationException("the feed has no package base address");
    }

    internal static async Task<IEnumerable<string>> Versions(string feed, string id, CancellationToken cancel)
    {
        string root = await FlatContainer(feed, cancel);
        JsonElement versions = Directory.Exists(feed)
            ? JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(root, id, "index.json"), cancel)).RootElement
            : await http.GetFromJsonAsync<JsonElement>($"{root}{id}/index.json", cancel);
        return versions.GetProperty("versions").EnumerateArray().Select(v => v.GetString()!).ToList();
    }

    internal static async Task Download(string feed, string id, string version, string target,
        Action<RoslynProgress> progress, CancellationToken cancel)
    {
        string root = await FlatContainer(feed, cancel);
        string file = $"{id}.{version}.nupkg";
        if (Directory.Exists(feed))
        {
            File.Copy(Path.Combine(root, id, version, file), target, true);
            return;
        }
        using HttpResponseMessage response = await http.GetAsync($"{root}{id}/{version}/{file}",
            HttpCompletionOption.ResponseHeadersRead, cancel);
        response.EnsureSuccessStatusCode();
        long total = response.Content.Headers.ContentLength ?? 0;
        await using Stream source = await response.Content.ReadAsStreamAsync(cancel);
        await using FileStream sink = File.Create(target);
        byte[] buffer = new byte[1 << 16];
        long done = 0, reported = 0;
        int read;
        while ((read = await source.ReadAsync(buffer, cancel)) > 0)
        {
            await sink.WriteAsync(buffer.AsMemory(0, read), cancel);
            done += read;
            if (done - reported > 1 << 20 || done == total)
            {
                progress(new RoslynProgress("downloading", done, total));
                reported = done;
            }
        }
    }

    /// <summary>The newest version: compared by its numbers, release and prerelease (5.4.0-2.26179.14).</summary>
    public static string? Newest(IEnumerable<string> versions) =>
        versions.MaxBy(v => Numbers().Matches(v).Select(m => long.Parse(m.Value)).ToArray(), Comparer.Instance);

    [GeneratedRegex(@"\d+")]
    private static partial Regex Numbers();

    private sealed class Comparer : IComparer<long[]>
    {
        public static readonly Comparer Instance = new();

        public int Compare(long[]? x, long[]? y)
        {
            x ??= []; y ??= [];
            for (int i = 0; i < Math.Max(x.Length, y.Length); i++)
            {
                long a = i < x.Length ? x[i] : -1, b = i < y.Length ? y[i] : -1;
                if (a != b)
                {
                    return a.CompareTo(b);
                }
            }
            return 0;
        }
    }
}
