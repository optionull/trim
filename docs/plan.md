# Plan and design

Native macOS nvim editor. Swift/AppKit shell, `nvim --embed`, Metal grid, libghostty panes, .NET sidecar,
agent and heed bridge. The source this was transcribed from is [plan-and-design.pdf](plan-and-design.pdf);
the boards are in [designs/](designs/).

## 1. What we are building

A native macOS code editor where nvim owns buffers, modes and keymaps and the app owns pixels, windows
and integrations.

- First-class for C#/.NET and Razor, Rust, Swift, Markdown; professional HTML/CSS/TS. Inspired by
  Zaneris/passenger, without the XAML focus.
- Built in: Metal-rendered grid, Ghostty terminals as ordinary editor splits, CPU and memory profiler,
  package view with CVEs, diff and three-way merge (also usable as git difftool and mergetool).
- Build errors and profiling sessions go to a coding agent, via an MCP server and a bridge to heed.
- A separate app, not a pane inside heed.

## 2. Architecture

```
AppKit shell (Swift 6, not sandboxed)
|-- single split tree: each pane = nvim window | Ghostty surface | tool view
|-- main thread        UI, overlays (completion, cmdline, messages)
|-- nvim thread        msgpack-RPC over `nvim --embed` (UI protocol)
|-- grid actor         GridModel, multigrid composition
|-- render thread      CAMetalDisplayLink -> CAMetalLayer
|-- TermKit            libghostty surfaces
|-- AgentKit           MCP server (unix socket), permission broker,
|                      HeedClient, BuildCapture
'-- .NET sidecar       JSON-lines: Roslyn LS broker, Razor bridge,
                       profiler (EventPipe, ClrMD), debugger (DAP)
```

- Layout decision: nvim owns the split tree. A Ghostty pane is backed by a placeholder nvim window (a
  `nofile` buffer) and the app draws the surface over that window's grid, so `:split`, `<C-w>hjkl`, resizing
  and `:only` keep working and a Ghostty pane splits like any editor window. Tool views are placed the same
  way.
- nvim UI protocol: `ext_linegrid`, `ext_multigrid`, `ext_popupmenu`, `ext_cmdline`, `ext_messages`,
  `ext_tabline`; `win_viewport` for smooth scroll. Inlay hints and diagnostics render inside the nvim grid;
  completion, cmdline and messages are native. The native popup takes built-in `vim.lsp.completion` through
  `ext_popupmenu`, and an adapter plugin routes nvim-cmp and blink menus to it as well.
- Config: sill runs as `NVIM_APPNAME=sill`. Its curated base config loads first, then sources the user's
  `~/.config/nvim/init.lua` with runtimepath and data paths pointed at the user's own nvim directories, so
  plugins and lockfile are shared with plain nvim. sill's native UI settings are applied last and win.
- Threading rule: nothing on the main thread waits on nvim; the render thread only reads immutable grid
  snapshots. IME queries (`NSTextInputClient` `firstRect`, `markedRange`) arrive synchronously on the main
  thread and are answered from the cached grid and cursor, never a round trip to nvim.

## 3. Metal renderer

- Glyph atlas (r8Unorm coverage + bgra8 colour), per-cell instance buffer, background pass, decoration pass,
  instanced text pass.
- Shaped-run cache per row, ASCII fast path, ligatures via CTLine, fallback fonts, wide chars, curly
  underlines in the shader, procedural box-drawing and powerline sprites (ported from Ghostty).
- Damage tracking, 120 Hz via CAMetalDisplayLink, pixel scrolling, IME and accessibility. CoreText still
  shapes and rasterises; Metal draws.
- Go/no-go for the grid spike: 120 fps pixel scroll on a full-screen 4K grid with ligatures (under 8.3 ms a
  frame); keypress-to-glyph latency no worse than plain nvim in Ghostty; the display link pauses when nothing
  changes; the 11.8M-sample flame graph pans and zooms at 120 fps.
- Profiler output on the GPU too: level-of-detail aggregation so huge data stays smooth (for example 11.8M
  samples as 6,420 blocks, 3.1M objects as 4,812 tiles).

## 4. Reuse map (all MIT)

