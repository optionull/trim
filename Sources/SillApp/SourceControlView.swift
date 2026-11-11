import AppKit
import MessagePack
import SillEditor
import SillNvim

/// Source control in the sidebar: git's changed files, grouped as git groups them. Return (or a click) opens a file;
/// a modified one opens beside its version at HEAD (:SillDiff). The bones of boards 4 to 6.
final class SourceControlView: NSView, ToolContent {
    struct Entry: Equatable {
        var path: String
        var code: String
    }

    private let channel: NvimChannel
    private let root: String
    private(set) var entries: [Entry] = []
    private(set) var selected = 0
    private var branch = ""

    init(channel: NvimChannel, root: String) {
        self.channel = channel
        self.root = root
        super.init(frame: .zero)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    private let rowHeight: CGFloat = 26
    private let listTop: CGFloat = 34

    func refresh() {
        let root = root
        Task.detached {
            let status = Git.status(in: root), branch = Git.branch(in: root)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Staged and changed first, untracked last, each by path.
                let all = status.map { Entry(path: $0.key, code: $0.value) }
                let changed = all.filter { $0.code != "??" }.sorted { $0.path < $1.path }
                let untracked = all.filter { $0.code == "??" }.sorted { $0.path < $1.path }
                entries = changed + untracked
                self.branch = branch
                selected = min(selected, max(entries.count - 1, 0))
                needsDisplay = true
            }
        }
    }

    private func describe(_ code: String) -> (String, NSColor) {
        if code == "??" { return ("U", Design.accent) }
        if code.contains("D") { return ("D", Design.error) }
        if code.contains("A") { return ("A", Design.accent) }
        if code.contains("R") { return ("R", Design.visual) }
        return ("M", Design.modified)
    }

    override func draw(_: NSRect) {
        Design.chrome.setFill()
        bounds.fill()
        let heading = NSAttributedString(
            string: entries.isEmpty ? "No changes on \(branch)" : "\(entries.count) changed on \(branch)",
            attributes: [.font: Design.ui(12), .foregroundColor: Design.textMuted]
        )
        heading.draw(at: NSPoint(x: 16, y: 8))
        let focused = (superview as? SidebarView)?.focused ?? false
        for (index, entry) in entries.enumerated() {
            let rect = NSRect(x: 0, y: listTop + CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
            guard rect.minY < bounds.height else { break }
            if index == selected, focused {
                Design.selection.setFill()
                rect.fill()
            }
            let (letter, color) = describe(entry.code)
            let name = NSAttributedString(string: (entry.path as NSString).lastPathComponent, attributes: [
                .font: Design.ui(13), .foregroundColor: Design.text,
            ])
            name.draw(at: NSPoint(x: 16, y: rect.midY - name.size().height / 2))
            let folder = NSAttributedString(string: (entry.path as NSString).deletingLastPathComponent, attributes: [
                .font: Design.ui(11), .foregroundColor: Design.textFaint,
            ])
            folder.draw(
                with: NSRect(
                    x: 24 + name.size().width,
                    y: rect.midY - folder.size().height / 2,
                    width: max(bounds.width - 60 - name.size().width, 0),
                    height: folder.size().height
                ),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            let mark = NSAttributedString(string: letter, attributes: [
                .font: Design.ui(11, weight: .semibold), .foregroundColor: color,
            ])
            mark.draw(at: NSPoint(x: bounds.width - 20 - mark.size().width / 2, y: rect.midY - mark.size().height / 2))
        }
    }

    private func open(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        let path = (root as NSString).appendingPathComponent(entry.path)
        Nvim.lua(channel, "require'sill'.open(...)", [.string(path)])
        if entry.code != "??", !entry.code.contains("A"), !entry.code.contains("D") {
            Nvim.lua(channel, "require'sill'.diff('HEAD')")
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int((point.y - listTop) / rowHeight)
        guard point.y >= listTop, entries.indices.contains(index) else { return }
        selected = index
        open(index)
        needsDisplay = true
    }

    var keyKind: String { "changes" }

    func perform(_ command: String, key _: String) -> Bool {
        switch command {
        case "changes.down": selected = min(selected + 1, max(entries.count - 1, 0))
        case "changes.up": selected = max(selected - 1, 0)
        case "changes.open": open(selected)
        case "changes.refresh": refresh()
        default: return false
        }
        needsDisplay = true
        return true
    }
}
