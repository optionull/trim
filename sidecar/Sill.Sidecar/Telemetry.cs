using System.Collections.Concurrent;
using System.Diagnostics.Tracing;
using System.Globalization;
using Microsoft.Diagnostics.NETCore.Client;
using Microsoft.Diagnostics.Tracing;

namespace Sill.Sidecar;

/// <summary>A running .NET program's logs, traces and metrics, as it makes them, without changing it: one EventPipe
/// session asks the runtime for Microsoft.Extensions.Logging's messages, every ActivitySource's finished activities and
/// every Meter's values once a second. The <c>telemetry</c> request stays open and sends them as partials, a batch a
/// quarter of a second; <c>telemetry.stop</c> ends it.</summary>
public static class Telemetry
{
    /// <summary>What an activity's stop carries: its ids, name, kind, status, times and tags.</summary>
    private const string ActivitySpec =
        "[AS]*/Stop:-TraceId;SpanId;ParentSpanId;DisplayName;Kind;Status;StartTimeTicks=StartTimeUtc.Ticks;" +
        "DurationTicks=Duration.Ticks;Tags=TagObjects.*Enumerate";

    private static readonly ConcurrentDictionary<int, EventPipeSession> Sessions = new();

    public static async Task<bool> Start(int id, TelemetryParams asked, Action<TelemetryBatch> partial, CancellationToken cancel)
    {
        List<EventPipeProvider> providers =
        [
            new("Microsoft-Extensions-Logging", EventLevel.Informational, 0x4),
            new("System.Diagnostics.Metrics", EventLevel.Informational, 0x2 | 0x4 | 0x8, new Dictionary<string, string>
            {
                ["SessionId"] = "sill-" + id, ["Metrics"] = "*", ["RefreshInterval"] = "1", ["MaxTimeSeries"] = "2000",
                ["MaxHistograms"] = "100",
            }),
            new("Microsoft-Diagnostics-DiagnosticSource", EventLevel.Verbose, 0x2 | 0x800,
                new Dictionary<string, string> { ["FilterAndPayloadSpecs"] = ActivitySpec }),
        ];
        EventPipeSession session = await new DiagnosticsClient(asked.ProcessId)
            .StartEventPipeSessionAsync(providers, requestRundown: false, circularBufferMB: 64, cancel);
        Sessions[id] = session;
        ConcurrentQueue<LogRecord> logs = new();
        ConcurrentQueue<SpanRecord> spans = new();
        ConcurrentQueue<MetricPoint> metrics = new();
        using CancellationTokenRegistration stopping = cancel.Register(() => _ = session.StopAsync(CancellationToken.None));
        // The batches: what came since the last one, a quarter of a second at a time.
        using CancellationTokenSource flushing = new();
        Task flusher = Task.Run(async () =>
        {
            while (!flushing.IsCancellationRequested)
            {
                try { await Task.Delay(250, flushing.Token); } catch (OperationCanceledException) { }
                TelemetryBatch batch = new(Drain(logs), Drain(spans), Drain(metrics));
                if (batch.Logs.Count + batch.Spans.Count + batch.Metrics.Count > 0)
                {
                    partial(batch);
                }
            }
        });
        try
        {
            using EventPipeEventSource source = new(session.EventStream);
            source.Dynamic.All += e =>
            {
                switch (e.ProviderName)
                {
                    case "Microsoft-Extensions-Logging" when e.EventName == "FormattedMessage":
                        logs.Enqueue(new LogRecord(Ms(e.TimeStamp), Int(e.PayloadByName("Level")),
                            e.PayloadByName("LoggerName") as string ?? "", e.PayloadByName("FormattedMessage") as string ?? "",
                            Text(e.PayloadByName("ActivityTraceId")), Text(e.PayloadByName("ActivitySpanId"))));
                        break;
                    case "Microsoft-Diagnostics-DiagnosticSource" when e.EventName == "Activity/Stop":
                        if (Span(e) is { } span)
                        {
                            spans.Enqueue(span);
                        }
                        break;
                    case "System.Diagnostics.Metrics" when e.EventName.EndsWith("ValuePublished", StringComparison.Ordinal):
                        if (Metric(e) is { } point)
                        {
                            metrics.Enqueue(point);
                        }
                        break;
                }
            };
            await Task.Run(source.Process, CancellationToken.None);
        }
        finally
        {
            Sessions.TryRemove(id, out _);
            flushing.Cancel();
            await flusher;
        }
        return true;
    }

    public static bool Stop(TelemetryRunParams asked)
    {
        if (!Sessions.TryGetValue(asked.Run, out EventPipeSession? session))
        {
            return false;
        }
        _ = session.StopAsync(CancellationToken.None);
        return true;
    }

    private static List<T> Drain<T>(ConcurrentQueue<T> queue)
    {
        List<T> out_ = [];
        while (out_.Count < 5000 && queue.TryDequeue(out T? item))
        {
            out_.Add(item);
        }
        return out_;
    }

    private static double Ms(DateTime time) => (time.ToUniversalTime() - DateTime.UnixEpoch).TotalMilliseconds;

    private static int Int(object? value) => value is IConvertible c ? c.ToInt32(CultureInfo.InvariantCulture) : 0;

