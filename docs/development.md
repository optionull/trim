---
navigation_title: "Developing Trim"
description: "Build, test and release Trim and Shim: the toolchain, the self-checks, the pictures and the docs."
---

# Developing Trim

## Building

Tools come from mise (`mise.toml`): Zig for GhosttyKit, SwiftFormat and SwiftLint. Xcode with the Metal toolchain and
Neovim 0.12 or later are needed too; `mise run doctor` checks.

```sh
mise run ghostty   # build Vendor/GhosttyKit.xcframework once (without it, terminal panes show a stand-in)
mise run build     # debug build: build/Trim.app and build/Shim.app
mise run dev       # build and open Trim.app
mise run test      # the Swift Testing suite; the nvim tests start a real `nvim --embed`
mise run lint
mise run verify    # lint, tests and the self-checks of Shim and Trim, stopping at the first failure
```

The build makes what the repository does not track: `Vendor/treesitter` (the parsers the apps ship, about a minute, again
only when `TREESITTER_COMMIT` moves), the icon font, the bundled plugins (`scripts/plugins.txt` pins each to a commit) and
the Neovim the apps carry as a fallback (`NVIM_VERSION` and its checksum in `mise.toml`).

## The self-check

`TRIM_CHECK=1 build/Trim.app/Contents/MacOS/Trim` plays the first week in the real app, with key events sent through the
window, and exits non-zero on the first failing step. `TRIM_CHECK_ONLY=tabs,scroll` runs those groups alone. Each check
has been broken on purpose (mutated) to confirm it can fail; keep doing that for new ones. A dialog in a check is a
failure that says what it asked, never a hang.

## Pictures and docs

Every picture in the docs is drawn by the app from a fixed fixture: `mise run shots` runs the `docshots` group of the
self-check into `docs/images/shots`. `mise run docs` builds the documentation with [docs-builder](https://github.com/elastic/docs-builder)
and serves it with the landing page over its home page. `mise run icons` draws the app icons.

## Releases

Pull requests merged to `main` keep a draft release up to date (release-drafter). The **release** workflow, run by hand,
builds, signs with the Developer ID, notarizes, packages `Trim.app` and `Shim.app` in one zip, publishes the draft and
updates the Homebrew cask in `optionull/homebrew-tap`. `scripts/release-secrets.sh` stores the signing and notarization
secrets. A dry run builds, signs and notarizes and keeps the zip on the run.

## Licences

Third-party code and licences: [THIRD_PARTY_NOTICES.md](https://github.com/optionull/trim/blob/main/THIRD_PARTY_NOTICES.md).
