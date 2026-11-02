import AppKit
import MessagePack
import SillCore
import SillEditor
import SillNvim
import SillRender

/// The explorer (board 1): the project's files as a tree, read from disk off the main thread as folders open, with
/// git's changes marked and ignored files hidden until asked for. The project files inform it (owner, 2026-10-23): a
/// folder holding a project is marked with its kind, files nest as Visual Studio nests them (`Counter.razor.cs` under
/// `Counter.razor`, a project's `DependentUpon`), and files a project removes are dimmed. With a .slnx it shows the
/// solution's tree too (Files | Solution, `s`), and says how the .slnx differs from the folders on disk. It is drawn
/// over the sidebar's placeholder window; while that window is current it takes j/k, Return, h/l, `/` to filter,
/// `I` for ignored files and `s` for the solution, and every other key goes to nvim.
final class ExplorerView: NSView, ToolContent {
    struct Row: Equatable {
        var path: String
        var name: String
        var depth: Int
        var isDirectory: Bool
        var ignored: Bool
        /// Files nested under this one (`Counter.razor.cs` under `Counter.razor`).
        var nested = 0
        /// The project this folder holds (or, in the solution's tree, is).
        var project: (name: String, kind: ProjectFile.Kind)?
        /// Left out of its project's items.
        var excluded = false
        /// The solution lists it, but it is not on disk.
        var missing = false
        /// A solution folder: its name in the .slnx (`/src/tooling/`).
        var solutionFolder: String?
        /// Said after the name, faint: a touched file's folder and its lines changed.
        var detail: String?

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.path == rhs.path && lhs.name == rhs.name && lhs.depth == rhs.depth &&
                lhs.isDirectory == rhs.isDirectory && lhs.ignored == rhs.ignored && lhs.nested == rhs.nested &&
                lhs.project?.name == rhs.project?.name && lhs.project?.kind == rhs.project?.kind &&
                lhs.excluded == rhs.excluded && lhs.missing == rhs.missing && lhs.solutionFolder == rhs
                .solutionFolder &&
                lhs.detail == rhs.detail
        }

