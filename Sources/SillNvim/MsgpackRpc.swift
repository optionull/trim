// Lifted from Veil (https://github.com/0x1b2c/Veil, MIT, a29c3d0); see THIRD_PARTY_NOTICES.md.
import Foundation
import MessagePack

public enum RpcMessage: Sendable {
    case response(msgid: UInt32, error: MessagePackValue, result: MessagePackValue)
    case notification(method: String, params: MessagePackValue)
    case request(msgid: UInt32, method: String, params: MessagePackValue)
}

public actor MsgpackRpc {
    private var nextMsgid: UInt32 = 0
    private var pendingRequests:
        [UInt32: CheckedContinuation<(error: MessagePackValue, result: MessagePackValue), Never>] =
        [:]
    private var eventContinuation: AsyncStream<RpcMessage>.Continuation?
    private var isClosed = false

    private let transport: RpcTransport

    public lazy var notifications: AsyncStream<RpcMessage> = AsyncStream { continuation in
        self.eventContinuation = continuation
    }

    public init(transport: RpcTransport) {
        self.transport = transport
    }

    public func start() async {
        var accumulated = Data()
        for await chunk in transport.dataStream {
            accumulated.append(chunk)
            let messages: [RpcMessage]
            do {
                messages = try Self.decodeAccumulated(data: &accumulated)
            } catch {
                continue
            }
            for message in messages {
                switch message {
                case let .response(msgid, error, result):
                    if let continuation = pendingRequests.removeValue(forKey: msgid) {
                        continuation.resume(returning: (error, result))
                    }
                case .notification, .request:
                    eventContinuation?.yield(message)
                }
            }
        }
        // Latch closed BEFORE draining so any caller awaiting actor entry
        // after this point fails fast instead of queueing into pendingRequests
        // with no one left to resolve them.
        isClosed = true
        eventContinuation?.finish()
        for (_, continuation) in pendingRequests {
            continuation.resume(returning: (error: .string("channel closed"), result: .nil))
        }
        pendingRequests.removeAll()
    }

    public func request(method: String, params: [MessagePackValue]) async -> (
        error: MessagePackValue, result: MessagePackValue
    ) {
        if isClosed {
            return (error: .string("channel closed"), result: .nil)
        }
        let msgid = nextMsgid
        nextMsgid += 1
        let data = Self.encodeRequest(msgid: msgid, method: method, params: params)

        return await withCheckedContinuation { continuation in
            pendingRequests[msgid] = continuation
            do {
                try transport.write(data)
            } catch {
                pendingRequests.removeValue(forKey: msgid)
                continuation.resume(
                    returning: (
                        error: .string("write failed: \(error.localizedDescription)"), result: .nil
                    ))
            }
        }
    }

    public func respond(msgid: UInt32, error: MessagePackValue = .nil, result: MessagePackValue) {
        let data = Self.encodeResponse(msgid: msgid, error: error, result: result)
        try? transport.write(data)
    }

    // MARK: - Static encode/decode (testable without actor)

    public nonisolated static func encodeResponse(
        msgid: UInt32, error: MessagePackValue, result: MessagePackValue
    ) -> Data {
        let message: MessagePackValue = .array([
            .uint(1),
            .uint(UInt64(msgid)),
            error,
            result,
        ])
        return pack(message)
    }

    public nonisolated static func encodeRequest(msgid: UInt32, method: String, params: [MessagePackValue])
        -> Data
    {
        let message: MessagePackValue = .array([
            .uint(0),
            .uint(UInt64(msgid)),
            .string(method),
            .array(params),
        ])
        return pack(message)
    }

    public nonisolated static func decode(data: Data) throws -> [RpcMessage] {
        var mutableData = data
        return try decodeAccumulated(data: &mutableData)
    }

    public nonisolated static func decodeAccumulated(data: inout Data) throws -> [RpcMessage] {
        var messages: [RpcMessage] = []
        // Pass the shrinking remainder through the loop instead of copying
        // it back into `data` on each iteration. Only update `data` once
        // at the end to discard consumed bytes.
        var remaining = data
        while !remaining.isEmpty {
            let value: MessagePackValue
            let next: Data
            do {
                (value, next) = try unpack(remaining)
            } catch {
                // Incomplete data — stop decoding, leave remainder as-is
                break
            }
            remaining = next
            guard let array = value.arrayValue, array.count >= 3 else { continue }
            guard let type = array[0].uint64Value else { continue }

            switch type {
            case 0: // request
                guard array.count >= 4,
                      let msgid = array[1].uint64Value,
                      let method = array[2].stringValue
                else { continue }
                messages.append(.request(msgid: UInt32(msgid), method: method, params: array[3]))
            case 1: // response
                guard array.count >= 4,
                      let msgid = array[1].uint64Value
                else { continue }
                messages.append(.response(msgid: UInt32(msgid), error: array[2], result: array[3]))
            case 2: // notification
                guard let method = array[1].stringValue else { continue }
                messages.append(.notification(method: method, params: array[2]))
            default:
                continue
            }
        }
        data = remaining
        return messages
    }
}

public extension MessagePackValue {
    nonisolated var intValue: Int {
        switch self {
        case let .int(v): return Int(v)
        case let .uint(v): return Int(v)
        case let .extended(_, data):
            // Neovim sends buffer, window and tabpage handles as msgpack ext types whose payload is the handle,
            // itself msgpack-encoded (window 1001 is `cd 03 e9`). Veil read the payload as a raw little-endian
            // integer, which gives the wrong number for every handle that does not fit in a positive fixint.
            guard let (value, _) = try? unpack(data) else { return 0 }
            return value.intValue
        default: return 0
        }
    }
}
