import CryptoKit
import Foundation
import MessagePack
import SillCore
import SillNvim

/// The language servers beside Roslyn (M7), found or provisioned when nvim first asks for one (a file it serves
/// opened): on the person's PATH first, else rust-analyzer from rustup and sourcekit-lsp from Xcode, else into sill's
/// cache (never the app, never the person's own installs): marksman downloaded at a pinned version with its checksum
/// checked, the web servers installed with npm at pinned versions. nvim is then told the command.
@MainActor
final class LanguageServers {
    private let channel: NvimChannel
    private let directory: String
    /// Asks handled so far (nvim's list of them only grows).
    private var handled = 0
    /// What each server resolved to, for the self-check: its command, or why there is none.
    private(set) var resolved: [String: Result<[String], ServerFailure>] = [:]

    nonisolated static let marksmanVersion = "2026-02-08"
    nonisolated static let marksmanSum = "6a801c17b5ac0dba69787c5282b3b3bd416e66c96253fae098d311c6bbd1833b"
    /// The npm packages, pinned: HTML, CSS and JSON's servers, and TypeScript, whose compiler is its own server.
    nonisolated static let webPackages = ["vscode-langservers-extracted@4.10.0", "typescript@7.0.2"]

    struct ServerFailure: Error, CustomStringConvertible {
        var description: String
    }

    init(channel: NvimChannel, directory: String) {
        self.channel = channel
        self.directory = directory
    }

