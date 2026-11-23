---
navigation_title: "Shim"
description: "Shim is nvim alone in a native window, with your own config, for the single file you want to edit now."
---

# Shim

Shim is nvim and nothing else in a native Metal window: the same grid, the same command line, completion and
messages drawn as native views, and **your own nvim config**. No tree, panels or servers of its own.

It starts instantly and is meant for the file you want to edit now. When you want a project, use [Trim](index.md).

There is no title bar by default. The window keeps macOS's rounded corners and shadow and moves by its margin
(`[shell] title_bar = true` brings the buttons back). ⌘+, ⌘- and ⌘0 size the font.

## Configs

nvim reads a config by its folder name (`NVIM_APPNAME`), so every folder in `~/.config` holding an `init.lua` or
`init.vim` is a config Shim can run. Choose one in the Config menu (⌃⌘1 to ⌃⌘9, or ⌃⌘] for the next), or
`:ShimConfig name` from inside nvim (`:ShimConfig` alone lists them through `vim.ui.select`, so your picker plugin
takes over). nvim restarts in the same window under it, in the same folder, with the files you had open and the
cursor where it was.

Unsaved changes are asked about first, a config that will not start puts the last one back, and the choice is
remembered. A `NVIM_APPNAME` set when Shim starts wins over it. Each config keeps its own plugins and lockfile, so
none disturbs another.

## Installed with Trim

`brew install --cask optionull/tap/trim` installs both. Shim uses the Neovim on your `PATH`, or the copy inside
Trim.app when they sit together.
