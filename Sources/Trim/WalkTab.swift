import AppKit
import MessagePack
import SillCore
import SillNvim
import TrimRun
import TrimTree
import TrimWalk

/// Walkthroughs are files in the editor: a tab like any other, in nvim. What the app adds is what nvim cannot know:
/// where each
/// anchor's code is now and whether it changed, a diff, and the Run pane for `@run`. It computes that for the buffer's
/// text
/// and gives it to `trim.walk` to draw.
extension TrimWindowController {
    /// A walkthrough is shown by opening it.
    func openWalkthrough(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        open(file: path, toEditor: true)
    }

    /// View ▸ Walkthroughs…, `<leader>W`, `:TrimWalk`: the repository's walkthroughs to choose from.
    @objc func showWalkthroughs(_: Any?) {
        let root = workspace
        Task { [weak self] in
            let found = await Task.detached { WalkFiles.find(in: root) }.value
            guard let self, listPicker == nil else { return }
            let items = found.map { walk in
                PickerItem(
                    id: walk.path, title: walk.title.isEmpty ? walk.relative : walk.title,
                    detail: (walk.by.map { "by " + $0 + " · " } ?? "") +
                        (walk.isPrivate ? "private" : "in the repository"),
                    subtitle: walk.relative
                )
            }
            showList(
                title: "Walkthroughs", items: items, current: items.first?.id,
                onChoose: { [weak self] item in self?.openWalkthrough(item.id) }
            )
        }
    }

    /// `@run` on Enter in the walkthrough: shown in the Run pane, run by that key press and nothing else.
    func walkRun(_ payload: String) {
        let parts = payload.components(separatedBy: "\t")
        guard parts.count == 2 else { return }
        runInRunPane(RunEntry(
            title: parts[0], source: "walkthrough", kind: .task, command: parts[1], directory: workspace,
            origin: "walkthrough"
        ))
    }

    /// The buffer's text (`{path, text}` from `trim.walk`): its anchors found, their code, what changed since, and the
    /// diffs.
    func walkModel(_ payload: String) {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let path = object["path"], let text = object["text"] else { return }
        let root = workspace
        Task { [weak self] in
            let string = await Task.detached { Self.walkModelJSON(text: text, path: path, root: root) }.value
            guard let self, let string else { return }
            _ = try? await session.channel.lua(
                "require('trim.walk').render(...)", args: [.string(path), .string(string)]
            )
        }
    }

    nonisolated static func walkModelJSON(text: String, path: String, root: String) -> String? {
        let model = walkModel(text: text, path: path, root: root)
        return (try? JSONSerialization.data(withJSONObject: model)).flatMap { String(data: $0, encoding: .utf8) }
    }

    nonisolated static func walkModel(text: String, path: String, root: String) -> [String: Any] {
        let walk = Walkthrough(text)
        let folder = (path as NSString).deletingLastPathComponent
        let resolver = AnchorResolver(root: root, folder: folder)
        func relative(_ file: String) -> String { file
            .hasPrefix(root + "/") ? String(file.dropFirst(root.count + 1)) : file
        }
        var items: [[String: Any]] = []
        var stale = 0
        for step in walk.steps {
            for block in step.blocks {
                switch block {
                case let .code(anchor, line):
                    var item: [String: Any] = ["line": line, "kind": "code", "heading": anchor.text]
                    switch resolver.resolve(anchor) {
                    case let .found(found):
                        item["path"] = found.path
                        item["relative"] = relative(found.path)
                        item["from"] = found.lines.lowerBound
                        item["to"] = found.lines.upperBound
                        item["code"] = found.text.joined(separator: "\n")
                        switch Freshness.of(recorded: walk.fingerprints[line], now: found) {
                        case .fresh: item["badge"] = "as written"; item["level"] = "ok"
                        case .changed: item["badge"] = "changed since written"; item["level"] = "warn"; stale += 1
                        case .unchecked, .orphaned: break
                        }
                    case let .problem(message):
                        item["badge"] = "not found"
                        item["level"] = "err"
                        item["message"] = message
                        stale += 1
                    }
                    items.append(item)
                case let .diff(file, line):
                    let text = WalkGit.diff(file, base: walk.base, in: root) ?? ""
                    items.append([
                        "line": line,
                        "kind": "diff",
                        "heading": file,
                        "text": text.isEmpty ? "no change in \(file)" : text,
                    ])
                default: break
                }
            }
        }
        var meta: [String] = []
        if let by = walk.by { meta.append("by " + by) }
        if let model = walk.model { meta.append(model) }
        if let commit = walk.commit { meta.append("at " + commit) }
        if let created = walk.created { meta.append(created) }
        meta.append("\(walk.steps.count) steps")
        return ["title": walk.title, "meta": meta.joined(separator: " · "), "stale": stale, "items": items]
    }
}
