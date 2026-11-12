# Developing sill

## Building

Tools come from mise (`mise.toml`): Zig for GhosttyKit, SwiftFormat and SwiftLint. Xcode with the Metal toolchain
and nvim 0.12 or later are needed too; `mise run doctor` checks. The build makes `Vendor/treesitter` the first time
(the parsers the app ships, about a minute; again only when `TREESITTER_COMMIT` moves, which `mise run
treesitter-latest` helps bump).

```sh
mise run ghostty   # build Vendor/GhosttyKit.xcframework once (without it, panes show a stand-in)
mise run dev       # build and open build/Sill.app
mise run test      # the Swift Testing suite; the nvim tests start a real `nvim --embed`
mise run lint
```

`SILL_SHOWCASE=<file.png>` renders a picture of the window (1440x900, off screen: a file beside a terminal pane running
`git log`; `SILL_SHOWCASE_FILE` picks the file; `SILL_SHOWCASE_SCENE=profile` shows the profiler instead, `agents` the Agents sidebar over heed's sessions). `SILL_CHECK=project SILL_CWD=<a .NET repo>` measures a real project (load, Roslyn, build) and fails if the UI ever waits over 100 ms. `SILL_CHECK=1 build/Sill.app/Contents/MacOS/Sill` plays the first week in the real app, with key events sent through
the window, and exits non-zero on the first failing step; it also measures idle frames and key-to-screen latency.
`SILL_CHECK_SHOT=<file.png>` saves the window with a pane open; `SILL_CHECK_SHOTS=<folder>` saves the README's pictures from the run and looked checks. `mise run bench` measures the Metal grid at 4K on a
release build. `SILL_FONTS=<dir>` uses the fonts in a directory without installing them (JetBrains Mono, say).

The checks need the .NET 11 runtime on the dotnet they find (the sidecar's and the fixtures' target), through the
login shell in `$SHELL` (sill reads its environment, as it does from the Dock: set `SHELL` to your own shell); `mise run verify` runs every one of them, lint and the tests first.

## Layout

| Path | |
|---|---|
| `Sources/SillNvim` | nvim over msgpack-RPC, lifted from Veil |
| `Sources/SillCore` | the screen model built from redraw events, and the session that runs nvim |
| `Sources/SillInput` | AppKit input in nvim's terms: key notation, mouse modifiers, wheel steps |
| `Sources/SillRender` | the Metal grid: glyph atlas, instanced passes, render thread; the flame graph's level of detail, the treemap |
| `Sources/SillTerminal` | the Ghostty surface, from heed |
| `Sources/SillApp` | the AppKit app: the frame, the sidebar (explorer, source control), the panel, tabs per split |
| `runtime/` | sill's nvim runtime (`:SillTerminal`, the placeholder buffers) |
| `Sources/SillSidecar`, `Sources/SillAgent` | the .NET sidecar's client (Roslyn, the profiler); the MCP server and heed's control socket |
| `sidecar/` | the .NET sidecar (`Sill.Sidecar`) and the profiler it runs (`Sill.Profiler`, from Passenger) |

Third-party code and licences: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
