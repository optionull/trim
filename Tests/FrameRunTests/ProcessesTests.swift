@testable import FrameRun
import Testing

@Suite("Process usage")
struct ProcessesTests {
    private let table = """
      100     1   0.0   9000 /Applications/Frame.app/Contents/MacOS/Frame
      200   100   1.5  50000 nvim --embed
      300   200  12.0 420000 /cache/roslyn-language-server --stdio
      301   300  30.5 210000 dotnet exec BuildHost.dll
      302   301   4.0  10000 dotnet exec Worker.dll
      400   200   0.5  30000 /cache/marksman server
      500     1   9.9  99999 /usr/bin/other
    """

    @Test("rows are parsed, the command keeping its spaces")
    func parse() {
        let rows = Processes.parse(table)
        #expect(rows.count == 7)
        #expect(rows[2] == ProcessRow(
            pid: 300,
            parent: 200,
            cpu: 12.0,
            memoryKB: 420_000,
            command: "/cache/roslyn-language-server --stdio"
        ))
    }

    @Test("a server's use is its process and everything it started; another server's is not in it")
    func usage() throws {
        let rows = Processes.parse(table)
        let roslyn = try #require(Processes.usage(of: "roslyn-language-server", below: 200, in: rows))
        #expect(roslyn.pid == 300 && roslyn.processes == 3)
        #expect(roslyn.memoryKB == 640_000 && abs(roslyn.cpu - 46.5) < 0.001)
        let marksman = try #require(Processes.usage(of: "marksman", below: 200, in: rows))
        #expect(marksman.processes == 1 && marksman.memoryKB == 30000)
        #expect(Processes.usage(of: "other", below: 200, in: rows) == nil, "not below the editor")
        #expect(Processes.usage(of: "rust-analyzer", below: 200, in: rows) == nil, "not running")
    }

    @Test("sizes read as people say them")
    func size() {
        #expect(Processes.size(kilobytes: 1536) == "1.5 MB")
        #expect(Processes.size(kilobytes: 420_000) == "410 MB")
        #expect(Processes.size(kilobytes: 3 * 1024 * 1024) == "3.0 GB")
    }
}
