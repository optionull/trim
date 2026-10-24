#!/usr/bin/env bash
# Assemble build/Sill.app from the SwiftPM product: the app binary, sill's nvim runtime (Contents/Resources/runtime),
# the .NET sidecar (Contents/Resources/sidecar, framework-dependent: it runs on the user's dotnet), Info.plist, then an
# ad-hoc signature. Follows heed's scripts/bundle.sh; Sparkle joins at M9.
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
# The sidecar: managed code only, no apphost, so nothing in it is native code to sign.
rm -rf "$app/Contents/Resources/sidecar"
dotnet publish "$root/sidecar/Sill.Sidecar" -c Release -o "$app/Contents/Resources/sidecar" -nologo -v q >/dev/null
# The debug adapter (M8), a process of its own on the same dotnet; dbgshim, the native part, is downloaded where sill runs.
rm -rf "$app/Contents/Resources/debugger"
dotnet publish "$root/sidecar/Sill.DebugAdapter" -c Release -o "$app/Contents/Resources/debugger" -nologo -v q >/dev/null
# Mach-O would need signing; a Windows native binary (TraceEvent's helpers) is dead weight, and not all of it is ours to ship.
native="$(find "$app/Contents/Resources/sidecar" "$app/Contents/Resources/debugger" -type f -exec file {} + | grep -iE 'Mach-O|PE32.*for MS Windows' | grep -v 'Mono/.Net assembly' || true)"
if [ -n "$native" ]; then
  echo "bundle: the sidecar carries native code, which would need signing: $native" >&2
  exit 1
fi
sed -e "s/__VERSION__/$version/g" -e "s/__BUILD__/$build/g" -e "s/__COMMIT__/$commit/g" \
  "$root/Resources/Info.plist" >"$app/Contents/Info.plist"
codesign --force --sign - "$app"
for wanted in runtime/plugin/sill.lua sidecar/Sill.Sidecar.dll; do
  if [ ! -f "$app/Contents/Resources/$wanted" ]; then
    echo "bundle: $wanted is missing from the app" >&2
    exit 1
  fi
done
echo "bundle: $app ($version, build $build, $commit)"

# The shell: nvim alone in a native window. Its binary, sill's runtime and its own Info.plist; no sidecar.
shell="${BUILD_DIR:-$root/build}/Sill Shell.app"
mkdir -p "$shell/Contents/MacOS" "$shell/Contents/Resources"
cp "$products/SillShell" "$shell/Contents/MacOS/SillShell"
rm -rf "$shell/Contents/Resources/runtime"
cp -R "$root/runtime" "$shell/Contents/Resources/runtime"
sed -e "s/__VERSION__/$version/g" -e "s/__BUILD__/$build/g" -e "s/__COMMIT__/$commit/g" \
  "$root/Resources/Shell-Info.plist" >"$shell/Contents/Info.plist"
codesign --force --sign - "$shell"
echo "bundle: $shell"
