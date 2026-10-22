# sill

A native macOS code editor where nvim owns buffers, modes and keymaps and the app owns pixels, windows
and integrations: a Metal-rendered grid, Ghostty terminals as ordinary splits, a profiler, packages,
diff and three-way merge, and a bridge that hands build errors and profiles to a coding agent.

[docs/plan.md](docs/plan.md) is the plan; [docs/designs/](docs/designs/) holds the nine boards. Days 1 and 2 of the
plan's first week are done: sill embeds nvim as a multigrid UI, and a terminal pane is a placeholder nvim window
with a Ghostty surface drawn over it. The grid is still drawn with CoreText; the Metal grid is day 3.

## Building

Tools come from mise (`mise.toml`): Zig for GhosttyKit, SwiftFormat and SwiftLint. Xcode with the Metal toolchain
and nvim 0.12 or later are needed too; `mise run doctor` checks.

```sh
mise run ghostty   # build Vendor/GhosttyKit.xcframework once (without it, panes show a stand-in)
mise run dev       # build and open build/Sill.app
mise run test      # the Swift Testing suite; the nvim tests start a real `nvim --embed`
mise run lint
```

`SILL_CHECK=1 build/Sill.app/Contents/MacOS/Sill` plays days 1 and 2 in the real app, with key events sent through
the window, and exits non-zero on the first failing step. `SILL_CHECK_SHOT=<file.png>` also saves the window with a
pane open.

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
| `Sources/SillTerminal` | the Ghostty surface, from heed |
| `Sources/SillApp` | the AppKit app |
| `runtime/` | sill's nvim runtime (`:SillTerminal`, the placeholder buffers) |

Third-party code and licences: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
