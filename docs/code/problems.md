---
navigation_title: "Problems"
description: "One list of everything that is wrong: language server diagnostics and build errors."
---

# Problems

⇧⌘M (or `<leader>rq`, or a click on the problem counts in the status bar) opens Problems with the keyboard in it.
It is one list of everything that is wrong: the diagnostics of every file nvim has open, and what the last build
printed (MSBuild, tsc, swiftc, clang, gcc, rustc), worst first, kept up to date as they change.

| Key | What it does |
|---|---|
| `e` `w` `i` `h` | Toggle errors, warnings, info and hints (or click). |
| `/` | Filter. |
| Return | Go to the line. |
| Alt+Enter | Go there and ask for the code actions. |
| Escape | Back to the code. |

In the tree a file with a diagnostic has a wavy line in the colour of its worst one.