    nonisolated static var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("sill/servers")
    }

    /// nvim's asks that are new.
    func answer(_ asks: [String]) {
        guard asks.count > handled else { return }
        let new = asks[handled...]
        handled = asks.count
        for name in new {
            Task { await resolve(name) }
        }
    }

    private func resolve(_ name: String) async {
        notify(name, "starting")
        let directory = directory
        let result: Result<[String], ServerFailure>
        do {
            result = try await .success(Task.detached { try await Self.command(for: name, in: directory) }.value)
        } catch {
            result = .failure(error as? ServerFailure ?? ServerFailure(description: "\(error)"))
        }
        resolved[name] = result
        switch result {
        case let .success(command):
            notify(name, "ready")
            _ = try? await channel.lua("require'sill.servers'.ready(...)", args: [
                .string(name), .array(command.map(MessagePackValue.string)),
            ])
        case let .failure(why):
            notify(name, "unavailable")
            _ = try? await channel.lua("require'sill.servers'.ready(...)", args: [.string(name), .nil])
            _ = try? await channel.lua("vim.notify(...)", args: [
                .string("No \(Self.label(name)): \(why.description)"), .int(3),
            ])
        }
    }

    private func notify(_ name: String, _ status: String) {
        Nvim.lua(channel, "vim.rpcnotify(vim.g.sill_channel, 'sill_lsp', ...)", [.map([
            .string("name"): .string(Self.label(name)), .string("status"): .string(status),
        ])])
    }

    nonisolated static func label(_ name: String) -> String {
        switch name {
        case "rust_analyzer": "rust-analyzer"
        case "sourcekit": "sourcekit-lsp"
        case "cssls": "CSS"
        case "jsonls": "JSON"
        case "html": "HTML"
        case "typescript": "TypeScript"
        default: name
        }
    }

    // MARK: Finding

    /// The command line that runs the server.
    nonisolated static func command(for name: String, in directory: String) async throws -> [String] {
        switch name {
        case "rust_analyzer":
            // rustup puts a proxy on the PATH whether or not the component is there: it must answer.
            if let path = await onPath("rust-analyzer"), await answers(path, "--version") { return [path] }
            return try await [rustAnalyzer()]
        case "sourcekit":
            if let path = await onPath("sourcekit-lsp"), await answers(path, "--help") { return [path] }
            let xcrun = try? await NativeRecorder.capture("/usr/bin/xcrun", ["--find", "sourcekit-lsp"], in: directory)
            if let xcrun, xcrun.code == 0 { return [xcrun.output.trimmingCharacters(in: .whitespacesAndNewlines)] }
            throw ServerFailure(description: "sourcekit-lsp comes with Xcode or a Swift toolchain")
        case "marksman":
            if let path = await onPath("marksman"), await answers(path, "--version") { return [path, "server"] }
            return try await [marksman(), "server"]
        case "html", "cssls", "jsonls":
            let binary = [
                "html": "vscode-html-language-server",
                "cssls": "vscode-css-language-server",
                "jsonls": "vscode-json-language-server",
            ][name]!
            if let path = await onPath(binary) { return [path, "--stdio"] }
            return try await [web().appendingPathComponent("node_modules/.bin/\(binary)").path, "--stdio"]
        case "typescript":
            // The project's own TypeScript 7 (its compiler is its server), else sill's.
            let local = (directory as NSString).appendingPathComponent("node_modules/typescript/package.json")
            if let data = FileManager.default.contents(atPath: local),
               let version = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? String,
               let major = Int(version.split(separator: ".").first ?? ""), major >= 7
            {
                return [(directory as NSString).appendingPathComponent("node_modules/.bin/tsc"), "--lsp", "--stdio"]
            }
            return try await [web().appendingPathComponent("node_modules/.bin/tsc").path, "--lsp", "--stdio"]
        default:
            throw ServerFailure(description: "sill does not know the server \(name)")
        }
    }

    /// Whether a found program runs: a proxy for a missing tool does not.
    nonisolated static func answers(_ path: String, _ argument: String) async -> Bool {
        await (try? NativeRecorder.capture(path, [argument], in: NSHomeDirectory()))?.code == 0
    }

    nonisolated static let rustAnalyzerVersion = "2026-10-19"
    nonisolated static let rustAnalyzerSums = [
        "aarch64": "eedad08a96f7bf92afd0890463787337d17591ea2e3df216033c6bc3ccc9d802",
        "x86_64": "bdfd46e82731a8d3502d852d28b6462c1f1c13eed0b3e76bbcf1ba839028249c",
    ]

    /// rust-analyzer's release, downloaded once into sill's cache: its releases publish no checksum, so the pinned
    /// ones are the release's archives as sill first fetched them (2026-10-24).
    nonisolated static func rustAnalyzer() async throws -> String {
        #if arch(arm64)
            let arch = "aarch64"
        #else
            let arch = "x86_64"
        #endif
        let folder = cache.appendingPathComponent("rust-analyzer-\(rustAnalyzerVersion)")
        let binary = folder.appendingPathComponent("rust-analyzer").path
        if FileManager.default.isExecutableFile(atPath: binary) { return binary }
        let url = URL(string: "https://github.com/rust-lang/rust-analyzer/releases/download/" +
            "\(rustAnalyzerVersion)/rust-analyzer-\(arch)-apple-darwin.gz")!
        let (download, _) = try await URLSession.shared.download(from: url)
        let data = try Data(contentsOf: download)
        let sum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard sum == rustAnalyzerSums[arch] else {
            throw ServerFailure(description: "rust-analyzer's download does not match its checksum")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = binary + ".gz"
        try data.write(to: URL(fileURLWithPath: archive))
        let unpacked = try await NativeRecorder.capture("/usr/bin/gunzip", ["-f", archive], in: folder.path)
        guard unpacked.code == 0 else { throw ServerFailure(description: "rust-analyzer's archive did not unpack") }
        chmod(binary, 0o755)
        return binary
    }

    nonisolated static func onPath(_ tool: String) async -> String? {
        guard let found = try? await NativeRecorder.capture("/usr/bin/env", ["which", tool], in: NSHomeDirectory()),
              found.code == 0 else { return nil }
        let path = found.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// marksman, downloaded once into sill's cache. Its releases publish no checksum: the pinned one is the release's
    /// binary as sill first fetched it (2026-10-24).
    nonisolated static func marksman() async throws -> String {
        let folder = cache.appendingPathComponent("marksman-\(marksmanVersion)")
        let binary = folder.appendingPathComponent("marksman").path
        if FileManager.default.isExecutableFile(atPath: binary) { return binary }
        let url = URL(string:
            "https://github.com/artempyanykh/marksman/releases/download/\(marksmanVersion)/marksman-macos")!
        let (download, _) = try await URLSession.shared.download(from: url)
        let data = try Data(contentsOf: download)
        let sum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard sum == marksmanSum
        else { throw ServerFailure(description: "marksman's download does not match its checksum") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: binary + ".part"))
        chmod(binary + ".part", 0o755)
        try? FileManager.default.removeItem(atPath: binary)
        try FileManager.default.moveItem(atPath: binary + ".part", toPath: binary)
        return binary
    }

    /// The web servers' folder, installed with npm (the person's, as their PATH has it) the first time.
    nonisolated static func web() async throws -> URL {
        let folder = cache.appendingPathComponent("web")
        let marker = folder.appendingPathComponent(".installed")
        let wanted = webPackages.joined(separator: " ")
        if (try? String(contentsOf: marker, encoding: .utf8)) == wanted { return folder }
        guard await onPath("npm") != nil, await onPath("node") != nil else {
            throw ServerFailure(description: "the web servers need Node.js and npm on your PATH")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let installed = try await NativeRecorder.capture("/usr/bin/env", [
            "npm", "install", "--prefix", folder.path, "--no-audit", "--no-fund", "--silent",
        ] + webPackages, in: folder.path)
        guard installed.code == 0
        else { throw ServerFailure(description: "npm install failed: \(installed.output.suffix(300))") }
        try wanted.write(to: marker, atomically: true, encoding: .utf8)
        return folder
    }
}
