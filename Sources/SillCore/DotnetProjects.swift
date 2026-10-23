import Foundation

/// The .NET programs in a folder that can be run, and so profiled: project files with an executable output (an
/// `OutputType` of Exe or WinExe, or a web project), not test projects. Build output and dependencies are skipped.
public enum DotnetProjects {
    static let skipped: Set<String> = ["bin", "obj", ".git", "node_modules", ".vs", ".idea", "build"]

    public static func runnable(in folder: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: folder) else { return [] }
        var found: [String] = []
        while let relative = walker.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            if skipped.contains(name) || walker.level > 4 {
                walker.skipDescendants()
                continue
            }
            guard name.hasSuffix(".csproj") || name.hasSuffix(".fsproj") else { continue }
            let path = (folder as NSString).appendingPathComponent(relative)
            if let text = try? String(contentsOfFile: path, encoding: .utf8), isRunnable(text) { found.append(path) }
        }
        // The shallowest first, then by path.
        return found.sorted {
            ($0.components(separatedBy: "/").count, $0) < ($1.components(separatedBy: "/").count, $1)
        }
    }

    /// The project to profile: the runnable one containing `file` if there is one, else the first.
    public static func pick(in folder: String, near file: String = "") -> String? {
        let all = runnable(in: folder)
        return all.first { file.hasPrefix(($0 as NSString).deletingLastPathComponent + "/") } ?? all.first
    }

    static func isRunnable(_ project: String) -> Bool {
        if project.contains("Microsoft.NET.Test.Sdk") || project.contains("<IsTestProject>true") { return false }
        if project.contains("Microsoft.NET.Sdk.Web") || project.contains("Microsoft.NET.Sdk.Worker") { return true }
        return project.range(of: "<OutputType>\\s*(Exe|WinExe)\\s*</OutputType>", options: [
            .regularExpression,
            .caseInsensitive,
        ]) != nil
    }
}
