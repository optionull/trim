import AppKit
import Foundation
import TrimWalk

// `trim`: what an agent (or a person) runs to write, check and open walkthroughs. See `trim walk format`.
let code = WalkCommands.run(
    Array(CommandLine.arguments.dropFirst()), cwd: FileManager.default.currentDirectoryPath,
    out: { print($0) }, err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
    open: { NSWorkspace.shared.open($0) }
)
exit(code)