    private static string? Text(object? value) => value is string { Length: > 0 } s && s.Trim('0').Length > 0 ? s : null;

    /// <summary>An activity's stop: its arguments are a list of key and value pairs.</summary>
    private static SpanRecord? Span(TraceEvent e)
    {
        Dictionary<string, object?> fields = [];
        if (e.PayloadByName("Arguments") is IEnumerable<object> arguments)
        {
            foreach (object argument in arguments)
            {
                if (argument is IDictionary<string, object> pair && pair.TryGetValue("Key", out object? key))
                {
                    fields[key?.ToString() ?? ""] = pair.TryGetValue("Value", out object? value) ? value : null;
                }
            }
        }
        if (Text(fields.GetValueOrDefault("SpanId")) is not { } spanId)
        {
            return null;
        }
        double start = long.TryParse(fields.GetValueOrDefault("StartTimeTicks")?.ToString(), out long ticks)
            ? (new DateTime(ticks, DateTimeKind.Utc) - DateTime.UnixEpoch).TotalMilliseconds : Ms(e.TimeStamp);
        double duration = long.TryParse(fields.GetValueOrDefault("DurationTicks")?.ToString(), out long length)
            ? length / 10_000.0 : 0;
        // Tags come as "[key, value]" strings.
        List<string> tags = [];
        if (fields.GetValueOrDefault("Tags") is IEnumerable<object> list)
        {
            foreach (object tag in list)
            {
                tags.Add(tag.ToString()?.Trim('[', ']') ?? "");
            }
        }
        else if (fields.GetValueOrDefault("Tags") is string all && all.Length > 2)
        {
            // One string: "[key, value],[key, value]".
            tags.AddRange(all[1..^1].Split("],[", StringSplitOptions.RemoveEmptyEntries));
        }
        return new SpanRecord(Text(fields.GetValueOrDefault("TraceId")) ?? "", spanId, Text(fields.GetValueOrDefault("ParentSpanId")),
            fields.GetValueOrDefault("DisplayName")?.ToString() ?? e.PayloadByName("ActivityName") as string ?? "",
            e.PayloadByName("SourceName") as string ?? "", fields.GetValueOrDefault("Kind")?.ToString() ?? "",
            fields.GetValueOrDefault("Status")?.ToString() ?? "", start, duration, tags);
    }

    /// <summary>A meter's value for an interval: a counter's rate in it, a gauge's or an up-down counter's value, a
    /// histogram's percentiles.</summary>
    private static MetricPoint? Metric(TraceEvent e)
    {
        string meter = e.PayloadByName("meterName") as string ?? "", instrument = e.PayloadByName("instrumentName") as string ?? "";
        if (meter.Length == 0 || instrument.Length == 0)
        {
            return null;
        }
        string kind = e.EventName switch
        {
            "CounterRateValuePublished" => "counter",
            "GaugeValuePublished" => "gauge",
            "UpDownCounterRateValuePublished" => "updown",
            "HistogramValuePublished" => "histogram",
            _ => "other",
        };
        static double? Number(object? value) =>
            double.TryParse(value?.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out double v) ? v : null;
        double? value = kind switch
        {
            // A counter's rate for the interval, else (an observable one) its value.
            "counter" => Number(e.PayloadByName("rate")) ?? Number(e.PayloadByName("value")),
            "gauge" => Number(e.PayloadByName("lastValue")),
            "updown" => Number(e.PayloadByName("value")),
            _ => null,
        };
        Dictionary<string, double>? quantiles = null;
        if (kind == "histogram" && e.PayloadByName("quantiles") is string text)
        {
            quantiles = [];
            foreach (string part in text.Split(';', StringSplitOptions.RemoveEmptyEntries))
            {
                string[] pair = part.Split('=');
                if (pair.Length == 2 && Number(pair[1]) is { } q)
                {
                    quantiles["p" + (Number(pair[0]) is { } at ? (at * 100).ToString(CultureInfo.InvariantCulture) : pair[0])] = q;
                }
            }
            value = quantiles.GetValueOrDefault("p50");
        }
        return new MetricPoint(Ms(e.TimeStamp), meter, instrument, e.PayloadByName("unit") as string ?? "",
            e.PayloadByName("tags") as string ?? "", kind, value, quantiles, Number(e.PayloadByName("count")));
    }
}

public sealed record TelemetryParams(int ProcessId);

public sealed record TelemetryRunParams(int Run);

/// <summary>Level: 0 trace, 1 debug, 2 information, 3 warning, 4 error, 5 critical.</summary>
public sealed record LogRecord(double AtMs, int Level, string Category, string Message, string? TraceId, string? SpanId);

public sealed record SpanRecord(string TraceId, string SpanId, string? ParentSpanId, string Name, string Source, string Kind,
    string Status, double StartMs, double DurationMs, IReadOnlyList<string> Tags);

public sealed record MetricPoint(double AtMs, string Meter, string Instrument, string Unit, string Tags, string Kind, double? Value,
    IReadOnlyDictionary<string, double>? Quantiles, double? Count);

public sealed record TelemetryBatch(IReadOnlyList<LogRecord> Logs, IReadOnlyList<SpanRecord> Spans, IReadOnlyList<MetricPoint> Metrics);
