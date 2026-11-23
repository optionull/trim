---
navigation_title: "Installation"
description: "Install Trim and Shim with Homebrew, what they need, and how to build from source."
---

# Installation

## Homebrew

```sh
brew install --cask optionull/tap/trim
```

This installs **Trim.app** and **Shim.app** together, and Neovim too if you do not have it (the cask depends on
Homebrew's `neovim`, so it is always the current one).

## What it needs

| | |
|---|---|
| macOS | 15 (Sequoia) or later, on Apple silicon |
| Neovim | 0.12 or later. Trim uses the `nvim` on your `PATH` first. Trim.app also carries a copy as a fallback for installs that are not through Homebrew, and Shim uses that one when it sits beside Trim.app. |
| Language servers | Found on your `PATH` or fetched on first use. C# and F# need the .NET SDK; the web servers need Node. See [Language servers](../code/language-servers.md). |

## From source

Trim builds with Swift and the tools in `mise.toml`.

```sh
git clone git@github.com:optionull/trim.git
cd trim
mise run ghostty   # GhosttyKit, once (needs Xcode and its Metal toolchain)
mise run build     # builds build/Trim.app and build/Shim.app
```

See `docs/development.md` in the repository for the rest.
