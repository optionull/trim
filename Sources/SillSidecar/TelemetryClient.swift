import Foundation
@_exported import SillCore

public extension Sidecar {
    /// Starts streaming a running .NET program's logs, traces and metrics; batches come to `onBatch` until
    /// `stopTelemetry`. Returns the run's id.
    func startTelemetry(processId: Int, onBatch: @escaping @Sendable (TelemetryBatch) -> Void) throws -> Int {
        struct Params: Encodable { var processId: Int }
        return try send("telemetry", Params(processId: processId)) { data in
            if let batch = try? JSONDecoder().decode(TelemetryBatch.self, from: data) { onBatch(batch) }
        }
    }

    @discardableResult
    func stopTelemetry(run: Int) async throws -> Bool {
        struct Params: Encodable { var run: Int }
        return try await request("telemetry.stop", Params(run: run), as: Bool.self)
    }
}
