import Foundation

/// A running program's logs, traces and metrics as the sidecar streams them (EventPipe: Microsoft.Extensions.Logging,
/// ActivitySource, Meter), kept for looking at and for an agent to ask about: the latest logs and spans, and each
/// metric's series.
public struct TelemetryBatch: Decodable, Sendable {
    public struct Log: Decodable, Sendable, Equatable {
        public var atMs: Double
        /// 0 trace, 1 debug, 2 information, 3 warning, 4 error, 5 critical.
        public var level: Int
        public var category: String
        public var message: String
        public var traceId: String?
        public var spanId: String?

        public init(
            atMs: Double,
            level: Int,
            category: String,
            message: String,
            traceId: String? = nil,
            spanId: String? = nil
        ) {
            self.atMs = atMs
            self.level = level
            self.category = category
            self.message = message
            self.traceId = traceId
            self.spanId = spanId
        }

        public var levelName: String {
            ["trace", "debug", "info", "warning", "error", "critical"][min(max(level, 0), 5)]
        }
    }

    public struct Span: Decodable, Sendable, Equatable {
        public var traceId: String
        public var spanId: String
        public var parentSpanId: String?
        public var name: String
        public var source: String
        public var kind: String
        public var status: String
        public var startMs: Double
        public var durationMs: Double
        public var tags: [String]

        public init(
            traceId: String,
            spanId: String,
            parentSpanId: String?,
            name: String,
            source: String = "",
            kind: String = "",
            status: String = "",
            startMs: Double,
            durationMs: Double,
            tags: [String] = []
        ) {
            self.traceId = traceId
            self.spanId = spanId
            self.parentSpanId = parentSpanId
            self.name = name
            self.source = source
            self.kind = kind
            self.status = status
            self.startMs = startMs
            self.durationMs = durationMs
            self.tags = tags
        }
    }

    public struct Metric: Decodable, Sendable, Equatable {
        public var atMs: Double
        public var meter: String
        public var instrument: String
        public var unit: String
        public var tags: String
        /// counter (a rate in the interval), gauge, updown, histogram (its p50 as the value).
        public var kind: String
        public var value: Double?
        public var quantiles: [String: Double]?
        public var count: Double?

        public init(
            atMs: Double,
            meter: String,
            instrument: String,
            unit: String = "",
            tags: String = "",
            kind: String,
            value: Double?,
            quantiles: [String: Double]? = nil,
            count: Double? = nil
        ) {
            self.atMs = atMs
            self.meter = meter
            self.instrument = instrument
            self.unit = unit
            self.tags = tags
            self.kind = kind
            self.value = value
            self.quantiles = quantiles
            self.count = count
        }

        /// A series: the instrument and its tags.
        public var series: String { tags.isEmpty ? instrument : "\(instrument) {\(tags)}" }
    }

    public var logs: [Log]
    public var spans: [Span]
    public var metrics: [Metric]

    public init(logs: [Log] = [], spans: [Span] = [], metrics: [Metric] = []) {
        self.logs = logs
        self.spans = spans
        self.metrics = metrics
    }
}

/// What a telemetry session has seen, bounded: the newest logs and spans, each series' newest points.
public struct TelemetryStore: Sendable {
    public struct Trace: Equatable, Sendable {
        public var id: String
        /// Its spans, parents before children, in the order they started.
        public var spans: [TelemetryBatch.Span]
        public var root: TelemetryBatch
            .Span? { spans.first { span in !spans.contains { $0.spanId == span.parentSpanId } } }
        public var startMs: Double { spans.map(\.startMs).min() ?? 0 }
        /// The root's name and, when a span says it, the route or path: "GET /order/{id:int}".
        public var label: String {
            let name = root?.name ?? id
            for key in ["http.route", "url.path", "url.full"] {
                for span in spans {
                    if let tag = span.tags.first(where: { $0.hasPrefix(key + ", ") }) {
                        let value = String(tag.dropFirst(key.count + 2))
                        return name.contains(value) ? name : "\(name) \(value)"
                    }
                }
            }
            return name
        }

        public var durationMs: Double { (spans.map { $0.startMs + $0.durationMs }.max() ?? 0) - startMs }
    }

    public private(set) var logs: [TelemetryBatch.Log] = []
    public private(set) var spans: [TelemetryBatch.Span] = []
    /// Each series' points, by its name, the newest last.
    public private(set) var series: [String: [TelemetryBatch.Metric]] = [:]
    public let logLimit: Int, spanLimit: Int, pointLimit: Int

    public init(logLimit: Int = 5000, spanLimit: Int = 5000, pointLimit: Int = 600) {
        self.logLimit = logLimit
        self.spanLimit = spanLimit
        self.pointLimit = pointLimit
    }

    public mutating func add(_ batch: TelemetryBatch) {
        logs.append(contentsOf: batch.logs)
        if logs.count > logLimit { logs.removeFirst(logs.count - logLimit) }
        spans.append(contentsOf: batch.spans)
        if spans.count > spanLimit { spans.removeFirst(spans.count - spanLimit) }
        for point in batch.metrics {
            series[point.series, default: []].append(point)
            if series[point.series]!.count > pointLimit { series[point.series]!.removeFirst() }
        }
    }

