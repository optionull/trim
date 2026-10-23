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
| C# / Razor (first, M3) | Roslyn LS with Razor cohosted in it, talked to by nvim's LSP client (M3, M6); an HTML server for Razor's markup (`__virtual.html`, `razor/updateHtml`) later | Downloaded on the user's machine, never bundled: nuget.org's `roslyn-language-server.<rid>` (MIT) still carries four Visual Studio assemblies, left out. |
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
- heed gap (closed 2026-10-23, heed-build/heed#137): heed had no inbound request API. It now has a control
  socket, `control.sock` beside its hooks socket: start, send, show, sessions and watch, one JSON object a line.
- heed owns agent sessions. sill shows a thin view over the control socket (who needs you, status, open in
  heed) and does not rebuild heed's session UI.
- Day-1 fallback: the editor's own Ghostty pane runs the agent.

## 8. Milestones

| | Scope | Exit criteria |
|---|---|---|
| M0 | Spikes, in order: placeholder Ghostty pane under multigrid with `<C-w>` across it; Veil RPC lift; instanced Metal grid; sidecar handshake | Each spike has a go/no-go note |
| M1 | Metal grid on a single nvim window | Daily-drivable text editing, 120 fps scroll |
| M2 | Full UI protocol and the app's chrome (see M2 below); signing and notarizing wait for the owner | sill looks like board 1, problems panel aside, and every nvim message, command line and completion is native |
| M3 (done) | LSP, C# sidecar, build capture, problems | Open a .NET solution, build, jump to errors |
| M4 (done) | MCP server, editor-only agent loop | Agent fixes a build error end to end |
| M5 (done) | heed bridge (needs heed's control socket) | Send to heed and see the session in the editor |
| M6 (done) | .NET profiler in sidecar, Razor | CPU and heap diff on a sample app |
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
- First versions of boards 5 and 6. The merge tool: `Sill merge LOCAL BASE REMOTE MERGED` (and `Sill diff A B`), as
  git's mergetool and difftool call it, opens ours, result and theirs in nvim's diff mode; `]x`/`[x` walk the
  conflict markers and `<localleader>o/t/b` take ours, theirs or both (§11); `:SillMergeBase` shows the base; the
  status bar's MERGE badge counts the conflicts down. The right-click menu: Go to definition, Find usages, Rename
  (language servers), Blame line, History of file, and Compare file (or the whole tree) with a recent branch, tag or
  commit; `:SillDiff` takes a tab page of its own when the window is too narrow to split.
- A first version of boards 7 and 8: `:SillProfile` opens the profiler in a tab page of its own: the flame graph
  drawn by level of detail (scroll to zoom around the pointer, drag to pan, click a frame), the selected frame's self
  time, total and hot path, and the payload an agent would get. The profile is M0's synthetic one; Timeline, Call
  tree, Allocations and Heap diff say they come with M6. Pane buffers have names ("Terminal 2", "Profile") for the
  tab line.
- Still placeholders: packages (board 3, M3's .NET work). Sessions (boards 2 and 9) are M5's thin list over heed,
  as decided, not the boards' full session UI.
- No swap files (owner, 2026-10-23): sill always starts nvim with `-n`, whatever a config sets. Quitting (⌘Q or
  closing the window) with unsaved changes asks: Save All, Don't Save, or Cancel.
- M3 (done 2026-10-23): build capture, Roslyn, Problems. Exit test `SILL_CHECK=m3` in a scratch solution: Roslyn
  5.4.0-2.26179.14 downloaded and ready in 20 s, reporting CS1061; Build (⌘B) captures it into Problems (the log in
  Output); Return goes to it; fixed, the build passes and its problems go.
  - Build capture (`SillCore/BuildCapture`) parses dotnet/MSBuild, Swift, Cargo and tsc into one `Diagnostic`
    shape and gives them to nvim as diagnostics (namespace `sill.build`), so Problems, signs and jumps are nvim's.
  - Roslyn: the sidecar downloads the newest server into `~/Library/Caches/sill/roslyn/<version>` (never in the
    app, §5), offline using the newest cached. Since M6 it is nuget.org's newest stable `roslyn-language-server.<rid>`
    (MIT, Razor in it; it was Microsoft's vs-impl feed). Changed from §5's broker: nvim's own LSP client talks to the
    server directly, as roslyn.nvim does (solution/open, project load, pull diagnostics). A config that already runs
    a C# server keeps its own.
- M4 (done 2026-10-23): sill's MCP server and the agent loop. Exit test `SILL_CHECK=m4` (a scripted agent) and,
  with `SILL_LIVE_AGENT=1`, Claude Code (haiku) given only sill's tools plus Read and Edit: it built, read the error,
  fixed `order.Total` and built again, in 14 s.
  - The server (`SillAgent`) speaks MCP on a Unix socket only the user can open; agents reach it as an ordinary stdio
    server through `nc -U <socket>`, written to an MCP config file (Passenger's `--mcp-attach`, without a helper).
  - Tools: `problems` (build and language server diagnostics), `build` (as ⌘B, returning its errors), `read_file`
    (as the editor has it, unsaved changes included), `open_file` (shows it to the person). Agents edit files with
    their own tools; sill runs `:checktime` after each call, so open files show the edits.
  - The permission broker: an agent's first `build` asks the person (Allow Once, Always for the session, Deny).
  - Send all to agent (board 9) starts `claude` (or `SILL_AGENT`) in a terminal pane with sill's MCP config and the
    problems in its prompt.
- M5 (done 2026-10-23): the heed bridge. Exit test `SILL_CHECK=m5` against a heed whose claude is a stand-in that
  logs what it is given (a dev heed in its own home: `CFFIXED_USER_HOME`, `XDG_CONFIG_HOME`):
  - heed's control socket (heed-build/heed#137): `start` runs an agent on a prompt in a folder, as work in a
    worktree heed knows or a chat in the folder, off screen, with extra launch `arguments`; `send` types into the
    agent's pane only while it is idle or done; `show`; `sessions`; `watch` streams the list as it changes.
  - Send all to agent goes to heed when it runs: a new session in this folder, claude given `--mcp-config` (codex
    `-c mcp_servers.sill…`), titled by the problems ("Fix CS1061"); again, the problems are typed into the session
    already working here; while it asks, heed holds them and sill says why. Without heed, the M4 terminal pane.
  - The Agents sidebar follows heed's sessions (`SillAgent/Heed`, a watch that reconnects): those that need you
    first, then this folder's, with a count on the activity bar. Return opens one in heed.
  - `:SillAgent next|send|list`; `<leader>a` (unless the config maps it) opens the next session that needs you in
    heed.
  - Not verified: a real claude started by heed reaching sill's MCP server (the stand-in shows it got the config;
    M4's live run showed claude using it), codex's MCP arguments, and heed in a fixture or tutor world.
- M6, the profiler (done 2026-10-23). Exit test `SILL_CHECK=m6` on the sample in
  `Tests/SillSidecarTests/Fixtures/Sample` (a hot loop and a cache that only grows), off screen at 1440x900
  (`SILL_OFFSCREEN=1`):
  - The sidecar vendors Passenger's profiler (`sidecar/Sill.Profiler`): `profile` builds the project in Release and
    runs it held at a diagnostic port of its own, so sampling starts at its first line; `profile.snapshot` writes the
    heap through createdump (no debugger) and reads it with ClrMD, compared object by object with the run's last;
    `profile.stop` ends the recording and answers with the call tree, hot spots with file:line from their PDBs,
    allocations and collections. Each snapshot took about 1.2 s on the sample.
  - `:SillProfile` (run, snapshot, stop; synthetic for M0's profile) profiles the project the current file is in, or
    the folder's first runnable one. The profile pane (boards 7 and 8): the flame graph from the real call tree (hot,
    warm and cool as board 7), the call tree as hot spots (Return opens the source), allocations, collections, and the
    heap diff as a treemap coloured by growth with growth bars; each with what the agent gets, and Send to agent
    ("Make Pricing Total faster", "Stop Order growing"), to heed or a terminal pane.
  - TraceEvent's Windows-only native helpers (KernelTraceControl, Microsoft's msdia140) are dropped from the
    sidecar's publish, and the bundle refuses any native binary, Windows' as well as Mach-O.
  - Not done: board 8's retainer path (who keeps them alive) and per-object zoom; board 7's CPU-over-time strip; an
    MCP tool for profiles; attaching to a running program.
- M6, Razor (done 2026-10-23). Exit test `SILL_CHECK=razor` in a Blazor app as `dotnet new blazor` makes it:
  - Razor is cohosted in Roslyn's server, so no broker is needed: nvim's client sends .razor and .cshtml files as
    `aspnetcorerazor`, and answers Razor's questions about their HTML (`razor/updateHtml`, and the requests it
    forwards with a checksum) empty, as Passenger does without an HTML server. Components, directives and the C#
    stand alone: a component's broken C# is reported at its own line, hover names a component, completion offers
    components in markup and the C# in `@code`, and ⌘B's build agrees.
  - Roslyn's nine diagnostic sources are registered for every document, so nvim pulled a Razor file nine more times
    and showed each error ten times: in Razor files only Razor's own pull counts.
  - Paths are the file system's (`realpath`): sill's folder, the build's PWD, and build capture no longer shortens
    /private/tmp to /tmp, so a diagnostic's file is the buffer's.
  - Not done: HTML, CSS and JavaScript in markup (VS Code's HTML server on Node, plan §5's bridge); Razor's semantic
    colours.
- A real project (2026-10-23): `SILL_CHECK=project` in elastic/docs-builder (59 projects in one .slnx; `SILL_CWD`,
  `SILL_CHECK_CLEAN=1` for a full build). The main thread is watched throughout (a block every 10 ms, how late it
  ran) and nvim is asked a round trip every 100 ms; the check fails on a main-thread stall over 100 ms. Measured:
  - Roslyn loads the solution in 7 s (14 s after a clean); completion answers in 0.15 to 0.27 s; a no-op ⌘B in 5 s,
    a full one in 136 s (191 s from a terminal before the fixes below), 85 problems.
  - Worst main-thread wait 17 ms and worst nvim round trip 13 ms, through all of it, the full build included.
  - Fixed on the way: the explorer read folders on the main thread (a filter over the whole tree stalled 150 ms a
    key): it reads them off it now. nvim matched every file a build touched against Roslyn's watch patterns in Lua
    (2 s pauses, and 2.8 s to quit): Roslyn is no longer offered file watching and watches the solution itself.
  - App Nap: in the background macOS naps sill and its run loop waits seconds through a build; in front it never
    does, and the check holds App Nap off as being in front does (`SILL_CHECK_NAP=1` lets it nap).
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
