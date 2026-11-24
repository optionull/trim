import Foundation

extension Walkthrough {
    /// The source with each `@code` anchor that has no fingerprint given the one of the code it points at now, and the
    /// front matter given the commit and the date when it has none: what a later reading compares against to say that
    /// code moved. An anchor that cannot be found is left as it is (the check names it). Authors never compute hashes.
    public static func stamping(_ source: String, resolver: AnchorResolver, commit: String?, date: String) -> String {
        let walk = Walkthrough(source)
        var lines = source.components(separatedBy: "\n")
        for step in walk.steps {
            for case let .code(anchor, line) in step.blocks where walk.fingerprints[line] == nil {
                guard case let .found(found) = resolver.resolve(anchor), line >= 1,
                      line <= lines.count else { continue }
                lines[line - 1] = lines[line - 1].trimmingCharacters(in: .whitespaces) + " #" + fingerprint(found.text)
            }
        }
        return settingFront(lines, ["commit": commit, "created": date]).joined(separator: "\n")
    }

    /// `lines` with each given key set in the front matter when it is not (the front matter made when there is none).
    static func settingFront(_ lines: [String], _ values: [String: String?]) -> [String] {
        var lines = lines
        let order = ["created", "commit"]
        func has(_ key: String, _ range: Range<Int>) -> Bool {
            lines[range].contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + ":") }
        }
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        {
            var insert = end
            for key in order {
                if let value = values[key] ?? nil, !has(key, 1 ..< insert) {
                    lines.insert("\(key): \(value)", at: insert)
                    insert += 1
                }
            }
            return lines
        }
        var front = ["---"]
        for key in order {
            if let value = values[key] ?? nil { front.append("\(key): \(value)") }
        }
        front.append("---")
        return front + lines
    }
}
