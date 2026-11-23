#!/usr/bin/env bash
# Redraw the documentation's pictures (docs/images/shots) from Trim.app, off a fixed fixture, in Trim's default look
# (an empty config home). Every picture is drawn by the self-check (TRIM_CHECK_ONLY=docshots), so they cannot drift
# from the app.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
app="${BUILD_DIR:-$root/build}/Trim.app/Contents/MacOS/Trim"
[ -x "$app" ] || { echo "shots: no $app (mise run build first)" >&2; exit 1; }
config="$(mktemp -d)"
trap 'rm -rf "$config"' EXIT
out="$root/docs/images/shots"
mkdir -p "$out"
TRIM_CHECK=1 TRIM_CHECK_ONLY=docshots TRIM_DOC_SHOTS="$out" XDG_CONFIG_HOME="$config" \
  perl -e 'alarm 300; exec @ARGV' "$app" 2>&1 | grep -E "^(ok|trim check)"
ls "$out"
