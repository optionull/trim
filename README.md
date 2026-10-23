# sill

A native macOS code editor where nvim owns buffers, modes and keymaps and the app owns pixels, windows
and integrations: a Metal-rendered grid, Ghostty terminals as ordinary splits, a profiler, packages,
diff and three-way merge, and a bridge that hands build errors and profiles to a coding agent.

[docs/plan.md](docs/plan.md) is the plan; [docs/designs/](docs/designs/) holds the nine boards. Days 1 to 4 of the
plan's first week are done: sill embeds nvim as a multigrid UI drawn by an instanced Metal grid, and a terminal pane
is a placeholder nvim window with a Ghostty surface drawn over it.

## Building

Tools come from mise (`mise.toml`): Zig for GhosttyKit, SwiftFormat and SwiftLint. Xcode with the Metal toolchain
and nvim 0.12 or later are needed too; `mise run doctor` checks.

```sh
mise run ghostty   # build Vendor/GhosttyKit.xcframework once (without it, panes show a stand-in)
mise run dev       # build and open build/Sill.app
mise run test      # the Swift Testing suite; the nvim tests start a real `nvim --embed`
mise run lint
```

![sill on 2026-10-23: a Lua file beside a terminal pane](docs/showcase-2026-10-23.png)

`SILL_SHOWCASE=<file.png>` renders a picture like that one (nvim at 150x46, a file beside a terminal pane running
`git log`; `SILL_SHOWCASE_FILE` picks the file). `SILL_CHECK=1 build/Sill.app/Contents/MacOS/Sill` plays the first week in the real app, with key events sent through
the window, and exits non-zero on the first failing step; it also measures idle frames and key-to-screen latency.
`SILL_CHECK_SHOT=<file.png>` saves the window with a pane open. `mise run bench` measures the Metal grid at 4K on a
release build. `SILL_FONTS=<dir>` uses the fonts in a directory without installing them (JetBrains Mono, say).

## Terminal panes

`:SillTerminal` opens one (to the right; `:belowright SillTerminal` and other modifiers place it as they place
`:new`). The pane is an nvim window like any other: `<C-w>hjkl` moves across it, `:resize` and `<C-w>=` size it,
`:only` and `:q` close it. As with nvim's own `:terminal`, `i` hands the keyboard to the terminal and `<C-\><C-n>`
hands it back; a click on the pane or on the editor does the same.

## Layout

| Path | |
|---|---|
| `Sources/SillNvim` | nvim over msgpack-RPC, lifted from Veil |
| `Sources/SillCore` | the screen model built from redraw events, and the session that runs nvim |
| `Sources/SillInput` | AppKit input in nvim's terms: key notation, mouse modifiers, wheel steps |
| `Sources/SillRender` | the Metal grid: glyph atlas, instanced passes, render thread; the flame graph's level of detail |
| `Sources/SillTerminal` | the Ghostty surface, from heed |
| `Sources/SillApp` | the AppKit app |
| `runtime/` | sill's nvim runtime (`:SillTerminal`, the placeholder buffers) |

Third-party code and licences: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
