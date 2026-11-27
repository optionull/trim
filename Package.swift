// swift-tools-version: 6.4
import Foundation
import PackageDescription

// GhosttyKit is built locally (`mise run ghostty`, needs Xcode + the Metal toolchain). Until it exists the app builds
// with a stand-in for each terminal pane, so everything else can be worked on without it.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasGhostty = FileManager.default.fileExists(atPath: "\(root)/Vendor/GhosttyKit.xcframework/Info.plist")

let messagePack = Target.Dependency.product(name: "MessagePack", package: "MessagePack.swift")

var targets: [Target] = [
    // Walkthroughs: the Markdown an agent writes to explain code, its anchors, staleness and where the files live. Foundation
    // only, so it is tested alone.
    .target(name: "TrimWalk"),
    .testTarget(name: "TrimWalkTests", dependencies: ["TrimWalk"]),
    // Mermaid diagrams: Mermaider's native library and a renderer for the SVG it makes (every diagram type of it).
    .target(name: "TrimDiagram"),
    .testTarget(name: "TrimDiagramTests", dependencies: ["TrimDiagram"], resources: [.copy("Fixtures")]),
    // `trim`: the command line tool agents use to write, check and open walkthroughs (installed as Helpers/trim in Trim.app).
    .executableTarget(name: "TrimCLI", dependencies: ["TrimWalk"]),
    // nvim over msgpack-RPC: the process, the transport and the redraw events. Lifted from Veil (MIT).
    .target(name: "SillNvim", dependencies: [messagePack]),
    // What the UI draws, built from redraw events: grids, their placement, and which windows are terminal panes.
    .target(name: "SillCore", dependencies: ["SillNvim", "SillInput", "TrimWalk", messagePack]),
    .testTarget(name: "SillCoreTests", dependencies: ["SillCore", "SillNvim", messagePack], exclude: ["Fixtures"]),
    // AppKit input in nvim's terms: key notation, mouse and IME.
    .target(name: "SillInput"),
    .testTarget(name: "SillInputTests", dependencies: ["SillInput"]),
    // The agent bridge: sill's MCP server on a Unix socket.
    .target(name: "SillAgent"),
    // The editor surface any nvim front end of sill's makes: the Metal grid and its input, nvim's command line,
    // completion and messages as native views, the design's tokens and the grid's font. sill and the shim use it.
    .target(name: "SillEditor", dependencies: ["SillCore", "SillNvim", "SillRender", "SillInput", messagePack]),
    .testTarget(name: "SillAgentTests", dependencies: ["SillAgent"]),
    // The Metal grid: glyph atlas, instanced passes, and the render thread that draws screens.
    .target(
        name: "SillRender", dependencies: ["SillCore", "TrimDiagram"],
        linkerSettings: [.linkedFramework("Metal"), .linkedFramework("QuartzCore"), .linkedFramework("CoreText")]
    ),
    .testTarget(name: "SillRenderTests", dependencies: ["SillRender", "SillCore", "SillNvim", messagePack]),
]
if hasGhostty {
    targets += [
        .binaryTarget(name: "GhosttyKit", path: "Vendor/GhosttyKit.xcframework"),
        .target(
            name: "SillTerminal",
            dependencies: ["GhosttyKit"],
            linkerSettings: [
                .linkedFramework("Carbon"), .linkedFramework("Metal"), .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"), .linkedLibrary("c++"),
            ]
        ),
    ]
}

// The shim: nvim alone in a native window, with sill's editor surface and nothing else.
targets.append(.executableTarget(
    name: "Shim",
    dependencies: ["SillEditor", "SillCore", "SillNvim", "SillRender", "SillInput", messagePack]
))
// Trim's file tree: what a folder holds, in order, and what git says of it. Foundation only, so it is tested alone.
targets.append(.target(name: "TrimTree"))
targets.append(.testTarget(name: "TrimTreeTests", dependencies: ["TrimTree"]))
// Trim: Shim's host grown into a workspace of native panes around nvim. A copy of Shim that diverges.
// Trim's modes: which surface has the keyboard (the editor, the tree, the switcher), what the tree is doing, and what
// Escape does from each. Pure, so it is tested alone.
targets.append(.target(name: "TrimModes"))
targets.append(.testTarget(name: "TrimModesTests", dependencies: ["TrimModes"]))
// Trim's workspace switcher: the repositories and worktrees to go to, what heed calls the work in them, and how a
// query finds them. No UI, so it is tested alone.
targets.append(.target(name: "TrimWorkspaces", dependencies: ["SillCore", "SillAgent", "TrimTree"]))
targets.append(.testTarget(
    name: "TrimWorkspacesTests",
    dependencies: ["TrimWorkspaces", "TrimTree", "SillCore", "SillAgent"]
))
// What Trim can run and build in its terminal pane: project files, Makefile, mise, npm, VS Code's tasks and launches.
targets.append(.target(name: "TrimRun", dependencies: ["SillCore"]))
targets.append(.testTarget(name: "TrimRunTests", dependencies: ["TrimRun"]))
targets.append(.executableTarget(
    name: "Trim",
    dependencies: [
        "SillEditor", "SillCore", "SillNvim", "SillRender", "SillInput", "SillAgent", "TrimTree", "TrimWorkspaces",
        "TrimModes", "TrimRun",
        messagePack,
    ] + (hasGhostty ? ["SillTerminal"] : []),
    swiftSettings: hasGhostty ? [.define("SILL_GHOSTTY")] : []
))

let package = Package(
    name: "Sill",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Shim", targets: ["Shim"]),
        .executable(name: "trim-cli", targets: ["TrimCLI"]),
        .executable(name: "Trim", targets: ["Trim"]),
    ],
    // The msgpack codec Veil's RPC layer is written against (MIT).
    dependencies: [.package(url: "https://github.com/qvacua/MessagePack.swift", exact: "4.1.0")],
    targets: targets
)
