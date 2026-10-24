using System.Collections.Concurrent;
using System.Diagnostics;
using Sill.Profiler;

namespace Sill.Sidecar;

/// <summary>Profiling runs (M6): <c>profile</c> builds a project (or takes a program), starts it under the profiler and
/// stays open while it runs, its output as partials; <c>profile.snapshot</c> takes a heap snapshot of a run, compared with
/// the run's last; <c>profile.stop</c> ends the recording (the program goes on until sill ends it), and the
/// <c>profile</c> request answers with the CPU profile. A program that ends by itself answers the same way.</summary>
public static class Profile
{
    /// <summary>The frames a profile document carries at most: past that, the lightest subtrees are left out.</summary>
    public const int MaxFrames = 200_000;

    private sealed class Run(ProfilingSession session, string name)
    {
        public ProfilingSession Session { get; } = session;
        public string Name { get; } = name;
        public TaskCompletionSource Stop { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public MemorySnapshot? Last { get; set; }
        public SemaphoreSlim Snapshotting { get; } = new(1, 1);
    }

    private static readonly ConcurrentDictionary<int, Run> Runs = new();

    /// <summary>Stretches the timeline strip is cut into.</summary>
    public const int TimelineBuckets = 120;

    /// <summary>What a run that ended leaves to look into: its CPU profile, for a stretch of it, and its last heap snapshot,
    /// for what keeps a type alive. The last two runs only: a heap graph is large.</summary>
    private sealed record Finished(Snapshot Cpu, string Name, bool Exited, MemorySnapshot? Heap);

    private static readonly ConcurrentDictionary<int, Finished> Done = new();
    private static readonly ConcurrentQueue<int> DoneOrder = new();

    private static void Keep(int id, Finished finished)
    {
        Done[id] = finished;
        DoneOrder.Enqueue(id);
        while (DoneOrder.Count > 2 && DoneOrder.TryDequeue(out int old))
        {
            Done.TryRemove(old, out _);
        }
    }

    public static async Task<ProfileDocument> Start(int id, ProfileParams asked, Action<ProfilePartial> partial, CancellationToken cancel)
    {
        string folder = asked.Folder ?? Path.Combine(Path.GetTempPath(), "sill-profiles");
        ProfileTarget target;
        if (asked.Project is { } project)
        {
            partial(new ProfilePartial("building", null, null));
            string dll = await Build(project, cancel);
            target = new ProfileTarget("dotnet", [dll, .. asked.Arguments ?? []], asked.WorkingDirectory ?? Path.GetDirectoryName(dll)!,
                new Dictionary<string, string>());
        }
        else
        {
            target = new ProfileTarget(asked.Program ?? throw new InvalidOperationException("profile needs a project or a program"),
                asked.Arguments ?? [], asked.WorkingDirectory ?? Environment.CurrentDirectory, new Dictionary<string, string>());
        }
        ProfilingSession session = await ProfilingSession.StartAsync(target, folder,
            (text, error) => partial(new ProfilePartial("output", text, error)), cancel);
        Run run = new(session, target.Name);
        Runs[id] = run;
        partial(new ProfilePartial("running", null, null) { ProcessId = session.ProcessId, Name = target.Name });
        try
        {
            using CancellationTokenRegistration stopping = cancel.Register(() => run.Stop.TrySetResult());
            Task ended = session.ExitedAsync();
            Snapshot snapshot;
            if (await Task.WhenAny(run.Stop.Task, ended) == ended)
            {
                snapshot = await session.WaitForExitAsync(CancellationToken.None);
            }
            else
            {
                // Wait for a snapshot being taken to finish: it needs the session.
                await run.Snapshotting.WaitAsync(CancellationToken.None);
                snapshot = await session.StopAsync();
                run.Snapshotting.Release();
            }
            partial(new ProfilePartial("reading", null, null));
            Keep(id, new Finished(snapshot, target.Name, session.HasExited, run.Last));
            return Document(snapshot, target.Name, session.HasExited) with { Timeline = Timeline(snapshot) };
        }
        finally
        {
            Runs.TryRemove(id, out _);
            session.Kill();
            await session.DisposeAsync();
        }
    }

    /// <summary>Ends a run's recording; its <c>profile</c> request then answers.</summary>
    public static bool Stop(ProfileRunParams asked) => Runs.TryGetValue(asked.Run, out Run? run) && run.Stop.TrySetResult();

