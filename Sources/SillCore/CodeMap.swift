import Foundation

/// A one-screen overview of a repository for someone who does not know it: its projects and what each builds on, what
/// kind each is, where it starts, and the files that change most (where the decisions usually are).
///
/// Built from the files git tracks and their history, not from a language server, so it is there in a second for a
/// repository of any size. .NET projects (`*.csproj`, `*.fsproj`) and Swift packages' targets come with their
/// references; Rust, Node and Python packages come as projects of their own.
public struct CodeMap: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case app, web, test, library
    }

    /// A place in a file, from the repository's root.
    public struct Place: Equatable, Sendable {
        public var path: String
        public var line: Int
        /// What starts there: "Main", "top-level statements", "HTTP endpoints".
        public var label: String

        public init(path: String, line: Int, label: String) {
            self.path = path
            self.line = line
            self.label = label
        }
    }

    public struct Project: Equatable, Sendable {
        public var name: String
        /// Its project file or manifest, from the root.
        public var file: String
        /// The folder its files are in, from the root ("" for the root).
        public var folder: String
        public var kind: Kind
        public var language: String
        /// The projects it references, by name.
        public var references: [String]
        public var files = 0
        public var lines = 0
        public var entryPoints: [Place] = []
        /// Its files that changed most in the history read, most first, with how often.
        public var hot: [(path: String, changes: Int)] = []

        public init(
            name: String, file: String, folder: String, kind: Kind, language: String, references: [String] = []
        ) {
            self.name = name
            self.file = file
            self.folder = folder
            self.kind = kind
            self.language = language
            self.references = references
        }

        public static func == (lhs: Project, rhs: Project) -> Bool {
            lhs.name == rhs.name && lhs.file == rhs.file && lhs.folder == rhs.folder && lhs.kind == rhs.kind &&
                lhs.language == rhs.language && lhs.references == rhs.references && lhs.files == rhs.files &&
                lhs.lines == rhs.lines && lhs.entryPoints == rhs.entryPoints &&
                lhs.hot.map(\.path) == rhs.hot.map(\.path) && lhs.hot.map(\.changes) == rhs.hot.map(\.changes)
        }
    }

    public var name: String
    public var projects: [Project]
    /// Files no project holds.
    public var otherFiles = 0

    public init(name: String, projects: [Project], otherFiles: Int = 0) {
        self.name = name
        self.projects = projects
        self.otherFiles = otherFiles
    }

    // MARK: Building

    /// The map of the files `files` (paths from the root, as git lists them), reading each with `read`, and `changes`,
    /// how often each file changed.
    public static func build(
        name: String, files: [String], changes: [String: Int] = [:], read: (String) -> String?
    ) -> CodeMap {
        var projects: [Project] = []
        for file in files {
            let url = file as NSString
            switch url.pathExtension {
            case "csproj", "fsproj", "vbproj":
                if let text = read(file) { projects.append(dotnet(file, text)) }
            default:
                switch url.lastPathComponent {
                case "Package.swift": if let text = read(file) { projects += swift(file, text, files) }
                case "Cargo.toml": if let text = read(file) { projects.append(contentsOf: manifest(file, text, "Rust"))
                    }
                case "package.json": if let text = read(file) { projects.append(contentsOf: node(file, text)) }
                case "pyproject.toml": if let text = read(file) {
                        projects.append(contentsOf: manifest(file, text, "Python"))
                    }
                default: break
                }
            }
        }
        // A file is the project's whose folder holds it most closely; in one folder, a project file's over a manifest.
        let folders = projects.indices.sorted {
            let (a, b) = (projects[$0], projects[$1])
            if a.folder.count != b.folder.count { return a.folder.count > b.folder.count }
            return a.file.hasSuffix("proj") && !b.file.hasSuffix("proj")
        }
        var other = 0
        for file in files {
            guard let index = folders.first(where: { contains(projects[$0].folder, file) }) else {
                other += 1
                continue
            }
            projects[index].files += 1
            let language = projects[index].language
            guard sourceExtensions.contains((file as NSString).pathExtension), let text = read(file) else { continue }
            projects[index].lines += text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            if let place = entryPoint(file, text, language: language) { projects[index].entryPoints.append(place) }
            if let count = changes[file], count > 0 { projects[index].hot.append((file, count)) }
        }
        for index in projects.indices {
            projects[index].hot = Array(projects[index].hot
                .sorted { $0.changes != $1.changes ? $0.changes > $1.changes : $0.path < $1.path }.prefix(3))
            projects[index].entryPoints.sort { $0.path < $1.path }
            let names = Set(projects.map(\.name))
            var seen = Set<String>()
            projects[index].references = projects[index].references
                .filter { names.contains($0) && seen.insert($0).inserted }
        }
        // A manifest beside a project file (a package.json for its assets) holds nothing of its own.
        projects.removeAll { $0.files == 0 }
        return CodeMap(name: name, projects: projects.sorted { $0.name < $1.name }, otherFiles: other)
    }

    /// The map of the git repository at `root`: its tracked files, and the last 2,000 commits' changes.
    public static func build(root: String) -> CodeMap {
        let files = (Review.git(["ls-files", "-z"], in: root) ?? "").split(separator: "\0").map(String.init)
        var changes: [String: Int] = [:]
        let log = Review.git(["log", "-n", "2000", "--format=", "--name-only", "--no-renames"], in: root) ?? ""
        for line in log.split(separator: "\n") where !line.isEmpty {
            changes[String(line), default: 0] += 1
        }
        return build(name: (root as NSString).lastPathComponent, files: files, changes: changes) { file in
            let path = (root as NSString).appendingPathComponent(file)
            // Generated or vendored giants say little and cost a lot.
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
                  size < 1_000_000
            else { return nil }
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
    }

    private static let sourceExtensions: Set<String> = [
        "cs", "fs", "vb", "razor", "swift", "rs", "ts", "tsx", "js", "jsx", "mjs", "py", "go", "kt", "java", "c", "h",
        "cpp", "m", "lua",
    ]

    private static func contains(_ folder: String, _ file: String) -> Bool {
        folder.isEmpty || file.hasPrefix(folder + "/")
    }

    private static func folder(of file: String) -> String { (file as NSString).deletingLastPathComponent }

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: match.numberOfRanges > 1 ? 1 : 0), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func all(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    // MARK: Projects

    private static func dotnet(_ file: String, _ text: String) -> Project {
        let name = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        let sdk = first(#"<Project\s+Sdk="([^"]+)""#, in: text) ?? ""
        // Test packages often come from a Directory.Build.props, so the name and the folder count too.
        let named = [".Tests", ".Test", ".IntegrationTests", ".Specs", "Tests"].contains { name.hasSuffix($0) } ||
            file.hasPrefix("tests/") || file.hasPrefix("test/") || file.contains("/tests/")
        let test = named || first(#"<IsTestProject>\s*(true)"#, in: text) != nil ||
            text.contains("Microsoft.NET.Test.Sdk") || text.contains("\"xunit") || text.contains("\"NUnit") ||
            text.contains("MSTest") || sdk.contains("MSTest")
        // A Razor class library is a library; only the web SDK hosts.
        let kind: Kind = test ? .test : sdk.hasSuffix(".Web") ? .web :
            first(#"<OutputType>\s*(\w+)"#, in: text).map { $0.lowercased().contains("exe") } == true ? .app :
            .library
        let references = all(#"<ProjectReference\s+Include="([^"]+)""#, in: text).map {
            (($0.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent as NSString)
                .deletingPathExtension
        }
        let language = file.hasSuffix(".fsproj") ? "F#" : file.hasSuffix(".vbproj") ? "Visual Basic" : "C#"
        return Project(
            name: name,
            file: file,
            folder: folder(of: file),
            kind: kind,
            language: language,
            references: references
        )
    }

    /// A Swift package's targets, each a project; their dependencies by name.
    private static func swift(_ file: String, _ text: String, _: [String]) -> [Project] {
        let root = folder(of: file)
        guard let regex = try? NSRegularExpression(pattern: #"\.(executableTarget|testTarget|target)\s*\("#) else {
            return []
        }
        // Targets are the items of `targets: [`; a `.target(name:)` deeper in is a dependency.
        let found = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let utf16 = Array(text.utf16)
        func depth(at offset: Int) -> Int {
            var depth = 0, quoted = false
            for unit in utf16[..<offset] {
                switch unit {
                case 0x22: quoted.toggle()
                case 0x28, 0x5B where !quoted: depth += 1
                case 0x29, 0x5D where !quoted: depth -= 1
                default: break
                }
            }
            return depth
        }
        let depths = found.map { depth(at: $0.range.location) }
        let outer = depths.min() ?? 0
        let starts = zip(found, depths).filter { $0.1 == outer }.map(\.0)
        return starts.enumerated().compactMap { index, match in
            guard let start = Range(match.range, in: text), let kindRange = Range(match.range(at: 1), in: text)
            else { return nil }
            let end = index + 1 < starts.count ? Range(starts[index + 1].range, in: text)?.lowerBound ?? text
                .endIndex : text.endIndex
            let body = String(text[start.upperBound ..< end])
            guard let name = first(#"name:\s*"([^"]+)""#, in: body) else { return nil }
            let kind: Kind = switch text[kindRange] {
            case "executableTarget": .app
            case "testTarget": .test
            default: .library
            }
            let dependencies = first(#"dependencies:\s*\[([^\]]*)\]"#, in: body).map {
                all(#"(?:^|[\[,\s])"([^"]+)""#, in: $0) + all(#"\.target\(\s*name:\s*"([^"]+)""#, in: $0)
            } ?? []
            let path = first(#"path:\s*"([^"]+)""#, in: body) ?? (kind == .test ? "Tests/" : "Sources/") + name
            let folder = root.isEmpty ? path : root + "/" + path
            return Project(
                name: name,
                file: file,
                folder: folder,
                kind: kind,
                language: "Swift",
                references: dependencies
            )
        }
    }

    private static func manifest(_ file: String, _ text: String, _ language: String) -> [Project] {
        guard let name = first(#"(?m)^name\s*=\s*"([^"]+)""#, in: text) else { return [] }
        let folder = folder(of: file)
        let app = language == "Rust" && (text.contains("[[bin]]") || text.contains("src/main.rs"))
        return [Project(name: name, file: file, folder: folder, kind: app ? .app : .library, language: language)]
    }

    private static func node(_ file: String, _ text: String) -> [Project] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String
        else { return [] }
        let language = text.contains("typescript") ? "TypeScript" : "JavaScript"
        return [Project(
            name: name,
            file: file,
            folder: folder(of: file),
            kind: json["bin"] != nil ? .app : .library,
            language: language
        )]
    }

    // MARK: Entry points

    private static func entryPoint(_ file: String, _ text: String, language _: String) -> Place? {
        let name = (file as NSString).lastPathComponent
        let checks: [(String, String)] = switch (file as NSString).pathExtension {
        case "cs": [
                (#"static\s+(?:async\s+)?(?:void|int|Task(?:<int>)?)\s+Main\s*\("#, "Main"),
                (#"WebApplication\.Create(?:Slim)?Builder"#, "web host"),
                (#"\.Map(?:Get|Post|Put|Patch|Delete|Group)\s*\("#, "HTTP endpoints"),
                (#"\[ApiController\]"#, "HTTP endpoints"),
            ]
        case "fs": [(#"\[<EntryPoint>\]"#, "main")]
        case "swift": [(#"(?m)^@main\b"#, "@main")]
        case "rs": [(#"(?m)^\s*(?:pub\s+)?(?:async\s+)?fn\s+main\s*\("#, "main")]
        case "go": [(#"(?m)^func\s+main\s*\("#, "main")]
        case "py": [(#"if\s+__name__\s*==\s*['"]__main__['"]"#, "__main__")]
        default: []
        }
        for (pattern, label) in checks {
            if let line = lineOf(pattern, in: text) { return Place(path: file, line: line, label: label) }
        }
        // A file that is only statements: C#'s Program.cs, Swift's main.swift.
        if name == "Program.cs" { return Place(path: file, line: 1, label: "top-level statements") }
        if name == "main.swift" { return Place(path: file, line: 1, label: "main.swift") }
        return nil
    }

    private static func lineOf(_ pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        return text[..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    // MARK: Reading it

    /// The projects in rows, what is built on at the bottom: each project above everything it references. Tests are
    /// in a row of their own, last: they reference nearly everything and say least about how the code is built.
    public var layers: [[Int]] {
        let byName = Dictionary(projects.enumerated().map { ($1.name, $0) }) { first, _ in first }
        var depth: [Int: Int] = [:]
        func depthOf(_ index: Int, _ seen: Set<Int>) -> Int {
            if let known = depth[index] { return known }
            // A cycle (which builds would refuse) stops here.
            let below = projects[index].references.compactMap { byName[$0] }.filter { !seen.contains($0) }
            let value = below.map { depthOf($0, seen.union([index])) + 1 }.max() ?? 0
            depth[index] = value
            return value
        }
        let built = projects.indices.filter { projects[$0].kind != .test }
        for index in built {
            _ = depthOf(index, [])
        }
        let top = built.map { depth[$0] ?? 0 }.max() ?? 0
        var rows: [[Int]] = (0 ... top).reversed().map { level in built.filter { depth[$0] == level } }
        let tests = projects.indices.filter { projects[$0].kind == .test }
        if !tests.isEmpty { rows.append(tests) }
        return rows.filter { !$0.isEmpty }
    }

    /// The map as text, for an agent: the projects from the top row down, with what each references, where it starts
    /// and its hot files.
    public var text: String {
        let files = projects.reduce(otherFiles) { $0 + $1.files }
        var out = ["Code map of \(name): " + Self.count(projects.count, "project") + ", " + Self.count(files, "file") +
            ". Top down: each builds on those below; tests last."]
        for row in layers {
            for index in row {
                let project = projects[index]
                var line = "- \(project.name) [\(project.kind.rawValue), \(project.language)] \(project.file): " +
                    Self.count(project.files, "file") + ", " + Self.count(project.lines, "line")
                if !project.references.isEmpty { line += "; references " + project.references.joined(separator: ", ") }
                out.append(line)
                for place in project.entryPoints.prefix(5) {
                    out.append("  starts: \(place.path):\(place.line) (\(place.label))")
                }
                if !project.hot.isEmpty {
                    out.append("  changes most: " + project.hot.map { "\($0.path) (\($0.changes))" }
                        .joined(separator: ", "))
                }
            }
        }
        if otherFiles >
            0 { out.append(otherFiles == 1 ? "1 file is in no project." : "\(otherFiles) files are in no project.") }
        return out.joined(separator: "\n")
    }

    public static func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)" + (number == 1 ? "" : "s") }
}