        /// Opens to show more: a folder, a solution folder or project, a file with files nested under it.
        var opens: Bool { isDirectory || nested > 0 }
    }

    /// The files touched on the branch (since it left its base, and not committed), the tree as the folders on disk
    /// have it, or as the solution (.slnx) does.
    enum Mode: Sendable, Equatable {
        case touched, files, solution
    }

    let root: String
    private let channel: NvimChannel
    private var metrics: CellMetrics { EditorFont.metrics }
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
    /// git's view has been read at least once: until then ignored files show, and rows may move when it arrives.
    private(set) var gitRead = false
    private var footerShow = NSRect.zero
    /// The ignored entries at the top level, for the footer: what is hidden. Read with the rows.
    private var hiddenAtTop: [String] = []
    /// Each rebuild's number: a tree read off the main thread is shown only if no later rebuild began meanwhile.
    private var generation = 0
    private(set) var mode: Mode = .files
    /// The folder's .slnx, read, and how it differs from the disk; nil without one.
    private(set) var solution: (path: String, slnx: Slnx, drift: [Slnx.Drift])?
    private var modeFrames: [(Mode, NSRect)] = []
    /// The files touched on the branch, most changed first (the workspace's story says).
    private(set) var branchFiles: [Review.File] = []
    /// Shows them first while there are any and no other was picked (a checkout opened from Home: the story first).
    var prefersTouched = false
    private var picked = false

    /// The files touched, from the workspace's story.
    func setTouched(_ files: [Review.File]) {
        guard files != branchFiles else { return }
        branchFiles = files
        if prefersTouched, !picked, !files.isEmpty { mode = .touched }
        if mode == .touched, files.isEmpty { mode = solution == nil ? .files : .solution }
        rebuild()
    }

    /// The tabs there are: Touched while files are, Files, Solution with a .slnx.
    private var modes: [Mode] {
        (branchFiles.isEmpty ? [] : [.touched]) + [.files] + (solution == nil ? [] : [.solution])
    }

    var onSolutionRead: ((String, Slnx, [Slnx.Drift]) -> Void)?

    init(channel: NvimChannel, root: String) {
        self.channel = channel
        self.root = realPath(root)
        expanded = [self.root]
        super.init(frame: .zero)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var rowHeight: CGFloat { 26 }
    /// The Touched | Files | Solution switch, when there is more than Files.
    private var switchHeight: CGFloat { modes.count > 1 ? 30 : 0 }
    /// The solution's drift, in its tree.
    private var bannerHeight: CGFloat { mode == .solution && !(solution?.drift.isEmpty ?? true) ? 26 : 0 }
    private var listTop: CGFloat { switchHeight + bannerHeight + (filter == nil ? 4 : 40) }
    private static let footer: CGFloat = 36

    // MARK: Reading the tree

    /// Reads git's status and ignored files again, the solution, and the tree.
    func refresh() {
        let root = root
        Task.detached {
            let changes = Git.status(in: root)
            let ignored = Git.ignored(in: root)
            await MainActor.run { [weak self] in
                self?.status = changes
                self?.ignored = ignored
                self?.gitRead = true
                self?.rebuild()
            }
        }
        readSolution()
        rebuild()
    }

    /// The folder's .slnx (the first, by name), read with its drift off the main thread. The first time one is found
    /// the explorer shows the solution's tree.
    func readSolution() {
        let root = root
        Task { [weak self] in
            let read = await Task.detached(priority: .utility) { () -> (String, Slnx, [Slnx.Drift])? in
                let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
                guard let name = names.sorted().first(where: { $0.hasSuffix(".slnx") }) else { return nil }
                let path = (root as NSString).appendingPathComponent(name)
                guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                      let slnx = try? Slnx(text: text) else { return nil }
                return (path, slnx, slnx.drift(in: root))
            }.value
            guard let self else { return }
            let first = solution == nil && read != nil
            solution = read.map { (path: $0.0, slnx: $0.1, drift: $0.2) }
            if first, mode != .touched { mode = .solution }
            if solution == nil, mode == .solution { mode = .files }
            if let read { onSolutionRead?(read.0, read.1, read.2) }
            rebuild()
        }
    }

    /// Selects a row (the self-check's way to point at one).
    func select(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        selected = index
        needsDisplay = true
    }

    func show(_ mode: Mode) {
        guard mode != self.mode, modes.contains(mode) else { return }
        picked = true
        self.mode = mode
        selected = 0
        rebuild { [weak self] in
            guard let self, !currentFile.isEmpty, let index = rows.firstIndex(where: { $0.path == currentFile })
            else { return }
            selected = index
        }
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
        // A nested file: the file it nests under open too (by the rules; a parent that is not there opens nothing).
        if let parent = FileNesting.rule((path as NSString).lastPathComponent) {
            expanded.insert(((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(parent))
        }
        // In the solution's tree: the folders down to the project holding it, or to the folder listing it.
        if let slnx = solution?.slnx {
            let relativePath = relative(path)
            let holder = slnx.listed.filter { entry in
                entry.isProject ? relativePath.hasPrefix((entry.path as NSString).deletingLastPathComponent + "/") :
                    entry.path == relativePath
            }.max { $0.path.count < $1.path.count }
            // `/src/tooling/`: `/src/` and `/src/tooling/` open.
            let segments = (holder?.folder ?? "").split(separator: "/")
            for count in segments.indices {
                expanded.insert(Reading.folderKey("/" + segments[...count].joined(separator: "/") + "/"))
            }
        }
        rebuild { [weak self] in
            guard let self, let index = rows.firstIndex(where: { $0.path == path }) else { return }
            selected = index
        }
    }

    private func relative(_ path: String) -> String {
        path == root ? "" : String(path.dropFirst(root.count + 1))
    }

    /// What a tree is read from: a snapshot of the view's state, so the reading can happen off the main thread.
    private struct Reading: Sendable {
        var root: String
        var expanded: Set<String>
        var filter: String?
        var ignored: Set<String>
        var showIgnored: Bool
        var mode: Mode
        var solution: Slnx?
        var touched: [Review.File] = []

        func relative(_ path: String) -> String {
            path == root ? "" : String(path.dropFirst(root.count + 1))
        }

        func isIgnored(_ path: String, directory: Bool) -> Bool {
            let name = (path as NSString).lastPathComponent
            if name == ".git" { return true }
            let relativePath = relative(path)
            return ignored.contains(relativePath) || (directory && ignored.contains(relativePath + "/"))
        }

        private func entries(_ folder: String) -> [(path: String, isDirectory: Bool)] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).map { name in
                var isDirectory: ObjCBool = false
                let path = (folder as NSString).appendingPathComponent(name)
                FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                return (path, isDirectory.boolValue)
            }
        }

        /// The project file in a folder, read; nil when there is none.
        private func projectFile(in folder: String, names: [String]? = nil) -> ProjectFile? {
            let names = names ?? ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            guard let name = names.sorted().first(where: { $0.hasSuffix(".csproj") || $0.hasSuffix(".fsproj") }) else {
                return nil
            }
            let path = (folder as NSString).appendingPathComponent(name)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            return ProjectFile(path: path, text: text)
        }

        /// The rows: the open folders read from disk (all of them under a filter), or the solution's tree; and the
        /// ignored names at the top.
        func rows() -> (rows: [Row], hidden: [String]) {
            let filtering = filter.map { !$0.isEmpty } ?? false
            var rows: [Row] = []
            if mode == .touched, !filtering {
                // A row a file, its name first: the folder and its lines changed after it.
                rows = touched.map { file in
                    let folder = (file.path as NSString).deletingLastPathComponent
                    return Row(
                        path: root + "/" + file.path, name: (file.path as NSString).lastPathComponent, depth: 1,
                        isDirectory: false, ignored: false,
                        detail: (folder.isEmpty ? "" : folder + "  ") + "+\(file.added) −\(file.removed)"
                    )
                }
            } else if mode == .solution, let solution, !filtering {
                rows = solutionRows(solution)
            } else {
                rows = [Row(
                    path: root,
                    name: (root as NSString).lastPathComponent,
                    depth: 0,
                    isDirectory: true,
                    ignored: false
                )]
                if expanded.contains(root) { walk(root, depth: 1, project: projectFile(in: root), into: &rows) }
            }
            if filtering {
                // Folders with nothing that matches go.
                rows = rows.enumerated().filter { index, row in
                    guard row.isDirectory, row.depth > 0 else { return true }
                    return rows.dropFirst(index + 1).prefix { $0.depth > row.depth }.contains { !$0.isDirectory }
                }.map(\.element)
            }
            let hidden = entries(root)
                .filter { ($0.path as NSString).lastPathComponent != ".git" && isIgnored(
                    $0.path, directory: $0.isDirectory
                ) }
                .map { ($0.path as NSString).lastPathComponent }.sorted()
            return (rows, hidden)
        }

        /// A folder's rows: folders first, a project's folder marked with it; files nested under the file they belong
        /// to (shown when that one is open, or holds the current file), and those its project removes dimmed.
        private func walk(_ folder: String, depth: Int, project: ProjectFile?, into rows: inout [Row]) {
            let filtering = filter.map { !$0.isEmpty } ?? false
            let listed = entries(folder).filter { entry in
                showIgnored || !isIgnored(entry.path, directory: entry.isDirectory)
            }
            let folders = listed.filter(\.isDirectory).map(\.path).sorted {
                ($0 as NSString).lastPathComponent
                    .localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending
            }
            for path in folders {
                let name = (path as NSString).lastPathComponent
                let inside = projectFile(in: path)
                var row = Row(
                    path: path,
                    name: name,
                    depth: depth,
                    isDirectory: true,
                    ignored: isIgnored(path, directory: true)
                )
                row.project = inside.map { ($0.name, $0.kind) }
                row.excluded = project?.removes(path + "/") ?? false
                rows.append(row)
                if expanded.contains(path) || filtering && !row.ignored {
                    walk(path, depth: depth + 1, project: inside ?? project, into: &rows)
                }
            }
            var files = listed.filter { !$0.isDirectory }.map { ($0.path as NSString).lastPathComponent }
            if let filter, filtering { files = files.filter { $0.localizedCaseInsensitiveContains(filter) } }
            files.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            // The project's DependentUpon for this folder, by file name.
            var explicit: [String: String] = [:]
            if let project, folder == project.directory || folder.hasPrefix(project.directory + "/") {
                let here = folder == project.directory ? "" : String(folder.dropFirst(project.directory.count + 1))
                for (item, parent) in project.dependentUpon
                    where (item as NSString).deletingLastPathComponent == here
                {
                    explicit[(item as NSString).lastPathComponent] = parent
                }
            }
            let parents = filtering ? [:] : FileNesting.parents(of: files, explicit: explicit)
            var children: [String: [String]] = [:]
            for (child, parent) in parents {
                children[parent, default: []].append(child)
            }
            func emit(_ name: String, _ depth: Int) {
                let path = (folder as NSString).appendingPathComponent(name)
                let nested = (children[name] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                var row = Row(
                    path: path,
                    name: name,
                    depth: depth,
                    isDirectory: false,
                    ignored: isIgnored(path, directory: false)
                )
                row.nested = nested.count
                row.excluded = project?.removes(path) ?? false
                rows.append(row)
                if !nested.isEmpty, expanded.contains(path) {
                    for child in nested {
                        emit(child, depth + 1)
                    }
                }
            }
            for name in files where parents[name] == nil {
                emit(name, depth)
            }
        }

        /// The solution's tree: its folders (as the .slnx names them), their projects (open to their files) and the
        /// files it lists.
        private func solutionRows(_ solution: Slnx) -> [Row] {
            var rows: [Row] = [Row(
                path: root,
                name: (root as NSString).lastPathComponent,
                depth: 0,
                isDirectory: true,
                ignored: false
            )]
            let listed = solution.listed
            let folders = solution.folders
            func emitItems(in folder: String?, depth: Int) {
                let items = listed.filter { $0.folder?.lowercased() == folder?.lowercased() }
                for item in items where item.isProject {
                    let path = (root as NSString).appendingPathComponent(item.path)
                    let directory = (path as NSString).deletingLastPathComponent
                    let project = (try? String(contentsOfFile: path, encoding: .utf8)).map {
                        ProjectFile(path: path, text: $0)
                    }
                    var row = Row(
                        path: directory,
                        name: project?.name ?? (item.path as NSString).lastPathComponent,
                        depth: depth,
                        isDirectory: true,
                        ignored: false
                    )
                    row.project = project.map { ($0.name, $0.kind) }
                    row.missing = project == nil
                    rows.append(row)
                    if expanded.contains(directory) { walk(directory, depth: depth + 1, project: project, into: &rows) }
                }
                for item in items where !item.isProject {
                    let path = (root as NSString).appendingPathComponent(item.path)
                    var row = Row(
                        path: path,
                        name: (item.path as NSString).lastPathComponent,
                        depth: depth,
                        isDirectory: false,
                        ignored: false
                    )
                    row.missing = !FileManager.default.fileExists(atPath: path)
                    rows.append(row)
                }
            }
            func emitFolders(under parent: String, depth: Int) {
                let inside = folders.filter { name in
                    let trimmed = String(name.dropFirst(parent.count))
                    return name.lowercased().hasPrefix(parent.lowercased()) && trimmed.hasSuffix("/") &&
                        trimmed.dropLast().split(separator: "/").count == 1
                }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                for name in inside {
                    let key = Self.folderKey(name)
                    var row = Row(
                        path: key,
                        name: String(name.dropLast().split(separator: "/").last ?? ""),
                        depth: depth,
                        isDirectory: true,
                        ignored: false
                    )
                    row.solutionFolder = name
                    rows.append(row)
                    if expanded.contains(key) {
                        emitFolders(under: name, depth: depth + 1)
                        emitItems(in: name, depth: depth + 1)
                    }
                }
            }
            if expanded.contains(root) {
                emitFolders(under: "/", depth: 1)
                emitItems(in: nil, depth: 1)
            }
            return rows
        }

        /// A solution folder's key in `expanded`.
        static func folderKey(_ name: String) -> String { "slnx:" + name.lowercased() }
    }

    /// Reads the tree again off the main thread (a filter reads all of it, which takes a while in a large repo), then
    /// shows it, unless another rebuild began meanwhile; `then` runs once it is shown.
    private func rebuild(then: (() -> Void)? = nil) {
        generation += 1
        let number = generation
        let reading = Reading(
            root: root, expanded: expanded, filter: filter, ignored: ignored, showIgnored: showIgnored, mode: mode,
            solution: solution?.slnx, touched: branchFiles
        )
        Task { [weak self] in
            let (rows, hidden) = await Task.detached(priority: .userInitiated) { reading.rows() }.value
            guard let self, number == generation else { return }
            self.rows = rows
            hiddenAtTop = hidden
            selected = min(selected, max(rows.count - 1, 0))
            then?()
            needsDisplay = true
        }
    }

    /// git's mark for a row: its own change, or for a folder whether anything under it changed.
    private func mark(_ row: Row) -> (String, NSColor)? {
        guard row.solutionFolder == nil, row.path.hasPrefix(root) else { return nil }
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
        drawSwitch()
        if bannerHeight > 0, let drift = solution?.drift {
            let text = NSAttributedString(
                string: "\(drift.count) difference\(drift.count == 1 ? "" : "s") from the folders on disk · " +
                    ":SillSlnx sync",
                attributes: [.font: Design.ui(11), .foregroundColor: Design.modified]
            )
            text.draw(
                with: NSRect(x: 14, y: switchHeight + 5, width: bounds.width - 28, height: 16),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
        }
        if let filter {
            let box = NSRect(x: 12, y: switchHeight + bannerHeight + 6, width: bounds.width - 24, height: 28)
            Design.editor.setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            Design.accent.setStroke()
            NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).stroke()
            NSAttributedString(string: filter.isEmpty ? "Filter files" : filter, attributes: [
                .font: Design.ui(12), .foregroundColor: filter.isEmpty ? Design.textFaint : Design.text,
            ]).draw(at: NSPoint(x: box.minX + 10, y: box.minY + 6))
        }
        drawRows()
    }

    /// Touched | Files | Solution, at the top when there is more than Files.
    private func drawSwitch() {
        modeFrames = []
        guard modes.count > 1 else { return }
        var x: CGFloat = 14
        for mode in modes {
            let title = switch mode {
            case .touched: "Touched"
            case .files: "Files"
            case .solution: "Solution"
            }
            let active = mode == self.mode
            let label = NSAttributedString(string: title, attributes: [
                .font: Design.ui(12, weight: active ? .semibold : .regular),
                .foregroundColor: active ? Design.text : Design.textMuted,
            ])
            label.draw(at: NSPoint(x: x, y: (switchHeight - label.size().height) / 2))
            if active {
                Design.accent.setFill()
                NSRect(x: x, y: switchHeight - 3, width: label.size().width, height: 2).fill()
            }
            modeFrames.append((mode, NSRect(x: x - 6, y: 0, width: label.size().width + 12, height: switchHeight)))
            x += label.size().width + 18
        }
        Design.border.setFill()
        NSRect(x: 0, y: switchHeight - 1, width: bounds.width, height: 1).fill()
    }

    /// Files an agent changed this session (relative): a bar in the accent at their row's edge.
    var touched: Set<String> = [] {
        didSet { if touched != oldValue { needsDisplay = true } }
    }

    private func drawRows() {
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
            if !row.isDirectory, row.path.hasPrefix(root), touched.contains(relative(row.path)) {
                Design.accent.setFill()
                NSRect(x: bounds.width - 4, y: rect.minY + 6, width: 3, height: rect.height - 12).fill()
            }
            var x = 12 + CGFloat(row.depth) * 14
            if row.opens {
                let chevron = expanded.contains(row.path) ? "chevron.down" : "chevron.right"
                symbol(chevron, size: 9, color: Design.textFaint, at: NSPoint(x: x, y: rect.midY))
            }
            x += 14
            let icon = row.project != nil ? "cube" : row.isDirectory ? "folder" : Self.icon(row.name)
            let tint = row.project != nil ? Design.insert : row.solutionFolder != nil ? Design.textFaint :
                row.isDirectory ? Design.textMuted : Self.tint(row.name)
            symbol(icon, size: 12, color: tint, at: NSPoint(x: x, y: rect.midY))
            x += 20
            let mark = mark(row)
            let color = row.missing ? Design.error : row.ignored || row.excluded ? Design.textFaint :
                mark?.0 == "M" ? Design.modified : Design.text
            var attributes: [NSAttributedString.Key: Any] = [
                .font: Design.ui(13, weight: row.depth == 0 ? .semibold : .regular), .foregroundColor: color,
            ]
            if row.missing { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let name = NSMutableAttributedString(string: row.name, attributes: attributes)
            if let detail = row.detail {
                name.append(NSAttributedString(string: "  " + detail, attributes: [
                    .font: Design.ui(11), .foregroundColor: Design.textFaint,
                ]))
            }
            if let project = row.project, row.depth > 0 {
                name.append(NSAttributedString(string: "  " + project.kind.rawValue, attributes: [
                    .font: Design.ui(11), .foregroundColor: Design.textFaint,
                ]))
            }
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

    /// Return: a folder, solution folder or project opens or closes; a file opens in the editor.
    private func activate(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        if row.isDirectory {
            toggle(index)
        } else if !row.missing {
            Nvim.lua(channel, "require'sill'.open(...)", [.string(row.path)])
        }
    }

    /// Opens or closes a row that opens: what is under it shown or hidden.
    private func toggle(_ index: Int) {
        guard rows.indices.contains(index), rows[index].opens else { return }
        let key = rows[index].path
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
        rebuild()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if footerShow.contains(point) {
            showIgnored.toggle()
            rebuild()
            return
        }
        if let mode = modeFrames.first(where: { $0.1.contains(point) })?.0 {
            show(mode)
            return
        }
        let index = top + Int((point.y - listTop) / rowHeight)
        guard point.y >= listTop, rows.indices.contains(index) else { return }
        selected = index
        // The chevron of a file with nested files opens it; the rest of the row opens the file.
        let chevron = 12 + CGFloat(rows[index].depth) * 14
        if !rows[index].isDirectory, rows[index].nested > 0, point.x < chevron + 12 {
            toggle(index)
        } else {
            activate(index)
        }
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
            guard rows.indices.contains(selected) else { return true }
            let row = rows[selected]
            if row.opens, !expanded.contains(row.path) {
                toggle(selected)
            } else if !row.isDirectory {
                activate(selected)
            }
        case "h", left:
            guard rows.indices.contains(selected) else { return true }
            let row = rows[selected]
            if row.opens, expanded.contains(row.path), row.depth > 0 {
                toggle(selected)
            } else if let parent = rows[..<selected].lastIndex(where: { $0.depth < row.depth }) {
                selected = parent
            }
        case "s":
            // The next tab there is.
            let all = modes
            show(all[((all.firstIndex(of: mode) ?? 0) + 1) % all.count])
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
