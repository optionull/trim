import AppKit
import MessagePack
import SillCore
import SillEditor
import SillNvim

/// The packages pane's actions (board 3, M9): updates written into the files that say the version (the open buffers
/// read again), the solution read again after; an agent asked to update one and run the tests.
@MainActor
final class Packages {
    private weak var app: AppDelegate?
    private let channel: NvimChannel
    let scanner: PackageScanner
    private var asked = 0
    /// What the last update wrote, for the self-check.
    private(set) var written: [String] = []

    init(app: AppDelegate, channel: NvimChannel, directory: String) {
        self.app = app
        self.channel = channel
        scanner = PackageScanner(directory: directory)
        scanner.onChange = { [weak self] in
            guard let view = self?.app?.tools.packages else { return }
            if self?.scanner.scanning == false { view.scanned() }
            view.needsDisplay = true
        }
    }

    func makeView() -> PackagesView {
        let view = PackagesView(scanner: scanner)
        view.onUpdate = { [weak self] package, version in self?.update([(package, version)]) }
        view.onUpdateSafe = { [weak self] packages in
            self?.update(packages.compactMap { package in package.safeUpdate.map { (package, $0) } })
        }
        view.onAskAgent = { [weak self] package in self?.ask(package) }
        view.onOpen = { [weak self] path in
            guard let self else { return }
            Nvim.lua(channel, "require'sill'.open_beside(...)", [.string(path)])
        }
        if scanner.report == nil { scanner.scan() }
        return view
    }

    /// `:SillPackages` asked again: read again if nothing is shown yet.
    func update(_ screen: Screen) {
        guard screen.packagesAsks > asked else { return }
        asked = screen.packagesAsks
        if scanner.report == nil, !scanner.scanning, app?.tools.packages != nil { scanner.scan() }
    }

    /// Each package moved to its version in every project that has it, then the solution read again.
    func update(_ moves: [(PackageReport.Package, String)]) {
        var files: [String] = []
        for (package, version) in moves {
            for project in package.projectPaths {
                guard let changes = PackageEdit.update(package.id, to: version, in: project) else { continue }
                for change in changes {
                    do {
                        try change.text.write(toFile: change.path, atomically: true, encoding: .utf8)
                        if !files.contains(change.path) { files.append(change.path) }
                    } catch {
                        say("Could not write \(change.path): \(error)", warn: true)
                    }
                }
            }
        }
        written = files
        guard !files.isEmpty else { return say("Nothing to change: the version is said nowhere sill can edit.") }
        Nvim.lua(channel, "vim.cmd('silent! checktime')")
        say("Updated \(moves.count) package\(moves.count == 1 ? "" : "s") in " +
            files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") + "; reading the packages again.")
        scanner.scan()
    }

    private func ask(_ package: PackageReport.Package) {
        let version = app?.tools.packages?.update(for: package) ?? package.latest ?? "its newest version"
        let reasons = package.vulnerabilities.map { "\($0.severity) \($0.advisory)" } +
            (package.alternative.map { ["deprecated: use \($0)"] } ?? []) +
            (package.change.map { ["a \($0.rawValue) update"] } ?? [])
        let shortName = package.id.replacingOccurrences(of: ".", with: " ")
        app?.agents.send(
            headline: "Update \(shortName) to \(version)",
            "Update the NuGet package \(package.id) from \(package.installed) to \(version) in " +
                package.projects
                .joined(separator: ", ") + (reasons.isEmpty ? "" : " (\(reasons.joined(separator: "; ")))") +
                ". Change the version where it is set (Directory.Packages.props when central package management is on), " +
                "fix what the update breaks, build with sill's build tool and run the tests."
        )
    }

    private func say(_ text: String, warn: Bool = false) {
        Nvim.lua(channel, "vim.notify(...)", [.string(text), .int(warn ? 3 : 2)])
    }
}
