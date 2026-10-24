import Foundation
@testable import SillCore
import Testing

@Suite("native profiles: samply's and xctrace's, as a profile document")
struct NativeProfilesTests {
    /// samply's processed format, trimmed to what is read: one thread, three frames (main, total in the program, an
    /// unsymbolicated system frame), and its symbols with total's file and line.
    private let samply = """
    {"meta": {"interval": 1.0, "product": "app"},
     "libs": [{"name": "app", "codeId": "AAAA", "debugName": "app"}, {"name": "libsystem_m.dylib", "codeId": "BBBB"}],
     "threads": [{"name": "app", "stringArray": ["app", "0x10", "0x20", "libsystem_m.dylib", "0x99"],
       "samples": {"stack": [1, 2, 2, 1, null], "weight": [1, 1, 1, 1, 1], "time": [0, 1, 2, 3, 4]},
       "stackTable": {"prefix": [null, 0, 1], "frame": [0, 1, 2]},
       "frameTable": {"func": [0, 1, 2], "address": [16, 32, 153]},
       "funcTable": {"name": [1, 2, 4], "resource": [0, 0, 1]},
       "resourceTable": {"lib": [0, 1], "name": [0, 3]}}]}
    """

    private let symbols = """
    {"string_table": ["main", "app::pricing::total", "/w/src/main.rs", "total"],
     "data": [{"debug_name": "app", "code_id": "AAAA", "symbol_table": [
       {"rva": 16, "size": 8, "symbol": 0, "frames": [{"function": 0, "file": 2, "line": 20}]},
       {"rva": 32, "size": 8, "symbol": 1, "frames": [{"function": 3, "file": 2, "line": 6}, {"function": 3, "file": 2, "line": 5}]}],
      "known_addresses": [[16, 0], [32, 1]]}]}
    """

    @Test("samply: symbols from the file beside it (the symbol's whole name), a system frame named for its library")
    func samplyDocument() throws {
        let document = try SamplyProfile.document(
            profile: Data(samply.utf8), symbols: Data(symbols.utf8), name: "app", exited: true
        )
        #expect(document.samples == 4, "a sample with no stack is not counted")
        let tree = document.preorder.map { (document.names[$0.name], $0.depth, $0.samples) }
        // The thread named for the process is the main thread; total's own frame, given twice, is one.
        #expect(tree.map(\.0) == ["app", "main thread", "main", "app::pricing::total", "[libsystem_m.dylib]"])
        #expect(tree.map(\.2) == [4, 4, 4, 4, 2])
        let hot = try #require(document.hotSpots.first)
        #expect(hot.name == "[libsystem_m.dylib]" && hot.selfSamples == 2)
        let total = try #require(document.hotSpots.first { $0.name == "app::pricing::total" })
        #expect(total.selfSamples == 2 && total.total == 4 && total.file == "/w/src/main.rs" && total.line == 6)
        #expect(document.durationMs == 3)
    }

    /// xctrace's export, trimmed: a frame named once and referred to after, a backtrace referred to whole, an
    /// unsymbolicated frame.
    private let xctrace = """
    <?xml version="1.0"?>
    <trace-query-result><node>
    <row><sample-time id="1" fmt="00:00.001">1000000</sample-time>
      <thread id="2" fmt="Main Thread (0x1) (app, pid: 7)"><tid id="3">1</tid></thread>
      <weight id="4" fmt="1.00 ms">1000000</weight>
      <tagged-backtrace id="5">
        <frame id="6" name="Pricing.total(_:)" addr="0x1"><binary id="7" name="app"/><source line="9"><path id="8">/w/main.swift</path></source></frame>
        <frame id="9" name="main" addr="0x2"><binary ref="7"/><source line="20"><path ref="8"/></source></frame>
      </tagged-backtrace></row>
    <row><sample-time id="10" fmt="00:00.002">2000000</sample-time><thread ref="2"/><weight ref="4"/>
      <tagged-backtrace ref="5"/></row>
    <row><sample-time id="11" fmt="00:00.003">3000000</sample-time><thread ref="2"/><weight ref="4"/>
      <tagged-backtrace id="12"><frame id="13" name="0x19953c0f4" addr="0x19953c0f4"><binary id="14" name="libsystem_m.dylib"/></frame>
        <frame ref="6"/><frame ref="9"/></tagged-backtrace></row>
    </node></trace-query-result>
    """

    @Test("xctrace: ids and refs, a whole backtrace referred to, leaf first, file and line")
    func xctraceDocument() throws {
        let document = try XctraceProfile.document(xml: Data(xctrace.utf8), name: "app", exited: false)
        #expect(document.samples == 3)
        #expect(document.sampleMs == 1)
        let tree = document.preorder.map { (document.names[$0.name], $0.depth, $0.samples) }
        #expect(tree.map(\.0) == ["app", "Main Thread", "main", "Pricing.total(_:)", "[libsystem_m.dylib]"])
        #expect(tree.map(\.2) == [3, 3, 3, 3, 1])
        let total = try #require(document.hotSpots.first { $0.name == "Pricing.total(_:)" })
        #expect(total.selfSamples == 2 && total.total == 3 && total.file == "/w/main.swift" && total.line == 9)
        #expect(document.durationMs == 2)
    }
}