    /// <summary>The run's heap now, and how it changed since its last snapshot.</summary>
    public static async Task<HeapDocument> Snapshot(ProfileRunParams asked, CancellationToken cancel)
    {
        if (!Runs.TryGetValue(asked.Run, out Run? run))
        {
            throw new InvalidOperationException("no such run: it ended, or it was never started");
        }
        await run.Snapshotting.WaitAsync(cancel);
        try
        {
            MemorySnapshot snapshot = await run.Session.TakeMemorySnapshotAsync(cancel);
            MemorySnapshot? older = run.Last;
            run.Last = snapshot;
            HeapComparison? comparison = null;
            if (older is not null && snapshot.WhyNotComparable(older) is null)
            {
                SnapshotComparison compared = await Task.Run(() => snapshot.CompareWith(older), cancel);
                comparison = new HeapComparison(compared.Title, compared.NewObjects, compared.DeadObjects, compared.SurvivedObjects,
                    compared.Inexact,
                    [.. compared.Types.OrderByDescending(t => t.BytesDelta).Take(60).Select(t => new HeapDelta(t.Name, t.ObjectsDelta,
                        t.BytesDelta, t.NewObjects, t.NewBytes, t.DeadObjects, t.DeadBytes))]);
            }
            return new HeapDocument(snapshot.Number, snapshot.Name, snapshot.Objects, snapshot.Bytes, snapshot.Took.TotalMilliseconds,
                [.. snapshot.Types.Take(60).Select(t => new HeapTypeRow(t.Name, t.Count, t.Bytes, t.RetainedBytes))], comparison);
        }
        finally
        {
            run.Snapshotting.Release();
        }
    }

    /// <summary>A stretch of a finished run's CPU profile, as selecting it on the timeline strip asks.</summary>
    public static Task<ProfileDocument> Within(ProfileWithinParams asked, CancellationToken cancel)
    {
        if (!Done.TryGetValue(asked.Run, out Finished? finished))
        {
            throw new InvalidOperationException("no such run: it is still recording, or too old");
        }
        Snapshot whole = finished.Cpu;
        double length = whole.EndMs - whole.StartMs;
        double from = whole.StartMs + (Math.Clamp(Math.Min(asked.From, asked.To), 0, 1) * length);
        double to = whole.StartMs + (Math.Clamp(Math.Max(asked.From, asked.To), 0, 1) * length);
        return Task.Run(() => Document(whole.Within(from, to), finished.Name, finished.Exited), cancel);
    }

    /// <summary>What keeps a type's objects alive in the run's last heap snapshot: its key retention paths, the most
    /// retained first, root first.</summary>
    public static Task<IReadOnlyList<RetainerRow>> Retainers(ProfileRetainersParams asked, CancellationToken cancel)
    {
        MemorySnapshot? heap = Runs.TryGetValue(asked.Run, out Run? run) ? run.Last :
            Done.TryGetValue(asked.Run, out Finished? finished) ? finished.Heap : null;
        if (heap is null)
        {
            throw new InvalidOperationException("no heap snapshot of that run");
        }
        HeapType type = heap.Types.FirstOrDefault(t => t.Name == asked.Type)
            ?? throw new InvalidOperationException($"no {asked.Type} in the snapshot");
        return Task.Run<IReadOnlyList<RetainerRow>>(() => [.. heap.ObjectsOf(type).KeyRetentionPaths().Take(5)
            .Select(p => new RetainerRow(p.Root.Text, p.Steps, p.Objects, p.RetainedBytes))], cancel);
    }

    /// <summary>Samples in each stretch of the run, every thread's, for the CPU over time strip.</summary>
    internal static int[] Timeline(Snapshot snapshot)
    {
        int[] buckets = new int[TimelineBuckets];
        double start = snapshot.StartMs, length = Math.Max(snapshot.EndMs - start, 1e-6);
        double width = length / TimelineBuckets;
        foreach (SampleRun sampled in snapshot.Timeline.SelectMany(t => t.Runs))
        {
            int first = Math.Clamp((int)((sampled.FromMs - start) / width), 0, TimelineBuckets - 1);
            int last = Math.Clamp((int)((sampled.ToMs - start) / width), 0, TimelineBuckets - 1);
            if (first == last)
            {
                buckets[first] += sampled.Count;
                continue;
            }
            for (int bucket = first; bucket <= last; bucket++)
            {
                buckets[bucket] += sampled.Within(start + (bucket * width), start + ((bucket + 1) * width) - 1e-9);
            }
        }
        return buckets;
    }

