// swift-tools-version: 6.4
import Foundation
import PackageDescription

// GhosttyKit is built locally (`mise run ghostty`, needs Xcode + the Metal toolchain). Until it exists the app builds
// with a stand-in for each terminal pane, so everything else can be worked on without it.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasGhostty = FileManager.default.fileExists(atPath: "\(root)/Vendor/GhosttyKit.xcframework/Info.plist")

let messagePack = Target.Dependency.product(name: "MessagePack", package: "MessagePack.swift")

var targets: [Target] = [
    // nvim over msgpack-RPC: the process, the transport and the redraw events. Lifted from Veil (MIT).
    .target(name: "SillNvim", dependencies: [messagePack]),
    // What the UI draws, built from redraw events: grids, their placement, and which windows are terminal panes.
    .target(name: "SillCore", dependencies: ["SillNvim", "SillInput", messagePack]),
    .testTarget(name: "SillCoreTests", dependencies: ["SillCore", "SillNvim", messagePack], exclude: ["Fixtures"]),
    // AppKit input in nvim's terms: key notation, mouse and IME.
    .target(name: "SillInput"),
    .testTarget(name: "SillInputTests", dependencies: ["SillInput"]),
    // The .NET sidecar: started on the user's own dotnet, JSON lines over its standard input and output.
    .target(name: "SillSidecar", dependencies: ["SillNvim", "SillCore"]),
    // Fixtures: a .NET sample the profiler tests run.
    .testTarget(name: "SillSidecarTests", dependencies: ["SillSidecar"], exclude: ["Fixtures"]),
    // The agent bridge: sill's MCP server on a Unix socket.
    .target(name: "SillAgent"),
    // The editor surface any nvim front end of sill's makes: the Metal grid and its input, nvim's command line,
    // completion and messages as native views, the design's tokens and the grid's font. sill and the shim use it.
    .target(name: "SillEditor", dependencies: ["SillCore", "SillNvim", "SillRender", "SillInput", messagePack]),
    .testTarget(name: "SillAgentTests", dependencies: ["SillAgent"]),
    // The Metal grid: glyph atlas, instanced passes, and the render thread that draws screens.
    .target(
        name: "SillRender", dependencies: ["SillCore"],
        linkerSettings: [.linkedFramework("Metal"), .linkedFramework("QuartzCore"), .linkedFramework("CoreText")]
    ),
    .testTarget(name: "SillRenderTests", dependencies: ["SillRender", "SillCore", "SillNvim", messagePack]),
]
var appDependencies: [Target.Dependency] = [
    "SillEditor",
    "SillCore",
    "SillNvim",
    "SillRender",
    "SillInput",
    "SillSidecar",
    "SillAgent",
    messagePack,
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
    appDependencies.append("SillTerminal")
}

// The shim: nvim alone in a native window, with sill's editor surface and nothing else.
targets.append(.executableTarget(
    name: "Shim",
    dependencies: ["SillEditor", "SillCore", "SillNvim", "SillRender", "SillInput", messagePack]
))
// Frame's file tree: what a folder holds, in order, and what git says of it. Foundation only, so it is tested alone.
targets.append(.target(name: "FrameTree"))
targets.append(.testTarget(name: "FrameTreeTests", dependencies: ["FrameTree"]))
// Frame: Shim's host grown into a workspace of native panes around nvim (a working title). A copy of Shim that diverges.
// Frame's modes: which surface has the keyboard (the editor, the tree, the switcher), what the tree is doing, and what
// Escape does from each. Pure, so it is tested alone.
targets.append(.target(name: "FrameModes"))
targets.append(.testTarget(name: "FrameModesTests", dependencies: ["FrameModes"]))
// Frame's workspace switcher: the repositories and worktrees to go to, what heed calls the work in them, and how a
// query finds them. No UI, so it is tested alone.
targets.append(.target(name: "FrameWorkspaces", dependencies: ["SillCore", "SillAgent", "FrameTree"]))
targets.append(.testTarget(
    name: "FrameWorkspacesTests",
    dependencies: ["FrameWorkspaces", "FrameTree", "SillCore", "SillAgent"]
))
targets.append(.executableTarget(
    name: "Frame",
    dependencies: [
        "SillEditor", "SillCore", "SillNvim", "SillRender", "SillInput", "SillAgent", "FrameTree", "FrameWorkspaces",
        "FrameModes",
        messagePack,
    ]
))
targets.append(.executableTarget(
    name: "SillApp",
    dependencies: appDependencies,
    swiftSettings: hasGhostty ? [.define("SILL_GHOSTTY")] : []
))

let package = Package(
    name: "Sill",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SillApp", targets: ["SillApp"]),
        .executable(name: "Shim", targets: ["Shim"]),
        .executable(name: "Frame", targets: ["Frame"]),
    ],
    // The msgpack codec Veil's RPC layer is written against (MIT).
    dependencies: [.package(url: "https://github.com/qvacua/MessagePack.swift", exact: "4.1.0")],
    targets: targets
)