    /// The series as a person reads them: the program's own meters first, then those whose values move, then the
    /// runtime's still ones; by name within each.
    public var orderedSeries: [(name: String, points: [TelemetryBatch.Metric])] {
        func rank(_ points: [TelemetryBatch.Metric]) -> Int {
            let meter = points.last?.meter ?? ""
            let platform = ["System.", "Microsoft.", "Private."].contains { meter.hasPrefix($0) }
            if !platform { return 0 }
            let values = points.compactMap(\.value)
            return (values.min() ?? 0) != (values.max() ?? 0) || values.contains { $0 != 0 } ? 1 : 2
        }
        return series.map { (name: $0.key, points: $0.value) }.sorted {
            let (a, b) = (rank($0.points), rank($1.points))
            return a != b ? a < b : $0.name < $1.name
        }
    }

    /// The traces, the newest first: spans grouped by trace, parents before their children.
    public var traces: [Trace] {
        var byTrace: [String: [TelemetryBatch.Span]] = [:]
        for span in spans {
            byTrace[span.traceId, default: []].append(span)
        }
        return byTrace.map { id, spans in Trace(id: id, spans: Self.ordered(spans)) }
            .sorted { $0.startMs > $1.startMs }
    }

    /// Spans as a tree in preorder: each after its parent, siblings by when they started.
    static func ordered(_ spans: [TelemetryBatch.Span]) -> [TelemetryBatch.Span] {
        let ids = Set(spans.map(\.spanId))
        var children: [String: [TelemetryBatch.Span]] = [:]
        var roots: [TelemetryBatch.Span] = []
        for span in spans {
            if let parent = span.parentSpanId, ids.contains(parent) {
                children[parent, default: []].append(span)
            } else {
                roots.append(span)
            }
        }
        var out: [TelemetryBatch.Span] = []
        func walk(_ span: TelemetryBatch.Span) {
            out.append(span)
            for child in (children[span.spanId] ?? []).sorted(by: { $0.startMs < $1.startMs }) {
                walk(child)
            }
        }
        for root in roots.sorted(by: { $0.startMs < $1.startMs }) {
            walk(root)
        }
        return out
    }

    /// A span's depth in its trace (0 for a root).
    public static func depth(of span: TelemetryBatch.Span, in trace: Trace) -> Int {
        var depth = 0, parent = span.parentSpanId
        while let id = parent, let next = trace.spans.first(where: { $0.spanId == id }) {
            depth += 1
            parent = next.parentSpanId
        }
        return depth
    }

    // MARK: For an agent

    /// The newest logs at `level` or worse, those containing `text` when given.
    public func logText(level: Int = 0, containing text: String? = nil, last: Int = 50) -> String {
        let chosen = logs.filter { log in
            log.level >= level && (text.map { log.message.localizedCaseInsensitiveContains($0) } ?? true)
        }.suffix(last)
        guard !chosen.isEmpty else { return "No logs" + (text.map { " containing \"\($0)\"" } ?? "") + "." }
        return chosen.map { log in
            let time = Date(timeIntervalSince1970: log.atMs / 1000).formatted(.dateTime.hour().minute().second())
            return "\(time) \(log.levelName) \(log.category): \(log.message)" +
                (log.traceId.map { " [trace \($0.prefix(8))]" } ?? "")
        }.joined(separator: "\n")
    }

    /// The slowest traces (or those whose root is named like `name`), each as its span tree with durations.
    public func traceText(slowest: Int = 5, named name: String? = nil) -> String {
        let chosen = traces
            .filter { trace in name.map { trace.root?.name.localizedCaseInsensitiveContains($0) ?? false } ?? true }
            .sorted { $0.durationMs > $1.durationMs }.prefix(slowest)
        guard !chosen.isEmpty else { return "No traces yet." }
        return chosen.map { trace in
            (["trace \(trace.id.prefix(8)) \(trace.label): \(String(format: "%.1f ms", trace.durationMs))"] + trace
                .spans.map { span in
                    String(repeating: "  ", count: Self.depth(of: span, in: trace) + 1) + span.name +
                        String(format: " %.1f ms", span.durationMs) +
                        (span.tags.isEmpty ? "" : " " + span.tags.joined(separator: ", "))
                }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// Each series' latest value and its range over what was seen (those named like `name` when given).
    public func metricText(named name: String? = nil) -> String {
        let chosen = series.filter { key, _ in name.map { key.localizedCaseInsensitiveContains($0) } ?? true }
            .sorted { $0.key < $1.key }
        guard !chosen.isEmpty else { return "No metrics" + (name.map { " named like \"\($0)\"" } ?? "") + " yet." }
        return chosen.compactMap { key, points in
            let values = points.compactMap(\.value)
            guard let last = values.last, let low = values.min(), let high = values.max() else { return nil }
            let unit = points.last?.unit ?? ""
            let what = points.last?.kind == "counter" ? "per interval" : points.last?.kind == "histogram" ? "p50" : "now"
            return "\(key): \(Self.number(last))\(unit.isEmpty ? "" : " " + unit) \(what) (\(Self.number(low))–\(Self.number(high)) " +
                "over \(points.count) points)"
        }.joined(separator: "\n")
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(format: "%.4g", value)
    }
}
