import Foundation

/// A path as the file system names it, symlinks resolved (/tmp is /private/tmp); the path itself when it is not there.
/// Foundation's own resolving maps /private/tmp back to /tmp, so this is realpath(3).
public func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

package extension String {
    /// nil when empty, else the string.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
