import Darwin
import Foundation

/// A path with its links followed, as nvim and git report paths. Foundation's `resolvingSymlinksInPath` is not that: it
/// turns `/private/var` back into `/var`, so a folder under /tmp or /var would never match the paths nvim gives.
public enum RealPath {
    public static func of(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
