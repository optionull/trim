import SillCore
import Testing

@Suite("profile comparison")
struct ProfileComparisonTests {
    /// main → total (its own `own` samples) → sqrt (`sqrt` samples), on one thread, a millisecond a sample.
    func profile(own: Int, sqrt: Int, other: Int) -> ProfileDocument {
        var builder = CallTreeBuilder(program: "app")
        let main = SampledFrame(name: "main", module: "app"), total = SampledFrame(name: "total", module: "app")
        for _ in 0 ..< own {
            builder.add(thread: "main thread", frames: [main, total])
        }
        for _ in 0 ..< sqrt {
            builder.add(thread: "main thread", frames: [main, total, SampledFrame(name: "sqrt", module: "libm")])
        }
        for _ in 0 ..< other {
            builder.add(thread: "main thread", frames: [main, SampledFrame(name: "log", module: "app")])
        }
        return builder.document(name: "app", sampleMs: 1, exited: true)
    }

    @Test("each function's own and total time before and after, the biggest change first")
    func compare() throws {
        let comparison = ProfileComparison(
            before: profile(own: 100, sqrt: 300, other: 50),
            after: profile(own: 100, sqrt: 30, other: 50)
        )
        #expect(comparison.cpuBefore == 450 && comparison.cpuAfter == 180)
        let first = try #require(comparison.rows.first)
        // main, total and sqrt each lose 270 ms in all; sqrt first, where the time itself went.
        #expect(first.name == "sqrt" && first.totalChange == -270 && first.selfChange == -270)
        #expect(comparison.rows.first { $0.name == "main" }?.totalChange == -270, "main loses what total lost")
        let total = try #require(comparison.rows.first { $0.name == "total" })
        #expect(total.totalBefore == 400 && total.totalAfter == 130 && total.selfChange == 0)
        let sqrt = try #require(comparison.rows.first { $0.name == "sqrt" })
        #expect(sqrt.selfBefore == 300 && sqrt.selfAfter == 30)
        #expect(!comparison.rows.contains { $0.name == "log" }, "unchanged is left out")
        #expect(comparison.text.hasPrefix("cpu: 450 ms → 180 ms (-270 ms)"))
        #expect(
            abs(total.shareBefore - 400.0 / 450) < 1e-9 && abs(total.shareAfter - 130.0 / 180) < 1e-9,
            "its share of each run"
        )
    }
}
