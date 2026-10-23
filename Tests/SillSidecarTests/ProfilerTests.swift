import Foundation
@testable import SillSidecar
import Testing

/// The profiler end to end on the sample (`Fixtures/Sample`): a hot loop in `Pricing.Total`, and a cache of `Order`s
/// that only grows.
@Suite("the profiler", .serialized, .timeLimit(.minutes(2)))
struct ProfilerTests {
    static let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Sample")

    /// A copy of the sample to build, so its bin and obj stay out of the source tree.
    static func copy() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sill-sample-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: sample, to: folder)
        return folder
    }

    @Test("a run: built, sampled, two heap snapshots compared, and its CPU profile once stopped")
    func run() async throws {
        let (sidecar, _) = try await BuiltSidecar.start()
        defer { Task { await sidecar.stop() } }
        let project = try Self.copy()
        defer { try? FileManager.default.removeItem(at: project) }
        let stages = Stages()
        let run = try await sidecar.startProfile(project: project.path, arguments: ["20"]) { stages.add($0) }
        try await stages.wait(for: "running")
        #expect(stages.all.first?.stage == "building")
        #expect(stages.all.first { $0.stage == "running" }?.name == "Sample")

        try await Task.sleep(for: .seconds(1))
        let first = try await sidecar.heapSnapshot(run: run)
        #expect(first.number == 1)
        #expect(first.comparison == nil)
        try await Task.sleep(for: .seconds(1.5))
        let second = try await sidecar.heapSnapshot(run: run)
        #expect(second.number == 2)
        let comparison = try #require(second.comparison)
        let orders = try #require(comparison.types.first { $0.name == "Order" })
        #expect(orders.objectsDelta > 1000)
        #expect(orders.newObjects >= orders.objectsDelta)
        #expect(comparison.newObjects > comparison.deadObjects)

        #expect(try await sidecar.stopProfile(run: run))
        let profile = try await sidecar.profileResult(run: run)
        #expect(profile.name == "Sample")
        #expect(profile.samples > 100)
        #expect(!profile.exited)
        let hot = try #require(profile.hotSpots.first)
        #expect(hot.name.hasPrefix("Pricing.Total"))
        #expect(hot.file?.hasSuffix("Program.cs") == true)
        #expect(hot.line != nil)
        let frames = profile.preorder
        #expect(frames.first?.depth == 0)
        #expect(profile.names[frames[0].name] == "Sample")
        #expect(frames.first?.samples == profile.samples)
        #expect(frames.contains { profile.names[$0.name].hasPrefix("Pricing.Total") })
        await #expect(throws: (any Error).self) { try await sidecar.heapSnapshot(run: run) }
    }

    @Test("a project that does not build says why")
    func brokenBuild() async throws {
        let (sidecar, _) = try await BuiltSidecar.start()
        defer { Task { await sidecar.stop() } }
        let project = try Self.copy()
        defer { try? FileManager.default.removeItem(at: project) }
        try "this is not C#".write(to: project.appendingPathComponent("Program.cs"), atomically: true, encoding: .utf8)
        let run = try await sidecar.startProfile(project: project.path)
        await #expect {
            _ = try await sidecar.profileResult(run: run)
        } throws: { error in
            "\(error)".contains("the build failed")
        }
    }
}

/// What a run said, for the test to wait on.
private final class Stages: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [ProfilePartial] = []

    var all: [ProfilePartial] { lock.withLock { stages } }

    func add(_ partial: ProfilePartial) { lock.withLock { stages.append(partial) } }

    func wait(for stage: String) async throws {
        for _ in 0 ..< 600 where !all.contains(where: { $0.stage == stage }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard all.contains(where: { $0.stage == stage }) else { throw CancellationError() }
    }
}