All four are MIT per GitHub's licence detection, checked 2026-10-22: [Veil](https://github.com/0x1b2c/Veil),
[VimR](https://github.com/qvacua/vimr), [Passenger](https://github.com/Zaneris/passenger),
[Ghostty](https://github.com/ghostty-org/ghostty). Recheck what is actually vendored before first release.

| Source | Take | Leave / replace |
|---|---|---|
| Veil | RPC layer, shaping, box drawing, font fallback, keyboard handling | Main-thread non-instanced renderer. No multigrid, popupmenu, cmdline, messages; never draws underlines; no emoji atlas. |
| VimR | API generator, NvimApi/NvimView ideas, IME notes | Its UI shell |
| Passenger | Profiler, Lsp/Razor, DebugAdapter, Host JSON-lines protocol, MCP design | XAML tooling |
| Ghostty | Renderer reference; libghostty xcframework from heed's pinned commit (zig 0.16) | n/a |

## 5. Language support

| Language | Server | Notes |
|---|---|---|
| C# / Razor (first, M3) | .NET sidecar LSP broker (Roslyn LS + Razor HTML bridge via `__virtual.html`, `razor/updateHtml`) | Roslyn LS NuGet package contains non-OSS Visual Studio assemblies: download on the user's machine, never bundle in the DMG. |
| Rust | rust-analyzer via `vim.lsp` | Profiling with samply |
| Swift | sourcekit-lsp via `vim.lsp` | Profiling with xctrace |
| Markdown | marksman | |
| HTML / CSS / JSON | vscode-langservers | |
| TS / JS | typescript-language-server | |

## 6. Profiler

- Vendor Passenger.Profiler (EventPipe sampling, ClrMD heap snapshots with retained sizes, snapshot diff).
  Rust via samply, Swift via xctrace. Common `ProfileDoc` model feeds every view.
- Views: timeline, call tree, flame graph, allocations, heap treemap, retainer chain, snapshot diff. All
  drawn with Metal and aggregated by zoom level.
- Profile to agent: a capped payload (about 4k tokens) with hot frame, path, file:line, a flamegraph
  attachment and the ask.
- Debugger: Passenger's standalone DAP adapter (milestone M8).

## 7. Agent bridge and heed

- MCP server on a unix socket, modeled on Passenger's `--mcp-attach`, with a permission broker.
- BuildCapture normalises dotnet, cargo JSON, swift and tsc output into one `Diagnostic` shape; problems
  panel sends them to the agent.
- heed gap: heed has no URL scheme and no inbound request API (one-way hook socket only). It needs
  start/send/sessions/watch over a control socket; that is heed work, scheduled on heed's roadmap to land
  before M5.
- heed owns agent sessions. sill shows a thin view over the control socket (who needs you, status, open in
  heed) and does not rebuild heed's session UI.
- Day-1 fallback: the editor's own Ghostty pane runs the agent.

## 8. Milestones

| | Scope | Exit criteria |
|---|---|---|
| M0 | Spikes, in order: placeholder Ghostty pane under multigrid with `<C-w>` across it; Veil RPC lift; instanced Metal grid; sidecar handshake | Each spike has a go/no-go note |
| M1 | Metal grid on a single nvim window | Daily-drivable text editing, 120 fps scroll |
| M2 | Full UI protocol and the app's chrome (see M2 below); signing and notarizing wait for the owner | sill looks like board 1, problems panel aside, and every nvim message, command line and completion is native |
| M3 | LSP, C# sidecar, build capture, problems | Open a .NET solution, build, jump to errors |
| M4 | MCP server, editor-only agent loop | Agent fixes a build error end to end |
| M5 | heed bridge (needs heed's control socket) | Send to heed and see the session in the editor |
| M6 | .NET profiler in sidecar, Razor | CPU and heap diff on a sample app |
| M7 | Rust and Swift profiling, remaining language servers | samply and xctrace sessions viewable |
| M8 | Debugger (DAP) | Breakpoints and stepping in C# |
| M9 | Polish: diff/merge tool modes, packages view, settings, Sparkle updates | Beta release |

### M2

Decided 2026-10-23: the chrome the boards draw joins M2, built as native views to the design (the owner chose
this over nvim drawing it); signing and notarizing wait until the owner wants them. In order:

1. The nvim UI protocol drawn natively: `ext_cmdline` (the command line as an overlay), `ext_messages` (messages
   and their history), `ext_popupmenu` (completion), `ext_tabline` (tabs).
2. Smooth scrolling from `win_viewport`'s `scroll_delta`.
3. The window's frame: the title bar (project and branch, Run), the activity bar, and the native status bar (mode,
   branch, language server state, file type, line and column) that replaces nvim's.
4. The explorer, as a tool view in nvim's layout (a placeholder window, like a terminal pane): the tree, file icons,
   git state, filtering, and the hide-ignored toggle.
5. Tabs per split (board 1's tab strips): what they list is to be settled when it is built.
6. Design tokens from the boards (dark first, mint accent, Inter and JetBrains Mono) used by everything above.

Where M2 stands (2026-10-23): all six steps are done.

- Smooth scrolling (step 2): a window that scrolls less than its height slides there over 120 ms (ease out), its
  new rows offset by what is left of the move and the rows not yet covered drawn from before it, clipped to the
  window; nvim has already moved, sill only shows the move. Off with `SILL_SMOOTH_SCROLL=0`.

- The command line, messages, completion and tabs are sill's views (step 1).
- The frame (step 3): a title bar (project and branch, Run), the activity bar, and a status bar (mode, branch,
  pending keys, the sidecar, file type, line and column) in place of nvim's status lines, which `:SillChrome` turns
  into rules, with the board's colours for what nvim still draws.
- Tool views (step 4): the sidebar and the bottom panel are placeholder windows, like terminal panes, so `<C-w>`
  reaches them; their views take the keys they use (j/k, Return, h/l, `/`) and pass the rest to nvim. The activity
  bar switches the sidebar: the explorer (tree, git marks, ignored files behind a toggle, `/` filter), source
  control (git's changes; Return opens a modified file beside its version at HEAD with `:SillDiff`), and empty
  states naming the board and milestone for agents, packages and the profiler. The panel's Problems tab lists nvim's
  diagnostics; Tests and Output wait for M3. Send all to agent says it comes with the heed bridge.
- Tabs per split (step 5), settled as editor groups: each editor window keeps the files opened in it, drawn as a
  strip over its winbar row (one cell high, lower than the board's).
- Run guesses the project's command (`swift run`, `dotnet run`, `cargo run`, `npm start`) and runs it in a terminal
  pane at the bottom.
- Tokens (step 6) are sampled from board 1 into `Sources/SillApp/Design.swift`. Inter is used when installed, else
  the system font; JetBrains Mono likewise.
- `SILL_CHECK=chrome` checks all of it in the app; `SILL_CHECK=1` still runs days 1 to 5 without the chrome.

## 9. Packaging

- Build, signing and release match heed exactly: same Developer ID, hardened runtime and notarization
  pipeline, same libghostty xcframework step, Homebrew cask in `mpdreamz/tap`, Sparkle updates.
- The .NET sidecar runs on the user's installed `dotnet` SDK, not a bundled runtime, so the app needs no JIT
  entitlements.
- Bundled pinned nvim with a "use PATH nvim" override.
- Licence audit before first release: Roslyn LS fetched at runtime.

## 10. Top risks and spikes

| Risk | Spike / mitigation |
|---|---|
| A Ghostty pane inside nvim's layout | Placeholder nvim window per pane; first M0 spike |
| Grid renderer perf with multigrid and huge profile views | Instanced renderer with LOD; M0 benchmark on 11.8M-sample trace |
| libghostty API stability and build (zig 0.16) | Pin to heed's commit; embed spike in M0 |
| Razor/Roslyn LS outside Visual Studio | Follow Passenger's Razor bridge; sidecar broker; early C# spike |
| Roslyn LS licensing | Download at first run, never bundle |
| heed has no inbound API | Ship editor-local agent pane first; heed control socket lands before M5 |
| Notarization with a sidecar | Sidecar runs on the user's dotnet; signed build tested in M2 |
| IME and accessibility with a custom grid | Use VimR notes and NSTextInputClient early |
| Merge tool correctness | Test against git's own conflict corpus; run as real mergetool in CI |

## 11. Keys

Nothing sill adds shadows a core nvim key.

- Merge view: `]x` / `[x` next and previous conflict; `<localleader>o` ours, `<localleader>t` theirs,
  `<localleader>b` both. (Board 5 shows `co`/`ct`/`cb`, which shadow change-till and change-back-word.)
- Diff view: nvim's own `]c`, `[c`, `do`, `dp`.
- Terminal panes: as nvim's own `:terminal`. The pane's window is in normal mode until `i` (or `a`, `I`, `A`,
  `<Insert>`) hands the keyboard to the terminal; `<C-\><C-n>` in the terminal hands it back, and `<C-\>`
  followed by anything else reaches the terminal as typed. A click on a pane makes it current and gives it the
  keyboard.
- `<leader>a`: jump to the next agent that needs you. (Board 2 shows `ga`, which shadows "print character
  code".)

## 12. First week

- Day 1 (done): repo skeleton on heed's build setup, lift Veil's RPC layer, `nvim --embed` hello.
- Day 2 (done): multigrid, and a placeholder window covered by a libghostty surface; `<C-w>` across it.
- Day 3 (done): instanced Metal grid drawing a static linegrid.
- Day 4 (done): live nvim input to grid, cursor, colours.
- Day 5 (sidecar done; signed build waiting): .NET sidecar handshake on the user's dotnet, signed build smoke test.

Days 1 and 2 left these behind, for later days to pick up or keep:

- Placeholder windows come from sill's runtime (`runtime/plugin/sill.lua`, `:SillTerminal`), which reports which
  windows are panes over `rpcnotify`. A pane lives as long as its buffer: closing its last window closes the
  terminal.
- sill runs as `NVIM_APPNAME=sill` with only its runtime added; sourcing the user's `init.lua` (§2, Config) is not
  done.
- Two fixes to the lifted RPC layer: window handles are decoded from their msgpack ext payload (Veil's decoding
  gave wrong numbers for every handle above 127), and keys go to nvim from one ordered queue instead of a task per
  key.
- Day 3 drew the live grid, not a static one: `SillRender` builds instances per row (cached by row version), draws
  them in two instanced passes per grid in multigrid order, on a render thread. The grid spike's go/no-go (§3),
  measured with `mise run bench` (offscreen, 3840x2160) and `SILL_CHECK=1` on the owner's machine and LG 4K display:
  - Scroll: a full 4K grid (240x49 cells, JetBrains Mono, 291 ligatures a frame) scrolled a line a frame, every row
    rebuilt: p99 2.1 ms a frame, CPU and GPU together. Go.
  - Flame graph: a synthetic 11.8M-sample profile (323,290 frames) zoomed 2000x and panned: p99 0.5 ms a frame. Go,
    with a caveat: it draws at most 1,335 blocks a frame, against the 6,420 board 7 shows, and no labels yet.
  - Idle: no frames drawn, and the display link paused, within 0.5 s of the last frame. Go.
  - Key to screen: a median 28 ms (p95 35 ms) from the key event to the frame's presented time, of which 25 ms is
    the wait for the display. Whether that is no worse than nvim in Ghostty is not measured: Ghostty does not expose
    when its frames are presented.
- Not `CAMetalDisplayLink` (§2, §3): with it key to screen was 65 ms, each frame drawn for a refresh about four
  ahead. The render loop uses the view's display link and `nextDrawable()`, and draws a due frame at once.
- The font is JetBrains Mono when installed, else the system monospace. `SILL_FONTS=<dir>` registers fonts for the
  process only; bundling JetBrains Mono (OFL) is still to decide.
- The atlas grows to 8192 pixels high and then starts over; a window moving to a display with another backing scale
  rebuilds the renderer.
- Day 4: key notation, mouse modifiers and wheel steps live in `SillInput` and are unit-tested. Keys, mouse events
  and pastes reach nvim through one ordered queue. Input methods go through `NSTextInputClient`, answered from the
  cached screen (`firstRect` in 0.01 ms), with the marked text shown at the cursor. The mouse sends every button,
  drags and releases to the grid they were pressed in, and the wheel adds trackpad pixels up into lines. ⌘V pastes
  with `nvim_paste`, ⌘C and ⌘X yank and delete to `+` in Visual mode, and `set_title` titles the window. The cursor is
  nvim's (`mode_info_set`: shape, size and highlight; a block shows the character under it reversed). Highlights
  draw undercurl, double, dotted and dashed underlines and `blend`, and floats cover what is under them.
- Not in day 4: cursor blinking, a hollow cursor when the window is not focused, Option as Meta (Option goes to the
  input method, so the layout's characters and dead keys work; `<M-x>` mappings need a setting), `guifont` and font
  size, and accessibility.
- Day 5, the sidecar half: `sidecar/Sill.Sidecar` (C#, net10.0, `RollForward=LatestMajor`, no apphost) speaks
  Passenger's protocol, adapted: JSON lines, requests by id, partial results, cancellation, a ready line with the
  protocol version. `SillSidecar` finds the user's dotnet (`SILL_DOTNET`, `DOTNET_ROOT`, the login shell's PATH, the
  usual places), starts it, and fails every waiting request with the exit status and stderr if it dies. The app
  starts it at launch; `scripts/bundle.sh` publishes it into Resources and refuses any native code in it.
- Day 5, the signed half, is not done: the owner chose to leave signing with the Developer ID for later
  (2026-10-23). The bundle id is settled as `com.mpdreamz.sill`. `scripts/sign.sh` is written (Developer ID, hardened
  runtime, timestamp, no entitlements) and has not been run; the smoke test is to run it, then `SILL_CHECK=1` on the
  signed app.
- The user's config (§2), as built: when `~/.config/nvim` (or `$NVIM_APPNAME`'s folder) has an init.lua or
  init.vim, nvim runs under its own name, so the config, plugins and lockfile are the ones nvim in a terminal uses;
  sill's base settings go first (`--cmd`) and the config wins them. Simpler than the plan's `NVIM_APPNAME=sill` with
  paths pointed back, and the same result. Without a config, in the self-check, or with `SILL_NVIM_CONFIG=0`, nvim
  runs as `sill` with the base settings. Tried on the owner's LazyVim: lazy.nvim resets the runtimepath, so sill
  loads its runtime again once startup is done; lualine's status lines are held off (`laststatus=0`) and the rows
  nvim keeps between stacked windows are drawn over as rules; the board's colours apply only without a colour scheme.
- The startup hang seen once in the chrome check: when a start-up step failed, sill opened an alert with
  `runModal`, which waits forever in an unattended run. The check and the showcase print and exit now, and a
  failing `:SillChrome` is a notification, not a failed start.
- No CI until sill has shown it has legs (owner's call, 2026-10-22): macOS runner minutes cost on a private repo.
  Until then `mise run lint test` and `SILL_CHECK=1` run locally.

## 13. Caveats

- Plan derived from a read of Veil, VimR, Passenger, Ghostty and heed. Neovide, Zed and neonim source were
  not read; the Veil app was not built.
- In the designs, CVE ids, package versions, profile counts and timings are placeholders.
- Design set: nine boards in a dark-first system (mint accent, Inter and JetBrains Mono; static render uses
  fallback fonts).

## Designs

| Board | |
|---|---|
| [1. Main window](designs/1-main-window.png) | Explorer with a hide-ignored toggle, editor splits with a Ghostty pane, problems panel |
| [2. Sessions and agents](designs/2-sessions.png) | Sessions grouped by who needs you, terminal, worktree and next steps |
| [3. Packages](designs/3-packages.png) | Vulnerable, outdated and deprecated packages |
| [4. Diff and log compare](designs/4-diff.png) | Any two refs, commits in range, side-by-side diff with word-level highlights |
| [5. Three-way merge](designs/5-merge.png) | Ours, Result, Theirs; usable as git mergetool and difftool |
| [6. Compare menu](designs/6-compare-menu.png) | Compare selection, file, folder or tree against branches, tags and commits |
| [7. CPU profiler](designs/7-cpu-profiler.png) | Flame graph on a huge trace shown as aggregated tiles |
| [8. Memory profiler](designs/8-memory-profiler.png) | Heap treemap by growth, retainer path, payload sent to the agent |
| [9. Agent handoff](designs/9-agent-handoff.png) | Build error to agent to verified diff |

## Next design pass

The boards predate the decisions above. Fix in the next pass:

- Board 2: a thin view over heed's sessions, not a full rebuild; `ga` becomes `<leader>a`.
- Board 5: merge keys become `<localleader>o/t/b`; the mergetool command `app` becomes `sill`.
- Board 4 has `List<Line> Lines` where boards 2 and 9 have `IReadOnlyList<Line> Lines`.
- Board 1's Ghostty pane says "Build succeeded" next to a problems panel with two errors.
- Board 9 has a stray `)` after "CreateOrder.cs".
