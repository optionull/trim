import AppKit
import FrameModes
import FrameRun
import FrameTree
import MessagePack

/// One line of the problems list: from nvim's diagnostics (the files it has open) or from a build's output.
struct ProblemRow: Equatable {
    var path: String
    var line: Int
    var column: Int
    var level: DiagnosticLevel
    var message: String
    var code: String
    var source: String

    static func glyph(_ level: DiagnosticLevel) -> String {
        switch level {
        case .error: "\u{f057}"
        case .warning: "\u{f071}"
        case .info: "\u{f05a}"
        case .hint: "\u{f0eb}"
        }
    }

    static func name(_ level: DiagnosticLevel) -> String {
        switch level {
        case .error: "Errors"
        case .warning: "Warnings"
        case .info: "Info"
        case .hint: "Hints"
        }
    }

    static let keys: [DiagnosticLevel: String] = [.error: "e", .warning: "w", .info: "i", .hint: "h"]

    /// What is shown: build rows that nvim already says too (same file, line and code) are dropped, then the worst
    /// first, by file and line.
    static func merged(nvim: [ProblemRow], build: [ProblemRow]) -> [ProblemRow] {
        let known = Set(nvim.map { "\($0.path):\($0.line):\($0.code)" })
        let extra = build.filter { $0.code.isEmpty || !known.contains("\($0.path):\($0.line):\($0.code)") }
        return (nvim + extra).sorted(by: before)
    }

    /// A total order: two problems that agree on everything that is shown never swap places between one listing and
    /// the next (the list does not shuffle under the pointer).
    static func before(_ a: ProblemRow, _ b: ProblemRow) -> Bool {
        if a.level != b.level { return a.level.rawValue < b.level.rawValue }
        if a.path != b.path { return a.path < b.path }
        if a.line != b.line { return a.line < b.line }
        if a.column != b.column { return a.column < b.column }
        if a.code != b.code { return a.code < b.code }
        if a.message != b.message { return a.message < b.message }
        return a.source < b.source
    }
}

extension FrameWindowController {
    /// What a finished build complained of: kept for the list, and its files marked in the tree.
    func takeBuildProblems(_ problems: [Problem]) {
        buildProblems = problems.map {
            ProblemRow(
                path: $0.path, line: $0.line, column: $0.column, level: $0.severity == .error ? .error : .warning,
                message: $0.message, code: $0.code, source: "build"
            )
        }
        var files: [String: DiagnosticLevel] = [:]
        for row in buildProblems {
            files[row.path] = max(files[row.path] ?? row.level, row.level)
        }
        buildDiagnostics = files
        sendDiagnosticsToTree()
        reloadProblems()
    }

    private func nvimProblems() async -> [ProblemRow] {
        let reply = try? await session.channel.lua("return require('frame.diag').list()")
        return (reply?.arrayValue ?? []).compactMap { entry -> ProblemRow? in
            guard let map = entry.dictionaryValue, let path = map[.string("path")]?.stringValue,
                  let raw = map[.string("severity")]?.integerValue, let level = DiagnosticLevel(rawValue: Int(raw))
            else { return nil }
            return ProblemRow(
                path: path, line: Int(map[.string("line")]?.integerValue ?? 1),
                column: Int(map[.string("col")]?.integerValue ?? 1), level: level,
                message: map[.string("message")]?.stringValue ?? "", code: map[.string("code")]?.stringValue ?? "",
                source: map[.string("source")]?.stringValue ?? ""
            )
        }
    }

