import Foundation
@testable import SillCore
import SillNvim

/// sill's runtime directory in the source tree.
let runtimeDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("runtime")

struct Timeout: Error, CustomStringConvertible {
    var description: String
}

/// A real `nvim --embed --clean` with sill's runtime, attached as a multigrid UI, and every update it sent.
actor Harness {
    let session = EditorSession()
    private(set) var latest: ScreenUpdate?
    private var collector: Task<Void, Never>?

    static func start(
        cols: Int = 80, rows: Int = 24, beforeAttach: @Sendable (EditorSession) async -> Void = { _ in }
    ) async throws -> Harness {
        let harness = Harness()
        await harness.collect()
        await beforeAttach(harness.session)
        try await harness.session.start(
            runtime: runtimeDirectory, cols: cols, rows: rows, appName: "sill-tests", extraArgs: ["--clean", "-n"]
        )
        return harness
    }

    private func collect() {
        let updates = session.updates
        collector = Task { [weak self] in
            for await update in updates {
                await self?.record(update)
            }
        }
    }

    private func record(_ update: ScreenUpdate) {
        latest = update
    }

    func keys(_ keys: String) async {
        await session.channel.send(keys: keys)
    }

    func command(_ command: String) async throws {
        try await session.channel.command(command)
    }

    /// Waits until the latest screen satisfies `predicate`, and returns it.
    @discardableResult
    func screen(
        _ what: String, timeout: Duration = .seconds(5), _ predicate: @Sendable (Screen) -> Bool
    ) async throws -> Screen {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let screen = latest?.screen, predicate(screen) { return screen }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Timeout(description: "timed out waiting for \(what); last screen: \(describe(latest?.screen))")
    }

    func stop() async {
        await session.stop()
        collector?.cancel()
    }

    private nonisolated func describe(_ screen: Screen?) -> String {
        guard let screen else { return "none" }
        let placements = screen.placements.sorted { $0.key < $1.key }
            .map { "grid \($0.key): win \($0.value.win) \($0.value.kind) at \($0.value.row),\($0.value.col) " +
                "\($0.value.width)x\($0.value.height)\($0.value.hidden ? " hidden" : "")"
            }
        return "cursor grid \(screen.cursorGrid), placements [\(placements.joined(separator: "; "))]"
    }
}

extension Screen {
    /// The window grids' placements, left to right.
    var windows: [(grid: Int, placement: Placement)] {
        placements.filter { $0.value.kind == .window && !$0.value.hidden }
            .map { (grid: $0.key, placement: $0.value) }
            .sorted { ($0.placement.row, $0.placement.col) < ($1.placement.row, $1.placement.col) }
    }
}
