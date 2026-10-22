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

- Layout decision: one app-level split tree; a Ghostty pane splits like any editor window.
- nvim UI protocol: `ext_linegrid`, `ext_multigrid`, `ext_popupmenu`, `ext_cmdline`, `ext_messages`,
  `ext_tabline`; `win_viewport` for smooth scroll. Inlay hints and diagnostics render inside the nvim grid;
  completion, cmdline and messages are native.
- Threading rule: nothing on the main thread waits on nvim; the render thread only reads immutable grid
  snapshots.

## 3. Metal renderer

- Glyph atlas (r8Unorm coverage + bgra8 colour), per-cell instance buffer, background pass, decoration pass,
  instanced text pass.
- Shaped-run cache per row, ASCII fast path, ligatures via CTLine, fallback fonts, wide chars, curly
  underlines in the shader, procedural box-drawing and powerline sprites (ported from Ghostty).
- Damage tracking, 120 Hz via CAMetalDisplayLink, pixel scrolling, IME and accessibility. CoreText still
  shapes and rasterises; Metal draws.
- Profiler output on the GPU too: level-of-detail aggregation so huge data stays smooth (for example 11.8M
  samples as 6,420 blocks, 3.1M objects as 4,812 tiles).

## 4. Reuse map (all MIT)

| Source | Take | Leave / replace |
|---|---|---|
| Veil | RPC layer, shaping, box drawing, font fallback, keyboard handling | Main-thread non-instanced renderer. No multigrid, popupmenu, cmdline, messages; never draws underlines; no emoji atlas. |
| VimR | API generator, NvimApi/NvimView ideas, IME notes | Its UI shell |
| Passenger | Profiler, Lsp/Razor, DebugAdapter, Host JSON-lines protocol, MCP design | XAML tooling |
| Ghostty | Renderer reference; libghostty xcframework from heed's pinned commit (zig 0.16) | n/a |

## 5. Language support

| Language | Server | Notes |
|---|---|---|
| C# / Razor | .NET sidecar LSP broker (Roslyn LS + Razor HTML bridge via `__virtual.html`, `razor/updateHtml`) | Roslyn LS NuGet package contains non-OSS Visual Studio assemblies: download on the user's machine, never bundle in the DMG. |
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
- heed gap: heed has no URL scheme and no inbound request API (one-way hook socket only). Needs heed
  start/send/sessions/watch plus a control socket on the heed side.
- Day-1 fallback: the editor's own Ghostty pane runs the agent.

## 8. Milestones

| | Scope | Exit criteria |
|---|---|---|
| M0 | Spikes: Veil RPC lift, instanced Metal grid, libghostty embed, sidecar handshake | Each spike has a go/no-go note |
| M1 | Metal grid on a single nvim window | Daily-drivable text editing, 120 fps scroll |
| M2 | Full UI protocol, multigrid, Ghostty pane, signed and notarized build | Notarized DMG opens on a clean Mac |
| M3 | LSP, C# sidecar, build capture, problems | Open a .NET solution, build, jump to errors |
| M4 | MCP server, editor-only agent loop | Agent fixes a build error end to end |
| M5 | heed bridge | Send to heed and see the session in the editor |
| M6 | .NET profiler in sidecar, Razor | CPU and heap diff on a sample app |
| M7 | Rust and Swift profiling, remaining language servers | samply and xctrace sessions viewable |
| M8 | Debugger (DAP) | Breakpoints and stepping in C# |
| M9 | Polish: diff/merge tool modes, packages view, settings, Sparkle updates | Beta release |

## 9. Packaging

- Developer ID, hardened runtime, notarization. JIT entitlements for the .NET sidecar. Homebrew cask and
  Sparkle updates.
- Bundled pinned nvim with a "use PATH nvim" override.
- Licence audit before first release: Roslyn LS fetched at runtime, heed licence not yet located.

## 10. Top risks and spikes

| Risk | Spike / mitigation |
|---|---|
| Grid renderer perf with multigrid and huge profile views | Instanced renderer with LOD; M0 benchmark on 11.8M-sample trace |
| libghostty API stability and build (zig 0.16) | Pin to heed's commit; embed spike in M0 |
| Razor/Roslyn LS outside Visual Studio | Follow Passenger's Razor bridge; sidecar broker; early C# spike |
| Roslyn LS licensing | Download at first run, never bundle |
| heed has no inbound API | Ship editor-local agent pane first; propose heed control socket |
| JIT and notarization for sidecar | Entitlements tested in M2 build |
| IME and accessibility with a custom grid | Use VimR notes and NSTextInputClient early |
| Merge tool correctness | Test against git's own conflict corpus; run as real mergetool in CI |

## 11. First week

- Day 1: repo skeleton, lift Veil's RPC layer, `nvim --embed` hello.
- Day 2: instanced Metal grid drawing a static linegrid.
- Day 3: live nvim input to grid, cursor, colours.
- Day 4: libghostty surface in a split.
- Day 5: .NET sidecar handshake, signed build smoke test.

## 12. Caveats

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

## Open questions

Raised in review on 2026-10-22, not yet decided. Each is resolved by changing the sections above.

1. **The shared split tree and nvim's own layout.** Under `ext_multigrid` nvim still owns window layout
   (`:split`, `<C-w>hjkl`, resize, `:only`). A Ghostty pane nvim does not know about breaks those.
   Proposal: back each Ghostty pane with a placeholder nvim window (a `nofile` buffer) and draw the
   surface over it, so nvim stays authoritative for layout. Add as an M0 spike and a §10 risk.
2. **IME on the main thread.** `NSTextInputClient` (`firstRect`, `markedRange`) is queried synchronously on
   the main thread; answers must come from the cached grid and cursor, never a round trip to nvim.
3. **Native completion needs the popupmenu path.** `ext_popupmenu` only sees completion that uses the
   pum (built-in `vim.lsp.completion`); nvim-cmp and blink draw floating windows instead.
4. **The sidecar may not need JIT entitlements.** Run it on the user's own `dotnet` SDK rather than a
   bundled runtime and the app's hardened runtime never covers JIT.
5. **heed is ours.** The control socket (§7) is heed work to schedule there, and the licence item in §9
   goes away. Board 2 largely rebuilds heed's sessions view inside the editor, which pulls against "a
   separate app, not a pane inside heed": decide who owns the sessions list before M5.
6. **Key conflicts.** Merge keys `ct` and `cb` (board 5) shadow core change-till and change-back-word, and
   `co` overlaps common conflict plugins; candidates are `<localleader>o/t/b` or `:diffget 2/3`. `ga`
   (board 2) shadows core "print character code"; candidates are `]a`/`[a`, or binding it only in the
   sessions view.
7. **Board consistency.** Board 4 has `List<Line> Lines` where boards 2 and 9 have
   `IReadOnlyList<Line> Lines`. Board 1's Ghostty pane says "Build succeeded" next to a problems panel
   with two errors. Board 9 has a stray `)` after "CreateOrder.cs". The mergetool command in board 5 is still
   `app`; it becomes `sill`.
8. **Licences unchecked.** "All MIT" in §4 and what Passenger contains have not been verified against
   each repo's LICENSE.
