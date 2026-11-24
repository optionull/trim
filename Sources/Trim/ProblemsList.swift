import AppKit
import MessagePack
import TrimModes
import TrimRun
import TrimTree

/// How much of the project the problems list covers: the file in the window, the folder it is in, or all of it.
enum ProblemScope: String, CaseIterable {
    case file, folder, project

    static var stored: ProblemScope {
        UserDefaults.standard.string(forKey: "trim.problemScope").flatMap(ProblemScope.init) ?? .project
    }

    static func store(_ scope: ProblemScope) { UserDefaults.standard.set(scope.rawValue, forKey: "trim.problemScope") }

    var title: String {
        switch self {
        case .file: "This file"
        case .folder: "This folder"
        case .project: "The whole project"
        }
    }

    var glyph: String {
        switch self {
        case .file: "\u{f15b}"
        case .folder: "\u{f07b}"
        case .project: "\u{f1b3}"
        }
    }

    /// Whether a problem in `path` is in the scope when `active` is the file in the window (no file: all of it).
    func includes(_ path: String, active: String?) -> Bool {
        guard let active else { return true }
        switch self {
        case .file: return path == active
        case .folder: return (path as NSString).deletingLastPathComponent == (active as NSString)
            .deletingLastPathComponent
        case .project: return true
        }
    }
}

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

extension TrimWindowController {
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

    nonisolated static func relative(_ path: String, to root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    /// Every problem nvim has, from its reply (off the main thread: there can be thousands).
    nonisolated static func rows(from reply: MessagePackValue?) -> [ProblemRow] {
        (reply?.arrayValue ?? []).compactMap { entry -> ProblemRow? in
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

    /// The list's rows for what nvim said and the build printed: merged, the levels shown, with the counts of each.
    nonisolated static func listing(
        _ reply: MessagePackValue?, build: [ProblemRow], levels: Set<DiagnosticLevel>, root: String,
        scope: ProblemScope = .project, active: String? = nil
    ) -> (items: [PickerItem], rows: [String: ProblemRow], counts: [DiagnosticLevel: Int]) {
        let all = ProblemRow.merged(nvim: rows(from: reply), build: build)
            .filter { scope.includes($0.path, active: active) }
        var counts: [DiagnosticLevel: Int] = [:]
        for row in all {
            counts[row.level, default: 0] += 1
        }
        var byID: [String: ProblemRow] = [:]
        let items = all.filter { levels.contains($0.level) }.map { row -> PickerItem in
            let id = "\(row.path)\t\(row.line)\t\(row.column)\t\(row.code)\t\(row.message)"
            byID[id] = row
            return PickerItem(
                id: id, title: row.message, detail: Self.relative(row.path, to: root) + ":\(row.line)",
                glyph: ProblemRow.glyph(row.level), subtitle: row.code, file: (row.path as NSString).lastPathComponent
            )
        }
        return (items, byID, counts)
    }

    /// The status bar's counts: nvim's own counts (kept by nvim as diagnostics arrive, so nothing is listed to count
    /// them) and what the last build printed in files nvim has nothing for.
    func recountProblems() {
        var totals = nvimCounts
        for row in buildProblems where nvimDiagnostics[row.path] == nil {
            totals[row.level, default: 0] += 1
        }
        problemTotals = totals
        applyProblemTotals()
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
        pane.scope = problemScope
        pane.loading = !lspProgress.isEmpty
        pane.onScope = { [weak self] scope in self?.problemScope = scope }
        pane.onTabChange = { [weak self] _ in self?.reloadProblems() }
        pane.onRebuild = { [weak self] in self?.rebuild() }
        pane.onFocus = { [weak self] in self?.terminalFocused() }
        pane.onEscape = { [weak self] in self?.focusEditor() }
        runPane = pane
        view.terminal = pane
        reloadProblems()
        return pane
    }

    /// What there is to say about problems: the counts for the status bar always (cheap), and the pane's list only
    /// while
    /// it is open on Problems, and then at most every so often however fast diagnostics arrive, the work done off the
    /// main thread. Called whenever either nvim's diagnostics or the build's change, or the pane opens.
    func reloadProblems() {
        recountProblems()
        guard let pane = runPane, !pane.isHidden, pane.tab == .problems else { return }
        guard !problemsReloading else {
            problemsDirty = true
            return
        }
        problemsReloading = true
        Task { [weak self] in
            guard let self else { return }
            let options: [MessagePackValue: MessagePackValue] = [
                .string("scope"): .string(problemScope.rawValue), .string("limit"): .int(3000),
                .string("active"): activeFile.map { .string($0) } ?? .nil,
            ]
            let reply = try? await session.channel.lua(
                "return require('trim.diag').list(...)", args: [.map(options)]
            )
            let build = buildProblems, levels = problemLevels, root = workspace
            let scope = problemScope, active = activeFile
            let listing = await Task.detached {
                Self.listing(reply, build: build, levels: levels, root: root, scope: scope, active: active)
            }.value
            if let pane = runPane {
                problemRows = listing.rows
                pane.problems.chips = DiagnosticLevel.allCases.sorted(by: >).map { level in
                    ListChip(
                        id: String(level.rawValue), title: ProblemRow.name(level), glyph: ProblemRow.glyph(level),
                        color: SquiggleView.color(level),
                        count: (problemScope == .project ? problemTotals?[level] : nil) ?? listing.counts[level] ?? 0,
                        on: problemLevels.contains(level), key: ProblemRow.keys[level] ?? ""
                    )
                }
                if pane.problems.all != listing
                    .items { pane.problems.set(listing.items, current: pane.problems.cursor) }
                pane.problemCount = (listing.counts[.error] ?? 0) + (listing.counts[.warning] ?? 0)
            }
            try? await Task.sleep(for: .milliseconds(300))
            problemsReloading = false
            if problemsDirty {
                problemsDirty = false
                reloadProblems()
            }
        }
    }

    /// The pane in the window (it may have been running a build unseen).
    func showBuildPane() {
        let pane = ensureBuildPane()
        if let run = runListPane, !run.isHidden {
            run.isHidden = true
            if modes.surface == .run { runGone() }
            view.needsLayout = true
        }
        if pane.isHidden {
            pane.isHidden = false
            view.needsLayout = true
            reloadProblems()
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
