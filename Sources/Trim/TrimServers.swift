import CryptoKit
import Foundation

/// Finds, or provisions, the program of a language server, for Trim's supervisor in nvim (`frame/lsp.lua`) to run: on
/// the
/// person's PATH first (and rustup's, Xcode's), else into Trim's own cache: marksman and rust-analyzer downloaded at a
/// pinned version with the checksum checked, the web servers installed with npm at pinned versions (Node must be there:
/// when it is not, the failure says so). Never the app, never the person's own installs.
enum TrimServers {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static let marksmanVersion = "2026-02-08"
    static let marksmanSum = "6a801c17b5ac0dba69787c5282b3b3bd416e66c96253fae098d311c6bbd1833b"
    static let rustAnalyzerVersion = "2026-10-19"
    static let rustAnalyzerSums = [
        "aarch64": "eedad08a96f7bf92afd0890463787337d17591ea2e3df216033c6bc3ccc9d802",
        "x86_64": "bdfd46e82731a8d3502d852d28b6462c1f1c13eed0b3e76bbcf1ba839028249c",
    ]
    /// HTML, CSS and JSON's servers, and TypeScript, whose compiler is its own server.
    static let roslynVersion = "5.12.0-1.26475.2"
    static let fsautocompleteVersion = "0.86.0"
    static let webPackages = ["vscode-langservers-extracted@4.10.0", "typescript@7.0.2"]

