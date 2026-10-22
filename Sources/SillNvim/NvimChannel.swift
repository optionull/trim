// Lifted from Veil (https://github.com/0x1b2c/Veil, MIT, a29c3d0); see THIRD_PARTY_NOTICES.md.
// Changed for sill: notifications other than `redraw` are delivered as events in order with the redraw batches,
// `ui_attach` takes its options from the caller, input goes through one ordered queue, and Veil's own commands and
// clipboard handlers are gone.
import Foundation
import MessagePack

public actor NvimChannel {
    private var process: NvimProcess?
    private var rpc: MsgpackRpc?
    private var transport: RpcTransport?
    private var eventContinuation: AsyncStream<[NvimEvent]>.Continuation?
    private var rpcTask: Task<Void, Never>?
    private let inputContinuation: AsyncStream<String>.Continuation
    private var inputTask: Task<Void, Never>?

    /// Events are delivered in batches (one array per redraw notification) to reduce actor isolation boundary
    /// crossings. A single redraw with 50 grid_line events becomes one yield instead of 50.
    public nonisolated let events: AsyncStream<[NvimEvent]>

    private let inputs: AsyncStream<String>

    public init() {
        let (stream, continuation) = AsyncStream<[NvimEvent]>.makeStream()
        events = stream
        eventContinuation = continuation
        (inputs, inputContinuation) = AsyncStream<String>.makeStream()
    }

    public func start(
        nvimPath: String = "", cwd: String = NSHomeDirectory(), appName: String = "nvim",
        extraArgs: [String] = [], env: [String: String]? = nil
    ) throws {
        let proc = NvimProcess(nvimPath: nvimPath, cwd: cwd, appName: appName, customEnv: env, extraArgs: extraArgs)
        try proc.start()
        process = proc

        let pipeTransport = PipeTransport(
            writePipe: proc.stdinPipe.fileHandleForWriting,
            readPipe: proc.stdoutPipe.fileHandleForReading
        )
        transport = pipeTransport
        startRpcEventLoop(transport: pipeTransport)
        startInputLoop()
    }

    private func startRpcEventLoop(transport: RpcTransport) {
        let rpc = MsgpackRpc(transport: transport)
        self.rpc = rpc

        rpcTask = Task {
            // Access notifications before starting the receive loop so the lazy var is initialized (and the
            // continuation is stored) on the MsgpackRpc actor.
            let notifications = await rpc.notifications
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await rpc.start() }
                group.addTask {
                    for await message in notifications {
                        switch message {
                        case let .notification(method, params):
                            let args = params.arrayValue ?? []
                            if method == "redraw" {
                                let events = NvimEvent.parse(redrawArgs: args)
                                // Yield the entire redraw batch at once to amortize actor isolation crossings.
                                if !events.isEmpty { await self.yieldBatch(events) }
                            } else {
                                await self.yieldBatch([.notification(method: method, args: args)])
                            }
                        case let .request(msgid, method, _):
                            await rpc.respond(
                                msgid: msgid, error: .string("sill: unknown request \(method)"), result: .nil
                            )
                        case .response:
                            break
                        }
                    }
                }
                await group.waitForAll()
            }
            self.finishEvents()
        }
    }

    /// Keys are sent by one task in the order they were queued. A task per key, as Veil had, may run out of order.
    private func startInputLoop() {
        let inputs = inputs
        inputTask = Task {
            for await keys in inputs {
                _ = await self.request("nvim_input", params: [.string(keys)])
            }
        }
    }

    private func yieldBatch(_ events: [NvimEvent]) {
        eventContinuation?.yield(events)
    }

    private func finishEvents() {
        eventContinuation?.finish()
    }

    /// Attaches as a UI. `options` are `nvim_ui_attach` options such as `ext_linegrid` and `ext_multigrid`; `rgb` is
    /// always on.
    public func uiAttach(width: Int, height: Int, options: [String: Bool]) async throws {
        var map: [MessagePackValue: MessagePackValue] = [.string("rgb"): .bool(true)]
        for (key, value) in options {
            map[.string(key)] = .bool(value)
        }
        let (error, _) = await request("nvim_ui_attach", params: [.int(Int64(width)), .int(Int64(height)), .map(map)])
        try Self.check(error, "ui_attach")
    }

    /// Queues keys in nvim's notation (`<C-w>h`). Never waits: safe to call from the main thread.
    public nonisolated func send(keys: String) {
        inputContinuation.yield(keys)
    }

    public func command(_ cmd: String) async throws {
        let (error, _) = await request("nvim_command", params: [.string(cmd)])
        try Self.check(error, "command")
    }

    /// Runs `nvim_exec_lua` and returns its result.
    public func lua(_ code: String, args: [MessagePackValue] = []) async throws -> MessagePackValue {
        let (error, result) = await request("nvim_exec_lua", params: [.string(code), .array(args)])
        try Self.check(error, "exec_lua")
        return result
    }

    /// This client's channel id, which `rpcnotify` in nvim needs to reach it.
    public func channelId() async throws -> Int {
        let (error, result) = await request("nvim_get_api_info", params: [])
        try Self.check(error, "get_api_info")
        return result.arrayValue?.first?.intValue ?? 0
    }

    public func request(_ method: String, params: [MessagePackValue]) async -> (
        error: MessagePackValue, result: MessagePackValue
    ) {
        guard let rpc else { return (.string("not connected"), .nil) }
        return await rpc.request(method: method, params: params)
    }

    public func uiTryResize(width: Int, height: Int) async {
        _ = await request("nvim_ui_try_resize", params: [.int(Int64(width)), .int(Int64(height))])
    }

    public func inputMouse(button: String, action: String, modifier: String, grid: Int, row: Int, col: Int) async {
        _ = await request(
            "nvim_input_mouse",
            params: [
                .string(button), .string(action), .string(modifier),
                .int(Int64(grid)), .int(Int64(row)), .int(Int64(col)),
            ]
        )
    }

    public func stop() {
        rpcTask?.cancel()
        inputTask?.cancel()
        inputContinuation.finish()
        transport?.close()
        process?.stop()
        eventContinuation?.finish()
    }

    private static func check(_ error: MessagePackValue, _ what: String) throws {
        if error == .nil { return }
        // nvim reports API errors as [type, message].
        let message = error.arrayValue?.last?.stringValue ?? error.stringValue ?? "\(error)"
        throw NvimChannelError.rpcError("\(what): \(message)")
    }
}

public nonisolated enum NvimChannelError: Error, LocalizedError {
    case rpcError(String)

    public var errorDescription: String? {
        switch self {
        case let .rpcError(msg): "Neovim RPC error: \(msg)"
        }
    }
}
