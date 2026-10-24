import Foundation

/// The packages of a .NET solution or project (board 3, M9), as the SDK reports them (`dotnet list package --format
/// json`, with --vulnerable, --outdated, --outdated --highest-patch and --deprecated, transitive ones included): each
/// package once, with the projects that have it, what is installed, what is newest, its advisories and whether it is
/// deprecated.
public struct PackageReport: Equatable, Sendable {
    public struct Vulnerability: Equatable, Sendable {
        public var severity: String
        public var advisory: String

        /// The advisory's id: `GHSA-5crp-9r3c-p9vr`.
        public var id: String { advisory.split(separator: "/").last.map(String.init) ?? advisory }

        public init(severity: String, advisory: String) {
            self.severity = severity
            self.advisory = advisory
        }
    }

    public enum Change: String, Sendable, Comparable {
        case patch, minor, major

        public static func < (lhs: Change, rhs: Change) -> Bool {
            [Change.patch, .minor, .major].firstIndex(of: lhs)! < [Change.patch, .minor, .major].firstIndex(of: rhs)!
        }
    }

    public struct Package: Equatable, Sendable {
        public var id: String
        /// Only through other packages, in every project that has it.
        public var transitive: Bool
        /// The projects that have it (their file names without extension).
        public var projects: [String]
        /// Their project files.
        public var projectPaths: [String]
        public var installed: String
        public var latest: String?
        /// The newest with the same major and minor version.
        public var highestPatch: String?
        public var vulnerabilities: [Vulnerability]
        public var deprecation: [String]?
        /// The package to use instead, when deprecated.
        public var alternative: String?

        public var change: Change? { latest.flatMap { Version.change(from: installed, to: $0) } }
        public var isVulnerable: Bool { !vulnerabilities.isEmpty }
        public var isOutdated: Bool { change != nil }
        public var isDeprecated: Bool { deprecation != nil }
        public var needsAttention: Bool { isVulnerable || isOutdated || isDeprecated }

        /// The worst advisory's severity: Critical, High, Moderate, Low.
        public var severity: String? {
            let order = ["critical", "high", "moderate", "low"]
            return vulnerabilities.map(\.severity).min {
                (order.firstIndex(of: $0.lowercased()) ?? 9) < (order.firstIndex(of: $1.lowercased()) ?? 9)
            }
        }

        /// Where a security or patch update goes: the newest patch when there is one, else (only vulnerable) the
        /// newest.
        public var safeUpdate: String? {
            if let highestPatch, Version.compare(highestPatch, installed) > 0 { return highestPatch }
            return nil
        }
    }

    public var packages: [Package]

    public init(packages: [Package]) {
        self.packages = packages
    }

    /// The report from the SDK's answers; any may be missing.
    public static func read(all: Data?, vulnerable: Data?, outdated: Data?, highestPatch: Data?, deprecated: Data?)
        -> PackageReport
    {
        var byID: [String: Package] = [:]
        var order: [String] = []
        func visit(_ data: Data?, _ apply: (inout Package, [String: Any]) -> Void) {
            guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            for project in (root["projects"] as? [[String: Any]]) ?? [] {
                let path = project["path"] as? String ?? ""
                let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                for framework in (project["frameworks"] as? [[String: Any]]) ?? [] {
                    for (key, transitive) in [("topLevelPackages", false), ("transitivePackages", true)] {
                        for entry in (framework[key] as? [[String: Any]]) ?? [] {
                            guard let id = entry["id"] as? String else { continue }
                            let installed = entry["resolvedVersion"] as? String ?? entry[
                                "requestedVersion"
                            ] as? String ??
                                "?"
                            var package = byID[id] ?? {
                                order.append(id)
                                return Package(
                                    id: id, transitive: transitive, projects: [], projectPaths: [],
                                    installed: installed,
                                    latest: nil, highestPatch: nil, vulnerabilities: [], deprecation: nil,
                                    alternative: nil
                                )
                            }()
                            if !transitive { package.transitive = false }
                            if !package.projects.contains(name) {
                                package.projects.append(name)
                                package.projectPaths.append(path)
                            }
                            // The oldest installed across projects is the one to report.
                            if Version.compare(installed, package.installed) < 0 { package.installed = installed }
                            apply(&package, entry)
                            byID[id] = package
                        }
                    }
                }
            }
        }
        visit(all) { _, _ in }
        visit(vulnerable) { package, entry in
            for item in (entry["vulnerabilities"] as? [[String: Any]]) ?? [] {
                let vulnerability = Vulnerability(
                    severity: item["severity"] as? String ?? "?", advisory: item["advisoryurl"] as? String ?? ""
                )
                if !package.vulnerabilities.contains(vulnerability) { package.vulnerabilities.append(vulnerability) }
            }
        }
        visit(outdated) { package, entry in
            if let latest = entry["latestVersion"] as? String, !latest.lowercased().contains("not found") {
                package.latest = latest
            }
        }
        visit(highestPatch) { package, entry in
            if let latest = entry["latestVersion"] as? String, !latest.lowercased().contains("not found") {
                package.highestPatch = latest
            }
        }
        visit(deprecated) { package, entry in
            package.deprecation = (entry["deprecationReasons"] as? [String]) ?? ["deprecated"]
            package.alternative = (entry["alternativePackage"] as? [String: Any])?["id"] as? String
        }
        return PackageReport(packages: order.compactMap { byID[$0] })
    }

