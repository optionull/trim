#!/usr/bin/env bash
# Sign build/Trim.app and build/Shim.app for distribution: Developer ID, the hardened runtime (notarization requires
# it) and a secure timestamp, inside out (the native code in Resources, then each app). Replaces bundle.sh's ad-hoc
# signatures. Follows yabar's scripts/sign.sh.
#
# No entitlements: nvim and the language servers are the user's own programs, started as child processes, so the
# hardened runtime does not cover them. A bundled nvim (the fallback, Resources/nvim/bin/nvim) is code of ours to sign.
#
#   scripts/sign.sh "Developer ID Application: Name (TEAMID)" [keychain]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
identity="${1:?usage: scripts/sign.sh <identity> [keychain]}"
build="${BUILD_DIR:-$root/build}"
keychain=()
[ -n "${2:-}" ] && keychain=(--keychain "$2")

sign() { codesign --force --options runtime --timestamp --sign "$identity" ${keychain[@]+"${keychain[@]}"} "$@"; }

for app in "$build/Trim.app" "$build/Shim.app"; do
  [ -d "$app" ] || { echo "sign: no $app (run scripts/bundle.sh first)" >&2; exit 1; }
  # Native code in Resources: tree-sitter's parsers, and nvim when the app carries one.
  while IFS= read -r file; do sign "$file"; done < <(find "$app/Contents/Resources" -type f \
    \( -name '*.so' -o -name '*.dylib' -o -path '*/nvim/bin/nvim' \))
  sign "$app"
  codesign --verify --strict --deep --verbose=2 "$app"
  echo "sign: $app signed by $identity"
done
