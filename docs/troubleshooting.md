---
navigation_title: "Troubleshooting"
description: "When Trim does not start, cannot find nvim, or a language server is missing."
---

# Troubleshooting

## "Neovim not found"

Trim looks for `nvim` on your `PATH` (it asks a login shell, then an interactive one, so mise and nvm setups work),
then in `/opt/homebrew/bin`, `/usr/local/bin` and `/opt/local/bin`, then in its own bundle. Install it with
`brew install neovim`. Trim needs 0.12 or later.

## A language server is missing

`name ✗` in the status bar means a server was given up on after dying five times in a minute. `:TrimLsp status`
says what each is doing and `:TrimLsp restart name` tries again.

C# and F# servers are .NET tools, so the **.NET SDK must be installed**. The web servers need **Node**. Trim says
so when one is missing.

## Files open without colours or completion

Files over 1 MB, or with a very long line, open plain on purpose so that opening is always quick
(`[editor] big_file_kb`, 0 turns it off).

## Start again from nothing

Quit Trim and move `~/.config/trim` and `~/.local/share/trim` aside. Trim writes them again.
