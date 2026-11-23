# Trim

A trimmed IDE around Neovim, for the Mac. Native panes (a file tree, tabs, a run pane, a workspace switcher), completion
and hover drawn by the window, and your editing still in nvim.

![Trim: a file tree with git marks beside Neovim editing C#](docs/images/shots/window.png)

Trim comes with **Shim**, a lightweight native nvim for the single file you want to edit now, with your own config.

## Install

```sh
brew install --cask optionull/tap/trim
```

Installs Trim.app and Shim.app (and Neovim, if you have none). macOS 15 or later, Apple silicon.

## What you get

- **A file tree that knows git**: branch, changed and new files, diagnostics on files and folders, a live filter.
- **Workspaces**: a search line over your repositories and worktrees, named by what the work is about.
- **Language servers** that start from your project files, recover when they crash and never touch your editor.
- **Completion, hover and signature help** drawn by the window: kind icons, deprecated candidates struck through,
  documentation in a panel beside the menu, highlighted code, overloads you can step through.
- **Run and build**: F5 and ⇧⌘B, read from what the folder offers (.NET, Swift, Rust, Makefiles, mise, just, npm, VS Code
  tasks), with the output in a tab each, its exit status, and run again.
- **Colour schemes and fonts** chosen from lists where each one is tried live.
- **Fast on purpose**: opening a file never waits for a plugin; big files open plain.
- Its **own isolated nvim config**: nothing in `~/.config/nvim` can break it.

Read the [documentation](https://trim.optionull.app/).

## Building

```sh
mise run ghostty   # GhosttyKit, once (needs Xcode and its Metal toolchain)
mise run build     # build/Trim.app and build/Shim.app
mise run verify    # lint, tests and the self-checks
```

See [Developing Trim](docs/development.md).

## Licence

MIT, see [LICENSE](LICENSE). Third-party code and licences are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