    /// <summary>Builds the project in Release and says where its program is.</summary>
    internal static async Task<string> Build(string project, CancellationToken cancel)
    {
        (int built, string said) = await Dotnet(project, ["build", project, "-c", "Release", "-nologo", "-v", "q"], cancel);
        if (built != 0)
        {
            string why = string.Join('\n', said.Split('\n').Select(l => l.Trim()).Where(l => l.Contains("error", StringComparison.Ordinal)).Distinct().Take(5));
            throw new InvalidOperationException($"the build failed: {(why.Length > 0 ? why : said.Trim())}");
        }
        // Evaluation only: where the build put the program.
        (int _, string path) = await Dotnet(project, ["msbuild", project, "-p:Configuration=Release", "-nologo", "-getProperty:TargetPath"], cancel);
        string dll = path.Trim();
        return File.Exists(dll) ? dll : throw new InvalidOperationException($"the build made no program to run ({dll})");
    }

    private static async Task<(int Code, string Output)> Dotnet(string project, string[] arguments, CancellationToken cancel)
    {
        ProcessStartInfo start = new("dotnet")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Directory.Exists(project) ? project : Path.GetDirectoryName(project)!,
        };
        foreach (string argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }
        using Process dotnet = Process.Start(start) ?? throw new InvalidOperationException("dotnet did not start");
        Task<string> output = dotnet.StandardOutput.ReadToEndAsync(cancel);
        Task<string> errors = dotnet.StandardError.ReadToEndAsync(cancel);
        await dotnet.WaitForExitAsync(cancel);
        return (dotnet.ExitCode, await output + await errors);
    }

    /// <summary>The CPU profile as sill draws it: the call tree of all threads flattened in preorder (each frame's name,
    /// depth and samples), the hot spots with where they are written, the collections and the allocations.</summary>
    internal static ProfileDocument Document(Snapshot snapshot, string name, bool exited)
    {
        List<string> names = [];
        Dictionary<string, int> named = new(StringComparer.Ordinal);
        int Name(string text)
        {
            if (!named.TryGetValue(text, out int index))
            {
                named[text] = index = names.Count;
                names.Add(text);
            }
            return index;
        }
        // The lightest frames go first when there are too many: the smallest total that still fits.
        int floor = 0;
        int count = Count(snapshot.All, 0);
        if (count > MaxFrames)
        {
            List<int> totals = [];
            Collect(snapshot.All, totals);
            totals.Sort();
            floor = totals[totals.Count - MaxFrames];
        }
        List<int> frames = [];
        void Walk(CallNode node, int depth)
        {
            // The root is the program.
            frames.Add(Name(depth == 0 ? name : node.Name));
            frames.Add(depth);
            frames.Add(node.Total);
            foreach (CallNode child in node.Ordered)
            {
                if (child.Total >= floor)
                {
                    Walk(child, depth + 1);
                }
            }
        }
        Walk(snapshot.All, 0);
        using MethodSources sources = new();
        List<HotFrame> hot = [.. snapshot.HotSpots.Take(25).Select(h =>
        {
            (string File, int Line)? at = h.Code is { } code ? sources.Find(code) : null;
            return new HotFrame(h.Name, h.Module, h.Self, h.Total, at?.File, at?.Line);
        })];
        return new ProfileDocument(name, snapshot.Samples, snapshot.Duration.TotalMilliseconds, snapshot.SampleMs, exited, names,
            frames, hot,
            [.. snapshot.Collections.Select(c => new GcRow(c.Number, c.Generation, c.Reason, c.AtMs, c.PauseMs))],
            [.. snapshot.Allocations.Take(40).Select(a => new AllocationRow(a.Name, a.Bytes, a.Ticks))]);

        static int Count(CallNode node, int sum) => node.Children.Aggregate(sum + 1, (s, c) => Count(c, s));
        static void Collect(CallNode node, List<int> totals)
        {
            totals.Add(node.Total);
            foreach (CallNode child in node.Children)
            {
                Collect(child, totals);
            }
        }
    }
}
