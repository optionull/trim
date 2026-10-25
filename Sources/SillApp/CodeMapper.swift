import AppKit
import SillCore
import SillNvim

/// The code map: built from the repository when `:SillMap` opens it, with the agent's summary on top when it has
/// written one (`code_map_summary`, kept in the repository's .sill so it is there next time and never committed).
@MainActor
final class CodeMapper {
    private weak var app: AppDelegate?
    private let channel: NvimChannel
    let directory: String
    private(set) var map: CodeMap?
    private(set) var building = false
    /// The agent's summary, read from .sill when the map is built (not as sill starts, and never while drawing).
    private(set) var summary: String?
    private var handled = 0
    var onChange: (() -> Void)?

    init(app: AppDelegate, channel: NvimChannel, directory: String) {
        self.app = app
        self.channel = channel
        self.directory = directory
    }

    /// Where the agent's summary is kept: in the repository's .sill, beside the review walkthroughs.
    private var summaryFile: String? { Self.summaryFile(directory) }

    private nonisolated static func summaryFile(_ directory: String) -> String {
        SillFolder.path(for: directory) + "/map/summary.md"
    }

    private nonisolated static func readSummary(_ directory: String) -> String? {
        try? String(contentsOfFile: summaryFile(directory), encoding: .utf8)
    }

    /// nvim's asks: `:SillMap`.
    func update(_ screen: Screen) {
        guard screen.mapAsks > handled else { return }
        handled = screen.mapAsks
        show()
    }

    func show() {
        Nvim.lua(channel, "require'sill'.show_pane('map')")
        if map == nil { rebuild() }
    }

    /// Builds the map again, off the main thread.
    func rebuild() {
        guard !building else { return }
        building = true
        onChange?()
        let directory = directory
        Task {
            let (map, summary) = await Task.detached {
                (CodeMap.build(root: directory), Self.readSummary(directory))
            }.value
            self.map = map
            if self.summary == nil { self.summary = summary }
            building = false
            onChange?()
        }
    }

    /// The map, built if it is not yet: what `code_map` answers.
    func current() async -> CodeMap {
        if let map { return map }
        let directory = directory
        let (map, summary) = await Task.detached { (CodeMap.build(root: directory), Self.readSummary(directory)) }.value
        self.map = map
        if self.summary == nil { self.summary = summary }
        onChange?()
        return map
    }

    func setSummary(_ text: String) {
        summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let file = summaryFile {
            try? FileManager.default.createDirectory(
                atPath: (file as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try? summary?.write(toFile: file, atomically: true, encoding: .utf8)
        }
        onChange?()
    }

    /// A file of the map (from the repository's root), in the editor.
    func open(_ path: String, line: Int = 1) {
        let file = (directory as NSString).appendingPathComponent(path)
        Nvim.lua(channel, "require'sill'.open_beside(...)", [.string(file), .int(Int64(line))])
    }

    // MARK: Asking the agent

    func askForSummary() {
        guard let map, let agents = app?.agents else { return }
        agents.send(headline: "Summarise this codebase for someone new to it", """
        Read enough of the code in \(directory) to explain it to someone who has never seen it: what it is for, how \
        it is put together, and where to start reading. Five to ten sentences, plain prose; name projects and files \
        in `code spans`. sill's code map of it:

        \(map.text)

        Then call sill's code_map_summary tool with the summary, so it shows on top of the map.
        """)
    }

    func askForTour() {
        guard let map, let agents = app?.agents, let summaryFile else { return }
        let path = (summaryFile as NSString).deletingLastPathComponent + "/tour.walk.md"
        agents.send(headline: "Write a walkthrough of this codebase for someone new to it", """
        Write a walkthrough of the codebase in \(directory) for someone new to it, following the sill-walkthrough \
        skill: from an entry point through the main flow to the places where the interesting decisions are. Write it \
        to \(path) (a throwaway in .sill). sill's code map of it:

        \(map.text)

        Then call sill's walkthrough_check with its path, fix what it reports, and call walkthrough_open.
        """)
    }
}
