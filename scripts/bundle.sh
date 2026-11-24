#!/usr/bin/env bash
# Assemble build/Shim.app and build/Trim.app from the SwiftPM products: each app's binary, the nvim runtime
# (Contents/Resources/runtime), its Info.plist, then an ad-hoc signature (scripts/sign.sh signs for release).
#
#   scripts/bundle.sh debug|release
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
config="${1:-debug}"
products="$(cd "$root" && swift build -c "$config" --show-bin-path)"
# TRIM_VERSION is set by the release workflow from the release's tag; local builds say dev. The build number is the
# commit count, which only grows on main (pull requests are squash-merged). SillCommit names the commit.
version="${TRIM_VERSION:-0.1.0-dev}"
build="$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 0)"
commit="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo dev)"
# Tree-sitter's parsers, native code built ahead of time (once per $TREESITTER_COMMIT, into Vendor/treesitter) so no one
# needs a compiler; signed one by one, as the app's signature does not cover them.
nvim -l "$root/scripts/treesitter.lua" "$root/Vendor/treesitter"

# The shim: nvim alone in a native window. Its binary, the runtime and its own Info.plist.
shim="${BUILD_DIR:-$root/build}/Shim.app"
mkdir -p "$shim/Contents/MacOS" "$shim/Contents/Resources"
cp "$products/Shim" "$shim/Contents/MacOS/Shim"
rm -rf "$shim/Contents/Resources/runtime"
cp -R "$root/runtime" "$shim/Contents/Resources/runtime"
cp "$root/Resources/Shim.icns" "$shim/Contents/Resources/Shim.icns"
sed -e "s/__VERSION__/$version/g" -e "s/__BUILD__/$build/g" -e "s/__COMMIT__/$commit/g" \
  "$root/Resources/Shim-Info.plist" >"$shim/Contents/Info.plist"
codesign --force --sign - "$shim"
echo "bundle: $shim"

# Trim: Shim's host with native panes around nvim (a working title). Its binary, sill's runtime and its own Info.plist.
frame="${BUILD_DIR:-$root/build}/Trim.app"
mkdir -p "$frame/Contents/MacOS" "$frame/Contents/Resources"
cp "$products/Trim" "$frame/Contents/MacOS/Trim"
rm -rf "$frame/Contents/Resources/runtime"
cp -R "$root/runtime" "$frame/Contents/Resources/runtime"
# The icon font the tree draws with, from Vendor/fonts (downloaded once, checksummed), licence files beside it.
"$root/scripts/fonts.sh" >/dev/null
rm -rf "$frame/Contents/Resources/fonts"
mkdir -p "$frame/Contents/Resources/fonts"
cp "$root"/Vendor/fonts/* "$frame/Contents/Resources/fonts/"
# The plugins Trim carries (scripts/plugins.txt, pinned), where its runtime finds them; and the tree-sitter parsers, as
# Sill has them (built once into Vendor/treesitter by the step above), signed one by one.
"$root/scripts/plugins.sh" >/dev/null
mkdir -p "$frame/Contents/Resources/runtime/pack/trim/start"
cp -R "$root"/Vendor/plugins/* "$frame/Contents/Resources/runtime/pack/trim/start/"
rm -rf "$frame/Contents/Resources/treesitter"
cp -R "$root/Vendor/treesitter" "$frame/Contents/Resources/treesitter"
codesign --force --sign - "$frame"/Contents/Resources/treesitter/parser/*.so
cp "$root/Resources/Trim.icns" "$frame/Contents/Resources/Trim.icns"
sed -e "s/__VERSION__/$version/g" -e "s/__BUILD__/$build/g" -e "s/__COMMIT__/$commit/g" \
  "$root/Resources/Trim-Info.plist" >"$frame/Contents/Info.plist"
# Neovim itself, as a fallback (the apps use the one on the PATH first): the pinned release with its licence.
"$root/scripts/nvim.sh" >/dev/null
rm -rf "$frame/Contents/Resources/nvim"
cp -R "$root/Vendor/nvim" "$frame/Contents/Resources/nvim"
codesign --force --sign - "$frame/Contents/Resources/nvim/bin/nvim"
# The `trim` tool agents use to write and check walkthroughs (the cask links it onto the PATH).
mkdir -p "$frame/Contents/Helpers"
cp "$products/trim-cli" "$frame/Contents/Helpers/trim"
codesign --force --sign - "$frame/Contents/Helpers/trim"
codesign --force --sign - "$frame"
echo "bundle: $frame"
for wanted in fonts/SymbolsNerdFontMono-Regular.ttf fonts/LICENSE ../Helpers/trim nvim/bin/nvim nvim/LICENSE.txt runtime/plugin/trim.lua runtime/pack/trim/start/tokyonight.nvim/colors/tokyonight-night.lua treesitter/parser/c_sharp.so; do
  if [ ! -f "$frame/Contents/Resources/$wanted" ]; then
    echo "bundle: $wanted is missing from Trim" >&2
    exit 1
  fi
done
