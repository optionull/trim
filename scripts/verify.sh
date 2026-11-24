#!/bin/bash
# Lint, tests and the self-checks of Shim and Trim; stops at the first failure (mise run verify).
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"
F=$REPO/scripts/fixtures
LOGS=$(mktemp -d /tmp/sill-verify.XXXX)
SKIPPED=""
mise run fmt >/dev/null 2>&1
# Lint's own status is not used: under pipefail a failing lint would make the test false and pass.
lint=$(mise run lint 2>&1 || true)
if echo "$lint" | grep -E "error|warning"; then echo "LINT FAILED"; exit 1; fi
mise run test > $LOGS/test.log 2>&1 || { tail -30 $LOGS/test.log; exit 1; }
passed=$(grep -c "Test run .*passed" $LOGS/test.log || true)
grep "Test run" $LOGS/test.log
[ "$passed" -ge 4 ] || { echo "only $passed suites passed"; exit 1; }
mise run build 2>&1 | tail -1
rm -rf /tmp/sill-shim-configs && mkdir -p /tmp/sill-shim-configs/alpha && printf 'vim.g.shim_marker = "alpha"\n-- A start screen of the config'"'"'s own, which Shim must close (Shim draws no dashboards).\nvim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))\nvim.bo.filetype = "alpha"\nvim.g.shim_dashboard = vim.api.nvim_get_current_buf()\n' >/tmp/sill-shim-configs/alpha/init.lua
out=$(cd /tmp && perl -e 'alarm 120; exec @ARGV or die' env SILL_SHIM_CHECK=1 XDG_CONFIG_HOME=/tmp/sill-shim-configs "$REPO/build/Shim.app/Contents/MacOS/Shim" 2>&1 | grep -E "^shim check" || true)
echo "$out" | grep -q "^shim check: passed$" || { echo "$out"; echo "CHECK shim FAILED"; exit 1; }
echo "shim check: passed"
# Trim's own config home: its additions (~/.config/trim) must load, a config of nvim's own (~/.config/nvim) must not.
rm -rf /tmp/trim-configs && mkdir -p /tmp/trim-configs/trim /tmp/trim-configs/nvim
printf 'vim.g.trim_user = "user"\nvim.g.mapleader = ","\n' >/tmp/trim-configs/trim/init.lua
printf 'vim.g.nvim_config_leaked = "yes"\n' >/tmp/trim-configs/nvim/init.lua
printf '[theme]\ncolorscheme = "rose-pine"\n' >/tmp/trim-configs/trim/settings.toml
out=$(cd /tmp && perl -e 'alarm 120; exec @ARGV or die' env TRIM_CHECK=1 XDG_CONFIG_HOME=/tmp/trim-configs "$REPO/build/Trim.app/Contents/MacOS/Trim" 2>&1 | grep -E "^trim check" || true)
echo "$out" | grep -q "^trim check: passed$" || { echo "$out"; echo "CHECK frame FAILED"; exit 1; }
echo "trim check: passed"
echo "ALL VERIFIED${SKIPPED:+ (skipped: $SKIPPED)}"