    /// The newest version and newest patch of each package, from the versions its feed lists (nuget.org's index): a
    /// stable install is compared with stable versions, a prerelease one with every version.
    public func with(versions: [String: [String]]) -> PackageReport {
        var copy = self
        for index in copy.packages.indices {
            let package = copy.packages[index]
            guard let listed = versions[package.id.lowercased()], !listed.isEmpty else { continue }
            let prerelease = package.installed.contains("-")
            let candidates = listed.filter { prerelease || !$0.contains("-") }
            let newest = candidates.max { Version.compare($0, $1) < 0 }
            copy.packages[index].latest = newest.flatMap { Version.compare($0, package.installed) > 0 ? $0 : nil }
            let (installed, _) = Version.parts(package.installed)
            let sameMinor = candidates.filter { version in
                let (numbers, _) = Version.parts(version)
                return numbers.prefix(2) == installed.prefix(2)
            }
            copy.packages[index].highestPatch = sameMinor.max { Version.compare($0, $1) < 0 }
                .flatMap { Version.compare($0, package.installed) > 0 ? $0 : nil }
        }
        return copy
    }

    /// What the SDK could not read (a project not restored), as it said it.
    public static func problems(in data: Data?) -> [String] {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return ((root["problems"] as? [[String: Any]]) ?? []).compactMap { problem in
            let project = (problem["project"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
            return (problem["text"] as? String).map { project.isEmpty ? $0 : "\(project): \($0)" }
        }
    }

    public var vulnerable: [Package] { packages.filter(\.isVulnerable) }
    public var outdated: [Package] { packages.filter(\.isOutdated) }
    public var deprecated: [Package] { packages.filter(\.isDeprecated) }
    public var upToDate: [Package] { packages.filter { !$0.needsAttention } }

    /// What needs attention, worst first: vulnerable (by severity), deprecated, then outdated (major first).
    public var attention: [Package] {
        let order = ["critical", "high", "moderate", "low"]
        func rank(_ package: Package) -> (Int, Int, String) {
            if let severity = package.severity {
                return (0, order.firstIndex(of: severity.lowercased()) ?? 9, package.id)
            }
            if package.isDeprecated { return (1, 0, package.id) }
            let change = package.change.map { [Change.major, .minor, .patch].firstIndex(of: $0)! } ?? 9
            return (2, change, package.id)
        }
        // Each package ranked once, not on every comparison.
        return packages.filter(\.needsAttention).map { (rank($0), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

/// NuGet's versions, compared as numbers part by part (a prerelease before its release).
public enum Version {
    static func parts(_ version: String) -> (numbers: [Int], prerelease: String) {
        let split = version.split(separator: "-", maxSplits: 1)
        let numbers = (split.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        return (numbers, split.count > 1 ? String(split[1]) : "")
    }

    public static func compare(_ lhs: String, _ rhs: String) -> Int {
        let (left, leftPre) = parts(lhs), (right, rightPre) = parts(rhs)
        for index in 0 ..< max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0, b = index < right.count ? right[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        if leftPre == rightPre { return 0 }
        if leftPre.isEmpty { return 1 }
        if rightPre.isEmpty { return -1 }
        return leftPre < rightPre ? -1 : 1
    }

    /// What kind of change going from one to the other is; nil when it is no newer.
    public static func change(from installed: String, to latest: String) -> PackageReport.Change? {
        guard compare(latest, installed) > 0 else { return nil }
        let (a, _) = parts(installed), (b, _) = parts(latest)
        if (a.first ?? 0) != (b.first ?? 0) { return .major }
        if (a.count > 1 ? a[1] : 0) != (b.count > 1 ? b[1] : 0) { return .minor }
        return .patch
    }
}

/// How a package came to be in a project, from its restore (`obj/project.assets.json`): the shortest chain from one of
/// the project's own packages.
public enum PackageGraph {
    public static func path(to id: String, assets: Data) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: assets) as? [String: Any],
              let targets = root["targets"] as? [String: Any],
              let frameworks = (root["project"] as? [String: Any])?["frameworks"] as? [String: Any] else { return nil }
        for (framework, packages) in targets {
            guard let packages = packages as? [String: Any] else { continue }
            // Package id (any case) to the ids it depends on.
            var graph: [String: [String]] = [:]
            for (key, value) in packages {
                let name = String(key.split(separator: "/").first ?? "")
                graph[name.lowercased()] = ((value as? [String: Any])?["dependencies"] as? [String: Any])?.keys
                    .map { $0 }
                    ?? []
            }
            let frameworkName = framework.split(separator: "/").first.map(String.init) ?? framework
            let top = ((frameworks[frameworkName] as? [String: Any] ?? frameworks.values.first as? [String: Any])?[
                "dependencies"
            ] as? [String: Any])?.keys.map { $0 } ?? []
            var queue: [[String]] = top.sorted().map { [$0] }
            var seen = Set(top.map { $0.lowercased() })
            while !queue.isEmpty {
                let chain = queue.removeFirst()
                if chain.last?.lowercased() == id.lowercased() { return chain }
                for next in (graph[chain.last!.lowercased()] ?? []).sorted() where !seen.contains(next.lowercased()) {
                    seen.insert(next.lowercased())
                    queue.append(chain + [next])
                }
            }
        }
        return nil
    }
}

/// Moving a package to a version by editing the files that say it, as written: under central package management the
/// `PackageVersion` in Directory.Packages.props, else the project's `PackageReference`; a transitive package gets a
/// reference of its own in the project, which pins it.
public enum PackageEdit {
    public struct Change: Equatable, Sendable {
        public var path: String
        public var text: String
    }

    /// The nearest Directory.Packages.props above a project, if central package management is on there.
    public static func centralFile(for project: String) -> String? {
        var folder = (project as NSString).deletingLastPathComponent
        while !folder.isEmpty, folder != "/" {
            let candidate = (folder as NSString).appendingPathComponent("Directory.Packages.props")
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// The edits that move `id` to `version` in `project`; nil when it is said nowhere it could be changed.
    public static func update(_ id: String, to version: String, in project: String) -> [Change]? {
        let central = centralFile(for: project)
        if let central, let text = try? String(contentsOfFile: central, encoding: .utf8),
           let changed = replacingVersion(of: id, element: "PackageVersion", in: text, with: version)
        {
            return [Change(path: central, text: changed)]
        }
        guard let text = try? String(contentsOfFile: project, encoding: .utf8) else { return nil }
        if let changed = replacingVersion(of: id, element: "PackageReference", in: text, with: version) {
            return [Change(path: project, text: changed)]
        }
        // Not referenced here: a reference of its own pins it (with its version in the central file when there is one).
        if let central, let centralText = try? String(contentsOfFile: central, encoding: .utf8),
           let withVersion = adding("    <PackageVersion Include=\"\(id)\" Version=\"\(version)\" />", to: centralText),
           let withReference = adding("    <PackageReference Include=\"\(id)\" />", to: text)
        {
            return [Change(path: central, text: withVersion), Change(path: project, text: withReference)]
        }
        return adding("    <PackageReference Include=\"\(id)\" Version=\"\(version)\" />", to: text)
            .map { [Change(path: project, text: $0)] }
    }

    /// The element for `id` with its Version (an attribute, or a child element) set to `version`.
    static func replacingVersion(of id: String, element: String, in text: String, with version: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: id)
        let attribute = "(<\(element)\\b[^>]*\\b(?:Include|Update)\\s*=\\s*\"\(escaped)\"[^>]*\\bVersion\\s*=\\s*\")[^\"]*(\")"
        if let regex = try? NSRegularExpression(pattern: attribute, options: [.caseInsensitive]),
           regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        {
            return regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text),
                withTemplate: "$1\(NSRegularExpression.escapedTemplate(for: version))$2"
            )
        }
        let before = "(<\(element)\\b[^>]*\\bVersion\\s*=\\s*\")[^\"]*(\"[^>]*\\b(?:Include|Update)\\s*=\\s*\"\(escaped)\")"
        if let regex = try? NSRegularExpression(pattern: before, options: [.caseInsensitive]),
           regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        {
            return regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text),
                withTemplate: "$1\(NSRegularExpression.escapedTemplate(for: version))$2"
            )
        }
        let child = "(<\(element)\\b[^>]*\\b(?:Include|Update)\\s*=\\s*\"\(escaped)\"[^>]*>\\s*<Version>)[^<]*(</Version>)"
        if let regex = try? NSRegularExpression(pattern: child, options: [.caseInsensitive]),
           regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        {
            return regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text),
                withTemplate: "$1\(NSRegularExpression.escapedTemplate(for: version))$2"
            )
        }
        return nil
    }

    /// The line added to the first ItemGroup with package lines (or a new one before `</Project>`).
    static func adding(_ line: String, to text: String) -> String? {
        if let range = text.range(
            of: "<ItemGroup>[^<]*<(PackageReference|PackageVersion)",
            options: .regularExpression
        ),
            let end = text.range(of: "</ItemGroup>", range: range.lowerBound ..< text.endIndex)
        {
            var copy = text
            copy.insert(contentsOf: line + "\n  ", at: end.lowerBound)
            return copy
        }
        guard let end = text.range(of: "</Project>", options: .backwards) else { return nil }
        var copy = text
        copy.insert(contentsOf: "  <ItemGroup>\n\(line)\n  </ItemGroup>\n", at: end.lowerBound)
        return copy
    }
}
