#!/usr/bin/env bash
# Vendor/fonts: the Nerd Fonts symbols-only font Frame draws its icons with (the tree's file and folder glyphs, later the
# status bar's), so nobody has to install a patched font. Pinned to a release and its checksum; the licence files that
# come with it (SIL OFL 1.1 for the font, MIT for the scripts) are kept beside it and bundled with it.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version="v3.5.1"
sha256="fdca3682534f6f65e1ccb2345b0362ccf67d9b8eca7c8025330946e93e2473bc"
out="$root/Vendor/fonts"
if [ -f "$out/.version" ] && [ "$(cat "$out/.version")" = "$version" ] && ls "$out"/*.ttf >/dev/null 2>&1; then
  echo "fonts: $out is $version"
  exit 0
fi
# The download is untrusted until its checksum matches: a folder of its own, nothing run from it.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/symbols.zip" "https://github.com/ryanoasis/nerd-fonts/releases/download/$version/NerdFontsSymbolsOnly.zip"
actual="$(shasum -a 256 "$work/symbols.zip" | cut -d' ' -f1)"
if [ "$actual" != "$sha256" ]; then
  echo "fonts: NerdFontsSymbolsOnly.zip $version is $actual, not the pinned $sha256" >&2
  exit 1
fi
mkdir "$work/unpacked"
unzip -q "$work/symbols.zip" -d "$work/unpacked"
rm -rf "$out"
mkdir -p "$out"
cp "$work/unpacked/SymbolsNerdFontMono-Regular.ttf" "$out/"
for licence in LICENSE README.md; do
  [ -f "$work/unpacked/$licence" ] && cp "$work/unpacked/$licence" "$out/"
done
echo "$version" >"$out/.version"
echo "fonts: $out is $version"
