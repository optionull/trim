import AppKit
import SillSidecar

/// The .NET sidecar every open checkout shares: one dotnet process for the app, not one per checkout (each was 50 to
/// 95 MB, and a second checkout waited for its own to start). Started by the first workspace that asks, kept while sill
/// runs, stopped when it quits. Roslyn is provisioned through it once; each workspace's nvim starts its own server.
/// Nothing in the sidecar is a checkout's: profiles and telemetry are by run and process, Roslyn a shared cache.
@MainActor
final class SharedSidecar {
    static let shared = SharedSidecar()

    struct Started {
        var sidecar: Sidecar
        var ready: SidecarReady
        var seconds: Double
    }

    private var starting: Task<Started, Error>?
    private var provisioning: Task<RoslynServer, Error>?
    private var listeners: [(RoslynProgress) -> Void] = []

    /// The sidecar, started the first time (again after a start failed).
    func start() async throws -> Started {
        if let starting { return try await starting.value }
        let task = Task {
            let sidecar = Sidecar(), began = CACurrentMediaTime()
            let ready = try await sidecar.start(dll: SidecarFiles.dll)
            return Started(sidecar: sidecar, ready: ready, seconds: CACurrentMediaTime() - began)
        }
        starting = task
        do {
            return try await task.value
        } catch {
            starting = nil
            throw error
        }
    }

    /// Roslyn's server, provisioned once (downloaded the first time); each asker hears its progress.
    func roslyn(_ sidecar: Sidecar, progress: @escaping (RoslynProgress) -> Void) async throws -> RoslynServer {
        listeners.append(progress)
        if let provisioning { return try await provisioning.value }
        let task = Task {
            try await sidecar.roslyn { progress in
                Task { @MainActor in SharedSidecar.shared.listeners.forEach { $0(progress) } }
            }
        }
        provisioning = task
        defer { listeners = [] }
        do {
            return try await task.value
        } catch {
            provisioning = nil
            throw error
        }
    }

    /// Whether it was started (for the checks: one for every checkout).
    var started: Sidecar? {
        get async { try? await starting?.value.sidecar }
    }

    func stop() async {
        let sidecar = await started
        starting = nil
        provisioning = nil
        await sidecar?.stop()
    }
}
