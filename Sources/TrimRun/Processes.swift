import Foundation

/// What `ps` says about processes, to attribute CPU and memory to a language server and what it started (Roslyn starts
/// build hosts). Read, not measured: the CPU is the share of a core since the process began, as `ps` gives it.
public struct ProcessRow: Equatable, Sendable {
    public var pid: Int32
    public var parent: Int32
    public var cpu: Double
    /// Resident memory in kilobytes.
    public var memoryKB: Int
    public var command: String
}

public enum Processes {
    /// The rows of `ps -axo pid=,ppid=,pcpu=,rss=,command=`.
    public static func parse(_ output: String) -> [ProcessRow] {
        output.split(separator: "\n").compactMap { line -> ProcessRow? in
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5, let pid = Int32(parts[0]), let parent = Int32(parts[1]),
                  let cpu = Double(parts[2]), let memory = Int(parts[3]) else { return nil }
            return ProcessRow(pid: pid, parent: parent, cpu: cpu, memoryKB: memory, command: String(parts[4]))
        }
    }

    /// Every process below `root` (children, and theirs), not `root` itself.
    public static func descendants(of root: Int32, in rows: [ProcessRow]) -> [ProcessRow] {
        var found: [ProcessRow] = []
        var frontier: Set<Int32> = [root]
        var seen: Set<Int32> = [root]
        while !frontier.isEmpty {
            let next = rows.filter { frontier.contains($0.parent) && !seen.contains($0.pid) }
            next.forEach { seen.insert($0.pid) }
            found += next
            frontier = Set(next.map(\.pid))
        }
        return found
    }

    /// What a server uses: the process that runs `program` (the first below `editor` whose command line has it) and
    /// everything it started; nil when it is not running.
    public static func usage(of program: String, below editor: Int32, in rows: [ProcessRow])
        -> (pid: Int32, cpu: Double, memoryKB: Int, processes: Int)?
    {
        let below = descendants(of: editor, in: rows)
        guard let main = below.first(where: { $0.command.contains(program) }) else { return nil }
        let all = [main] + descendants(of: main.pid, in: rows)
        return (main.pid, all.reduce(0) { $0 + $1.cpu }, all.reduce(0) { $0 + $1.memoryKB }, all.count)
    }

    /// 1536 KB as "1.5 MB", 420000 KB as "410 MB", 3 GB as "3.0 GB".
    public static func size(kilobytes: Int) -> String {
        let megabytes = Double(kilobytes) / 1024
        if megabytes >= 1024 { return String(format: "%.1f GB", megabytes / 1024) }
        return megabytes >= 100 ? String(format: "%.0f MB", megabytes) : String(format: "%.1f MB", megabytes)
    }
}
