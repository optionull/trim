// Lifted from Veil (https://github.com/0x1b2c/Veil, MIT, a29c3d0); see THIRD_PARTY_NOTICES.md.
import Foundation

/// Abstraction over the byte-level transport used by MsgpackRpc.
/// Implementations provide a stream of incoming data chunks and a way
/// to write outgoing data. The protocol is actor-compatible: all
/// requirements are async or nonisolated.
public protocol RpcTransport: Sendable {
    /// Incoming data chunks from the remote end (e.g. nvim stdout or TCP socket).
    nonisolated var dataStream: AsyncStream<Data> { get }
    /// Send data to the remote end (e.g. nvim stdin or TCP socket).
    nonisolated func write(_ data: Data) throws
    /// Tear down the connection.
    nonisolated func close()
}
