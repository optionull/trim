#!/usr/bin/env bash
# Assemble build/Sill.app from the SwiftPM product: the app binary, sill's nvim runtime (Contents/Resources/runtime),
# Info.plist, then an ad-hoc signature. Follows heed's scripts/bundle.sh; Sparkle joins at M9.
#
#   scripts/bundle.sh debug|release
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
config="${1:-debug}"
products="$(cd "$root" && swift build -c "$config" --show-bin-path)"
app="${BUILD_DIR:-$root/build}/Sill.app"
# SILL_VERSION will be set by the release workflow from the release's tag; local builds say dev. The build number is
# the commit count, which only grows on main (pull requests are squash-merged). SillCommit names the commit.
version="${SILL_VERSION:-0.1.0-dev}"
build="$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 0)"
commit="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo dev)"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$products/SillApp" "$app/Contents/MacOS/Sill"
rm -rf "$app/Contents/Resources/runtime"
cp -R "$root/runtime" "$app/Contents/Resources/runtime"
sed -e "s/__VERSION__/$version/g" -e "s/__BUILD__/$build/g" -e "s/__COMMIT__/$commit/g" \
  "$root/Resources/Info.plist" >"$app/Contents/Info.plist"
codesign --force --sign - "$app"
if [ ! -f "$app/Contents/Resources/runtime/plugin/sill.lua" ]; then
  echo "bundle: sill's runtime is missing from the app" >&2
  exit 1
fi
echo "bundle: $app ($version, build $build, $commit)"
