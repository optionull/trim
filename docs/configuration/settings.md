---
navigation_title: "settings.toml"
description: "Every setting in ~/.config/trim/settings.toml."
---

# settings.toml

`~/.config/trim/settings.toml` (or the file `$TRIM_SETTINGS` names). A value that is commented out is at its
default. The file is made the first time Trim changes a setting itself, and editing it by hand has the same effect as
the settings window.

```toml
[editor]
leader = "\\"
font = "JetBrains Mono"
font_size = 13
line_height = 1.2
tabwidth = 4
expandtab = true
wrap = false
number = true
relativenumber = false
scrolloff = 4
smooth_scroll = true
pixelscroll = true
big_file_kb = 1024

[theme]
colorscheme = "tokyonight-night"

[plugins]
disabled = []

[whichkey]
delay = 400

[lsp]
autostart = true

[home]
roots = ["~/Projects"]

[shell]
title_bar = false
```

| Setting | Meaning |
|---|---|
| `editor.leader` | The leader key. Takes effect on the next start. |
| `editor.font`, `font_size`, `line_height` | The editor font, its size in points, and its line height as a multiple. |
| `editor.tabwidth`, `expandtab`, `wrap`, `number`, `relativenumber`, `scrolloff` | nvim's own options of those names. |
| `editor.smooth_scroll` | Slide the text when nvim scrolls by less than a screenful. |
| `editor.pixelscroll` | A trackpad scrolls by the pixel. `false` puts it back on line slides. |
| `editor.big_file_kb` | Files over this size (or with a very long line) open plain: no tree-sitter, folds, undo or language server. 0 turns it off. |
| `theme.colorscheme` | The colour scheme, by its `:colorscheme` name. |
| `plugins.disabled` | Bundled plugins left out, by name. |
| `whichkey.delay` | Milliseconds before which-key shows its hints. |
| `lsp.autostart` | Start servers when a folder opens, from its project files. |
| `home.roots` | Folders the workspace switcher looks in. |
| `shell.title_bar` | Give the window a title bar with its buttons. |
