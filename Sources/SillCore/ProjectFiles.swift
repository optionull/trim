import Foundation

/// What a .NET project file says about the files around it, read lightly (its XML, no MSBuild): what kind of project it
/// is, which files it removes from its items, and which it nests under another (`DependentUpon`).
public struct ProjectFile: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case app, web, test, library
    }

    /// Its folder.
    public var directory: String
    public var name: String
    public var kind: Kind
    /// Glob patterns, relative to the project's folder, its items remove (`<Compile Remove="..."/>`).
    public var removed: [String]
    /// A file (relative to the project's folder) and the file it is nested under, in the same folder.
    public var dependentUpon: [String: String]

    public init(path: String, text: String) {
        directory = (path as NSString).deletingLastPathComponent
        name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let lower = text.lowercased()
        if text.contains("Microsoft.NET.Test.Sdk") || lower.contains("<istestproject>true") {
            kind = .test
        } else if text.contains("Microsoft.NET.Sdk.Web") || text.contains("Microsoft.NET.Sdk.BlazorWebAssembly") {
            kind = .web
        } else if DotnetProjects.isRunnable(text) {
            kind = .app
        } else {
            kind = .library
        }
        removed = Self.attributes("Remove", in: text).flatMap { $0.split(separator: ";").map {
            String($0).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
        } }
        var nested: [String: String] = [:]
        for (item, parent) in Self.dependents(in: text) {
            let item = item.replacingOccurrences(of: "\\", with: "/")
            nested[item] = (parent.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        }
        dependentUpon = nested
    }

    /// Whether the project's items leave out the file (a path under the project's folder).
    public func removes(_ path: String) -> Bool {
        guard path.hasPrefix(directory + "/") else { return false }
        let relative = String(path.dropFirst(directory.count + 1))
        return removed.contains { Glob.matches($0, relative) }
    }

    /// Every value of an attribute, from the elements that carry it.
    static func attributes(_ name: String, in text: String) -> [String] {
        let pattern = "\\s\(name)\\s*=\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Items with a DependentUpon, as an attribute or a child element: (the item, its parent).
    static func dependents(in text: String) -> [(String, String)] {
        let pattern =
            "<\\w+\\s+(?:Include|Update)\\s*=\\s*\"([^\"]+)\"(?:[^>]*?DependentUpon\\s*=\\s*\"([^\"]+)\"[^>]*?/?>" +
            "|[^>]*?>\\s*(?:<[^>]+>[^<]*</[^>]+>\\s*)*?<DependentUpon>([^<]+)</DependentUpon>)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let item = Range(match.range(at: 1), in: text) else { return nil }
            let parent = Range(match.range(at: 2), in: text) ?? Range(match.range(at: 3), in: text)
            return parent.map { (String(text[item]), String(text[$0]).trimmingCharacters(in: .whitespaces)) }
        }
    }
}

/// MSBuild's globs: `**` any folders, `*` within a name, `?` one character.
public enum Glob {
    public static func matches(_ pattern: String, _ path: String) -> Bool {
        var regex = "^"
        var characters = Array(pattern)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*", index + 1 < characters.count, characters[index + 1] == "*" {
                // `**/` matches any folders, none included.
                if index + 2 < characters.count, characters[index + 2] == "/" {
                    regex += "(?:.*/)?"
                    index += 3
                } else {
                    regex += ".*"
                    index += 2
                }
                continue
            }
            switch character {
            case "*": regex += "[^/]*"
            case "?": regex += "[^/]"
            default: regex += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        characters = []
        regex += "$"
        return path.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// File nesting, as Visual Studio and Rider show it: a file under the file it belongs to, in the same folder.
public enum FileNesting {
    /// The parent of each nested file among `names` (one folder's files): its project's `DependentUpon` first, then
    /// `X.razor.cs` under `X.razor` (any file with an extension added to another), `appsettings.Development.json` under
    /// `appsettings.json` (a configuration's own file), `X.Designer.cs` and `X.g.cs` under `X.cs`, `X.min.js` under
    /// `X.js`, `package-lock.json` under `package.json`.
    public static func parents(of names: [String], explicit: [String: String] = [:]) -> [String: String] {
        let present = Set(names)
        var parents: [String: String] = [:]
        for name in names {
            if let parent = explicit[name], present.contains(parent), parent != name {
                parents[name] = parent
                continue
            }
            if let parent = rule(name), present.contains(parent) { parents[name] = parent }
        }
        // A file never nests under one nested under it.
        for (child, parent) in parents where parents[parent] == child {
            parents[child] = nil
        }
        return parents
    }

    /// The file `name` nests under by the rules alone, if it would be there.
    public static func rule(_ name: String) -> String? {
        if name == "package-lock.json" { return "package.json" }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, !parts[0].isEmpty else {
            return nil
        }
        let ext = parts.last!.lowercased()
        let segment = parts[parts.count - 2]
        let lowerSegment = segment.lowercased()
        // X.razor.cs, X.cshtml.css, X.xaml.cs, X.js.map: an extension added to a file's own.
        let added = parts.dropLast().joined(separator: ".")
        let codeBehind = ["cs", "css", "js", "ts", "scss", "map", "vb", "fs"]
        if codeBehind.contains(ext), ["razor", "cshtml", "xaml", "axaml", "js", "css", "ts", "aspx", "master"]
            .contains(lowerSegment)
        {
            return added
        }
        // Without the second-to-last segment: appsettings.Development.json, X.Designer.cs, X.min.js.
        let without = (parts.dropLast(2) + [parts.last!]).joined(separator: ".")
        switch ext {
        case "json", "config", "yml", "yaml": return parts[0].lowercased().hasPrefix("appsettings") ||
            ["web", "app"].contains(parts[0].lowercased()) ? without : nil
        case "cs", "vb": return ["designer", "g", "generated"].contains(lowerSegment) ? without : nil
        case "js", "css": return lowerSegment == "min" ? without : nil
        default: return nil
        }
    }
}
