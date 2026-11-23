---
navigation_title: "The status bar"
description: "What the bar under the editor shows, and how to move or replace it."
---

# The status bar

The bar under the editor shows the mode (nvim's, or TREE, FILTER, SWITCH, RUN, BUILD while the keyboard is in
a pane), the file relative to the workspace with its icon and a mark when it is changed, and on the right the
diagnostics, the language servers, the file type and the position. The workspace button under the tree shows the
repository and branch.

A path too long for the room loses its front folders, never the file's name. While the tree is hidden the branch
joins the bar.

## Across the window

View ▸ Status Bar Across Window (`:TrimStatusline window`; `:TrimStatusline editor` puts it back) makes one bar
across the whole window with the workspace as its first segment.

## Turning it off

nvim's own status line is off while Trim's bar shows, and put back when it hides (`:TrimStatusline
[toggle|show|hide]`). Set `vim.g.trim_statusline = false` in your `init.lua` to keep your own (lualine and the
like).