    nonisolated static func relative(_ path: String, to root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    /// Where a problem is, in the editor: the file, the line and the column.
    func go(to row: ProblemRow, then afterwards: String = "") {
        Task { [session] in
            _ = try? await session.channel.lua(
                """
                local path, line, col = ...
                local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
                if not ok then return vim.notify(tostring(err), vim.log.levels.ERROR) end
                pcall(vim.api.nvim_win_set_cursor, 0, { line, math.max(col - 1, 0) })
                vim.cmd('normal! zz')
                \(afterwards)
                """,
                args: [.string(row.path), .int(Int64(row.line)), .int(Int64(row.column))]
            )
        }
        focusEditor()
    }

    /// The pane, made when first wanted (a run, or the problems), with its Problems tab set up.
    func ensureBuildPane() -> BuildPane {
        if let pane = runPane { return pane }
        let pane = BuildPane(look: tree.look)
        let list = pane.problems
        list.onFocus = { [weak self] in self?.terminalFocused() }
        list.onDismiss = { [weak self] in self?.focusEditor() }
        list.onChoose = { [weak self] item in
            if let row = self?.problemRows[item.id] { self?.go(to: row) }
        }
        list.onChip = { [weak self] id in
            guard let self, let level = Int(id).flatMap(DiagnosticLevel.init(rawValue:)) else { return }
            if problemLevels.contains(level) { problemLevels.remove(level) } else { problemLevels.insert(level) }
            reloadProblems()
        }
        list.onKey = { [weak self] key, item in
            guard key == "<M-CR>", let row = self?.problemRows[item.id] else { return false }
            self?.go(to: row, then: "vim.defer_fn(function() vim.lsp.buf.code_action() end, 200)")
            return true
        }
        pane.onMinimize = { [weak self] in self?.hideBuildPane() }
        pane.onRebuild = { [weak self] in self?.rebuild() }
        pane.onFocus = { [weak self] in self?.terminalFocused() }
        pane.onEscape = { [weak self] in self?.focusEditor() }
        runPane = pane
        view.terminal = pane
        reloadProblems()
        return pane
    }

    /// What there is to say about problems, from what nvim has now and what the last build printed: the counts for the
    /// status bar always, and the pane's list (worst first, only the levels switched on) when there is a pane. Called
    /// whenever either changes.
    func reloadProblems() {
        Task { [weak self] in
            guard let self else { return }
            let all = await ProblemRow.merged(nvim: nvimProblems(), build: buildProblems)
            var totals: [DiagnosticLevel: Int] = [:]
            for row in all {
                totals[row.level, default: 0] += 1
            }
            problemTotals = totals
            applyProblemTotals()
            guard let pane = runPane else { return }
            let root = workspace
            let shown = all.filter { problemLevels.contains($0.level) }
            var rows: [String: ProblemRow] = [:]
            let items = shown.map { row -> PickerItem in
                let id = "\(row.path)\t\(row.line)\t\(row.column)\t\(row.code)\t\(row.message)"
                rows[id] = row
                return PickerItem(
                    id: id, title: row.message, detail: Self.relative(row.path, to: root) + ":\(row.line)",
                    glyph: ProblemRow.glyph(row.level), subtitle: row.code,
                    file: (row.path as NSString).lastPathComponent
                )
            }
            problemRows = rows
            pane.problems.chips = DiagnosticLevel.allCases.sorted(by: >).map { level in
                ListChip(
                    id: String(level.rawValue), title: ProblemRow.name(level), glyph: ProblemRow.glyph(level),
                    color: SquiggleView.color(level),
                    count: totals[level] ?? 0, on: problemLevels.contains(level), key: ProblemRow.keys[level] ?? ""
                )
            }
            if pane.problems.all != items { pane.problems.set(items, current: pane.problems.cursor) }
            pane.problemCount = (totals[.error] ?? 0) + (totals[.warning] ?? 0)
        }
    }

    /// The pane in the window (it may have been running a build unseen).
    func showBuildPane() {
        let pane = ensureBuildPane()
        if pane.isHidden {
            pane.isHidden = false
            view.needsLayout = true
        }
    }

    /// The minimize button: the pane goes out of the way (a build in it goes on), the keyboard back in the code.
    func hideBuildPane() {
        guard let pane = runPane, !pane.isHidden else { return }
        let wasFocused = modes.surface == .terminal
        pane.isHidden = true
        view.needsLayout = true
        if wasFocused { focusEditor() }
    }

    /// A click on the build in the status bar: its output (the pane opens, or switches to it); on the output already,
    /// the
    /// pane folds away.
    func showBuildOutput() {
        if let pane = runPane, !pane.isHidden, pane.tab == .output { return hideBuildPane() }
        showBuildPane()
        runPane?.select(.output)
        focus(.terminal)
    }

    /// The rebuild button: what ran last runs again, else the build.
    func rebuild() {
        if let entry = runPane?.entry { run(entry) } else { buildDefault(nil) }
    }

    /// A click on the status bar's section for the pane: it opens on that tab, and a click while it is open puts it
    /// away.
    func toggleBuildPane(on tab: BuildPane.Tab) {
        // Open, it folds away at once, whichever tab it is on; folded, it opens on this section's tab.
        if let pane = runPane, !pane.isHidden { return hideBuildPane() }
        showBuildPane()
        runPane?.select(tab)
        reloadProblems()
        focus(.terminal)
    }

    /// ⇧⌘M: the pane on its Problems tab with the keyboard in it; again, back to the code.
    @objc func showProblems(_: Any?) {
        showBuildPane()
        guard let pane = runPane else { return }
        if modes.surface == .terminal, pane.tab == .problems { return focusEditor() }
        pane.select(.problems)
        reloadProblems()
        focus(.terminal)
    }
}
