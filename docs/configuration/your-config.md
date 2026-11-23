---
navigation_title: "Your own config"
description: "Trim runs its own isolated nvim config; ~/.config/trim/init.lua is the place for yours."
---

# Your own config

Trim runs its **own isolated nvim config**, never yours. It starts nvim under the name `trim`, so its config, data,
state and cache folders are Trim's (`~/.config/trim`, `~/.local/share/trim`...) and nothing of `~/.config/nvim` (nor
any other config) is read. A config of yours, LazyVim included, cannot clash with it, and Trim cannot break yours.

## What loads, in order

1. Trim's base settings (`runtime/lua/trim/base.lua`): spaces for indent, four wide, the system clipboard,
   `smoothscroll`, no line wrapping, quiet whitespace markers, folds from the syntax tree, a 400 ms key timeout, `\`
   as the leader.
2. `settings.toml`.
3. `~/.config/trim/init.lua`, if there is one. nvim loads it as it loads any `init.lua`: options, a plugin of your
   own, key maps. It wins over both.

A key you bind in `init.lua` always wins over one of Trim's defaults, and Trim's defaults are only bound where yours
are not.

## Binding Trim's modes

Every mode has a `<Plug>` mapping to bind to a key of your own:

| Plug | Mode |
|---|---|
| `<Plug>(trim-tree-toggle)`, `-tree-focus`, `-tree-filter` | The file tree |
| `<Plug>(trim-workspace)` | The workspace switcher |
| `<Plug>(trim-tabs-list)` | The list of open files |
| `<Plug>(trim-theme)`, `<Plug>(trim-font)` | The colour scheme and font pickers |
| `<Plug>(trim-find)`, `<Plug>(trim-grep)` | Find files and text |
| `<Plug>(trim-run)`, `-build`, `-run-pick`, `-problems` | Run and build |

```
vim.keymap.set('n', '<leader>p', '<Plug>(trim-find)')
```

For the nvim you use every day with your own config, use [Shim](../shim.md).
