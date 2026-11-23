---
navigation_title: "Tabs"
description: "Open files as tabs in the status bar, over the editor, or in a list at the side."
---

# Tabs

The open files are tabs (nvim's buffers), and show only when more than one file is open. By default they live in
the status bar: the file's name there, with `▾ 3`, opens a list of the open files when clicked, or with ⌥⌘E,
`:TrimTabs list` or `<leader>t`.

View ▸ Tabs puts them over the editor, under it or as a list at its right instead, or hides them
(`:TrimTabs top|bottom|right|statusbar|hide|show|toggle`). The choice is remembered.

## What a tab shows

Each has the file's icon in its colour. The shown one is on the colour scheme's selection colour. A file you never
edited is in italics (a preview), and one with changes has a dot.

## Too many tabs

Past a maximum (10 by default, `:TrimTabs max N`, 0 for none) the tabs you never edited are closed, least recently
used first. An edited tab, one with changes and the one showing are never closed. View ▸ Tabs ▸ Close Unedited
Tabs Past the Maximum turns it off.

## Keys

| Key | What it does |
|---|---|
| ⌃⇥, ⌃⇧⇥ (also ⌘⇧], ⌘⇧[) | Next and previous tab. |
| ⌘W | Close the current tab. |
| Middle click, the close mark | Close a tab. |

In the build and Run panes the same keys go to the pane's own tabs while it has the keyboard.
