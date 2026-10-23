import AppKit
import MessagePack
import SillCore
import SillNvim
import SillRender

/// The explorer (board 1): the project's files as a tree, read from disk as folders open, with git's changes marked
/// and ignored files hidden until asked for. It is drawn over the sidebar's placeholder window; while that window is
/// current it takes j/k, Return, h/l, `/` to filter and `I` for ignored files, and every other key goes to nvim.
final class ExplorerView: NSView, ToolContent {
    struct Row: Equatable {
        var path: String
        var name: String
        var depth: Int
        var isDirectory: Bool
        var ignored: Bool
    }

    let root: String
    private let channel: NvimChannel
    private let metrics: CellMetrics
    private(set) var rows: [Row] = []
    private(set) var selected = 0
    private(set) var expanded: Set<String>
    private(set) var showIgnored = false
    private(set) var filter: String?
    private var top = 0
    /// git's view: changes by path (relative to the root), and what is ignored.
    private(set) var status: [String: String] = [:]
    private(set) var ignored: Set<String> = []
    private var currentFile = ""
    private var footerShow = NSRect.zero

    init(channel: NvimChannel, root: String, metrics: CellMetrics) {
        self.channel = channel
        self.root = (root as NSString).standardizingPath
        self.metrics = metrics
        expanded = [self.root]
        super.init(frame: .zero)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var rowHeight: CGFloat { 26 }
    private var listTop: CGFloat { filter == nil ? 4 : 40 }
    private static let footer: CGFloat = 36

    // MARK: Reading the tree

    /// Reads git's status and ignored files again, and the tree.
    func refresh() {
        let root = root
        Task.detached {
            let changes = Git.status(in: root)
            let ignored = Git.ignored(in: root)
            await MainActor.run { [weak self] in
                self?.status = changes
                self?.ignored = ignored
                self?.rebuild()
            }
        }
        rebuild()
    }

    /// The current file, highlighted and revealed.
    func reveal(_ path: String) {
        guard path != currentFile else { return }
        currentFile = path
        guard path.hasPrefix(root + "/") else {
            needsDisplay = true
            return
        }
        var folder = (path as NSString).deletingLastPathComponent
        while folder.count > root.count {
            expanded.insert(folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
        rebuild()
        if let index = rows.firstIndex(where: { $0.path == path }) { selected = index }
        needsDisplay = true
    }

    private func relative(_ path: String) -> String {
        path == root ? "" : String(path.dropFirst(root.count + 1))
    }

    private func isIgnored(_ path: String, directory: Bool) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == ".git" { return true }
        let relativePath = relative(path)
        return ignored.contains(relativePath) || (directory && ignored.contains(relativePath + "/"))
    }

    private func rebuild() {
        var rows: [Row] = [Row(
            path: root,
            name: (root as NSString).lastPathComponent,
            depth: 0,
            isDirectory: true,
            ignored: false
        )]
        func walk(_ folder: String, depth: Int) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            let entries = names.map { name -> (String, Bool) in
                var isDirectory: ObjCBool = false
                let path = (folder as NSString).appendingPathComponent(name)
                FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                return (path, isDirectory.boolValue)
            }
            .sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 : (lhs.0 as NSString).lastPathComponent
                    .localizedStandardCompare((rhs.0 as NSString).lastPathComponent) == .orderedAscending
            }
            for (path, isDirectory) in entries {
                let ignored = isIgnored(path, directory: isDirectory)
                if ignored, !showIgnored { continue }
                let name = (path as NSString).lastPathComponent
                if let filter, !filter.isEmpty, !isDirectory,
                   !name.localizedCaseInsensitiveContains(filter) { continue }
                rows.append(Row(path: path, name: name, depth: depth, isDirectory: isDirectory, ignored: ignored))
                if isDirectory, expanded.contains(path) || (filter.map { !$0.isEmpty } ?? false) && !ignored {
                    walk(path, depth: depth + 1)
                }
            }
        }
        if expanded.contains(root) { walk(root, depth: 1) }
        if let filter, !filter.isEmpty {
            // Folders with nothing that matches go.
            rows = rows.enumerated().filter { index, row in
                guard row.isDirectory, row.depth > 0 else { return true }
                return rows.dropFirst(index + 1).prefix { $0.depth > row.depth }.contains { !$0.isDirectory }
            }.map(\.element)
        }
        self.rows = rows
        selected = min(selected, max(rows.count - 1, 0))
        needsDisplay = true
    }

