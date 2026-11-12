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
| Rust | rust-analyzer via `vim.lsp` (M7) | Profiling with samply. The person's if it runs, else its release into sill's cache |
| Swift | sourcekit-lsp via `vim.lsp` (M7) | Profiling with xctrace. From the PATH or Xcode |
| Markdown | marksman (M7) | Its release into sill's cache |
| HTML / CSS / JSON | vscode-langservers-extracted (M7) | npm into sill's cache |
| TS / JS | TypeScript 7's own `tsc --lsp` (M7) | npm into sill's cache, or the project's TypeScript 7; typescript-language-server needs the tsserver TypeScript 7 no longer ships |

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
| M7 (done) | Rust and Swift profiling, remaining language servers | samply and xctrace sessions viewable |
| M8 (done) | Debugger (DAP) | Breakpoints and stepping in C# |
| M9 (started) | Polish: diff/merge tool modes, packages view, settings, Sparkle updates | Beta release |

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
- sill's own panes (Home, the summary, the review, Run, …) take keys from one list, `Keymaps`: `g` then a letter
  goes somewhere, `?` lists the pane's keys, `f` labels what can be clicked, `:SillKey <name>` runs a command by
  name and `[keys]` in the settings rebinds it. These are the panes' keys, not nvim's: in the editor `g` is nvim's.

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
- Still placeholders: packages (board 3, M3's .NET work; built in M9). Sessions (boards 2 and 9) are M5's thin list over heed,
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
  - Not done (HTML, CSS and JavaScript in markup came after M9, below): Razor's semantic
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
- The explorer and the solution (owner's decisions, 2026-10-23): one explorer with a Files | Solution switch, light
  parsing (no MSBuild), .slnx only. Exit test `SILL_CHECK=solution` in Tests/SillCoreTests/Fixtures/Solution.
  - Files, informed by the project files: a folder holding a project is marked with its kind (app, web, test,
    library); files nest as Visual Studio nests them (`X.razor.cs` and `.css` under `X.razor`,
    `appsettings.*.json` under `appsettings.json`, `X.Designer.cs`, `X.g.cs`, `X.min.js`, `package-lock.json`, and
    a project's `DependentUpon`), opening the nest of a file that is opened; files a project removes are dimmed.
  - Solution: the .slnx's own tree (solution folders, projects open to their files, listed files), and how it
    differs from the disk, as a banner and as warnings on the .slnx in Problems: a listed file not there or in
    another case, a project or file in another folder than the rule's.
  - The rule: a project in the solution folder of its directory's parent (`src/tooling/docs-builder/…csproj` in
    `/src/tooling/`), a listed file in its directory's (`config/navigation.yml` in `/config/`), a root file in
    `/root/`. `:SillSlnx sync` shows the .slnx rewritten to it as a diff (its own tab page) and writes nothing;
    `:SillSlnx apply` writes it. It changes as little as it can: case fixed in place, a misplaced entry moved to
    its folder's end, a needed folder added after its parent, an emptied one gone, nothing added. On
    elastic/docs-builder (which follows the rule by hand) it changes CONTRIBUTING.MD's case, and re-indents the few
    lines indented with tabs.
- M7 (done 2026-10-24). Exit tests `SILL_CHECK=m7` in Tests/SillCoreTests/Fixtures/RustSample and SwiftSample,
  and `SILL_CHECK=servers` in Fixtures/Polyglot.
  - Native profiles: `:SillProfile` in a Cargo package records with samply, in a Swift package with xctrace (Time
    Profiler), each built in release with line tables in a folder of its own (Cargo profile `sill-profile`,
    `.build/sill-profile`), so the person's release build is left alone. Stop interrupts the program (samply waits
    for it; xctrace ends it). samply's processed profile and the symbols it writes beside it, and xctrace's exported
    time-profile table, become the same profile document the .NET profiler's does; frames the symbols cannot name
    (the dyld shared cache's, stubs) are named for their library, and the hot frame shown is the hottest with a
    source. On the samples: `rsample::pricing::total` at main.rs:7, `Pricing.total(_:)` at main.swift:9. No heap
    snapshots for native programs yet.
  - samply 0.13.1 is the person's if on their PATH, else its release downloaded into sill's cache, checksum checked.
  - Language servers: a file's server starts the first time one opens, unless the person's config runs one for it.
    sill finds it (the PATH, rustup, Xcode; a found one must run, as rustup's proxy for a missing component does not)
    or provisions it into `~/Library/Caches/sill/servers`: rust-analyzer's and marksman's releases at pinned versions
    with checksums (their releases publish none: the pinned sums are of the archives sill first fetched), and with npm,
    vscode-langservers-extracted 4.10.0 and TypeScript 7.0.2, whose compiler is its own server (`tsc --lsp`).
  - Once (2026-10-24), the Swift check, run straight after the Rust one, sat before recording until its 10-minute
    timeout; it passed in the full verification before and in every run since. Not explained; the check now says
    where it waits (building, or the recorder starting).
  - Not done: heap profiling for native programs, Xcode
    projects (only Swift packages), Cargo workspaces with several programs (the last one built is profiled).
- M8 (done 2026-10-24): the debugger. Exit test `SILL_CHECK=m8` on Tests/SillSidecarTests/Fixtures/Sample, and the DAP
  client's end-to-end test (`DebuggerTests`) against the adapter.
  - Passenger's debug adapter (ICorDebug through dbgshim, Roslyn's expression evaluator, ILSpy for code without
    source), vendored as `sidecar/Sill.DebugAdapter` and its libraries, ported from .NET 11 to .NET 10 (its Windows
    start dropped) and run on the person's dotnet as a process of its own. The app carries it as managed code only
    (no apphost); dbgshim, its native part, is Microsoft's package for this Mac, downloaded by the sidecar into
    `~/Library/Caches/sill/dbgshim` and loaded from there.
  - sill's side: a DAP client (`SillSidecar/DapClient`), the session (`Debugger`): the project built in Debug and
    launched, nvim's breakpoints sent once the adapter is initialized and as they change, and a pause shown: the line
    marked (▶ and a highlight), the call stack and the variables (opened as clicked) in the panel's Debug tab, "paused
    at Program.cs:5" in the status bar. Keys: F9 breakpoint, F5 start/continue, F10 over, F11 in, Shift-F11 out,
    Shift-F5 stop; `:SillDebug`, `:SillBreakpoint`. On the sample: paused at the breakpoint 2 s after F5.
  - Found on the way: the helper that runs commands (builds, finding language servers) blocked a thread until a
    command's output closed, with no limit; something a command left behind holding it open (a mise shim's, likely)
    held up a server's start for good about one run in three. It now reads without blocking, waits on the process's
    end, and kills what outlives its time; the servers check passed four runs out of four after, in 5 to 7 s.
  - Not done: Rust and Swift (lldb-dap). The rest of this list was done after M9, below.
- M9, started 2026-10-24 without signing, Sparkle or a release (owner: "no releases yet"). Packages (board 3) done:
  `PackageScanner` restores the solution (the .slnx, else the .sln, else the first project) and asks the SDK
  `dotnet list package --include-transitive --format json`, plain, `--vulnerable` and `--deprecated`, in parallel;
  what it could read is kept when it exits with an error over a project it could not (its problems are counted in the
  footer). Newer versions come from nuget.org's flat container index, not `--outdated`: the SDK's `--outdated` fails
  with "Sequence contains no matching element" on docs-builder.slnx and on 43 of its 59 projects one by one. A stable
  install is compared with stable versions; the newest patch is the newest with the same major and minor. Advisories
  (summary, fixed versions) come from osv.dev by GHSA id. "How it got here" is the shortest chain in the project's
  `project.assets.json` (obj or artifacts/obj), read off the main thread once per package. Update writes
  `PackageVersion` in Directory.Packages.props, else the project's `PackageReference` (attribute or child element),
  else adds one for a transitive package; open buffers read again, the solution is read again.
  - `SILL_CHECK=packages` in a copy of Tests/SillCoreTests/Fixtures/PackagesProject: the report in 2 s (2 vulnerable,
    4 outdated, 1 deprecated), Newtonsoft.Json first with "fixed in 13.0.1"; Update security and patches moves 4;
    Update moves Newtonsoft.Json to 13.0.1, leaving nothing vulnerable.
  - On docs-builder (`SILL_CHECK=project`): 327 packages, 1 vulnerable, 283 outdated, 4 deprecated, in 37 s (restore,
    the SDK and 327 index reads); the main thread's worst was 23 ms. The first version stalled it 725 ms: the side
    panel read project.assets.json on every draw, and the report's lists were sorted again on every draw.
- M9's merge and diff tool, hardened (2026-10-24): in merge or diff mode sill ends with nvim's status (`:cquit` is
  1), and a merge whose saved result still has conflicts ends with 1 whatever nvim said, so git's `trustExitCode`
  keeps it unmerged; ⌘Q or closing the window goes by the result file. Markers are matched as git writes them (seven
  characters, then a space or nothing; `=======` alone on its line; CRLF), in Lua and in `SillCore.MergeConflicts`.
  - Tested through git itself by `scripts/mergetool-check.sh` (`SILL_CHECK=merge` run as `mergetool.sill.cmd`): six kinds of conflict (one hunk,
    the first and last lines, two near each other, CRLF, a Markdown underline in theirs, a deletion against an edit)
    in merge, diff3 and zdiff3 styles, each resolved as theirs (git sees it resolved, its text what `git merge-file
    --theirs` makes), left with conflicts and resolved-then-`:cq` (both unmerged); and `git difftool
    --trust-exit-code` (`:qa` 0, `:cq` failing). Found on the way: splitting on "\n" in Swift never splits CRLF
    (one character), so a CRLF result's conflicts went uncounted; the old Lua took a `========` underline in theirs
    for the separator and dropped lines. Mutations of the exit status, the conflict count and the separator each
    failed the run.
- M9's settings (2026-10-24, owner: "Native settings window, powered by something more user editable. Like toml
  which I believe heed uses"): `~/.config/sill/settings.toml` (`$XDG_CONFIG_HOME`, or `SILL_SETTINGS`), heed's
  hand-written TOML parser copied in (`SillCore/Settings/TOML.swift`, with its tests) and heed's folder watcher.
  The window (⌘,, AppKit in the design tokens) writes one value in place through `TOMLDocument.setting`, or on its
  commented-out line, and the watcher reads the file back, so a hand edit and the window take the same path. Each
  setting stands for an environment variable sill already read (SILL_AGENT, SILL_CHROME, …), and a variable set
  when sill starts wins, its row disabled; the checks run without a settings file unless they name one. Font,
  size and line height (new: `CellMetrics(font:size:lineHeight:)`) apply at once: every view reads the grid's
  metrics from `EditorFont`, and a change makes the glyph atlas again and tells nvim the new grid size; ⌘+ and ⌘-
  change the size for the session, ⌘0 goes back to the file's. The chrome and the nvim config apply when sill
  starts again; the rest at once. Unknown keys are reported (a typo), a bad value keeps its default, a syntax error
  keeps the last good settings.
  - `SILL_CHECK=settings`: the default written on first start; the size stepper and agent field written in place
    with comments kept and read back (the agent becomes codex); a hand edit turning smooth scrolling off applied
    at once with a typo reported; a syntax error keeping the last good settings; HEED_CONTROL disabling its row.
  - The check also sets 15 pt from the file and presses ⌘+ twice: nvim went from 37 lines to 32, and ⌘0 came back.
  - Terminal panes follow the font (after M9): the grid's family a point smaller (13 beside 12, as before), set
    before the first pane starts libghostty and handed to it after with `ghostty_app_update_config` and
    `ghostty_surface_update_config` for every pane. `SILL_CHECK=1`: ⌘+ twice took a pane's cells from 32 to 37 px,
    ⌘0 back.
  - Sparkle and signing come last, once the owner no longer codes from the phone (owner, 2026-10-24).
- After M9 (owner, 2026-10-24: all four of debugger depth, profiler depth, Razor markup and polish, in that order).
  Debugger depth: breakpoints carry a condition, a hit count or a log message (`:SillBreakpoint if/hits/log`,
  Shift-F9 asks for a condition; ◆ and ◇ signs), function breakpoints (`fn`), and the exceptions that stop the
  program (`:SillDebug exceptions`, user-unhandled by default; the exception shown in the Debug tab from
  `exceptionInfo`). Evaluating: `:SillEval` (the cursor's expression or the selection), `:SillWatch` (evaluated at
  every pause), and the value of the expression the pointer rests on while paused (`HoverExpression`: the identifier
  with the member accesses before it), in a popover, so no key is taken. `:SillDebug attach` lists .NET processes by
  their diagnostics socket (`$TMPDIR/dotnet-diagnostic-<pid>-…-socket`, as dotnet's tools find them) and attaches;
  Shift-F5 detaches and leaves it running.
  - `SILL_CHECK=debug` in a copy of Tests/SillSidecarTests/Fixtures/Debuggee: the function breakpoint stops in
    Pricing.Total (seed 0); removed, the condition stops line 10 at i == 3; `orders.Count` = 3 by `:SillEval` and the
    hover, a watch `i * 10` = 30, `orders.Nope` says why; a logpoint writes "order 9 for 9" without stopping; the
    handled exception does not stop it, the unhandled ArgumentException does; then the program run on its own is
    attached to, paused in Clock.Tick, and detached, still running. Mutating the condition away fails it.
  - Found on the way: detaching killed the program: the disconnect read whether it was attached after the session
    had already forgotten. The adapter calls a function breakpoint's stop a "breakpoint", and every breakpoint is
    "not processed" until the program loads its code, which is not worth a warning.
- Profiler depth (after M9, 2026-10-24): board 7's CPU over time and board 8's retainer path.
  - CPU over time: the document carries samples per 120 stretches of the run (`timeline`); dragging on the strip
    above the flame graph shows that stretch alone, a click or 0 the whole run. For .NET the sidecar answers
    `profile.within` from the run's snapshot (Passenger's `Snapshot.Within`), kept for the last two runs after they
    end; native documents carry each sample's time and leaf frame, and `ProfileDocument.within` rebuilds the tree
    and hot spots in sill itself.
  - Who keeps them alive: `profile.retainers` answers a type's key retention paths from the last heap snapshot's
    graph (Passenger's `KeyRetentionPaths`), read when the type is selected; the first is shown root to type, and
    the agent's payload says it (`retainer:`).
  - Checked in `SILL_CHECK=m6`: Order is kept by Static reference: OrderCache.orders → List<Order>._items → Order[]
    elements → Order; 25% to 50% of the run is 280 of 1809 samples, and the strip shows the program stopped while
    each heap snapshot was written. `SILL_CHECK=m7`: the first half of the Rust run is 1236 of 2472 samples, the
    Swift one's 1823 of 3628. Unit tests cover a stretch's tree, totals and hot spots.
- Razor markup (after M9, 2026-10-24): plan §5's bridge. Razor, cohosted in Roslyn, sends each file's HTML as
  `razor/updateHtml` (`{ textDocument, checksum, text }`: the file's text with its C# masked, line for line) and asks
  the client what it would ask of HTML, as the request wrapped in `{ textDocument, checksum, request }` (found by
  logging what Roslyn 5.11.0 sends). `sill.razor_html` keeps each file's HTML open as a virtual
  `…razor__virtual.html` document in vscode-html-language-server (CSS and JavaScript in it included), started
  without a buffer (`vim.lsp.start{…}, { attach = false }`) the first time a Razor file's HTML comes, with the
  command sill provisions for .html files (`servers.want`). A question waits for the HTML at its checksum, then goes
  to the HTML server about the virtual document; nvim runs a server's request in a coroutine, so the handler yields
  for the answer without holding nvim. Without an HTML server Razor's questions get empty answers, as before. A
  hover's inline SVG (a browser-support badge) is left out.
  - `SILL_CHECK=razor`: `<h1>`'s hover says "The h1 element represents a section heading.", completion offers `div`
    beside `PageTitle`, and `color` in a `<style>`. With the bridge taken out it fails.
- Direction (owner, 2026-10-24): sill is a capable editor that augments agentic coding, not a full IDE: people stay
  in the agent session and use sill to open, browse and understand code. Queue: islands and zen; the agent driving
  the debugger and profiler over MCP, seen live, with profile comparison; review mode; walkthroughs (a file DSL, a
  skill that writes it, MCP to drive it); then following the agent, references from sessions, ask about a
  selection, a code map, symbol tracing, logs, traces and metrics, a context basket, session replay, PR prep and
  debugging a test. A slim nvim shell app (no title bar, a rounded window) from the same package. Both sill and the
  shell will be public; the owner says when.
- Islands and zen (2026-10-24): JetBrains' islands, a setting on by default. `IslandsView` sits over the editor (under
  the popups): the canvas everywhere, each nvim window's rounded rectangle cleared and floats cleared as they are, so
  nvim's separator columns and rule rows become the gaps whatever the colour scheme; it takes no clicks. The bars
  sit on the canvas and the editor is inset by the gap. `:SillZen` (⌃⌘Z) closes the explorer and panel (and reopens
  what it closed), hides the bars and centres a 100-column island. Checked: `SILL_CHECK=chrome` (zen in and out),
  `SILL_CHECK=settings` (the switch applies at once).
  - The chrome check's zen step timed out about once in five runs. What it reported (2026-10-25: zen on, the sidebar
    open and current) showed the cause: the activity bar's `focus('sidebar')` goes to nvim in a task of its own and
    can land after `:SillZen`, reopening the sidebar. The check now waits for the sidebar to be current first. A
    person would have to click the explorer and enter zen within the same moment; chrome actions sent by
    `Nvim.lua` are not ordered among themselves (as the ⌘-click on a reference and the pane's own focus were not).
- The agent driving the debugger and profiler (2026-10-24): MCP tools `debug_start`, `debug_attach`,
  `debug_breakpoint`, `debug_step`, `debug_state`, `debug_evaluate`, `debug_stop`, `profile_start`,
  `profile_snapshot`, `profile_stop`, `profile_compare`. They drive the same Debugger and Profiler the person sees
  (breakpoints through nvim, so they are signs; the Debug tab and the profile tab as they go, marked as the agent's),
  and a call that runs the program waits until it pauses or ends (`Debugger.settle`) and answers with a summary.
  Starting or attaching asks the person (`debug`, `profile` in `allow`). `ProfileComparison` (SillCore): each
  function's own and total time in milliseconds before and after, and its share of each run, which is what compares
  when the runs were not as long; the Compare tab shows it after a program's second run.
  - `SILL_CHECK=agentdebug` (copies of Debuggee and Sample side by side): the agent's conditional breakpoint as a
    sign, debug_start to i == 5, orders.Count = 5 evaluated (in the Debug tab too), a step, continue to the unhandled
    ArgumentException; profile_start, two snapshots (Order grows, kept by OrderCache), Pricing.Total hot, a second
    run compared with the first. Dropping the condition in the tool fails it.
  - Found on the way: `settle` answered once the program paused but before its frame's variables were read, so
    the agent's answer could lack the locals (one run in the full chain); it now waits for the pause to be read.
- Review mode (2026-10-24): `SillCore.Review` takes a baseline as a git tree of the worktree (untracked files
  in, ignored ones out) through a temporary index copied from the repository's (so it only hashes what changed, and
  the index and history are untouched), lists the files between two trees, parses a file's hunks, and takes a hunk
  back with `git apply -R --recount` (false when the file changed since). `Reviewer` keeps up to twelve baselines
  (when sill opened, when work goes to an agent, after an agent's turn when heed's session here stops working,
  `:SillReview mark`; the same tree is not taken twice, and baselines are taken in the order asked). The review pane: baseline chips,
  files, hunks named by their first changed line with Keep, Take back and Comment; Send review sends the comments
  as one prompt; Return opens the baseline beside the file in nvim's diff.
  - `SILL_CHECK=review`: a.txt's two changes and c.txt since sill opened; Take back restored line 17 in the file; a
    comment on line 3 sent as a review; a turn's end took a baseline. Found on the way: baselines were taken as separate tasks, so a
    slow snapshot could take a later moment's worktree under its own name (one run in the full chain); they are
    now taken in the order asked. Unit tests on a real repository (the index
    unchanged, a log ignored, a hunk taken back twice failing the second time). Dropping `-R` fails them.
- Walkthroughs (2026-10-24; the owner chose: any `*.walk.md`, symbol anchors first with file and lines as the
  fallback, answers written into the file). `SillCore.Walkthrough` parses front matter (`title`, `for`), `##` steps,
  prose, `@code` anchors (`Type.Member`, optionally `lines a-b` of it; a path, optionally `:a-b`) and `@ask`
  questions with their `>` answers, and writes an answer under its question. `sill.walk` finds anchors: a symbol
  through the running servers' `workspace/symbol` (Roslyn's container reads `in Pricing (project …)`), else its
  declaration by `git grep`; the excerpt runs to where its braces close or its indentation ends. The pane shows
  each step with its live code, stale anchors in red, and Ask the agent; the prompt names the walkthrough and the
  question's line, and `walkthrough_answer` writes the answer back. The skill ships in the app's runtime
  (`runtime/skills/sill-walkthrough`), `:SillWalk skill` copies it to `~/.claude/skills`.
  - `SILL_CHECK=walk` (a git copy of Debuggee; CFFIXED_USER_HOME a scratch home): walkthrough_check finds
    Pricing.Total, Clock.Tick and Debuggee.csproj by Roslyn and reports Missing.Thing; walkthrough_open at step 1
    shows Program.cs 20–25; the question went to the agent and walkthrough_answer wrote the answer under it; the
    skill installed. Without a server the text fallback finds the same lines. Found on the way: git grep's
    extended expressions have no `\b` or `\s`. Unit tests for the format and the write-back.
- Following an agent (2026-10-24): `SillCore.FileEvents` (FSEvents, file by file, a quarter second late) less
  .git, build folders, temporary files (an atomic write's `.sb-`, swap and backup files, vim's `4913`) and what git
  ignores (`git check-ignore --stdin` in a batch). `Follower` holds each event half a second so nvim's word of the
  person's own write (`BufWritePost`) lands first, and their write is the file's known content, so it is not
  followed; a changed file is marked in the explorer, and with `:SillFollow` opens in a Follow tab at its first
  changed line (against what sill saw, else git's HEAD). MCP's read_file names what the agent reads.
  - `SILL_CHECK=follow`: a.txt opened at line 15 (from git), then at 3 (from what sill saw), marked in the explorer;
    b.txt written from sill, obj/out.txt and an ignored run.log not followed, c.txt followed. Found on the way: URL's
    symlink resolving takes /private off again (realpath instead), and atomic writes' temporary files. With the
    person's write not recorded, b.txt is followed and the check fails.
- Asking about code (2026-10-24): `:SillAsk` (a range, the question as arguments or asked for) sends the lines with
  their numbers and the question to the agent working here (`AgentBridge.ask`), naming the file and the line to
  answer under; the agent's `annotate` MCP call shows the answer as virtual lines under it (`sill.ask`, its own
  namespace, wrapped to the window), until `:SillAsk clear`. `SILL_CHECK=ask`: the prompt carries Program.cs:20-25
  and the question; the answer shows under line 25 and clears; with the extmark not set the check fails.
- Logs, traces and metrics (2026-10-24, the owner's addition): one EventPipe session from the sidecar
  (`telemetry`, streaming batches a quarter second apart; `telemetry.stop`) with Microsoft-Extensions-Logging's
  FormattedMessage (level, category, message, trace and span ids), DiagnosticSource's `[AS]*/Stop:-…` (every
  ActivitySource's finished activities with ids, name, kind, status, start, duration and tags; the tags arrive as
  one string of `[key, value]` pairs) and System.Diagnostics.Metrics with `Metrics=*` (every Meter, once a second:
  counters' rates, gauges, up-down counters, histograms' percentiles). Found by spiking against the Shop fixture
  (Tests/SillSidecarTests/Fixtures/Shop, a minimal API that calls itself). `TelemetryStore` (SillCore) keeps the
  newest 5000 logs and spans and 600 points a series, groups spans into traces (each after its parent, labelled by
  route or path), and writes logs, the slowest traces and metrics as text for an agent. The pane: Logs (filtered by
  level), Traces (a waterfall), Metrics (the program's own meters first, sparklines). MCP: `telemetry_watch`,
  `telemetry_logs`, `telemetry_traces`, `telemetry_metrics`. .NET only for now; OTLP for others is a later step.
  - `SILL_CHECK=telemetry`: the shop run on its own and watched through MCP; its warnings, its slowest trace with
    price order and order.id, shop.orders and ASP.NET's request duration histogram read back; stop leaves the shop
    running. Without the logging provider it fails. Found on the way: a trace can be read before all of its spans
    are in, and a request under way when the watch begins never has its client span (its activity was made
    before anyone listened), so the check looks among the slowest five, and ASP.NET's graceful shutdown outlived a check (it is killed now).
- Fixtures' restore output (obj/ of Debuggee and Sample) had been committed, with absolute paths of the machine
  that restored them; untracked and ignored since, but still in the history.
- The slim shell (2026-10-24; owner: public later, no title bar by default, rounded like a macOS app). First the
  editor surface moved into a library, `SillEditor` (EditorView, the native command line, completion, messages and
  toasts, Design, EditorFont; the font hands terminal panes their size through a hook), with no change in behaviour
  (the full chain passed). The shell (`Sources/SillShell`, `Sill Shell.app`, bundle id com.mpdreamz.sill.shell for
  now) uses it and nothing else: nvim with the person's config and sill's runtime, a titled window with a
  transparent title bar and its buttons hidden (so macOS rounds and shadows it), moving by an 8-point margin; sill's
  settings file for the font and `[shell] title_bar`. `SILL_SHELL_CHECK=1`: typed text comes back in a grid (each
  window is a grid of its own under multigrid), the buttons hidden but the window titled, a picture with the
  window's corners. Showing the buttons fails it.
  - Found on the way: an Objective-C exception from a write to nvim's closed pipe (the input loop's last request
    racing stop) took the unit tests down once; writes and close now share a lock and the process closes with the
    throwing close.
- Review walkthroughs and notebooks (2026-10-25, owner: "no one does full reviews any more"; examples as isolated
  .NET 10 scripts and the like; throwaway docs; a notebook with an outline). The format gains `base:` (front
  matter), `@diff <path>` (that file's change from the base to the worktree now) and `@example <file>` (a script
  beside the walkthrough). `ScriptRunner` (SillCore) runs one by its language: `dotnet run file.cs` (a file-based
  app; `#:project` reaches the changed code; checked on .NET 10.0.400), node for TypeScript and JavaScript, uv (PEP
  723) or python3, `swift`, cargo's script format through a scratch package on stable, bash. Walkthrough in the
  review pane asks the agent for one in `.git/sill/reviews/<time>/` with both trees, the files and how to write
  examples; walkthrough_check now runs the examples too. The walkthrough pane became a notebook: one scroll, an
  outline that follows it and goes to a section, diffs, code, examples with Run and their output in place. A
  walkthrough inside .git belongs to the worktree around it (git's toplevel does not answer there).
  - `SILL_CHECK=reviewwalk` (a git copy of Tests/SillSidecarTests/Fixtures/Orders): the agent's change to
    Pricing.cs; Walkthrough asks for one with `git diff <base> <now>` and its place in .git; written as the agent
    would, walkthrough_check runs its example (Total(4) = 14, Discounted(4, 10%) = 12.6); the notebook has two
    sections and the outline scrolls to the second. Without the .git rule the diff is missing and it fails.
  - Found on the way: a one-line member's excerpt ran into the next member.
- SharpLsp spike (2026-10-25; owner: "sharplsp as the backend for dotnet. Spike."). github.com/Nimblesite/SharpLsp,
  MIT: a Rust host (`sharplsp`, stdio LSP, signed ad hoc) with a C# sidecar (Roslyn) and an F# sidecar (FCS);
  releases every day or two (v0.30.0, 2026-10-20), a macOS arm64 archive of 50 MB checked against SHA256SUMS;
  needs a .NET 10 SDK. Started from nvim headless with `init_options = { solutionPicker = false }`:
  - Debuggee (one project): ready at once (37 ms), a semantic error (`Totl`) reported in 2.8 s, completion 199 ms
    with Total, hover 12 ms, definition 5 ms. Capabilities include call hierarchy, code lens, inlay hints, linked
    editing, implementations.
  - F# (a console app; sill has no F# today): an undefined `prise` reported in 1.8 s, hover
    `val price: seed: int -> float`, 288 completion items.
  - docs-builder (59 projects): 62 to 67 s to a semantic error in an edited file, twice; its log: about 30 s to
    load the solution (Roslyn's server here: 7 to 14 s), the solution loaded two or three times in one session, and
    about 25 s from the edit to its diagnostic. Completion 0.6 to 1.4 s returning 23,382 unfiltered items (Roslyn
    0.15 to 0.27 s).
  - Razor: its own server-side Razor (projection, tag helpers); HTML is the client's, pulled with
    `sharplsp/razor/htmlProjection` and merged with the HTML server's answers client-side, unlike Roslyn's cohosting.
  - .NET 10 file-based apps fully (`#:project`, `#:package`, `#:include`, synthesized projects): review examples
    would get project-level intelligence when opened.
  - Its own debugger and profiler exist too (DEBUGGING-SPEC, PROFILER-SPEC); sill keeps Passenger's for now.
  - Integration would be: download and pin it as Roslyn is now (it is a native binary: downloaded to the cache, not
    bundled, so nothing to sign); `[dotnet] server = "roslyn" | "sharplsp"`; F# files to it; the Razor HTML bridge
    reworked to its pull-and-merge.
  - Why docs-builder is slow (its source, 2026-10-25): the C# side is Roslyn's `MSBuildWorkspace`. A solution
    without F# loads in one `LoadSolutionInfoAsync`; one that lists an .fsproj (docs-builder has build/build.fsproj)
    goes through `RoslynProjectLoading.LoadEachProjectAsync`, a design-time build per C# project, one after another,
    to slot in F# placeholders. The two or three reloads were not traced to a cause.
  - Decision (owner, 2026-10-25): SharpLsp only for F# is too much. C# stays on Roslyn's server; F# comes from
    fsautocomplete. Later, once the ideas list is done: performance work on SharpLsp upstream, and SharpLsp as the
    single .NET server (C#, F#, Razor, navigation across C# and F#) is still worth pursuing.
- F# (2026-10-25): fsautocomplete beside the other servers (`servers.lua`, `LanguageServers`): the person's on the
  PATH (mise's here), else `dotnet tool install fsautocomplete --tool-path` at 0.86.0 into sill's cache (run from the
  cache: a project's global.json may pin an absent SDK). Its root is the nearest .fsproj or solution; it is started
  with `init_options = { AutomaticWorkspaceInit = true }`, without which it waits for the client to pick a
  workspace and answers nothing. Checked: `SILL_CHECK=servers` with fsharp/ in the Polyglot fixture (symbols in
  2 s, the type error on line 5), once through the cache install with the PATH lookup hidden; without the init
  option the check fails.
- File references from sessions (2026-10-25): ⌘-click on a path in a terminal pane opens it in the editor at its
  line. `SillCore.FileReference.find(in:at:directory:root:)` reads the clicked row for the forms agents, compilers
  and stack traces print (`path:line[:col]`, `path(line,col)`, `path#Lline`, `:line N`, Python's `File "…", line
  N`, a bare path) and keeps only files that exist, from the shell's folder (Ghostty's PWD action, OSC 7), then the
  project. `GhosttySurfaceView.row(at:)` maps the click to a cell inside the pane's padding and reads that row from
  the viewport text, walking soft-wrapped lines (a selection starting at an exact point reads nothing in this
  libghostty). The click does not focus the pane when it opens something: the pane's own `set_current_win` raced
  the open. `action_cb` now handles OPEN_URL (`file://` in sill, the rest through NSWorkspace) and PWD.
  - Checked: `SILL_CHECK=refs` (a shell prints `src/a.txt:7`; a ⌘-click opens a.txt at line 7, the keyboard back
    with nvim), three runs in a row. Tests in `FileReferenceTests`; mutations (folder order, the trailing-dot trim,
    folders counting as files, the click position, `(l,c)` columns, `:line`, the row's padding) all fail them.
  - From other apps: `sill://open?path=…&line=…&column=…` (CFBundleURLTypes) and files (CFBundleDocumentTypes,
    text and source code, rank Alternate so sill never becomes the default) reach `application(_:open:)`;
    `FileReference(url:)` reads them (absolute paths only). Until nvim is up they wait; a cold launch from `/` starts
    in the first file's repository. Files AppKit hands over from the command line are skipped (nvim opens those,
    and git's merge files must not open as files). The refs check calls the handler with both.
  - Not checked: Ghostty's own ⌘-click on a plain URL (OPEN_URL; an OSC 8 link is, see below); wide characters before a path shift
    the column; a real `open sill://…` through LaunchServices (that registers the build with the system), and the
    cold launch.
  - Next, in heed (its own repo, the owner's call): ⌘-click on a reference in a heed session could hand it to sill
    through the link.
- The code map (2026-10-25): `SillCore.CodeMap.build(root:)` from `git ls-files` and the last 2,000 commits' names
  (no language server, so a second for docs-builder's 60 projects and 3,597 files). Projects: `*.csproj`/`.fsproj`
  (`ProjectReference`s; web is `Sdk.Web` only, a Razor class library is a library; tests by `IsTestProject`, test
  packages, a test-ish name or a `tests/` folder, since packages often come from Directory.Build.props), a Swift
  package's targets (bracket depth tells a target from a `.target(name:)` dependency), Cargo, package.json,
  pyproject. A file belongs to the deepest project folder, a project file over a manifest in the same folder; a
  project left with no files is dropped. Entry points by regex per language; hot files are the three source files
  changed most. `layers`: each project above what it references, tests last (on top they filled docs-builder's
  first screen). `:SillMap` pane (`CodeMapView`): cards in rows, lines down to what each references (tests' lines
  only when selected), tests as chips; clicks open; `s` asks the agent for a summary (`code_map_summary` puts it on
  top and keeps it in `.git/sill/map/summary.md`), `w` for a codebase walkthrough in `.git/sill/map/tour.walk.md`.
  MCP: `code_map` (the text form), `code_map_summary`.
  - Checked: `CodeMapTests` (mutations of every rule above fail them), `SILL_CHECK=map` on the MapShop fixture with
    git history (rows, a click on the hot file opens it, the ask's prompt, both tools, the summary kept); a mutation
    of the hot-file link fails it. Looked at on docs-builder.
  - Not checked: `w`'s walkthrough end to end with a real agent; maps whose layers are wider than the pane read
    left to right without horizontal scrolling.
- Trace a symbol (2026-10-25): `sill.trace` asks the language server for `textDocument/prepareCallHierarchy` and
  `callHierarchy/incomingCalls`/`outgoingCalls` with `client:request`, keeping the items in Lua by number (Roslyn's
  carry opaque `data`) and stashing each answer for sill to `take`, so nvim never waits on a server; `Tracer` polls.
  `SillCore.TraceTree`: levels as they are asked, sorted by file and call line, a symbol among its own ancestors
  marked recursive and never asked, `unasked(within:)` for a deeper trace, `text` for an agent. `:SillTrace
  [callers|callees]` at the cursor, the trace pane (`TraceView`: l/h, ↵ opens a caller at its call line, d turns
  it, e asks the agent to explain the path root to row with each step's first lines), MCP `trace_symbol` (a symbol
  found as walkthrough anchors are, or a path and line; depth 1 to 6, at most 200 nodes).
  - Roslyn names items `Tax.Of(decimal)` with the type as detail; its callees are what is in source (a constant
    used, not `Math.Round`). A trace asked before Roslyn has the project is retried while no server answers; the
    check retries `:SillTrace` until callers come (2.6 s from opening).
  - Checked: `TraceTreeTests` (mutations of sorting, the recursion guard, opening the unasked, the depth limit, the
    text all fail them), `SILL_CHECK=trace` on the restored TraceShop fixture; opening a caller at its declaration
    instead of its call fails it.
  - Not checked: other languages' servers (rust-analyzer, sourcekit-lsp and TypeScript have call hierarchy too),
    and very wide trees (no limit on a level's size in the pane).
- `.sill/` (2026-10-25, owner): what sill keeps per repository lives in `.sill/` at its root, not `.git/sill`:
  review walkthroughs (`.sill/reviews/<time>/`), the code map's summary and tour (`.sill/map/`), and baskets next.
  `SillCore.SillFolder.path(for:)` makes it and adds `/.sill/` to the git common dir's `info/exclude` (never committed,
  every worktree), once; what `.git/sill` held moves over the first time. Review snapshots (`git add -A` through a
  temporary index) and agents' diffs never see it; the follower skips it; walkthroughs in it resolve against the
  folder around it, and `:SillWalk` lists them by glob (git does not). An example's `#:project` is four folders up
  now. Checked: `SillFolderTests` (git status sees nothing of it, the exclude line once, the move), the map check
  (git status clean after the summary is kept), reviewwalk (the walkthrough in .sill, its example builds), walk.
- Context baskets (2026-10-25, owner: a private .sill folder, several baskets, notebooks with an outline or a
  filtered file tree; sending one closes it). A basket is a `.sill/baskets/<slug>.basket.md` in the walkthrough
  format: front matter `title`, `question`, `by`, `status` (open, sent, concluded); `@code` anchors carry a
  fingerprint (`#` and seven hex digits of the SHA-256 of their lines when added), `@trace Symbol callers|callees N`
  embeds a call tree (`Tracer.text`, built apart from the trace pane). `SillCore.BasketFile` edits the text: a piece
  under its section (made before Findings), its note as the prose above it; a file range touching or overlapping one
  already in the basket joins it, the fingerprint renewed; removing takes the note; `concluding` replaces Findings and
  sets the status. `Baskets` (the app) keeps the current basket in `.sill/baskets/.current`; `:SillBasket add` takes
  the buffer's lines for the fingerprint (unsaved edits count), stays in the editor and says what it added; send
  reads the code now, marks pieces changed since added (`Walker.moved`), sets `sent`, clears current, and asks for
  `basket_conclude`. The notebook is `WalkView(basket: true)` on a second `Walker` (pane `basket`): status and
  question on top, Remove on each piece, Tab for the files menu (folders, pieces per file, a mark on changed ones; a
  click scrolls to the file's first piece). `b` in the trace pane adds the node's code with how it calls.
  - Checked: `BasketFileTests` (mutations of joining, the renewed fingerprint, the note's removal, section order,
    concluding, fingerprint parsing, callees all fail them), `SILL_CHECK=basket` on a git copy of TraceShop (new,
    add and join, whole file, from the trace, the files menu, a change on disk marked, remove, send, conclude, the
    next piece in a new basket, git clean); inverting the change detection fails it.
  - Found on the way: adding switched to the basket's tab each time, away from the code being read; it no longer
    does.
- Investigations (2026-10-25, owner: skills for agents to run an investigation through sill and make baskets on
  their own). `runtime/skills/sill-investigate/SKILL.md`: read-only; `basket_create` with the title and question, orient
  (`code_map`, `trace_symbol`), `basket_add` each place with a note on why in sections, what was ruled out, the
  debugger/profiler/telemetry tools when reading is not enough (each asks first), a reproducing `@example`, and
  `basket_conclude` (answer, certainty, open, next steps). MCP: `basket_create` (by the agent's name), `basket_add` (a
  symbol, or a path with or without lines; an agent's adds are not announced in nvim), `basket_note` (prose, `@trace`,
  `@example`), `basket_list`, `basket_read` (the code and trees as they are now). `:SillInvestigate <question>` asks
  the agent with the skill's steps in the prompt (it works before the skill is installed); `:SillInvestigate skill`
  installs it into ~/.claude/skills, as `:SillWalk skill` does, only when asked.
  - Checked: `SILL_CHECK=investigate` (the ask, every tool as an agent calls them, the notebook's sections, tree,
    files and findings, the skill installed into a scratch home); a basket lookup that ignores the name fails it.
  - Not checked: a real agent running an investigation end to end.
- Keys and discoverability (2026-10-25, owner: "Do these commands have short bindings? Also make these
  discoverable"). Only `<leader>a` had a key. The understanding commands now have keys under `<leader>i` (free in the
  owner's LazyVim, checked by dumping its leader maps: s, f, g, b, c, x, q, u are taken), from `sill.keys`, each set
  only where `maparg` is empty, a which-key group "sill: understand". The menu bar's Code menu (`CodeMenu`) lists
  them with ⇧⌘ keys for five (B basket, H who calls, I investigate, M map) and the nvim key and command as each
  item's tooltip; the right-click menu adds Add to basket, Ask about this, Who calls this, What this calls.
  `basket_add_here` and `ask_here` take a Visual selection's lines. Checked in the basket check (all twelve keys set,
  every key the menu names exists, ⇧⌘B's item adds a Visual selection's lines); ignoring the selection fails it.
- One `.sill` for the repository (2026-10-25, owner: "Everything resolves the same to root dir"): like `.git`, at
  the main worktree's root (the folder around the common git dir; a bare repository's worktrees keep their own),
  whichever worktree sill is open on. A worktree's own `.sill` from before merges in entry by entry, nothing
  overwritten (what would be is left where it was). What is in it resolves against the worktree sill is open on:
  `walk.resolve` takes that root for files in .sill, `Walker.root`, the notebook's files, baskets' anchors; a path in
  another worktree of the repository is stored from its root (`SillFolder.relative`, from `git worktree list`). New
  baskets record `worktree` and `commit`. Review examples and investigation scripts reach the code by absolute paths
  in the worktree, since their folder is shared (a relative `#:project` would build the main worktree's code).
  Checked: `SillFolderTests` (both worktrees resolve to one, the merge, the relative paths, git clean in the
  feature worktree), the investigate check (a file added from a second worktree is stored relative and read here),
  reviewwalk (absolute `#:project`).
- Basket context (2026-10-25, owner: collect metadata as pieces go in, in a separate file: "human readable is a
  feature too"). `SillCore.BasketContext`, kept as `<name>.basket.context.json` by anchor: project and kind (the code
  map), symbol, signature and summary (the first sentence of the hover's prose), tests (references in test projects'
  folders, named by the symbol around each), the lines' history (`git log -L a,b:file -s`: count and the newest), and
  diagnostics in range. `sill.context` asks the language server without making nvim wait (documentSymbol, hover,
  references, documentSymbol per test file); `Baskets.collectMissing` runs after every read of the basket shown, for
  pieces of any origin, saving as it goes and forgetting anchors no longer in the basket; `basket_add` waits for the
  piece's context and answers with it; `basket_read` includes it. The notebook: chips after each piece's heading,
  `i` for its details, a third left menu (Context: projects, tests, who changed it last; Tab cycles). TraceShop has a
  test project now (`ReportTests.Prints` calls `Report.Print`; a `.slnx` so Roslyn loads both).
  - Checked: `BasketContextTests` (history, hover, chips by day, the agent's lines, the overview, the file; mutations
    of each fail them), the basket check (Pricing.cs:3-7: TraceShop, Total, one change "base"; the file beside, the
    basket without it; chips, the Context menu, `i`), the investigate check (`basket_add` of Report.cs answers that
    `Prints` reaches it); not saving the context fails the basket check.
  - Not yet: the agent's summary of a basket on request.
- Notebook cells (2026-10-25, owner: "The notepads should look more like a code pane. With reference cells clear
  boundaries."). Walkthroughs, reviews and baskets draw each reference as a cell on the canvas: a header strip (the
  path from the worktree's root and lines, the facts, the actions on the right), the code on the editor's ground with
  a line-number gutter and its rule, a footer inside the same 1 pt border for a piece's details and an example's
  output, a modified-coloured border on a piece changed since it was added, a diff's added and removed rows tinted
  across. Looked at in the basket and review walkthrough screenshots; the checks drive the same actions.
  - Monospaced throughout (owner: "Monospace font the whole thing. Different sizes and colors is fine"): the
    notebook's text is the editor's font at each size, bold from semibold up (`WalkView.font`); `code spans` keep
    their colour to stand out.
  - Also: a basket piece's context collected after the piece had changed (lines joined) was saved under its old
    anchor, counting it twice in the Context menu; it is dropped now. The basket check waits for exactly the
    basket's pieces, but the race clears on the next read, so removing the guard does not fail it reliably.
- Agent hooks, first step (2026-10-25, owner: "Love it, project local option"; plan start and end asked for). Read
  against Claude Code's hooks reference: about 30 events; tool events take matchers; `permission_mode` (`plan` while
  planning) is on many events, and no event marks entering plan mode; `ExitPlanMode`'s PreToolUse has the plan
  (injected `plan`, `planFilePath`), its PostToolUse the approved one (`tool_response.plan`). `SillAgent.HookServer`:
  a socket per worktree (`$TMPDIR/sill-hooks-<fingerprint of the root>.sock`), one event per connection, answered
  within 1.5 s or not at all; the hook command is `{ tr -d '\n'; echo; } | nc -U -w 2 <socket> || true`, so an
  absent sill costs nothing. `Hooks`: UserPromptSubmit is a baseline ("prompt: …"), Stop another ("turn ended");
  PostToolUse of Edit/Write/MultiEdit/NotebookEdit goes to the follower as the agent's; planning starts at the first
  event in plan mode and ends at one in another; ExitPlanMode presented writes `.sill/plans/<time>-<title>.plan.md`
  (`SillCore.PlanFile`: the plan, its files as `@code` cells) and shows it, approved sets its status and a baseline
  that joins the last one's name when nothing changed (`Reviewer.mark(joining:)`); each event is a line in
  `.sill/sessions/<id>.jsonl`. Installed with `--settings` for the agents sill starts and `:SillHooks
  install|remove|status` (`HookSettings`: beside the person's own hooks, recognised by the socket name; the file
  backed up once as `.before-sill`; both kept out of git).
  - Checked: `HookServerTests` (the real command through sh, a pretty-printed event, no sill), `PlanFileTests`
    (the notebook, /private paths, installing and removing beside the person's settings), `SILL_CHECK=hooks` (the
    installed command for a prompt in plan mode, the plan presented and approved, an edit, the turn's end; the log;
    `--settings`; remove); not noticing planning, and matching only one spelling of the root, fail them.
  - Not checked: a real Claude Code session (the events are built from its reference), what a rejected plan sends,
    and an `EnterPlanMode` tool call. Not built: approving a plan from sill (not asked for). Next: the investigation
    guards (edits denied while one is open, no stop before its findings), editor context on prompts.
- Investigation guards, soft (2026-10-25, owner took my pick over blocking): blocking edits would also stop a log
  line or a quick experiment, and blocking a stop can loop an agent that is stuck or was interrupted. So while an
  investigation is open (`Baskets.investigating`, from basket_create until basket_conclude): a PreToolUse of an
  editing tool answers with `additionalContext` reminding that it is read-only (no permission decision), its
  PostToolUse notes the edit under "Edits made while investigating" and tells the person; Stop with the basket still
  open marks it `stopped` and says so, and `f` in the basket asks the agent for findings. Checked in the hooks check
  (the reminder in the hook's answer, the note, stopped, `f`'s prompt, nothing once concluded); not marking stopped
  fails it. The check runs hooks off the main thread now: sill answers on it, so a check waiting there got no answer.
- Hooks against real Claude Code (2.1.306, 2026-10-25, owner's go-ahead; two `claude -p --model haiku` runs in a
  scratch copy of TraceShop, with a capture-only hook on ten events). Confirmed: UserPromptSubmit has `prompt` and
  `permission_mode`; Edit's `tool_input.file_path` is absolute (`/private/tmp/…`); `permission_mode` is on every
  event but SessionStart and SessionEnd; Stop has `last_assistant_message` (for session replay). In plan mode the
  agent writes its plan with the Write tool to `~/.claude/plans/<name>.md` before presenting it: sill followed that
  as an edit. Now a Write or Edit to a `.claude/plans/*.md` shows the plan as a drafting notebook (one per session,
  presented and approved in the same file), and edits outside the worktree are not followed (compared through
  realpath). `ExitPlanMode` is not available in `-p` runs, so a presented, approved or rejected plan was not seen
  for real; sill's own install was also written before git ignored it, and the follower took its backup for a change
  (it is excluded first now). Checked in the hooks check (the draft, then presented into the same notebook; the plan
  file and another file outside not followed); not guarding outside paths fails it.
- A deep look with the owner's LazyVim on docs-builder (2026-10-25, after "Right now the app doesn't spark joy").
  `SILL_PROBE=<script>` runs sill as the person does (their nvim config, offscreen) through steps (`wait`, `cmd`,
  `lua`, `keys`, `menu`, `shot`, `state`, `messages`, each timed). Found: LazyVim's own UI beside sill's (dashboard,
  snacks explorer, noice, bufferline-like rows), tokyonight repainting the editor inside sill's neutral chrome, tool
  panes as tab pages that stay in the strip, eight panes with eight headers, IDE features in the front door. Not a
  defect after all: Roslyn shows a file's errors on open (checked with an error on disk, before and after; the m3
  check now opens such a file); an edit inside a primary constructor's parameter list cascades into hundreds of
  errors, and docs-builder's style rules are errors by its own `.editorconfig` with `EnforceCodeStyleInBuild`. Not
  reproduced here: the owner's M5 not building docs-builder or showing its problems, and Packages freezing (here it
  took over a minute, restoring first, but stayed responsive). The docs-builder check runs in a clone of its own now
  (it had left an empty `.sill` and two exclude lines in the owner's working copy; removed).
- sill's own nvim by default (2026-10-25, owner: "Go" on making sill opinionated). `[nvim] config` defaults to
  `sill` now: nvim runs as `sill` with `sill.base` and `sill.config` (`--cmd`), and `~/.config/sill/init.lua` after
  them for the person's additions. `sill.config` uses only what nvim 0.12 has: completion from language servers with
  `vim.lsp.completion` (autotrigger) in the native popupmenu, `findfunc` fuzzy over `git ls-files` (cached until a
  write or focus), `rg` for `:grep`, diagnostics underlined with `virtual_lines` for the cursor's line, a few keys,
  and `colors/sill.lua`: Design.swift's palette for the editor, syntax, Tree-sitter and LSP semantic groups,
  diagnostics, diff, floats and the terminal (no generator yet: the hexes are copied, as the 12 in init.lua were).
  `config = "yours"` gets `sill.compat` after VimEnter (and 300 ms later): noice disabled, `vim.notify` back to
  nvim's (kept by base.lua before plugins replace it), snacks' notifier and folder takeover off, start screens and
  explorer windows closed; `vim.g.sill` tells a config it runs inside sill. Checks stay bare unless one asks
  (`SILL_CHECK_CONFIG=1`, `SILL_CHECK_USER=1`). Checked: `SILL_CHECK=config` (the colours, `:find`, the problems'
  layout, `Tax.` offering Of from Roslyn in the native menu), `SILL_CHECK=compat` (a stand-in config with a start
  screen and its own notify: both undone, the config loaded and told); not closing start screens fails it. A wrong
  `fillchars` (two glyphs lost) made the whole config fail to load: found by the check.
- The front door (2026-10-25, step 3 of the deep look): the activity bar is what sill is for. Explorer, Changes
  (source control) and Agents switch the sidebar; under a rule, Map, Baskets and Review open their panes, and the
  icon of the pane showing is lit (nvim's current window's kind). Packages and the Profiler's placeholder left the
  bar; the title bar lost Run. The Project menu has them instead: Build (⌘B), Run (⌘R), then Debug, Profile,
  Packages, Telemetry and Terminal. The bottom panel shows Problems and Output, and Debug once a debug session has
  used it; the Tests placeholder is gone, and no empty text names a milestone. Checked in the chrome check (the map
  from the bar, its icon lit, the editor after); not lighting the icon fails it.
- One pane scaffold (2026-10-25, step 4 of the deep look). Tool panes (the map, a trace, the review, the profiler,
  the packages, telemetry, a walkthrough, a basket) open in place of the code in the last editor window, not as tab
  pages: `show_pane` keeps what the window showed and its options, `q` (`close_pane`) puts them back, and another tool
  pane there is swapped, not stacked; the sidebar and the panel stay. So the tab strip no longer names a pane its own
  header names again. Their headers are one (`PaneBar`): a 44-point strip with the title, what it shows cut to fit
  (it ran under the keys in a narrow window), and the actions at the right; their keys are one footer strip, ending
  in `q back`; telemetry's and the profiler's tabs are one row. The chrome is in the UI font, code and data in the
  editor's (`EditorFont.font`, which replaced SF Mono in the packages and the profiler). The walkthrough and basket
  notebook keeps its own top: it is a document, monospaced throughout. The colour scheme's palette is held to
  Design.swift's by a test (`ColorSchemeTests`), not generated. Checked in the chrome check (the map in place, not in
  a tab page, and q back to the code); a pane opened as a tab page fails it, and so does a scheme hex changed.
- Editor context on prompts (2026-10-25, the hooks' next step). A UserPromptSubmit hook is answered with
  `additionalContext`: the file and line of the last editor window, the selection (the one still in visual mode, as
  when the person types into the agent's pane beside it, else the last one made, within ten minutes, kept by a
  ModeChanged autocmd), and the basket open; paths relative to the worktree, a selection cut at 60 lines.
  `EditorContext` (SillCore) tells only what changed since what the session was told last, so an unchanged view adds
  nothing to the conversation. `[agents] editor_context` (on by default, a switch in the settings window) turns it
  off. Checked in the hooks check (Tax.cs:3-5 selected: told with the file; the same again: nothing) and
  `EditorContextTests`; forgetting what was told fails the check. `:normal!` ends visual mode without ModeChanged, so
  the check selects with `nvim_input`. Not yet seen in a real Claude Code session: that the context reaches the model
  is Claude Code's documented behaviour, not checked here.
- OSC 8 links in terminal panes (2026-10-25, the experiment after editor context). A link an agent or tool prints
  (`ESC ] 8 ; ; file:///…/a.txt#L3 BEL the rounding ESC ] 8 ; ; BEL`), whose text is no path, opens in the editor
  on ⌘-click: sill's own row reading finds no file in "the rounding", so the click goes to Ghostty, whose press and
  release each report the position with ⌘ (the pane tracks no hovering, and needs none), so it finds the link and
  hands its URL to OPEN_URL; a `file://` URL opens in sill with its line from a `#L<n>` fragment. Checked in the refs
  check, by a click alone (no move first); ignoring the fragment fails it. Found on the way: fish reads `\\` in
  single quotes as one backslash, so the check ends the sequences with BEL; and a long command line wraps, so the
  link's screen row is found through the pane's own row reading. Not done: a pointing hand over a link (Ghostty's
  MOUSE_SHAPE needs hover events the pane does not track), and the URL shown on hover (MOUSE_OVER_LINK).
- Code opened from a pane opens beside it (2026-10-25, a regression of panes in place). The map, a trace, a notebook
  and the packages opened code with `tabprevious` then `open`, from when they were tab pages: with the pane in place,
  that replaced the pane, or with tab pages of the person's own went to the wrong one. `open_beside` opens in another
  editor window of the tab page (the last used first), else in a new one to the right of the pane with the code's
  window options; the pane stays. Checked by the replay's step (below); `open` in its place fails it.
- Session replay (2026-10-25). Each session's log now also keeps the worktree's tree at each prompt and each turn's
  end (`{"tree":…, "of":"UserPromptSubmit"|"Stop"}`, from the review baselines `Reviewer.mark` takes, handed back by
  a `then`). `SessionLog` (SillCore) reads a log into turns: the prompt, the mode, the steps (the tool and its file,
  command or pattern; a plan presented and approved), the end, and the two trees; tools before any prompt are a turn
  without one, and events after a turn's end with no new prompt stay in it. `:SillReplay [session]` (`␣ih`, the Code
  menu) picks or opens one; the replay pane lists the turns, the selected one's steps, and its changes between its
  trees (a turn not ended: to the next turn's start, else the worktree now), file by file with the diff; `↵` opens
  a file beside it. Trees are unreferenced, so git prunes them after two weeks: the replay says so. Checked in the
  hooks check (the first session: one planned turn, its steps, its change to Pricing.cs, the file opened beside the
  replay) and `SessionLogTests`; not handing the tree back fails it. Not done: stepping through a turn edit by edit
  (the log has no content per edit), and replaying sessions from before trees were logged.
- The branch's pull request (2026-10-25, owner: "agents typically commit and PR … identify the PRs from the worktree
  and offer the agent more insights and the user"). `PullRequests` runs `gh pr list --head <branch> --state all --json
  …` (with the login shell's environment; `SILL_GH` for a stand-in) and reads the branch with git: commits not pushed
  (`@{upstream}..HEAD`), behind the base (`HEAD..origin/<base>`, as of the last fetch), files not committed.
  `PullRequest` (SillCore) parses gh's JSON (check runs and commit statuses, latest reviews, comments) and turns it
  into insights, most pressing first: attention (checks failing, changes requested, conflicting, not pushed), waiting
  (checks running, a review required, a draft, behind, uncommitted), fine (approved, checks passed, merged). The
  person: the status bar beside the branch (its colour the most pressing level), a click or `:SillPR` (`␣ip`, the Code
  menu) opens the PR pane (Now, Checks, Reviews and comments, Here; Send to agent, Open on GitHub). The agent: the
  `pull_request` tool reads it now; `EditorContext` tells the next prompt the pressing part when it changed. Read at
  start, on activation, every two minutes while active, and 8 s after an agent's turn ends; checks read only a
  stand-in. Checked: `SILL_CHECK=pr` (pr-fixture.sh: a branch with one commit pushed to a local remote and one not, a
  stand-in gh logging its arguments) and `PullRequestTests`; ignoring unpushed commits fails it. Found on the way:
  with no file open the editor context was an empty Lua table, which comes as an array, so the prompt was told
  nothing at all (the basket included); and a crash left macOS's "reopen windows?" alert blocking every later start
  of sill, so sill registers `ApplePersistenceIgnoreState` (it restores no windows).
- From the pull request to a review and a walkthrough (2026-10-25, owner: "e.g. walkthrough from pr, review PR").
  The PR pane's Review (`v`) pins a baseline at where the branch left its base (`git merge-base HEAD origin/<base>`,
  the local base when origin's is not fetched, as a tree) and opens the Review pane on it; Walkthrough (`w`) pins the
  same and asks for the review walkthrough. A pinned baseline stays first and is never dropped for newer ones (the
  twelve kept are the newest of the rest); a new pin replaces it. `askForWalkthrough` now reads the files between the
  baseline and the worktree itself rather than the pane's last list. Checked in the PR check (a.txt +2 against main,
  pinned; the walkthrough's prompt); comparing with HEAD instead of the merge base fails it.
- Perceived performance on docs-builder (2026-10-26, owner: "perceived performance is key … it needs to be fast
  and non blocking"). Measured with probes on an M2 (60 projects, 3,597 files): the main thread watched by phase
  (`phase`, `stalls`), how long until something is ready (`until`), memory (`rss`, its `ps` now off the main thread:
  run on it, the probe's own wait was the "open" and "scroll" stalls it reported), and a pane's draw (`draw`, ten forced
  draws). Found and fixed: the code map drew every card and line, scrolled out of view or not (11.3 ms a draw, 5.2 ms
  now it draws what is visible); Roslyn started only when a C# file opened, 15 s before its features answered: with a
  solution at the root of the folder sill opened it starts with sill now (`roslyn.prestart`, `vim.lsp.start` without
  a buffer), and the first C# file reuses it (ready on open after 20 s of looking around). Two runs after: no stall
  over 50 ms in one, one of 76 ms (the map's first draw) in the other; scrolling, typing, review and idle 2 ms p99 or
  under. Left: Roslyn's first call hierarchy (a trace) takes 6 s, its own; and it uses 0.6 to 1.3 GB, now also when
  no C# file is opened. Checked: the m3 check (Roslyn started for Orders.slnx before any C# file opens, the file
  reusing it); not starting it ahead fails it.
- Build, packages, and the owner's large pull requests on docs-builder (2026-10-26). Build: a cold `dotnet build`
  (145 to 195 s on the M2) stalled the main thread for seconds; a sample showed AppKit saving window state for
  restoration, waiting on the disk the build kept busy (windows are not restorable now). The stalls left are the
  machine's (the main thread idle in the samples, waiting to be scheduled, with 12 GB swapped and the compiler server
  at 2.7 GB); running the build at utility QoS did not change them and was not kept. Packages: 72 s before anything
  showed; now the SDK's list shows first (9.5 s), newer versions next, advisories and deprecations last (asked after
  the listing: at the same time they slowed it threefold), the last answers are kept in `.sill/packages` and shown
  at once (0.7 s), and JSON is read off the main thread. Drawing: fonts were looked up by name for every string
  drawn, and one-line strings laid out to truncate whether they fit or not (packages 50 to 20 ms a draw, the map 5.2
  to 4.0). The owner's pull requests (#4530: 648 files, +59.7k; #4174; the stacked #4179 onto chore/dotnet-11), read
  through a stand-in gh on GitHub's public API, since the owner's gh token is not authorized for the elastic
  organization's single sign-on (sill now says so, and how to authorize it): the review's file list drew all 648
  files (102 ms a draw, 4.2 now that it draws what fits), did not scroll (it follows the selection now, the wheel
  scrolls it, and it says how many are above and below), and cut paths before their file name (the name first now);
  the walkthrough's prompt listed every file (54k characters; folders with their counts and the largest files past
  60 files, 5.6k); the PR pane did not say where a pull request changes things (it outlines its changes against
  where the branch left its base now, and the agent's `pull_request` text does too), listed 47 passed checks one by
  one (counted in a line now), and showed bots' HTML comments (stripped). A stacked pull request's base must be
  fetched; without it the review says to fetch rather than compare with the wrong base. Not done: rename detection
  (the review counts a rename as a delete and an add: 669 files for GitHub's 648), and a pane's first opening costs
  about 250 ms once.
- The pivot (2026-11-02, owner: "sill is the editor you leave running in the background to peek into what agents
  are doing"; the plan agreed in chat): Home over the folders watched, then one sill for many checkouts with the
  agent's story first (summary, walkthrough, review, run; touched files on the left), runnables, the handoff skill,
  since-you-last-looked. Not an orchestrator: agents are working or idle, nothing "needs you".
- Home (phase 1, 2026-11-02). `Checkouts.find` walks the roots (four levels, not into node_modules, bin, obj and the
  like, nor into a checkout) and asks each repository for its worktrees (`git worktree list`, in parallel), wherever
  they are. `CheckoutState.read`: the branch, the changes (`git --no-optional-locks status`: never git's index lock,
  so an agent never finds git busy because sill looked; `.sill/` not counted), when a changed file was last written,
  the last commit, the agent from Claude Code's transcripts (`~/.claude/projects/<cwd, non-alphanumerics as ->`: the
  newest session's end, 256 KB, working while its last turn has not ended and was written in the last ten minutes;
  the prompt from its `last-prompt` entries, else the person's last message), and the notebooks agents prepared in
  the repository's `.sill` (handoffs, reviews, plans, walkthroughs) for this checkout (`worktree:` in their front
  matter; the main checkout gets those naming none), seen when opened in sill since last written (`.sill/seen.json`,
  written by the walker). Home's window lists them most recently active first with the summary of summaries on top;
  the menu bar item counts the working; a checkout opens in a sill of its own (`SILL_CWD`, and `SILL_WALK` for a
  walkthrough). First paint from a cache (Application Support), then a read in the background, then file events
  (raw: `.git` and `.sill` count) re-reading only the checkout they are in, and the transcripts' folder for the
  agents. Started without a folder (the Dock), sill is Home; `SILL_HOME=1` asks for it. The folders are `[home]
  roots` (`SILL_ROOTS`), asked for on first launch with an open panel. On the owner's machine: 94 checkouts, read in
  2.3 s, at once from the cache. Checked: `SILL_CHECK=home` (home-fixture.sh: a repository with a worktree outside
  the roots, an old one, a handoff and a review walkthrough, a transcript with a turn under way: the order, the agent
  working on "Round the tax once", the summary of summaries, then the turn ending, an edit, a walkthrough seen, each
  followed live) and `CheckoutsTests`; finding no worktrees, or counting a walkthrough seen once ever opened, fails
  them. Not checked: the first launch's questions (modal panels) and the menu bar item's menu, by hand only.
- The check chain moved into the repository (2026-11-02): `mise run verify` (scripts/verify.sh, the fixtures in
  scripts/fixtures). It had lived in /tmp/sill-scripts, and macOS's periodic cleanup deleted it; rebuilt from the
  session's own record of every edit made to it.
- Workspaces (phase 2, 2026-11-02). First, behaviour-identical: what AppDelegate held for the one folder sill opened
  is a `Workspace`; AppDelegate keeps the app's own (settings, Home) and hands it launch, files and quitting (the full
  chain passed before and after). Then many: a checkout opened from Home opens in this sill, in a window of its own
  (cascaded beside the last), or its window comes to the front (on the walkthrough asked for). A workspace opened so
  reads the process's environment without what only the launch means (SILL_CHECK, SILL_PROBE, SILL_SHOWCASE, SILL_CWD,
  SILL_WALK, SILL_HOME). The settings and the grid's font tell every workspace (one listener each in the app, which
  fans out); the menu bar is the window in front's (rebuilt as a window becomes key, Home's too); the MCP config and
  the hooks' settings are named for the checkout as well as the process. With Home, closing a workspace's window (or
  :qa in it) ends that checkout alone, after the question about its unsaved files; quitting asks once for all of them.
  Found on the way: a closed workspace's "nvim exited" ran with `self` gone, and `self?.check == nil` read true, which
  quit sill. Checked in the Home check (open a checkout, again the same window, a second beside it, its window closed,
  :qa in the other, Home stays); the old exit path fails it. Each workspace still starts its own .NET sidecar (66 MB):
  sharing one is next to look at.
- The story first (phase 2, 2026-11-02). `Story` (SillCore): the branch's base (origin's HEAD, else main or master;
  on the base itself what is not pushed), where the branch left it, the files touched since with the worktree as it
  is (`git diff --numstat -M <fork>`, renames followed, new files counted as added, `.sill/` left out), the commits
  since, and the person's prompts from Claude Code's newest session here (text messages, not tools' results or
  commands). A workspace reads it off the main thread when it opens, when its window comes to the front, and after an
  agent's turn (`Stories`). The summary pane (`:SillSummary`, `␣iu`) says it; the explorer has a Touched tab first
  (the file's name, its folder and lines after it) and opens on it in a checkout opened from Home (a folder opened
  directly keeps Files, so its checks are unchanged); the rail is the story (summary, walkthroughs, review) over the
  browsing. Opened from Home, a checkout lands on its newest unseen walkthrough, else its summary; `v` in the summary
  pins where the branch left its base and reviews against it. Home now re-reads every checkout of a repository when
  its `.sill` changes (a walkthrough seen in a worktree is the repository's). Checked in the Home check (alpha-feature
  lands on its handoff, which Home then has seen; beta lands on its summary with a.txt touched and the explorer on
  it) and `StoryTests`; always landing on the summary fails it. Run (phase 3) is not on the rail yet.
- Run (phase 3, 2026-11-02, owner: "Command shift r to pick (and alter) a run configuration"). `Runnables.find` reads
  the files git knows (and new ones): .NET projects by `ProjectFile`'s kind (a program, a run per `launchSettings.json`
  profile of `commandName: Project`; a test project, `dotnet test`; a library, none), `Package.swift`'s
  `executableTarget`s and `testTarget`s, `Cargo.toml`'s `[[bin]]`s (else the package with `src/main.rs`) and its tests,
  `package.json` scripts with pnpm, yarn, bun or npm by lockfile, `mise.toml` tasks and justfile recipes (not
  assignments, defaults with `=` allowed). Debug where sill's debugger is (.NET programs), Profile where its profiler
  is (.NET, Cargo, Swift). `RunConfigurations` keep what was run, its command as changed, one per name and folder,
  the last first, in `.sill/run.json`. The Run pane (`run`, the rail's story group): touched on the branch (its files
  in the runnable's folder), run before, then programs, tests, scripts; ↵ e d p. ⌘R (Project ▸ Run Again) runs the
  last again, a choice the first time; ⇧⌘R (Run…, `:SillRun`) is the choice (`vim.ui.select`: what was run first,
  then the touched, then the rest) and then the command line (`vim.ui.input`, the command as default) to change
  before it runs. It runs as Run did, in a terminal at the bottom (`cd folder &&` when not at the root). A workspace
  opened directly now reads its story at start too (the explorer's Touched tab). Checked: `SILL_CHECK=run`
  (run-fixture.sh, a Swift package with hello: found, run in a terminal, kept; ⇧⌘R picks it and adds " again", run
  and kept so; ⌘R that again) and `RunnablesTests`; running the command as found instead of as changed fails it.
  Also: the probe's `menu` sends an action without a target to the workspace (off screen no window is in front).
- Handoff (phase 4, 2026-11-02, owner: agents always hand off). `HandoffFile` writes one: front matter with
  `status: handoff` and `worktree:`, the summary, "Read in this order" (a why, then `@code path:from-to` per file),
  "Run it" (`@run Name: command`, a new walkthrough block: a name of up to 40 characters before the first colon, no
  `/` or `&`, else the whole line is name and command). The notebook shows a run as a box with Run (into a terminal,
  from the root); `Stories` reads the newest handoff's runs, which the Run pane lists first ("From the agent's
  handoff") and ⇧⌘R first (★). The `sill_handoff` MCP tool takes title, summary, read `[{path, from, to, why}]`, run
  `[{name, command}]` and by, refuses a file not in the checkout, and writes `.sill/handoffs/<stamp>-<slug>.walk.md`.
  The prompt hook tells a session's first prompt how to hand off (the tool, else the file and its format), whether or
  not editor context is on; the text is found once off the main thread, as finding `.sill` asks git six times and
  pushed the hook's answer past its 1.5 s. `runtime/skills/sill-handoff` says the same for any agent; `:SillWalk
  skill` installs it beside the walkthrough skill. Checked: `SILL_CHECK=run` (a missing file refused; the handoff
  written, its run first in the Run pane; opened, its Run prints `sill-run-hello handed`), `SILL_CHECK=hooks` (the
  first prompt told, the second not), `SILL_CHECK=walk` (both skills installed) and `HandoffFileTests`. Telling every
  prompt, dropping the Run pane's handoff section, or a Run cell that does nothing each fail a check.
- Since you last looked (phase 5, 2026-11-02). `Looked` keeps, per checkout in `.sill/looked.json`, the point and
  the last leaving (a time and a worktree tree, as a review baseline). Leaving is sill resigning active (every open
  workspace notes it, off the main thread) or a workspace closing or quitting; coming back (the workspace opening, sill
  active again) makes the leaving the point when it was 300 s or more ago, else drops it, so a glance does not move
  the point under a review. `Stories` reads what is new since (files: the worktree now against the point's tree,
  80 ms on docs-builder off the main thread; prompts and commits after it) and the summary leads with it; the review
  gets "since you last looked" as a lasting baseline (never trimmed, in its place by time), `n` in the summary
  (`V` since the keymaps, below).
  Review by area: 20 files or more in more than one area (`Review.area`, two folders deep, which the prompt outline
  now shares) are listed under area headings, the most changed first, each with its seen count. `SeenFiles` keeps
  marks in `.sill/seen-files.json` with each file's blob (`git ls-tree` of the current tree), so a file changed again
  is not seen; `m` toggles one and goes to the next not seen, `M` marks the area. Checked: `SILL_CHECK=looked`
  (looked-fixture.sh: a leaving an hour ago, 23 files changed in three areas) and `LookedTests`; any leaving moving
  the point, seen ignoring content, never by area, or no baseline offered each fail it. Not done: seen marks in the
  explorer's Touched tab, and Home counting what is new since.
- Renames in the review (2026-11-02, owner's pick). `Review.files` asks git with `-M` and `-z`, so a moved file is one
  `renamed` entry with its old path (docs-builder #4530: 648 files, as GitHub says, where it was 669); its diff is
  against the old path, side by side shows the old file, and taking a hunk back changes the file where it is now (the
  patch's rename header becomes a plain one), not moving it back. The story's touched files carry renames too, and
  replays read their diffs the same way. Checked by `ReviewTests` (a file moved into `docs/` with a space in its name
  and changed: one rename, its hunk taken back in place); without `-M`, or with the rename header kept, it fails.
- One .NET sidecar for the app (2026-11-02, owner's pick). `SharedSidecar` starts it for the first workspace that
  asks (again after a failed start) and stops it when sill quits or a merge or diff tool session ends; closing a
  checkout no longer stops it. Each was 50 to 95 MB, and a second checkout no longer waits for its own to start.
  Roslyn is provisioned through it once (its progress to every workspace asking); each workspace's nvim still starts
  its own Roslyn server. Nothing in the sidecar belongs to a checkout: profiles and telemetry are by run and process,
  Roslyn and dbgshim a shared cache. Checked: `SILL_CHECK=home` (alpha-feature and beta open share one sidecar, one
  dotnet process a child of sill; beta closed, it still runs); a sidecar per workspace, or closing one stopping it,
  each fail it.
- One keymap for sill's own panes (2026-11-11, the clarity review's first step, owner: "Go"). `Keymaps` (SillInput)
  lists every key of every native pane and Home, each a named command (`review.keep`), so a key means one thing
  wherever it means anything; `KeymapTests` holds the grammar (`a` the agent, `r` read again, `x` take away or stop,
  `J`/`K` inside a row …), that no key in a pane is two things or the start of another, and that every name is
  handled somewhere in `Sources/SillApp`. The clashes moved: the review's keep `a` → `y` and send `s` → `a`, the map's
  summary `s` → `a`, the trace's callees `d` → `t` and explain `e` → `a`, the PR's browser `o` → `gB`, telemetry's
  levels `a`/`w`/`e` → `L`, the summary's since-you-looked `n` → `V`, a walkthrough's sections `n`/`p` → `J`/`K` and
  examples `e` → `R`, the basket's send `s` → `a` and findings `f` → `A`, the explorer's tab `s` → `⇥`, top `g` →
  `gg`, refresh `R` → `r`, Home's folders `f` → `F`. `Keyboard` dispatches: a pane's `perform(name, key:)` does the
  command, `g…` goes where the rail goes (a panel lists what can follow; a sequence sill does not finish goes to nvim,
  so `gt` still changes tab), `?` lists the pane's keys, `f` labels what can be clicked (a typed label clicks it, a
  real button pressed as one), `:SillKey <name>` runs a command and `[keys]` in the settings rebinds one (a name that
  is no command is a settings problem). Footers draw the keymap as key caps. Checked: `SILL_CHECK=run` (`?` opens and
  closes, `g` waits and `v` reviews, `gr`, `[keys]` rebinding `gV`, `:SillKey go.run`, hello's Run clicked by its
  hint) and `SILL_CHECK=chrome` (`gg` then `j`); a clash, an unhandled command or a key with two meanings each fail
  `KeymapTests`.
- Tree-sitter and change marks in sill's own nvim (2026-11-11, the clarity review's second step; owner: downloading
  parsers on first launch is fine, and keeps them up to date). nvim 0.12 ships parsers for C, Lua, Vim script, its
  help, queries and Markdown only, so C# and the rest were coloured by syntax files until Roslyn's semantic tokens
  came. `SyntaxParsers` (one for the app) asks git for nvim-treesitter's `main`, takes its tarball, has nvim read
  `parsers.lua` as JSON, plans with `Treesitter.plan` (the wanted languages and what their queries require, nvim's own
  left out), and builds each grammar at its pin with the Command Line Tools' `cc` (Swift's from its newest
  `-with-generated-files` tag, as its parser.c is generated), four at a time, into `~/Library/Caches/sill/treesitter`,
  with nvim-treesitter's queries beside them; 25 parsers in about 15 s here. Checked within the week: nothing asked;
  a new commit rebuilds only parsers whose pin moved; a failed build is tried again next start; without the Command
  Line Tools nothing is asked of `cc` (macOS would offer its installer) and nvim's syntax files stay. Only with sill's
  own config (`config = "yours"` is left alone). `lua/sill/syntax.lua` starts tree-sitter on each buffer with a parser
  (`cs` → `c_sharp` and the like registered). `lua/sill/gutter.lua` marks lines added, changed or removed against the
  branch's merge base with the default branch (HEAD on it), off nvim's loop, `]h`/`[h` between them. Checked:
  `SILL_CHECK=config` with `SILL_CHECK_TREESITTER=1` (the parsers built, C# and Swift among them; `static` in
  Pricing.cs a tree-sitter keyword; a line added on disk marked) and `TreesitterTests`; a plan that skips what queries
  require, or staleness that ignores revisions, fails them.
- Home's clarity pass (2026-11-11, the clarity review's third step: what is the view for, what must one see in a
  second, what must and can one do). For "does anything need me, and where?": a headline that counts the checkouts
  with something new and the agents working; checkouts by repository (`HomeList.groups`, the repository last active
  first), each with one reason (`HomeList.reason`: new, working, done, changed) in its colour and a mark (new filled,
  working haloed blue, done a ring; working shows on a row that also has something new); a week quiet folded under
  "Quiet" (`z`); times as "12 min", "3 h", then the day. At 880 points and wider, the selected checkout at the right:
  its new walkthroughs in their agents' words, chips for what it holds, and its buttons, ↵ the filled one. ↵ opens on
  the newest walkthrough not read, `o` the checkout alone, `m` marks its walkthroughs read (`HomeModel.markSeen`).
  The summary of summaries is now the headline's newest and each row's "New:" line. Checked: `HomeListTests` and
  `SILL_CHECK=home` (`m` marks a second review read; with `markSeen` doing nothing it fails). Not done: the activity
  strip and Home's pull request state, both new reads, to measure first.
- The summary's clarity pass (2026-11-11, the clarity review's third step, second view). For "what happened here
  since I looked, and is it any good?": a headline (`StoryLine.headline`: the walkthrough not read, else what
  happened counted, else the latest walkthrough's title) with verdict chips; at the left the walkthrough to read as
  the one card with its buttons, the others under it, and the session as a line (`StoryLine.place`: prompts, commits
  and the last look by time, a day at most); at the right the handoff's runs (`R`, with when each last ran from
  `.sill/run.json`) and the touched files by folder with churn bars. `↵` reads the walkthrough not read, else reviews
  since you looked, else the branch. Checked: `StoryLineTests` and `SILL_CHECK=run` (the summary on the handoff, its
  walkthrough, review and run clickable); `SILL_CHECK_SHOTS=<folder>` saves pictures of it there and in
  `SILL_CHECK=looked`. Not done: hiding the Problems panel on story views while it is empty, a run's result (its exit
  code is not kept yet) and the pull request's state among the verdicts.
- The review's clarity pass (2026-11-12, the clarity review's third step, third view). For "decide on each change,
  and know how much is left": the files seen of all as a bar at the top right with what was kept and what is to be
  sent; by area, each heading with its own bar, and an area all seen folded to its heading (unless the file read is
  in it); each hunk named by git's function context (`Review.Hunk.context`, after the header's second `@@`) before
  its line; the hunk's buttons with their keys; the send button says how many comments, or that there are none.
  Checked: `HunkContextTests` and `SILL_CHECK=looked` (its picture, in `SILL_CHECK_SHOTS`, after the tests' area is
  marked seen). Not done: changes of the same shape folded into one row ("9 alike"), and the handoff's note on a file
  above its diff.
- A prompt's hook within its budget (2026-11-12). The hook server gives an answer 1.5 s; the editor context took
  0.8 to 1.4 s, so `SILL_CHECK=hooks` failed about one run in three (on 9112809 too, before the clarity work), and
  each prompt held the main thread that long. Not nvim (a round trip is under a millisecond): git, on the main
  thread. `SillFolder.relative` asked git for the worktrees twice for each path, and `Baskets.folder` found `.sill`
  (git four times or more) at every read of the current basket. Now the worktrees' roots are found once off the main
  thread when the hooks start (`SillFolder.roots`, then `relative(_:roots:)`, strings only), `Hooks.root` once, and
  `.sill` once, warmed off the main thread when the workspace starts. The context takes under a millisecond (0.3 to
  0.4 s on the one prompt that follows a basket edit, nvim still busy). Checked: `SILL_CHECK=hooks` passing in a
  whole verify run and six runs alone. Not done: Baskets' own `relative` calls still ask git, off the hook path.
- The parsers shipped, not built on a person's Mac (2026-11-12, owner: "I didn't realize it needed native code, we
  should build and ship this ahead of time"). `scripts/treesitter.lua` (run by nvim) builds them once per
  `TREESITTER_COMMIT` (mise.toml) into `Vendor/treesitter` (72 s here, then 4 s while the pin holds); `bundle.sh`
  copies them to `Contents/Resources/treesitter` and signs each ad hoc, `sign.sh` with the identity (not run yet:
  signing is deferred). `lua/sill/syntax.lua` puts that folder on the runtimepath. `SyntaxParsers`, the cache and the
  weekly check are gone: the parsers move with sill's releases. The app grows by 59 MB. Checked:
  `SILL_CHECK=config` (25 parsers in the bundle, Pricing.cs highlighted; without the runtimepath line it fails) and
  `TreesitterBuildTests` (the plan from a cut-down parsers.lua).
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
