import Foundation

/// Mermaider as a native library (`mermaider.dylib`, see its `mermaider.h`), loaded with `dlopen` so Trim runs without
/// it:
/// `init` is nil when the library is not there or is not an interface version this knows.
public final class MermaidLibrary: @unchecked Sendable {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// The version of the C interface this speaks.
    public static let abiVersion: Int32 = 1

    private let handle: UnsafeMutableRawPointer
    private let renderFunction: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?)
        -> UnsafeMutablePointer<CChar>?
    private let lastErrorFunction: @convention(c) () -> UnsafePointer<CChar>?
    private let freeFunction: @convention(c) (UnsafeMutableRawPointer?) -> Void
    /// The library keeps one reason per thread; calls from several threads of ours are serialised so each reads its
    /// own.
    private let lock = NSLock()

    public init?(path: String) {
        guard let handle = dlopen(path, RTLD_NOW),
              let version = dlsym(handle, "mermaider_abi_version"),
              let render = dlsym(handle, "mermaider_render_svg"),
              let lastError = dlsym(handle, "mermaider_last_error"),
              let free = dlsym(handle, "mermaider_free")
        else { return nil }
        let abi = unsafeBitCast(version, to: (@convention(c) () -> Int32).self)()
        guard abi == Self.abiVersion else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        renderFunction = unsafeBitCast(
            render,
            to: (@convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?).self
        )
        lastErrorFunction = unsafeBitCast(lastError, to: (@convention(c) () -> UnsafePointer<CChar>?).self)
        freeFunction = unsafeBitCast(free, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
    }

    /// Where the library is looked for: next to the app's frameworks, then `Vendor/Mermaider` in a source tree.
    public static func locate(bundle: Bundle = .main) -> MermaidLibrary? {
        var candidates: [String] = []
        if let frameworks = bundle.privateFrameworksPath { candidates.append(frameworks + "/mermaider.dylib") }
        if let override = ProcessInfo.processInfo
            .environment["TRIM_MERMAIDER_LIB"] { candidates.insert(override, at: 0) }
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Vendor/Mermaider/mermaider.dylib").path)
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let library = MermaidLibrary(path: path) { return library }
        }
        return nil
    }

    /// The SVG for Mermaid `source`; `options` are the library's (a theme name, `bg`, `fg`, `accent`, `style`...).
    public func renderSVG(_ source: String, options: [String: Any] = [:]) throws -> String {
        let json = try options.isEmpty ? nil : String(
            data: JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]), encoding: .utf8
        )
        lock.lock()
        defer { lock.unlock() }
        let svg: UnsafeMutablePointer<CChar>? = source.withCString { text in
            if let json { return json.withCString { renderFunction(text, $0) } }
            return renderFunction(text, nil)
        }
        guard let svg else {
            throw Failure(description: lastErrorFunction().map { String(cString: $0) } ?? "the library gave no reason")
        }
        defer { freeFunction(svg) }
        return String(cString: svg)
    }
}
