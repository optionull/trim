# Frame: the road back toward Sill

Frame started as a copy of Shim (nvim alone in a native Metal window) and grows native panes around nvim. Sill has the
features and a look its owner is not happy with, and its panes are tangled into `Workspace.swift` (1,141 lines) and a
`SillApp` of about 22,700 lines, a fifth of it Sill's own `SelfCheck.swift`. So Frame takes Sill's features one at a
time, each **ported** (rebuilt in Frame's look, with a check of its own), **replaced** (by something nvim or Frame
already does), **parked** (later, when something else exists), or **dropped**.

This file is the ledger. Verdicts here are **proposals**; nothing is decided until the owner says so, one row at a
time. Sizes are lines of Swift in `Sources/SillApp` (and the libraries named), to show what a port weighs.

## Rules for every port

- One feature per commit (a PR where the concerns differ), each with a **Frame self-check** (`SILL_FRAME_CHECK=1`) that
  runs against a real nvim, and a mutation of the code that makes it fail. Unit tests for what is pure.
- The owner keeps the look: no pane is copied, each is drawn again from Frame's tokens (`TreeLook`, `TreePalette`, the
  editor's font, islands).
- **heed is optional** everywhere: it adds (titles, states), never gates, and every heed-fed feature has a good fallback.
- **Modes**: a pane that takes the keyboard is a `Surface` in `FrameModes`, with Escape leading back to where the person
  came from, and a word in the status bar. No pane invents its own flags for this.
- Nothing is written into the repositories Frame looks at without being asked. Sill's `.sill` folder format (handoffs,
  walkthroughs, baskets, seen marks) is kept compatible while both apps exist.

## What Frame has already

