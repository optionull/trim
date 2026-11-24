---
navigation_title: "Keys"
description: "Trim's shortcuts and leader keys."
---

# Keys

## Shortcuts

| Key | What it does |
|---|---|
| ⌘P | Find a file. |
| ⇧⌘F | Find text in files. |
| ⌘⇧O | Switch workspace. |
| ⌘B | Hide or show the file tree. |
| ⇧⌘E | Go into the file tree. |
| ⌥⌘F | Filter the tree. |
| ⌥⌘E | The list of open files. |
| ⌃⇥, ⌃⇧⇥ | Next and previous tab. |
| ⌘W | Close the current tab. |
| ⌥⌘T | Colour scheme. |
| F5 | Run. |
| ⇧⌘B | Build. |
| ⇧⌘R | Choose what to run. |
| ⌘J, ⇧⌘J | Go into the run pane and back; close it. |
| ⇧⌘M | Problems. |
| ⌃⌘W | Walkthroughs. |
| ⌘+, ⌘-, ⌘0 | Font size. |
| ⌘, | Settings. |

## The leader (`\` by default)

Each is bound only where your config has nothing there.

| Key | What it does |
|---|---|
| `<leader>e`, `<C-w>e` | Toggle the file tree, go into it. |
| `<leader>E` | Filter the tree. |
| `<leader>w` | Workspace switcher (also `<leader>fw`). |
| `<leader>t`, `<leader>o` | List of open files. |
| `<leader>c` | Colour scheme. |
| `<leader>F` | Font. |
| `<leader>P` | Packages. |
| `<leader>W` | Walkthroughs. |
| `<leader>ff`, `<leader>fg` | Find files, find text. |
| `<leader>rr`, `rb`, `rp`, `rt`, `rx`, `rq` | Run, build, choose, terminal, close, problems. |
| `<leader>ls`, `lS`, `la`, `lr`, `lf`, `ld`, `ll`, `lR` | Symbols, workspace symbols, actions, rename, format, diagnostics, restart servers. |

In normal mode with a language server: `gd`, `gy`, `gr`, `gI`, `K`. In insert mode: Tab, Shift-Tab, Enter, Ctrl-Space,
Ctrl-S, Alt-Down and Alt-Up (see [Completion](../code/completion.md)).
