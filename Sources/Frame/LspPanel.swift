import AppKit
import FrameRun
import MessagePack

/// The language servers as a mode: each one that has been wanted, how it is, what it is busy with, how much of a core
/// and
/// how much memory it and what it started use (read from `ps`, a moment old), where it is rooted. `r` restarts one, `s`
/// stops it, and it keeps up with them while it is open.
struct LspRow: Equatable {
    var name: String
    var status: String
    var root: String
    var buffers: Int
    var deaths: Int
    var busy: String
    var program: String
    var cpu: Double?
    var memoryKB: Int?
    var processes: Int?
}

extension FrameWindowController {
    static func lspLabel(_ name: String) -> String { FrameServers.label(name) }

    static func lspGlyph(_ status: String) -> String {
        switch status {
        case "ready": "\u{f111}"
        case "starting": "\u{f110}"
        case "restarting": "\u{f021}"
        case "failed": "\u{f057}"
        case "stopped": "\u{f04d}"
        default: "\u{f10c}"
        }
    }

    static func lspItems(_ rows: [LspRow], root: String) -> [PickerItem] {
        rows.map { row in
            var detail = row.status
            if let cpu = row.cpu, let memory = row.memoryKB {
                detail = String(format: "%.0f%% CPU · ", cpu) + Processes.size(kilobytes: memory)
                    + ((row.processes ?? 1) > 1 ? " · \(row.processes ?? 1) processes" : "")
            } else if row.deaths > 0 {
                detail += " · died \(row.deaths)×"
            }
            var subtitle = row.busy.isEmpty ? "" : row.busy
            if !row.root.isEmpty {
                subtitle += (subtitle.isEmpty ? "" : "  ·  ") + FrameWindowController.relative(row.root, to: root)
            }
            return PickerItem(
                id: row.name, title: lspLabel(row.name) + (row.status == "ready" ? "" : "  " + row.status),
                detail: detail,
                glyph: lspGlyph(row.status), subtitle: subtitle
            )
        }
    }

    /// The servers as nvim and `ps` say them now.
    func lspRows() async -> [LspRow] {
        let reply = try? await session.channel.lua("return { vim.fn.getpid(), require('frame.lsp').rows() }")
        guard let pair = reply?.arrayValue, pair.count == 2, let editor = pair[0].integerValue else { return [] }
        let table = await (try? FrameServers.run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,rss=,command="]))?.output ?? ""
        let processes = Processes.parse(table)
        return (pair[1].arrayValue ?? []).compactMap { value -> LspRow? in
            guard let map = value.dictionaryValue, let name = map[.string("name")]?.stringValue else { return nil }
            func text(_ key: String) -> String { map[.string(key)]?.stringValue ?? "" }
            func number(_ key: String) -> Int { map[.string(key)]?.integerValue.map(Int.init) ?? 0 }
            let program = (text("program") as NSString).lastPathComponent
            let usage = program.isEmpty ? nil : Processes.usage(of: program, below: Int32(editor), in: processes)
            return LspRow(
                name: name, status: text("status"), root: text("root"), buffers: number("buffers"),
                deaths: number("deaths"), busy: text("busy"), program: program, cpu: usage?.cpu,
                memoryKB: usage?.memoryKB, processes: usage?.processes
            )
        }
    }

    /// Clicking the servers in the status bar (or `:FrameLsp panel`): the panel.
    @objc func showLspPanel(_: Any?) {
        guard listPicker == nil else { return }
        Task { [weak self] in
            guard let self, listPicker == nil else { return }
            let root = workspace
            let rows = await lspRows()
            let items = Self.lspItems(rows, root: root)
            showList(
                title: "Language servers", items: items, current: nil, onChoose: { _ in },
                configure: { [weak self] picker in
                    picker.wide = true
                    picker.onKey = { key, item in
                        guard let self, ["r", "s"].contains(key) else { return false }
                        let verb = key == "r" ? "restart" : "stop"
                        Task {
                            _ = try? await self.session.channel.lua(
                                "vim.cmd('FrameLsp ' .. ...)", args: [.string(verb + " " + item.id)]
                            )
                        }
                        return true
                    }
                }
            )
            // It keeps up with them while it is open.
            guard let picker = listPicker else { return }
            while listPicker === picker {
                try? await Task.sleep(for: .milliseconds(1500))
                guard listPicker === picker else { return }
                let fresh = await Self.lspItems(lspRows(), root: root)
                if fresh != picker.all { picker.set(fresh, current: picker.cursor) }
            }
        }
    }
}
