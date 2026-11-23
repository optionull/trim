#!/usr/bin/env bash
# Vendor/nvim: the Neovim release the apps carry as a fallback for installs that are not through Homebrew (the cask
# depends on Homebrew's neovim, which is always the one used first). Pinned and checksummed (NVIM_VERSION and
# NVIM_SHA256 in mise.toml), with Neovim's licence beside it: Apache 2.0, and the Vim licence for parts of the runtime.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version="${NVIM_VERSION:?NVIM_VERSION is not set (mise.toml)}"
sha="${NVIM_SHA256:?NVIM_SHA256 is not set (mise.toml)}"
dest="$root/Vendor/nvim"
if [ -x "$dest/bin/nvim" ] && [ "$(cat "$dest/VERSION" 2>/dev/null)" = "$version" ]; then exit 0; fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/nvim.tar.gz" "https://github.com/neovim/neovim/releases/download/$version/nvim-macos-arm64.tar.gz"
echo "$sha  $work/nvim.tar.gz" | shasum -a 256 -c - >/dev/null || { echo "nvim: checksum of $version does not match NVIM_SHA256" >&2; exit 1; }
tar -xzf "$work/nvim.tar.gz" -C "$work"
rm -rf "$dest"
mkdir -p "$dest"
cp -R "$work/nvim-macos-arm64/." "$dest/"
curl -fsSL -o "$dest/LICENSE.txt" "https://raw.githubusercontent.com/neovim/neovim/$version/LICENSE.txt"
grep -q "Apache License" "$dest/LICENSE.txt" || { echo "nvim: no licence text for $version" >&2; exit 1; }
echo "$version" >"$dest/VERSION"
echo "nvim: $version in $dest"
