import AppKit
import MessagePack
import SillCore
import SillEditor
import SillNvim

/// The folder's .slnx and the folders on disk (owner, 2026-10-23): how it differs is shown on it in Problems, and
/// `:SillSlnx sync` shows it rewritten to follow the disk (projects in their directory's parent folder, listed files in
/// their directory's, root files in /root/), as a diff; `:SillSlnx apply` writes that.
@MainActor
final class Solutions {
    private weak var app: AppDelegate?
    private let channel: NvimChannel
    private let directory: String
    /// Where the rewritten solution is put for the diff.
    private let proposals = (NSTemporaryDirectory() as NSString).appendingPathComponent("sill-slnx")

    init(app: AppDelegate, channel: NvimChannel, directory: String) {
        self.app = app
        self.channel = channel
        self.directory = directory
    }

    /// A solution was read: its drift, on it.
    func read(_ path: String, _: Slnx, _ drift: [Slnx.Drift]) {
        Task {
            let text = await Task.detached { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }.value
            let list: [MessagePackValue] = drift.map { item in
                .map([
                    "line": .int(Int64(Slnx.line(of: item.path, in: text) ?? 1)),
                    "message": .string(item.message),
                ])
            }
            // Read as sill starts, the solution can come before sill's runtime is loaded in nvim: try again a while.
            for _ in 0 ..< 40 {
                if await (try? channel.lua("require'sill'.slnx_result(...)", args: [.string(path), .array(list)])) !=
                    nil
                {
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func answer(_ action: String) {
        guard let solution = app?.tools.sidebar.explorer.solution else {
            return say("There is no .slnx in this folder.")
        }
        let directory = directory
        let path = solution.path
        Task {
            let result = await Task.detached { () -> (String, String)? in
                guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                      let slnx = try? Slnx(text: text) else { return nil }
                return (text, slnx.synced(in: directory).text)
            }.value
            guard let (text, synced) = result else { return say("\(path) does not read as a .slnx.", warn: true) }
            guard synced != text else {
                return say("\((path as NSString).lastPathComponent) already follows the folders on disk.")
            }
            switch action {
            case "apply":
                do {
                    try synced.write(toFile: path, atomically: true, encoding: .utf8)
                } catch {
                    return say("Could not write \(path): \(error)", warn: true)
                }
                _ = try? await channel.lua("vim.cmd('silent! checktime')")
                app?.tools.sidebar.explorer.readSolution()
                say("Wrote \((path as NSString).lastPathComponent): it follows the folders on disk.")
            default:
                let proposal = (proposals as NSString).appendingPathComponent((path as NSString).lastPathComponent)
                do {
                    try FileManager.default.createDirectory(atPath: proposals, withIntermediateDirectories: true)
                    try synced.write(toFile: proposal, atomically: true, encoding: .utf8)
                } catch {
                    return say("Could not write the proposal: \(error)", warn: true)
                }
                lastProposal = proposal
                // In a tab page of its own: the two-file diff takes its window over, as a merge tool's does.
                Nvim.lua(
                    channel,
                    "vim.cmd('tabnew'); require'sill.merge'.diff(...)",
                    [.string(path), .string(proposal)]
                )
                say("The .slnx on the left, rewritten to follow the folders on the right. :SillSlnx apply writes it.")
            }
        }
    }

    /// The last proposal shown, for the self-check.
    private(set) var lastProposal: String?

    private func say(_ text: String, warn: Bool = false) {
        Nvim.lua(channel, "vim.notify(...)", [.string(text), .int(warn ? 3 : 2)])
    }
}
