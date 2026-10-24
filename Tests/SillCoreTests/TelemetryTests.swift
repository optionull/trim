import Foundation
import SillCore
import Testing

@Suite("telemetry")
struct TelemetryTests {
    typealias Span = TelemetryBatch.Span

    @Test("the sidecar's batch reads: logs, spans and metric points")
    func decode() throws {
        let json = """
        {"logs":[{"atMs":1000,"level":3,"category":"Shop","message":"Order 5 is slow to price","traceId":"aa","spanId":"bb"}],
         "spans":[{"traceId":"aa","spanId":"bb","parentSpanId":null,"name":"price order","source":"Shop","kind":"Internal",
                   "status":"Unset","startMs":1000,"durationMs":6.4,"tags":["order.id, 5"]}],
         "metrics":[{"atMs":1000,"meter":"Shop","instrument":"shop.orders","unit":"","tags":"","kind":"counter","value":4,
                     "quantiles":null,"count":null}]}
        """
        let batch = try JSONDecoder().decode(TelemetryBatch.self, from: Data(json.utf8))
        #expect(batch.logs.first?.levelName == "warning" && batch.spans.first?.tags == ["order.id, 5"])
        #expect(batch.metrics.first?.series == "shop.orders")
    }

    @Test("traces: spans grouped, each after its parent; the slowest first for an agent")
    func traces() {
        var store = TelemetryStore()
        store.add(TelemetryBatch(spans: [
            Span(traceId: "t1", spanId: "c", parentSpanId: "a", name: "price order", startMs: 102, durationMs: 120),
            Span(
                traceId: "t1",
                spanId: "a",
                parentSpanId: "remote",
                name: "GET",
                startMs: 100,
                durationMs: 125,
                tags: ["http.route, /order/{id:int}"]
            ),
            Span(traceId: "t1", spanId: "b", parentSpanId: "a", name: "auth", startMs: 101, durationMs: 1),
            Span(traceId: "t2", spanId: "d", parentSpanId: nil, name: "GET /order/8", startMs: 300, durationMs: 6),
        ]))
        let traces = store.traces
        #expect(traces.map(\.id) == ["t2", "t1"], "the newest first")
        let slow = traces[1]
        #expect(slow.spans.map(\.spanId) == ["a", "b", "c"] && slow.label == "GET /order/{id:int}")
        #expect(TelemetryStore.depth(of: slow.spans[2], in: slow) == 1 && slow.durationMs == 125)
        let text = store.traceText(slowest: 1)
        #expect(text.hasPrefix("trace t1 GET /order/{id:int}: 125.0 ms\n  GET 125.0 ms http.route, /order/{id:int}\n" +
                "    auth 1.0 ms\n    price order 120.0 ms"))
    }

    @Test("logs and metrics for an agent, filtered; the store keeps only the newest")
    func text() {
        var store = TelemetryStore(logLimit: 3, pointLimit: 2)
        store.add(TelemetryBatch(logs: (1 ... 5).map {
            TelemetryBatch.Log(
                atMs: Double($0) * 1000,
                level: $0 == 5 ? 3 : 2,
                category: "Shop",
                message: "Priced order \($0)"
            )
        }, metrics: (1 ... 3).map {
            TelemetryBatch.Metric(
                atMs: Double($0),
                meter: "Shop",
                instrument: "shop.orders",
                kind: "counter",
                value: Double($0)
            )
        }))
        #expect(store.logs.map(\.message) == ["Priced order 3", "Priced order 4", "Priced order 5"])
        #expect(store.logText(level: 3).hasSuffix("warning Shop: Priced order 5"))
        #expect(store.logText(containing: "order 4").contains("order 4") && !store.logText(containing: "order 4")
            .contains("order 3"))
        #expect(store.metricText() == "shop.orders: 3 per interval (2–3 over 2 points)")
        store.add(TelemetryBatch(metrics: [
            .init(atMs: 1, meter: "System.Runtime", instrument: "dotnet.assembly.count", kind: "updown", value: 0),
            .init(
                atMs: 1,
                meter: "Microsoft.AspNetCore.Hosting",
                instrument: "http.server.active_requests",
                kind: "updown",
                value: 2
            ),
        ]))
        #expect(
            store.orderedSeries.map(\.name) == ["shop.orders", "http.server.active_requests", "dotnet.assembly.count"],
            "the program's own first, then what moves"
        )
    }
}
