import AppKit
import MessagePack
import SillNvim

/// The editor's right-click menu (board 6): the language server's actions, compare with a branch, tag or commit,
/// blame and history.
@MainActor
enum ContextMenu {
    /// Refs to compare with: recent branches, tags, and the last commits, newest first.
    static func refs(in directory: String) -> (branches: [String], tags: [String], commits: [(String, String)]) {
        let branches = Git.run([
            "for-each-ref",
            "--sort=-committerdate",
            "--count=8",
            "--format=%(refname:short)",
            "refs/heads",
            "refs/remotes",
        ], in: directory)?
            .split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") } ?? []
        let tags = Git.run([
            "for-each-ref",
            "--sort=-creatordate",
            "--count=5",
            "--format=%(refname:short)",
            "refs/tags",
        ], in: directory)?.split(separator: "\n").map(String.init) ?? []
        let commits = Git.run(["log", "-5", "--format=%h%x09%s"], in: directory)?.split(separator: "\n").compactMap {
            line -> (String, String)? in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        } ?? []
        return (branches, tags, commits)
    }

    static func menu(directory: String, channel: NvimChannel, run: @escaping (String) -> Void) -> NSMenu {
        let menu = NSMenu(title: "Editor")
        menu.autoenablesItems = false
        func item(_ title: String, key: String = "", _ action: @escaping () -> Void) -> NSMenuItem {
            let item = ClosureItem(title: title, action: action)
            item.keyEquivalent = key
            return item
        }
        menu.addItem(item("Go to definition") { Nvim.lua(channel, "require'sill'.lsp('definition')") })
        menu.addItem(item("Find usages") { Nvim.lua(channel, "require'sill'.lsp('references')") })
        menu.addItem(item("Rename") { Nvim.lua(channel, "require'sill'.lsp('rename')") })
        menu.addItem(.separator())
        menu.addItem(item("Blame line") { Nvim.lua(channel, "require'sill'.blame()") })
        menu.addItem(item("History of file") {
            run("git log --oneline --follow -- \"$(git rev-parse --show-prefix 2>/dev/null)\"")
        })
        menu.addItem(.separator())

        let refs = refs(in: directory)
        func compareMenu(_ title: String, _ pick: @escaping (String) -> Void) -> NSMenuItem {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            sub.autoenablesItems = false
            func section(_ heading: String, _ entries: [(ref: String, label: String)]) {
                guard !entries.isEmpty else { return }
                let header = NSMenuItem(title: heading, action: nil, keyEquivalent: "")
                header.isEnabled = false
                sub.addItem(header)
                for entry in entries {
                    sub.addItem(item(entry.label) { pick(entry.ref) })
                }
            }
            section("Branches", refs.branches.map { ($0, $0) })
            section("Tags", refs.tags.map { ($0, $0) })
            section("Recent", refs.commits.map { ($0.0, "\($0.0)  \($0.1)") })
            if sub.items.isEmpty {
                let none = NSMenuItem(title: "Not in a git repository", action: nil, keyEquivalent: "")
                none.isEnabled = false
                sub.addItem(none)
            }
            parent.submenu = sub
            return parent
        }
        menu.addItem(compareMenu("Compare file with") { ref in
            Nvim.lua(channel, "require'sill'.diff(...)", [.string(ref)])
        })
        menu.addItem(compareMenu("Compare whole tree with") { ref in
            run("git --no-pager diff --stat \(ref) && git --no-pager diff \(ref) | head -400")
        })
        return menu
    }
}

/// A menu item that runs a closure.
final class ClosureItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(chosen), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) { fatalError("not used") }

    @objc private func chosen() { run() }

    /// What choosing it does, for the self-check.
    func choose() { run() }
}