| Frame | Replaces in Sill |
|---|---|
| Native file tree (vim keys, filter, hidden/ignored toggles, git marks, icons, FSEvents, reveal of the current file) | the Explorer (`ExplorerView`, 868) |
| Workspace switcher: a window per repository or worktree, fuzzy search, last-opened order, heed's titles when present, in-place or new window | Home's list of checkouts (`HomeView` 475, `Home` 239, `HomeController` 207) |
| Native status bar (mode, branch, file, diagnostics, servers, position), placeable beside the tree or across the window | `StatusBarView` and the title bar's branch |
| Modes of the window (editor, tree, switcher; the tree's filter) with Escape leading back | Sill's per-pane focus rules |
| nvim config switching in place (`:FrameConfig`, the Config menu), your own config by default | `[nvim] config = ...` |
| which-key.nvim drawn in Frame's colours | Sill's `g` panel (see "Keys" below) |
| A bundled Nerd Font for icons | nothing (Sill relied on an installed one) |

## The ledger

"Weight" is Sill's code for it. "Needs" is what it is tangled with, which decides the order: nothing at the top,
services and sidecars at the bottom. **Proposed** is my suggestion; **Why** says what it rests on.

### A. Editor chrome (needs nothing new)

| # | Feature | Weight | Needs | Proposed | Why |
|---|---|---|---|---|---|
| A1 | **Tabs**: nvim's tab pages as a native strip (`ext_tabline`), and Sill's per-window file tabs (`SplitTabs`) | `RootView` 159, `SplitTabs` 188 | `Screen.tabs` (already arrives) | **Port first** | Smallest, most visible, and it settles how Frame draws a strip over the grid. Native tab strip for tab pages; the per-window file strip is a separate decision (a bufferline plugin already does it in most configs) |
| A2 | **Settings window** (⌘, writes `~/.config/sill/settings.toml`) | `SettingsWindow` 390 | `SillCore` settings (shared) | **Port, small** | Frame already reads these settings; a window for font, size, title bar, status bar placement and nvim config is what is missing |
| A3 | **Zen** (hide chrome, centre the text) and islands | in `ChromeViews`, `Workspace` | none | **Port, small** | Frame's panes are islands already; zen is a toggle of the sidebar, bar and a centred grid |
| A4 | **Context menu** (right-click: LSP actions, compare with a branch, blame, history) | `ContextMenu` 111 | LSP via nvim | **Park** | Wants the review and git panes first |
| A5 | **Links in**: `sill://open?...`, `open -a Sill file` | in `AppDelegate` | none | **Port** with terminal panes | Tiny, and `frame://` can share the code |
| A6 | **Own nvim setup** (`colors/sill.lua`, 25 tree-sitter parsers, change signs, `]h`/`[h`) | `runtime/`, `Vendor/treesitter` | the runtime Lua | **Decided: Frame runs its own isolated config** | Frame is an out of the box editor; the shim is the bare nvim app. What it needs: `docs/frame-config-audit.md` |
| A7 | **Language server provisioning** (Roslyn, rust-analyzer, sourcekit-lsp, marksman, web servers) | `LanguageServers` 248 | the own nvim setup | **Required (was: drop)** | With an isolated config nothing else starts servers: today none run in Frame. Port or rewrite it in Lua (audit, step 3) |

### B. Keys and panes (the framework the rest needs)

| # | Feature | Weight | Needs | Proposed | Why |
|---|---|---|---|---|---|
| B1 | **Pane host**: a pane opens in place of the code (or beside it) with one header, one footer of keys, `q` back | `PaneBar` 168, `ToolViews` 703 | `FrameModes` (a `pane` surface) | **Port before any pane** | Every later pane sits on it. Decision: native view over an nvim placeholder window (Sill's way; nvim keeps the layout and `<C-w>` works) or a native region beside the grid (Frame's way for the tree) |
| B2 | **Keys**: one keymap per pane, `g` + letter goes somewhere, `?` lists keys, `f` labels what can be clicked, `:SillKey name`, `[keys]` in settings | `Keyboard` 328, `SillInput` | B1 | **Port with the first pane** | `?` and `f` are worth having; `g`-chords overlap which-key. Keep the named-command idea, drop the duplicate panel |
| B3 | **Terminal panes** (Ghostty surfaces, ⌘-click on `file:line` and OSC 8 links, `i` / `<C-\><C-n>` hand-off) | `TerminalPanes` 208, `SillTerminal`, `SillApp` glue | GhosttyKit (built, in `Vendor/`), B1 | **Port** | Needed by Run, Build, agents without heed. The biggest unknown is the pane model (B1) |
| B4 | **Problems panel, Build (⌘B), Output** | `Build` 104, in `ToolViews` | diagnostics from nvim, B1/B3 | **Port** | Diagnostics already reach the status bar; the panel lists them, Build feeds them |

### C. Git and running (own data, no agents)

| # | Feature | Weight | Needs | Proposed | Why |
|---|---|---|---|---|---|
| C1 | **Changes** list (what git says is touched) | `SourceControlView` 132 | the tree's `GitState` | **Port, small** | The tree has the marks; this is the same data as a list |
| C2 | **Review** what changed since a baseline: keep, take back, comment, seen marks by area, rename detection | `ReviewView` 417, `Reviewer` 394, `SillCore` | B1, git trees via a temporary index | **Port** | The heart of Sill's loop, and useful with no agent at all |
| C3 | **Run**: what a checkout can run (.NET, Swift, Cargo, npm, mise, just), ⌘R, history in `.sill/run.json` | `RunView` 250, `Runner` 224 | B1, B3 | **Port** | Project detection is pure and already in `SillCore` (`Runnables.swift`) |
| C4 | **The branch's pull request** (`gh`, read only): checks, reviews, conflicts, unpushed commits | `PullRequests` 220, `PullRequestView` 220 | `gh`, B1 | **Port** | A segment of the status bar and one pane |
| C5 | **Summary / Stories**: what happened since you looked | `SummaryView` 397, `Stories` 115 | agent transcripts (optional), `.sill` | **Port later** | Rests on C2 and, for prompts, on agents; with no agent it is commits and touched files, which is still good |
| C6 | **Home** as its own screen | above | | **Drop as a screen** | The switcher answers "where do I go"; its "needs you" marks come from heed when present. Revisit if a dashboard is missed |

### D. Agents (heed optional, MCP and hooks are the big decisions)

| # | Feature | Weight | Needs | Proposed | Why |
|---|---|---|---|---|---|
| D1 | **Agents list** and Send to agent via heed | `AgentsView` 147, `AgentBridge` 1,175, `SillAgent/Heed` | heed (optional), B3 as fallback | **Port, thin** | Start with the heed client and a sidebar segment; without heed, a terminal pane runs `claude` |
| D2 | **Hooks** (Claude Code's: baselines per prompt, the editor's context told to the agent, plans as notebooks, session logs) | `Hooks` 336, `HookServer` | D1, C2 | **Park, decide** | Powerful and invasive (writes `.claude/settings.local.json`). Whether Frame is an agent-aware app at all is the owner's call |
| D3 | **MCP server** (`problems`, `build`, `read_file`, `open_file`, and the tool families below) | `SillAgent/McpServer` | D1 | **Park, decide** | Same question as D2 |
| D4 | **Handoffs and walkthroughs** (`.walk.md` notebooks, `@code` anchors, `@ask`, `@run`) | `WalkView` 689, `Walker` 384 | B1, LSP, D3 for agents writing them | **Port later** | A reading experience with real value for reading anyone's code, agent or not |
| D5 | **Following an agent** (files changing on disk, opened as they land) | `Follower` 193 | D1 | **Port later** | Small once D1 exists |
| D6 | **Replay a session** | `ReplayView` 243, `Replays` 127 | D2's logs | **Drop** | Depends on hooks logs; revisit only if D2 happens |

### E. Understanding code

| # | Feature | Weight | Needs | Proposed | Why |
|---|---|---|---|---|---|
| E1 | **Code map** (projects, entry points, hot files) | `CodeMapView` 292, `CodeMapper` 122 | git history | **Park** | Self-contained and nice, but not the loop |
| E2 | **Trace a symbol** (callers/callees tree) | `Tracer` 268, `TraceView` 154 | LSP call hierarchy | **Park** | Rests on the language server in nvim |
| E3 | **Context baskets, investigations, `:SillAsk`** | `Baskets` 503 | D1-D3 | **Drop candidate** | Entirely an agent workflow; raised in the original plan as a drop candidate |

### F. Language-specific (the .NET sidecar, needs the SDK)

| # | Feature | Weight | Needs | Proposed | Why |
|---|---|---|---|---|---|
| F1 | **Debugger** (DAP: breakpoints, stack, variables) | `Debugger` 821, `DapClient` | the sidecar, .NET 11 | **Park, probably a plugin** | nvim-dap does this in nvim; Frame could style it instead of owning it |
| F2 | **Profiler** (EventPipe, samply, xctrace; flame graph, heap diff) | `ProfileView` 1,159, `Profiler` 287, `NativeRecorder` 358, `FlameGraph`, `Treemap` | sidecar, tools | **Park** | Big, impressive, rarely needed; a candidate for staying in Sill |
| F3 | **Telemetry** (logs, traces, metrics of a running .NET program) | `TelemetryView` 251, `TelemetryWatch` 119 | sidecar | **Drop candidate** | .NET only and a lot of machinery |
| F4 | **Packages** (NuGet with advisories) | `PackagesView` 818 | `dotnet`, osv.dev | **Park** | Self-contained, .NET only |
| F5 | **`.slnx`, Razor, project-file nesting** | `SillCore` (`FileNesting`, `Slnx`) | none | **Port the nesting (small), park the rest** | The logic is in `SillCore` and tested, but Frame's tree does not use it yet: `Counter.razor.cs` does not nest under `Counter.razor` there |

### G. Infrastructure that does not port

| # | What | Weight | Proposed |
|---|---|---|---|
| G1 | `SelfCheck.swift` (Sill's own check of itself) | 4,940 | **Drop**: Frame has `FrameCheck` and grows it per feature |
| G2 | `Bench.swift`, `HomeCheck.swift` | 187, 219 | **Drop** |
| G3 | Sill's telemetry of itself, if any, and the menu-bar eye of agents | | **Ask**: not looked at yet |

## Suggested order

1. **A1 tabs**: smallest, settles how a strip is drawn over the grid.
2. **B1 the pane host** and **B2 keys**: decide the pane model once, with a `pane` surface in `FrameModes`.
3. **B3 terminal panes**, then **B4 Problems and Build**.
4. **C2 Review**, **C3 Run**, **C4 the pull request**, **C1 Changes**: the useful loop with no agent.
5. **D1 a thin agents list via heed**, then **C5 the summary**, **D4 walkthroughs**, **D5 following**.
6. Then only what is missed: E1, E2, F4, and the decisions D2, D3, A6.

## Decisions I need from the owner before row 2

1. **The pane model (B1)**: a native view over an nvim placeholder window (nvim keeps the layout, `<C-w>` works, Sill's
   way, tied to Sill's Lua) or a native region beside the grid (clean, but nvim's layout does not know it).
2. **Is Frame agent-aware (D2, D3)?** Hooks and an MCP server make it part of an agent's loop; without them Frame is a
   very good editor and reviewer that heed can enrich.
3. **A built-in config (A6)** for someone with none, or always your own.
4. **Which of the parked and dropped rows** you would rather see ported.
