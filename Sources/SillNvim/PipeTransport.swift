// Lifted from Veil (https://github.com/0x1b2c/Veil, MIT, a29c3d0); see THIRD_PARTY_NOTICES.md.
import Foundation

/// Transport that wraps a pair of Foundation pipes (stdin/stdout),
/// used for communicating with a local nvim process.
public final class PipeTransport: RpcTransport, @unchecked Sendable {
    private let writePipe: FileHandle
    private let readPipe: FileHandle
    private let streamContinuation: AsyncStream<Data>.Continuation

    private let finishLock = NSLock()
    private nonisolated(unsafe) var isFinished = false

    public let dataStream: AsyncStream<Data>

    public nonisolated init(writePipe: FileHandle, readPipe: FileHandle) {
        self.writePipe = writePipe
        self.readPipe = readPipe

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        dataStream = stream
        streamContinuation = continuation

        readPipe.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                finishStream()
                return
            }
            streamContinuation.yield(data)
        }
    }

    /// Writes and closing under one lock: a write after the pipe closed throws, rather than reaching a closed handle,
    /// which raises an Objective-C exception no Swift code can catch (the input loop's last request racing `stop`).
    private let writeLock = NSLock()
    private nonisolated(unsafe) var writeClosed = false

    public struct Closed: Error {}

    public nonisolated func write(_ data: Data) throws {
        try writeLock.withLock {
            guard !writeClosed else { throw Closed() }
            try writePipe.write(contentsOf: data)
        }
    }

    public nonisolated func close() {
        writeLock.withLock {
            guard !writeClosed else { return }
            writeClosed = true
            try? writePipe.close()
        }
        // readPipe is owned by the Process's stdout pipe; closing it here
        // would race with the readabilityHandler. Let the Process teardown
        // handle it.
        finishStream()
    }

    // MARK: - Private

    /// Idempotent termination: detaches the readabilityHandler and finishes
    /// the stream exactly once. The handler must be cleared before finishing
    /// because Foundation can otherwise keep invoking it with empty data
    /// after the remote pipe closes, busy-looping the dispatch queue.
    private nonisolated func finishStream() {
        finishLock.lock()
        if isFinished {
            finishLock.unlock()
            return
        }
        isFinished = true
        finishLock.unlock()

        readPipe.readabilityHandler = nil
        streamContinuation.finish()
    }
}
