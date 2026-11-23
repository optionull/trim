#!/usr/bin/env bash
# Sign build/Frame.app for distribution: Developer ID, the hardened runtime (notarization requires it) and a secure
# timestamp. Replaces bundle.sh's ad-hoc signature. Follows heed's scripts/sign.sh.
#
# No entitlements: nvim and the sidecar's dotnet are the user's own programs, started as child processes, so the
# hardened runtime does not cover them, and nothing in the bundle is code compiled at run time (the sidecar is
# managed code with no apphost).
#
#   scripts/sign.sh "Developer ID Application: Name (TEAMID)" [keychain]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
identity="${1:?usage: scripts/sign.sh <identity> [keychain]}"
app="${BUILD_DIR:-$root/build}/Frame.app"
keychain=()
[ -n "${2:-}" ] && keychain=(--keychain "$2")

# Tree-sitter's parsers are native code in Resources: each signed before the app (not yet run: signing is deferred).
codesign --force --options runtime --timestamp --sign "$identity" ${keychain[@]+"${keychain[@]}"} \
  "$app"/Contents/Resources/treesitter/parser/*.so
codesign --force --options runtime --timestamp --sign "$identity" ${keychain[@]+"${keychain[@]}"} "$app"
codesign --verify --strict --deep --verbose=2 "$app"
echo "sign: $app signed by $identity"