    static var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("trim/servers")
    }

    /// A name as people read it.
    static func label(_ name: String) -> String {
        [
            "rust_analyzer": "rust-analyzer",
            "sourcekit": "sourcekit-lsp",
            "cssls": "CSS",
            "jsonls": "JSON",
            "html": "HTML",
            "typescript": "TypeScript",
            "csharp": "C# (Roslyn)",
            "fsautocomplete": "F#",
        ][name] ?? name
    }

    /// The PATH a program is looked for on: the person's, which an app started from the Dock does not get, as far as
    /// the
    /// usual places go.
    static var searchPath: String {
        let home = NSHomeDirectory()
        let more = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home + "/.cargo/bin",
            home + "/.local/share/mise/shims",
            home + "/.local/bin",
            home + "/.dotnet/tools",
            "/usr/bin",
            "/bin",
        ]
        let have = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (have + more.filter { !have.contains($0) }).joined(separator: ":")
    }

    static func onPath(_ tool: String) -> String? {
        for folder in searchPath.split(separator: ":") {
            let path = folder + "/" + tool
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Runs a program to its end: its exit code and what it wrote.
    static func run(
        _ tool: String,
        _ arguments: [String],
        in directory: String? = nil,
        timeout: Duration = .seconds(600)
    )
        async throws -> (code: Int32, output: String)
    {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = searchPath
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let watchdog = Task {
                try await Task.sleep(for: timeout)
                process.terminate()
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }

    /// Whether a found program runs: rustup's proxy for a missing tool does not.
    static func answers(_ path: String, _ argument: String) async -> Bool {
        await (try? run(path, [argument], timeout: .seconds(20)))?.code == 0
    }

    /// The command line that runs the server, found or provisioned.
    static func command(for name: String, in directory: String) async throws -> [String] {
        switch name {
        case "rust_analyzer":
            if let path = onPath("rust-analyzer"), await answers(path, "--version") { return [path] }
            return try await [rustAnalyzer()]
        case "sourcekit":
            if let path = onPath("sourcekit-lsp"), await answers(path, "--help") { return [path] }
            if let found = try? await run("/usr/bin/xcrun", ["--find", "sourcekit-lsp"]), found.code == 0 {
                return [found.output.trimmingCharacters(in: .whitespacesAndNewlines)]
            }
            throw Failure(description: "sourcekit-lsp comes with Xcode or a Swift toolchain")
        case "marksman":
            if let path = onPath("marksman"), await answers(path, "--version") { return [path, "server"] }
            return try await [marksman(), "server"]
        case "csharp":
            if let path = onPath("roslyn-language-server") { return [path, "--stdio"] }
            return try await [dotnetTool("roslyn-language-server", version: roslynVersion), "--stdio"]
        case "fsautocomplete":
            if let path = onPath("fsautocomplete"), await answers(path, "--version") { return [path] }
            return try await [dotnetTool("fsautocomplete", version: fsautocompleteVersion)]
        case "html", "cssls", "jsonls":
            let binary = [
                "html": "vscode-html-language-server",
                "cssls": "vscode-css-language-server",
                "jsonls": "vscode-json-language-server",
            ][name]!
            if let path = onPath(binary) { return [path, "--stdio"] }
            return try await [web().appendingPathComponent("node_modules/.bin/\(binary)").path, "--stdio"]
        case "typescript":
            // The project's own TypeScript 7 (its compiler is its server), else Trim's.
            let local = (directory as NSString).appendingPathComponent("node_modules/typescript/package.json")
            if let data = FileManager.default.contents(atPath: local),
               let version = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? String,
               let major = Int(version.split(separator: ".").first ?? ""), major >= 7
            {
                return [(directory as NSString).appendingPathComponent("node_modules/.bin/tsc"), "--lsp", "--stdio"]
            }
            return try await [web().appendingPathComponent("node_modules/.bin/tsc").path, "--lsp", "--stdio"]
        default:
            throw Failure(description: "Trim does not know the server \(name)")
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// rust-analyzer's release, downloaded once into the cache (its releases publish no checksum: the pinned ones are
    /// the
    /// archives as first fetched).
    static func rustAnalyzer() async throws -> String {
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
        guard sha256(data) == rustAnalyzerSums[arch] else {
            throw Failure(description: "rust-analyzer's download does not match its checksum")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: binary + ".gz"))
        guard try await run("/usr/bin/gunzip", ["-f", binary + ".gz"], in: folder.path).code == 0
        else { throw Failure(description: "rust-analyzer's archive did not unpack") }
        chmod(binary, 0o755)
        return binary
    }

    /// marksman, downloaded once into the cache at a pinned version with its checksum checked.
    static func marksman() async throws -> String {
        let folder = cache.appendingPathComponent("marksman-\(marksmanVersion)")
        let binary = folder.appendingPathComponent("marksman").path
        if FileManager.default.isExecutableFile(atPath: binary) { return binary }
        let url = URL(string:
            "https://github.com/artempyanykh/marksman/releases/download/\(marksmanVersion)/marksman-macos")!
        let (download, _) = try await URLSession.shared.download(from: url)
        let data = try Data(contentsOf: download)
        guard sha256(data) == marksmanSum
        else { throw Failure(description: "marksman's download does not match its checksum") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: binary + ".part"))
        chmod(binary + ".part", 0o755)
        try? FileManager.default.removeItem(atPath: binary)
        try FileManager.default.moveItem(atPath: binary + ".part", toPath: binary)
        return binary
    }

    /// A .NET tool, installed once into the cache at a pinned version (NuGet checks the package's signature). Without
    /// the SDK the
    /// failure says so.
    static func dotnetTool(_ name: String, version: String) async throws -> String {
        let folder = cache.appendingPathComponent("\(name)-\(version)")
        let binary = folder.appendingPathComponent(name).path
        if FileManager.default.isExecutableFile(atPath: binary) { return binary }
        guard let dotnet = onPath("dotnet") else {
            throw Failure(description: "the .NET SDK is not installed (no dotnet on the PATH): C# and F# need it")
        }
        // From the cache, not the project: a global.json there may pin an SDK that is not installed.
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let installed = try await run(
            dotnet, ["tool", "install", name, "--tool-path", folder.path, "--version", version], in: cache.path
        )
        guard installed.code == 0, FileManager.default.isExecutableFile(atPath: binary)
        else { throw Failure(description: "dotnet tool install \(name) failed: \(installed.output.suffix(300))") }
        return binary
    }

    /// The web servers' folder, installed with npm the first time. Without Node the failure says so.
    static func web() async throws -> URL {
        let folder = cache.appendingPathComponent("web")
        let marker = folder.appendingPathComponent(".installed")
        let wanted = webPackages.joined(separator: " ")
        if (try? String(contentsOf: marker, encoding: .utf8)) == wanted { return folder }
        guard onPath("npm") != nil, onPath("node") != nil else {
            throw Failure(
                description: "Node.js is not installed (no node or npm on the PATH): the HTML, CSS, JSON and TypeScript servers need it"
            )
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let installed = try await run("/usr/bin/env", [
            "npm", "install", "--prefix", folder.path, "--no-audit", "--no-fund", "--silent",
        ] + webPackages, in: folder.path)
        guard installed.code == 0
        else { throw Failure(description: "npm install failed: \(installed.output.suffix(300))") }
        try wanted.write(to: marker, atomically: true, encoding: .utf8)
        return folder
    }
}
