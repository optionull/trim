import Foundation
import MessagePack
import SillNvim
import Testing

@Suite("msgpack-RPC")
struct RpcTests {
    @Test("window handles decode from their ext payload", arguments: [1, 127, 1000, 1001, 65536, 2_000_000])
    func handles(handle: Int) {
        // nvim's Window ext type (1): the payload is the handle, msgpack-encoded.
        let value = MessagePackValue.extended(1, pack(.uint(UInt64(handle))))
        #expect(value.intValue == handle)
    }

    @Test("a redraw batch split across reads decodes once complete")
    func splitBatch() throws {
        let message = MessagePackValue.array([
            .uint(2),
            .string("redraw"),
            .array([.array([.string("flush"), .array([])])]),
        ])
        let bytes = pack(message)
        var buffer = Data(bytes.prefix(5))
        #expect(try MsgpackRpc.decodeAccumulated(data: &buffer).isEmpty)
        buffer.append(bytes.dropFirst(5))
        let messages = try MsgpackRpc.decodeAccumulated(data: &buffer)
        #expect(messages.count == 1 && buffer.isEmpty)
    }
}
