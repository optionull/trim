import AppKit
import MessagePack
import SillCore
import SillEditor
import SillNvim

/// Following an agent (after M9): the files changing on disk that the person did not write from sill, each marked in
/// the explorer for the session, and with `:SillFollow` opened in a Follow tab at its first changed line as it lands;
/// what an agent reads through sill's MCP server is shown too.
@MainActor
final class Follower {
    private weak var app: AppDelegate?
    private let channel: NvimChannel
    private let directory: String
    private let events: FileEvents
    /// Files changed this session by someone else (an agent), relative, with when.
    private(set) var touched: [String: Date] = [:]
    /// The last change seen: a file and its first changed line.
    private(set) var last: (path: String, line: Int)?
    /// The last file an agent read.
    private(set) var reading: String?
    /// `:SillFollow`: changes open as they land.
    private(set) var following = false
    /// How many of nvim's writes were read.
    private var writesSeen = 0
    /// What each followed file held, for the next change's first changed line.
    private var contents: [String: [String]] = [:]
    var onChange: (() -> Void)?
    private var handled = 0

    init(app: AppDelegate, channel: NvimChannel, directory: String) {
        self.app = app
        self.channel = channel
        self.directory = directory
        events = FileEvents(root: directory)
        // Held a moment: nvim's word that the person wrote a file comes first, so their write is known as theirs.
        events.onChange = { [weak self] paths in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                self?.changed(paths)
            }
        }
        events.start()
    }

    /// nvim's asks: the files the person wrote, and `:SillFollow`.
    func update(_ screen: Screen) {
        // What the person wrote is what the file holds: a change on disk to just that is theirs, not followed.
        if screen.writes > writesSeen {
            for path in screen.written.suffix(min(screen.writes - writesSeen, screen.written.count)) {
                contents[path] = (try? String(contentsOfFile: path, encoding: .utf8))?.components(separatedBy: "\n")
            }
            writesSeen = screen.writes
        }
        if screen.followAsks > handled {
            handled = screen.followAsks
            following.toggle()
            Nvim.lua(channel, "vim.notify(...)", [.string(following ?
                    "Following: what changes on disk opens in the Follow tab as it lands. :SillFollow again stops." :
                    "No longer following."), .int(2)])
            notify()
        }
    }

    /// An agent's tool wrote a file (its hook says so): followed as the agent's, whatever the file system said.
    func agentWrote(_ path: String) {
        changed([path])
    }

    /// An agent read a file (through sill's MCP server).
    func read(_ path: String) {
        reading = relative(path)
        notify()
    }

    private func changed(_ paths: [String]) {
        let now = Date()
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else {
                // Gone: an agent's when sill had seen it, or git has it; anything else was never anyone's file.
                if contents.removeValue(forKey: path) != nil {
                    touched[relative(path)] = now
                } else {
                    let directory = directory, name = relative(path)
                    Task {
                        if await Task.detached(operation: { Self.tracked(name, in: directory) }).value {
                            touched[name] = now
                            notify()
                        }
                    }
                }
                continue
            }
            let lines = (try? String(contentsOfFile: path, encoding: .utf8))?.components(separatedBy: "\n") ?? []
            let before = contents[path]
            contents[path] = lines
            if before == lines { continue }
            touched[relative(path)] = now
            if let before {
                let line = Self.firstDifference(before, lines)
                last = (relative(path), line)
                if following { show(path, line) }
            } else {
                // Not seen before: git knows what it was.
                let directory = directory
                Task {
                    let line = await Task.detached { Self.firstChange(path, in: directory) }.value
                    last = (relative(path), line)
                    if following { show(path, line) }
                    notify()
                }
            }
        }
        notify()
    }

    /// Whether git's HEAD has the file.
    nonisolated static func tracked(_ path: String, in directory: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory, "cat-file", "-e", "HEAD:" + path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// A file's first changed line against git's HEAD (1 for a file git does not have).
    nonisolated static func firstChange(_ path: String, in directory: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory, "diff", "--no-color", "-U0", "HEAD", "--", path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 1 }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        // @@ -a,b +c,d @@: the first hunk's c.
        guard let hunk = text.split(separator: "\n").first(where: { $0.hasPrefix("@@") }),
              let plus = hunk.split(separator: " ").first(where: { $0.hasPrefix("+") }),
              let line = Int(plus.dropFirst().split(separator: ",").first ?? "") else { return 1 }
        return max(line, 1)
    }

    /// The first line (1-based) where two versions of a file differ.
    nonisolated static func firstDifference(_ old: [String], _ new: [String]) -> Int {
        for index in 0 ..< max(old.count, new.count)
            where index >= old.count || index >= new.count || old[index] != new[index]
        {
            return min(index, max(new.count - 1, 0)) + 1
        }
        return 1
    }

    /// The change in the Follow tab: its window shows the file at the line, the person's own windows left alone.
    private func show(_ path: String, _ line: Int) {
        Nvim.lua(channel, """
        local path, line = ...
        local tab
        for _, t in ipairs(vim.api.nvim_list_tabpages()) do
          if vim.t[t].sill_follow then tab = t end
        end
        local from = vim.api.nvim_get_current_tabpage()
        if not tab then
          vim.cmd('tabnew')
          tab = vim.api.nvim_get_current_tabpage()
          vim.t[tab].sill_follow = true
        else
          vim.api.nvim_set_current_tabpage(tab)
        end
        vim.cmd('silent! checktime')
        vim.cmd('edit ' .. vim.fn.fnameescape(path))
        pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
        vim.cmd('normal! zz')
        """, [.string(path), .int(Int64(line))])
    }

    private func relative(_ path: String) -> String {
        path.hasPrefix(directory + "/") ? String(path.dropFirst(directory.count + 1)) : path
    }

    /// What the status bar says while following, or of the last change.
    var status: String? {
        guard following || reading != nil else { return nil }
        if let last { return (following ? "following · " : "") + "\(last.path):\(last.line)" }
        if let reading { return "agent reading \(reading)" }
        return following ? "following" : nil
    }

    private func notify() { onChange?() }
}
