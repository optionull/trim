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
    .target(name: "SillCore", dependencies: ["SillNvim", messagePack]),
    .testTarget(name: "SillCoreTests", dependencies: ["SillCore", "SillNvim", messagePack]),
    // The Metal grid: glyph atlas, instanced passes, and the render thread that draws screens.
    .target(
        name: "SillRender", dependencies: ["SillCore"],
        linkerSettings: [.linkedFramework("Metal"), .linkedFramework("QuartzCore"), .linkedFramework("CoreText")]
    ),
    .testTarget(name: "SillRenderTests", dependencies: ["SillRender", "SillCore", "SillNvim", messagePack]),
]
var appDependencies: [Target.Dependency] = ["SillCore", "SillNvim", "SillRender", messagePack]
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
    ],
    // The msgpack codec Veil's RPC layer is written against (MIT).
    dependencies: [.package(url: "https://github.com/qvacua/MessagePack.swift", exact: "4.1.0")],
    targets: targets
)
