// The sidecar's protocol, adapted from Passenger's project host (https://github.com/Zaneris/passenger, MIT,
// src/Passenger.Host/Protocol.cs); see THIRD_PARTY_NOTICES.md.
//
// One JSON object a line each way over the sidecar's standard input and output. sill asks (Request); the sidecar
// answers each request with partial results as they come, then with its result or why it failed (Reply, by the
// request's id). The sidecar's first line, id 0, is Ready: the protocol version and the runtime it is on.
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Sill.Sidecar;

public sealed record Request(int Id, string Method, JsonElement Params);

public sealed record Reply
{
    public int Id { get; init; }

    public JsonElement? Partial { get; init; }

    public JsonElement? Result { get; init; }

    public string? Error { get; init; }
}

public static class Methods
{
    /// <summary><see cref="PingParams"/> to <see cref="Pong"/>: the text back, for a round trip.</summary>
    public const string Ping = "ping";

    /// <summary>No parameters, to <see cref="Info"/>: the process and the runtime it is on.</summary>
    public const string Info = "info";

    /// <summary><see cref="CountParams"/>: a <see cref="Count"/> partial per number, then the last: for streaming.</summary>
    public const string Count = "count";

    /// <summary><see cref="RoslynParams"/>: <see cref="RoslynProgress"/> partials while downloading, then
    /// <see cref="RoslynServer"/>: Roslyn's language server on this machine, the newest version, downloaded if needed.</summary>
    public const string Roslyn = "roslyn";

    /// <summary><see cref="ProfileParams"/>: builds and starts a program under the profiler, <see cref="ProfilePartial"/>
    /// partials (building, running, its output, reading), then <see cref="ProfileDocument"/> once stopped or ended. The
    /// request's id names the run.</summary>
    public const string Profile = "profile";

    /// <summary><see cref="ProfileRunParams"/> to <see cref="HeapDocument"/>: a heap snapshot of a run, compared with its
    /// last.</summary>
    public const string ProfileSnapshot = "profile.snapshot";

    /// <summary><see cref="ProfileRunParams"/>: ends a run's recording; true if it was recording.</summary>
    public const string ProfileStop = "profile.stop";

    /// <summary><see cref="CancelParams"/>: ends a running request; true if one was running.</summary>
    public const string Cancel = "cancel";
}

public static class Json
{
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };
}

/// <summary>The first line: the protocol version sill checks, and what the sidecar runs on.</summary>
public sealed record Ready(int Protocol, string Runtime, int ProcessId);

public sealed record PingParams(string Text);

public sealed record Pong(string Text);

public sealed record Info(string Runtime, string RuntimeDirectory, string Os, int ProcessId, string Version);

public sealed record CountParams(int To, int DelayMilliseconds);

public sealed record Count(int Number);

public sealed record CancelParams(int Request);

public sealed record RoslynParams(string CacheDirectory, string Rid, string? Feed);

public sealed record RoslynProgress(string Stage, long Bytes, long Total);

public sealed record RoslynServer(string Dll, string Version, bool Downloaded);

/// <summary>A project (folder or project file) to build and run, or a program; its arguments; where traces go.</summary>
public sealed record ProfileParams(string? Project, string? Program, string[]? Arguments, string? WorkingDirectory, string? Folder);

public sealed record ProfileRunParams(int Run);

/// <summary>building, running (with the program's process and name), output (its text, on standard error or not), or
/// reading.</summary>
public sealed record ProfilePartial(string Stage, string? Text, bool? Error)
{
    public int? ProcessId { get; init; }

    public string? Name { get; init; }
}

/// <summary>The call tree flattened in preorder as triples in <see cref="Frames"/>: a name's index in <see cref="Names"/>,
/// the depth, the samples.</summary>
public sealed record ProfileDocument(string Name, int Samples, double DurationMs, double SampleMs, bool Exited,
    IReadOnlyList<string> Names, IReadOnlyList<int> Frames, IReadOnlyList<HotFrame> HotSpots, IReadOnlyList<GcRow> Collections,
    IReadOnlyList<AllocationRow> Allocations);

public sealed record HotFrame(string Name, string Module, int Self, int Total, string? File, int? Line);

public sealed record GcRow(int Number, int Generation, string Reason, double AtMs, double PauseMs);

public sealed record AllocationRow(string Name, long Bytes, int Ticks);

public sealed record HeapDocument(int Number, string Name, int Objects, long Bytes, double TookMs, IReadOnlyList<HeapTypeRow> Types,
    HeapComparison? Comparison);

public sealed record HeapTypeRow(string Name, int Count, long Bytes, long RetainedBytes);

public sealed record HeapComparison(string Title, int NewObjects, int DeadObjects, int SurvivedObjects, string? Inexact,
    IReadOnlyList<HeapDelta> Types);

public sealed record HeapDelta(string Name, int ObjectsDelta, long BytesDelta, int NewObjects, long NewBytes, int DeadObjects, long DeadBytes);