    /// The ignored entries at the top level, for the footer: what is hidden.
    private var hiddenAtTop: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { name in
            var isDirectory: ObjCBool = false
            let path = (root as NSString).appendingPathComponent(name)
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return name != ".git" && isIgnored(path, directory: isDirectory.boolValue)
        }.sorted()
    }

    /// git's mark for a row: its own change, or for a folder whether anything under it changed.
    private func mark(_ row: Row) -> (String, NSColor)? {
        let path = relative(row.path)
        if !row.isDirectory, let code = status[path] {
            let color = code == "??" || code.contains("A") ? Design.accent : code.contains("D") ? Design.error :
                Design.modified
            return (code == "??" ? "U" : String(code.trimmingCharacters(in: .whitespaces).prefix(1)), color)
        }
        if row.isDirectory, row.depth > 0, status.keys.contains(where: { $0.hasPrefix(path + "/") }) {
            return ("●", Design.modified)
        }
        return nil
    }

    // MARK: Drawing

    override func draw(_: NSRect) {
        Design.chrome.setFill()
        bounds.fill()
        if let filter {
            let box = NSRect(x: 12, y: 6, width: bounds.width - 24, height: 28)
            Design.editor.setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            Design.accent.setStroke()
            NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).stroke()
            NSAttributedString(string: filter.isEmpty ? "Filter files" : filter, attributes: [
                .font: Design.ui(12), .foregroundColor: filter.isEmpty ? Design.textFaint : Design.text,
            ]).draw(at: NSPoint(x: box.minX + 10, y: box.minY + 6))
        }
        let footer = bounds.height - Self.footer
        let visible = max(Int((footer - listTop) / rowHeight), 1)
        if selected < top { top = selected }
        if selected >= top + visible { top = selected - visible + 1 }
        top = min(top, max(rows.count - visible, 0))
        let focused = (superview as? SidebarView)?.focused ?? false
        for (offset, row) in rows.dropFirst(top).prefix(visible).enumerated() {
            let index = top + offset
            let rect = NSRect(x: 0, y: listTop + CGFloat(offset) * rowHeight, width: bounds.width, height: rowHeight)
            let current = row.path == currentFile
            if index == selected, focused || current {
                (focused ? Design.selection : Design.selection.withAlphaComponent(0.6)).setFill()
                rect.fill()
                if focused {
                    Design.accent.setFill()
                    NSRect(x: 0, y: rect.minY, width: 2, height: rect.height).fill()
                }
            }
            var x = 12 + CGFloat(row.depth) * 14
            if row.isDirectory {
                let chevron = expanded.contains(row.path) ? "chevron.down" : "chevron.right"
                symbol(chevron, size: 9, color: Design.textFaint, at: NSPoint(x: x, y: rect.midY))
            }
            x += 14
            symbol(
                row.isDirectory ? "folder" : Self.icon(row.name),
                size: 12,
                color: row.isDirectory ? Design.textMuted : Self.tint(row.name),
                at: NSPoint(x: x, y: rect.midY)
            )
            x += 20
            let mark = mark(row)
            let color = row.ignored ? Design.textFaint : mark?.0 == "M" ? Design.modified : Design.text
            let name = NSAttributedString(string: row.name, attributes: [
                .font: Design.ui(13, weight: row.depth == 0 ? .semibold : .regular), .foregroundColor: color,
            ])
            name.draw(
                with: NSRect(
                    x: x,
                    y: rect.minY + (rowHeight - name.size().height) / 2,
                    width: bounds.width - x - 30,
                    height: name.size().height
                ),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            if let (text, markColor) = mark {
                let label = NSAttributedString(string: text, attributes: [
                    .font: Design.ui(11, weight: .semibold), .foregroundColor: markColor,
                ])
                label.draw(at: NSPoint(
                    x: bounds.width - 18 - label.size().width / 2,
                    y: rect.midY - label.size().height / 2
                ))
            }
        }
        drawFooter(at: footer)
    }

    private func drawFooter(at y: CGFloat) {
        Design.border.setFill()
        NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
        let hidden = hiddenAtTop
        guard !hidden.isEmpty else {
            footerShow = .zero
            return
        }
        symbol(
            showIgnored ? "eye" : "eye.slash",
            size: 11,
            color: Design.textMuted,
            at: NSPoint(x: 18, y: y + Self.footer / 2)
        )
        let toggle = NSAttributedString(string: showIgnored ? "Hide" : "Show", attributes: [
            .font: Design.ui(12, weight: .semibold), .foregroundColor: Design.accent,
        ])
        footerShow = NSRect(
            x: bounds.width - 14 - toggle.size().width,
            y: y,
            width: toggle.size().width + 14,
            height: Self.footer
        )
        toggle.draw(at: NSPoint(x: footerShow.minX, y: y + (Self.footer - toggle.size().height) / 2))
        let summary = showIgnored ? "\(hidden.count) ignored shown" :
            "\(hidden.count) ignored hidden: " + hidden.prefix(3)
            .joined(separator: ", ") + (hidden.count > 3 ? "…" : "")
        NSAttributedString(string: summary, attributes: [.font: Design.ui(12), .foregroundColor: Design.textMuted])
            .draw(
                with: NSRect(x: 42, y: y + 10, width: footerShow.minX - 48, height: 18),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
    }

    private func symbol(_ name: String, size: CGFloat, color: NSColor, at centre: NSPoint) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))?.tinted(color) else { return }
        image.draw(in: NSRect(
            x: centre.x,
            y: centre.y - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        ))
    }

    /// A file's icon and colour by its extension, as board 1 colours them.
    static func icon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "md": "doc.richtext"
        case "json", "yaml", "yml", "toml", "plist": "curlybraces"
        case "sln", "csproj", "fsproj", "props", "targets": "hammer"
        case "png", "jpg", "jpeg", "gif", "svg", "pdf": "photo"
        default: "doc.text"
        }
    }

    static func tint(_ name: String) -> NSColor {
        switch (name as NSString).pathExtension.lowercased() {
        case "cs", "fs": Design.insert
        case "swift", "rs": NSColor(hex: 0xF0965F)
        case "json", "yaml", "yml", "toml": Design.modified
        case "csproj", "sln", "props", "fsproj": Design.visual
        case "md": Design.textMuted
        case "lua", "ts", "js": NSColor(hex: 0x7FB4F0)
        default: Design.textMuted
        }
    }

    // MARK: Acting

    private func activate(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        if row.isDirectory {
            if expanded.contains(row.path) { expanded.remove(row.path) } else { expanded.insert(row.path) }
            rebuild()
        } else {
            Nvim.lua(channel, "require'sill'.open(...)", [.string(row.path)])
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if footerShow.contains(point) {
            showIgnored.toggle()
            rebuild()
            return
        }
        let index = top + Int((point.y - listTop) / rowHeight)
        guard point.y >= listTop, rows.indices.contains(index) else { return }
        selected = index
        activate(index)
        needsDisplay = true
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              let key = event.charactersIgnoringModifiers else { return false }
        if var filter {
            switch key {
            case "\u{1B}":
                self.filter = nil
            case "\r":
                self.filter = filter.isEmpty ? nil : filter
                activate(rows.firstIndex { !$0.isDirectory } ?? selected)
                self.filter = nil
            case "\u{7F}":
                filter = String(filter.dropLast())
                self.filter = filter
            default:
                guard let character = event.characters, character.unicodeScalars.allSatisfy({ $0.value >= 0x20 })
                else { return true }
                filter += character
                self.filter = filter
            }
            rebuild()
            return true
        }
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!), up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!),
            left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        switch key {
        case "j", down: selected = min(selected + 1, max(rows.count - 1, 0))
        case "k", up: selected = max(selected - 1, 0)
        case "g": selected = 0
        case "G": selected = max(rows.count - 1, 0)
        case "\r", "o": activate(selected)
        case "l", right:
            if rows.indices.contains(selected), rows[selected].isDirectory, !expanded.contains(rows[selected].path) {
                activate(selected)
            } else if rows.indices.contains(selected), !rows[selected].isDirectory {
                activate(selected)
            }
        case "h", left:
            guard rows.indices.contains(selected) else { return true }
            let row = rows[selected]
            if row.isDirectory, expanded.contains(row.path), row.depth > 0 {
                activate(selected)
            } else if let parent = rows[..<selected].lastIndex(where: { $0.depth < row.depth }) {
                selected = parent
            }
        case "I":
            showIgnored.toggle()
            rebuild()
        case "R":
            refresh()
        case "/":
            filter = ""
            rebuild()
        default:
            return false
        }
        needsDisplay = true
        return true
    }
}

/// What the chrome asks git: the branch, changed files and ignored files of a working tree.
enum Git {
    static func run(_ arguments: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func branch(in directory: String) -> String {
        run(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Changed files by path relative to the working tree's root ... and so to `directory` when it is the root.
    static func status(in directory: String) -> [String: String] {
        guard let output = run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: directory) else {
            return [:]
        }
        var result: [String: String] = [:]
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let code = String(entry.prefix(2)), path = String(entry.dropFirst(3))
            result[path] = code
            if code.contains("R") || code.contains("C") { _ = entries.popFirst() } // The rename's old path.
        }
        return result
    }

    /// Ignored files and folders (folders end in /), relative to `directory`.
    static func ignored(in directory: String) -> Set<String> {
        guard let output = run(
            ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"], in: directory
        ) else { return [] }
        return Set(output.split(separator: "\0").map(String.init))
    }
}
