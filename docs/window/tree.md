---
navigation_title: "The file tree"
description: "The file tree beside the editor: git marks, diagnostics, filtering, and keys."
---

# The file tree

A native tree sits left of the editor. It lists folders first, then files, in the order Finder sorts them, with
an icon for each file type. It is kept up to date as files change on disk.

![The file tree beside the editor](../images/shots/window.png)

## What it shows

- **Git:** the branch under the folder's name, **M** on changed files, **U** on new ones, and a dot on folders that
  hold a change. What git ignores is left out (the eye at the top right shows it dimmed).
- **Diagnostics:** a file with a problem has a wavy line under its name in the colour of its worst one, and every
  folder above it takes the worst of what is below.
- **Follow:** the tree follows the file nvim shows.

## Keys

| Key | What it does |
|---|---|
| ⌘B | Hide or show the tree. |
| ⇧⌘E, `<C-w>e` | Go into the tree. |
| `j` `k` `h` `l`, arrows, Return | Move, collapse, expand and open. |
| `/`, ⌥⌘F | Filter: narrow the tree to the paths that hold what you type. Escape puts it back. |
| `I`, `H` | Show or hide what git ignores, and dotfiles. |
| Escape | Back to the editor. |

Keys that belong to nvim (the leader, `:`, Control chords like `<C-w>l`) go to nvim whatever row is selected.
Drag the divider to size the tree.

`:TrimTree [toggle|show|hide|focus|filter|ignored|dotfiles]` does the same from nvim, and `<leader>e` toggles it
where your config has not bound that key.
