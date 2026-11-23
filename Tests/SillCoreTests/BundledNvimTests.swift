import Foundation
import SillNvim
import Testing

/// The nvim an app carries as a fallback: its own, else the one in Trim.app beside it, else none.
@Suite("The nvim an app carries")
struct BundledNvimTests {
    private func app(_ name: String, in root: URL, nvim: Bool) throws -> URL {
        let resources = root.appendingPathComponent("\(name).app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        if nvim {
            let bin = resources.appendingPathComponent("nvim/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let file = bin.appendingPathComponent("nvim")
            try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return resources
    }

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-nvim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("an app uses its own nvim")
    func own() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let trim = try app("Trim", in: root, nvim: true)
        #expect(NvimProcess.bundledNvim(resources: trim) == trim.appendingPathComponent("nvim/bin/nvim").path)
    }

    @Test("Shim, without its own, uses the one in Trim.app beside it")
    func sibling() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let trim = try app("Trim", in: root, nvim: true)
        let shim = try app("Shim", in: root, nvim: false)
        #expect(NvimProcess.bundledNvim(resources: shim) == trim.appendingPathComponent("nvim/bin/nvim").path)
    }

    @Test("there is none when neither carries one")
    func none() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let shim = try app("Shim", in: root, nvim: false)
        #expect(NvimProcess.bundledNvim(resources: shim) == nil)
        #expect(NvimProcess.bundledNvim(resources: nil) == nil)
    }
}
