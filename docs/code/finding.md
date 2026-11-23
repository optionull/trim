---
navigation_title: "Finding"
description: "Find files by name and text in files, in the workspace."
---

# Finding

Both are modes of their own, drawn by Trim.

- **Files:** `<leader>ff`, ⌘P or `:TrimFind` lists the workspace's files (git's own list in a repository, the
  ignored ones left out) and ranks them as you type, the name counting above its folders.
- **Text:** `<leader>fg`, ⇧⌘F or `:TrimGrep` finds lines containing the text with `git grep`, so no ripgrep is
  needed.

Return opens the file (on the line), Escape goes back at once.
