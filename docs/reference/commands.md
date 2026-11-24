---
navigation_title: "Commands"
description: "The :Trim commands."
---

# Commands

| Command | What it does |
|---|---|
| `:TrimTree [toggle\|show\|hide\|focus\|filter\|ignored\|dotfiles]` | The file tree. |
| `:TrimWorkspace` | The workspace switcher. |
| `:TrimTabs [list\|top\|bottom\|right\|statusbar\|hide\|show\|toggle\|next\|prev\|close\|N\|max N\|autoclose]` | Tabs. |
| `:TrimStatusline [toggle\|show\|hide\|window\|editor]` | The status bar. |
| `:TrimTheme [name]` | The colour scheme picker, or set one by name. |
| `:TrimFont` | The font picker. |
| `:TrimFind`, `:TrimGrep` | Find files, find text. |
| `:TrimRun [default\|build\|pick\|terminal\|close\|problems\|lsp\|zen]` | Run and build. |
| `:TrimLsp [status\|restart\|stop] [name]` | Language servers. |
| `:TrimPackages` | Packages. |
| `:TrimWalk [file]` | Walkthroughs: choose one, or open a file. |
| `:ShimConfig [name]` | (Shim) Switch nvim config. |

## The `trim` tool

| Command | What it does |
|---|---|
| `trim walk new "<title>"` | A walkthrough skeleton in `.trim/walkthroughs`; prints its path. |
| `trim walk check <file> [--json]` | Check anchors, diagrams and structure; exit 1 on errors. |
| `trim walk stamp <file>` | Record each anchor's fingerprint and the commit. |
| `trim walk list [--json]`, `trim walk open <file>` | List the repository's walkthroughs; show one in Trim. |
| `trim walk format`, `trim skill install` | Print or install the agent skill. |
