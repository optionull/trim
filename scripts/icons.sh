#!/usr/bin/env bash
# Draw the app icons (scripts/icon.swift) and make Resources/Trim.icns, Resources/Shim.icns and the docs' PNGs.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swift "$root/scripts/icon.swift" "$work"
mkdir -p "$root/docs/images/png"
for app in Trim Shim; do
  set="$work/$app.iconset"
  mkdir -p "$set"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$work/$app-1024.png" --out "$set/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$work/$app-1024.png" --out "$set/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$set" -o "$root/Resources/$app.icns"
  lower="$(echo "$app" | tr '[:upper:]' '[:lower:]')"
  for size in 32 64 180 512; do
    sips -z $size $size "$work/$app-1024.png" --out "$root/docs/images/png/$lower-$size.png" >/dev/null
  done
done
echo "icons: Resources/Trim.icns, Resources/Shim.icns and docs/images/png"
