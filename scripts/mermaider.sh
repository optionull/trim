#!/usr/bin/env bash
# Builds Mermaider's native library (the NativeAOT build with a C ABI, see Mermaider.Native in nullean/mermaider) into
# Vendor/Mermaider/mermaider.dylib, which Trim loads to draw ```mermaid diagrams. Without it Trim runs and a diagram stays source.
#
#   MERMAIDER_SRC=~/Projects/mermaider mise run mermaider          # a checkout that has src/Mermaider.Native
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
src="${MERMAIDER_SRC:-}"
if [ -z "$src" ] || [ ! -f "$src/src/Mermaider.Native/Mermaider.Native.csproj" ]; then
  echo "set MERMAIDER_SRC to a Mermaider checkout that has src/Mermaider.Native (got: '${src}')" >&2
  exit 2
fi
case "$(uname -m)" in
  arm64) rid=osx-arm64 ;;
  x86_64) rid=osx-x64 ;;
  *) echo "no runtime identifier for $(uname -m)" >&2; exit 2 ;;
esac
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
dotnet publish "$src/src/Mermaider.Native/Mermaider.Native.csproj" -r "$rid" -c Release -o "$out" >/dev/null
mkdir -p "$here/Vendor/Mermaider"
cp "$out/mermaider.dylib" "$here/Vendor/Mermaider/mermaider.dylib"
echo "Vendor/Mermaider/mermaider.dylib ($(wc -c <"$here/Vendor/Mermaider/mermaider.dylib" | tr -d ' ') bytes, $rid)"
