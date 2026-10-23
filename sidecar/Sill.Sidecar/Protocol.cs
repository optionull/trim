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
