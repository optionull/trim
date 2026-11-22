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
        return (nvim + extra).sorted {
            ($0.level.rawValue, $0.path, $0.line, $0.column) < ($1.level.rawValue, $1.path, $1.line, $1.column)
        }
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

    /// Every problem as a mode: nvim's diagnostics for the files it has open and what the last build printed, worst
    /// first, with a toggle for each level (a click, or e w i h). Return goes there, Alt+Enter asks for the code
    /// actions
    /// at the problem.
    @objc func showProblems(_: Any?) {
        guard listPicker == nil else { return }
        Task { [weak self] in
            guard let self, listPicker == nil else { return }
            let all = await ProblemRow.merged(nvim: nvimProblems(), build: buildProblems)
            var shown = Set(DiagnosticLevel.allCases)
            let root = workspace
            func chips() -> [ListChip] {
                DiagnosticLevel.allCases.sorted(by: >).map { level in
                    ListChip(
                        id: String(level.rawValue), title: ProblemRow.name(level), color: SquiggleView.color(level),
                        count: all.count(where: { $0.level == level }), on: shown.contains(level),
                        key: ProblemRow.keys[level] ?? ""
                    )
                }
            }
            func rows() -> [ProblemRow] { all.filter { shown.contains($0.level) } }
            func items() -> [PickerItem] {
                rows().enumerated().map { index, row in
                    let name = (row.path as NSString).lastPathComponent
                    let place = Self.relative(row.path, to: root) + ":\(row.line)"
                    return PickerItem(
                        id: String(index), title: row.message, detail: place, glyph: ProblemRow.glyph(row.level),
                        subtitle: row.code, file: name
                    )
                }
            }
            func row(of item: PickerItem) -> ProblemRow? { Int(item.id)
                .flatMap { rows().indices.contains($0) ? rows()[$0] : nil }
            }
            showList(
                title: "Problems", items: items(), current: nil,
                onChoose: { [weak self] item in
                    if let problem = row(of: item) { self?.go(to: problem) }
                },
                configure: { [weak self] picker in
                    picker.wide = true
                    picker.chips = chips()
                    picker.onChip = { [weak picker] id in
                        guard let level = Int(id).flatMap(DiagnosticLevel.init(rawValue:)) else { return }
                        if shown.contains(level) { shown.remove(level) } else { shown.insert(level) }
                        picker?.chips = chips()
                        picker?.set(items(), current: nil)
                    }
                    picker.onKey = { [weak self] key, item in
                        guard key == "<M-CR>", let problem = row(of: item) else { return false }
                        self?.closeList()
                        self?.go(to: problem, then: "vim.defer_fn(function() vim.lsp.buf.code_action() end, 200)")
                        return true
                    }
                }
            )
        }
    }
}
