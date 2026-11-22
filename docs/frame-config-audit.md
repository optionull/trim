# Frame's own nvim config: an audit

Decided: Frame runs its **own isolated nvim config** (name `frame`, `~/.config/frame/init.lua` for additions), an out of
the box editor; the shim stays the barebones "nvim the nvim way" app. This is what that config is today, measured by running
Frame's exact startup headless (`--cmd set runtimepath^=runtime`, `sill.base`, `frame.base`) and dumping options, keymaps,
commands, parsers and autocommands, and what it needs to be an editor someone would choose.

Requirements from the owner: a **which-key experience**, **bundled plugins**, a **settings view** (like heed's) that manages
the config, and **smooth scrolling of nvim's buffers**.

## What Frame's nvim is today

It is Sill's own setup with Sill's host left out: `sill.base` (13 options), `plugin/sill.lua` → `sill.setup()` (an editor
module of 960 lines built for Sill's chrome and agent workflow), then Frame's `frame.*` modules (status feeder, tabs, theme,
keys) and nvim 0.12's own defaults. Nothing else: no colour scheme, no plugins, no language servers started.

## Findings

Severity: **P0** an editor is not usable without it; **P1** noticeably worse than any editor people compare it with; **P2** polish.

| # | Finding | Evidence | Sev |
|---|---|---|---|
| 1 | **No language servers start.** `sill.servers` asks the *host* (Sill.app's `LanguageServers.swift`) for each server's command over `sill_*` notifications; Frame answers none, so rust-analyzer, sourcekit-lsp, marksman, the web servers, TypeScript, F# and Roslyn never run. No diagnostics, hover, go to definition, completion, rename or code actions beyond the keys nvim binds (`grn gra grr gri` do nothing without a client). | `lsp config` empty; `servers.M.commands` filled only by the host. Measured: with `sourcekit-lsp` and `rust-analyzer` both on the PATH, opening a `.swift` and a `.rs` file starts 0 clients after 3 s | **P0** |
| 2 | **Tree-sitter parsers are not in Frame.app.** Sill.app carries 25 built parsers; `scripts/bundle.sh` copies them only for Sill. Frame has nvim's seven (C, Lua, Vim, Vimdoc, Markdown, Query) and falls back to regex syntax for every other language (the parsers are built and sitting in `Vendor/treesitter`). | `treesitter parsers available: 7` | **P0** |
| 3 | **No find file / grep / buffers / symbols.** `<leader>ff` and `<leader>/` exist only under `vim.g.sill_chrome` (Sill's own mode); Frame has a tree and a workspace switcher but no way to jump to a file by name. | no `\ff` in the keymap dump | **P0** |
| 4 | **No which-key.** The leader is nvim's `\` and its only keys are Frame's and Sill's `\i*` agent keys; nothing shows what follows a prefix. (A native panel was tried and cannot work: nvim delivers notifications late while a key sequence is pending. A Lua plugin drawing in the grid can, as which-key.nvim did under LazyVim.) | no plugin; native hints measured at ~1 s late | **P0** |
| 5 | **No colour scheme.** `colors_name` is empty: Frame looks like nvim's default scheme. The sidebar, bar and tabs follow whatever scheme is active, so Frame's whole look is decided by a choice nobody has made. Sill's `colors/sill.lua` exists but is applied only by `sill.chrome()`. | `colorscheme (none)` | **P0** |
| 6 | **Sill's agent commands and keys are loaded and do nothing.** 30 `Sill*` commands (`SillReview`, `SillMap`, `SillBasket`, `SillAgent`, debug F-keys...) and `\i*`/`\a` maps, whose hosts are not in Frame (ledger groups C to F). They clutter completion and which-key and fail silently. | `\iu \ip \ih \if \ir \iw \im \ii \it \is \ib \a`, F5 to F11 | **P1** |
| 7 | **Defaults that are nvim's, not an editor's:** `tabstop=shiftwidth=8`, `expandtab` off, `wrap` on, `clipboard` empty (yank does not reach the system clipboard), `smoothscroll` off, `timeoutlen=1000`, no `list`/`fillchars`, `foldmethod=manual`, no format-on-save. | options dump | **P1** |
| 8 | **No editing helpers:** no pairs, no surround, no extra text objects (nvim 0.12 has `gc`, `an/in` tree-sitter selection and `vim.snippet`; nothing else). | keymap dump | **P1** |
| 9 | **No git in the buffer:** signs, hunks, blame. (`sill/gutter.lua` draws change signs but is wired to Sill's chrome.) The tree and bar show git; the buffer does not. | no `]h`/`[h` | **P1** |
| 10 | **No settings surface.** Options live in Lua only; Frame's own choices (tabs, status bar placement) are in menus, the font in sill's `settings.toml`. | | **P1** |
| 11 | **Scrolling slides but only by line.** Whole-line steps animate (0.12 s, chained since this branch); a trackpad does not move the text by pixels, and `smoothscroll` (wrapped lines by screen line) is off. | `smoothscroll=false` | **P2** |
| 12 | **Messages/cmdline/popup menu are Frame's own** (`ext_*` UI). Completion menu, signature help (`<C-s>`), snippet jumping (`<Tab>`) are bound. | `completeopt=menu,popup`, `<Tab>`, `<C-s>` | fine |
| 13 | What nvim 0.12 gives for free and Frame keeps: `gc` comments, `grn/gra/grr/gri/grt`, `[d ]d`, `<C-w>d`, matchit, editorconfig, osc52, `inccommand`, `jumpoptions=clean`, undofile. | | fine |

## Proposal

### 1. Split Frame's runtime from Sill's
Stop loading `sill.setup()` whole. Frame gets its own `frame/init.lua` that sets up only what the host needs
(`vim.g.sill_channel` and the notifications Frame uses) and what Frame wants: options, diagnostics display, tree-sitter,
LSP, keymaps, plugins. Sill's modules are kept where Frame ports them (ledger rows) and dropped from Frame's load until then,
which removes finding 6 and makes Frame's startup faster and its which-key honest. Order of loading: `sill.base` is replaced
by `frame.base` (defaults), then plugins, then `~/.config/frame/init.lua` (wins).

### 2. Defaults (finding 7), set in `frame.base`
`expandtab`, `tabstop=shiftwidth=4` (and per-filetype by editorconfig, which nvim honours), `clipboard=unnamedplus`,
`smoothscroll`, `timeoutlen=400`, `wrap` off with `linebreak`, `list` with quiet markers, `fillchars` without `~`, `confirm`,
`foldmethod=expr` over tree-sitter (open by default), `laststatus` stays the bar's.

### 3. Tree-sitter (finding 2)
Copy `Vendor/treesitter` into Frame.app as Sill does (parsers signed one by one), and load them from `frame.syntax`. One line
in `bundle.sh`, no new code.

### 4. A colour scheme and a theme setting (finding 5)
Ship a default (proposal: **tokyonight "night"**, MIT, because its `Visual` and background hues already suit the tree and
status bar; **catppuccin** and **rose-pine** as choices, a light one too) chosen in the settings view and by
`vim.g.frame_theme`. Frame derives its chrome from the scheme as it does now; this decides what "Frame" looks like out of
the box.

### 5. Bundled plugins (findings 4, 8, 9, and the picker of 3)
A **pinned, vendored** set, no package manager at runtime and no network: `scripts/plugins.sh` (`mise run plugins`) fetches each at
a commit with a checksum into `Vendor/plugins/` (as fonts and tree-sitter are), `bundle.sh` copies them to
`Contents/Resources/runtime/pack/frame/start/<name>` (nvim finds them on its own: the runtime is on the `packpath`), each with
its licence in `THIRD_PARTY_NOTICES.md`. Each is set up by one file, `runtime/lua/frame/plugins/<name>.lua`, and switched off
by name in the settings view or `vim.g.frame_plugins = { 'x' }`.

Proposed set (all permissively licensed Lua, no binaries but ripgrep for grep):

| Plugin | For | Why this one |
|---|---|---|
| **which-key.nvim** (folke) | the which-key experience: leader and multi-key vim sequences, in Frame's colours | the one that worked in the grid; Frame already styles its `WhichKey*` groups |
| **mini.nvim** (echasnovsky), modules `pairs`, `surround`, `ai`, `bracketed` | pairs, surround, text objects, `[`/`]` jumps | one repository, independent modules, tiny |
| **snacks.nvim** picker only (folke), or **fzf-lua** | find files, grep, buffers, recent, symbols, diagnostics (finding 3) | snacks: pure Lua, no extra binary, one pin shared with which-key's author; **not** its `scroll` (it would fight the host's slide) |
| **gitsigns.nvim** | change signs, hunks, blame in the buffer | the standard; or port `sill/gutter.lua` |
| a colour scheme pack | finding 5 | tokyonight, catppuccin, rose-pine |

Not bundled (decide later): completion plugins (nvim's own `vim.lsp.completion` with Frame's native menu is enough),
formatters (conform), a file explorer (the native tree is it), session managers, AI plugins.

### 6. Which-key (finding 4)
Bundle which-key.nvim, configured with Frame's groups: `<leader>e` tree, `w` workspaces, `t`/`o` tabs, `f` files, `g` code,
`b` buffers, `s` search, `u` ui, `x` diagnostics (a **spec**, so keys the user adds show too). Its delay and style are settings.
It covers the vim sequences too (`g`, `z`, `[`, `]`, operators, registers, marks). The existing `frame.whichkey` styling stays.

### 7. Language servers (finding 1): the largest piece
Frame needs what Sill's host did: find or provision each server and tell nvim its command. Options:
- **A. Port `LanguageServers.swift`** (248 lines: PATH first, rustup/Xcode, else download into `~/Library/Caches/frame/servers`
  with a pinned version and checksum; npm for the web servers). Known, tested in Sill; ties Frame to Swift for this.
- **B. A small Lua provisioner** inside Frame's runtime (`frame.servers`): the same table, `vim.system` for download and
  unpack, progress as messages. No host round trip; testable headless.
- **C. Bundle mason.nvim.** Large, moves, network at runtime, and brings its own registry and UI.

Recommendation: **B** over a pinned table (also readable from the settings view: which servers, on/off, where installed), reusing
Sill's `servers.specs` and Roslyn's setup. Diagnostics display (virtual text style, signs, float) is set in the same module.

### 8. Settings view (finding 10), like heed's
A native window (⌘,) in Frame's look with sections: **General** (font, size, line height, title bar), **Editor** (tabs and
indent, wrap, line numbers, clipboard, scrolloff, smooth scrolling), **Theme** (colour scheme with a live preview), **Keys**
(leader; the list of Frame's keys, each rebindable), **Plugins** (each on/off, which-key delay), **Language servers** (installed,
on/off), **Layout** (tabs and status bar placement, sidebar). Stored in `~/.config/frame/settings.toml` (the window changes one
value in place and keeps comments, as Sill's does, whose `SettingsWindow` and TOML code are reused). At start Frame hands the
values to nvim as `vim.g.frame_settings` (JSON); a change applies live by RPC. `~/.config/frame/init.lua` stays the escape
hatch and wins over the settings. A key sill does not know is named at the top of the window.

### 9. Smooth scrolling of nvim's buffers (finding 11)
**Done (all three below):** pixel scrolling (`SillCore/PixelScroll.swift`, `EditorView.pixelScroll`), `smoothscroll` and `mousescroll=ver:1`, and the setting. The notes below are the design as built: nvim is kept a line ahead of the drawn text, the slide's progress comes from the finger, and the text settles 90 ms after the last event.

Was: scrolls slide by line and chain (a scroll during a slide goes on from where the window is drawn). To do:
1. `smoothscroll=true` in `frame.base` (nvim scrolls wrapped lines by screen line). Trivial.
2. **Pixel scrolling for the trackpad.** Keep a sub-line offset in the editor view: a precise scroll delta moves the window by
   points; whole lines cross to nvim as scrolls (as now) while the remainder is drawn as a vertical offset of the window's rows
   (the renderer already draws a previous and a current grid at a fractional offset for a slide; this feeds it the offset directly
   and rebases it when nvim reports the lines). Momentum from the system arrives as scroll events with phases and fits the same
   path. Open points: cursor and `scrolloff` while the offset is non-zero, windows other than the current one, and not
   fighting a plugin that animates scrolling (so neither snacks.scroll nor neoscroll is bundled).
3. Settings: on/off, duration of a slide, pixel mode on/off.

## Order and weight

| Step | What | Weight |
|---|---|---|
| 1 | Runtime split, defaults, tree-sitter bundled, `smoothscroll`, a default scheme | small to medium (mostly Lua and one `bundle.sh` line) |
| 2 | Plugin bundling mechanism + **which-key** | small to medium |
| 3 | Language servers (option B) and diagnostics display | medium to large |
| 4 | Picker: find files, grep, buffers, symbols | medium |
| 5 | Settings view | medium to large |
| 6 | Pixel scrolling | large (renderer) |

Steps 1 and 2 give the largest visible change for the least work: Frame stops looking like stock nvim, highlights code properly
and shows what keys do. Step 3 is what makes it an editor for code.

## Decisions I need

1. **Default colour scheme** (proposal: tokyonight night; with catppuccin, rose-pine and a light one as choices).
2. **Picker**: snacks.nvim's picker or fzf-lua (needs `fzf`).
3. **Language servers**: option B (Lua provisioner) over A (port the Swift)?
4. **Leader key**: keep nvim's `\`, or space (the usual for an out of the box config; `\` then becomes the local leader)?
5. **The plugin set** above: anything to add or drop (surround and pairs in particular are opinionated).
