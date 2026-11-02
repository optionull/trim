#!/bin/bash
# A stand-in for a person's nvim config at $1/nvim (XDG_CONFIG_HOME=$1), doing what LazyVim's plugins do that sill
# draws itself: a start screen on VimEnter, and its own vim.notify.
set -euo pipefail
rm -rf "$1" && mkdir -p "$1/nvim"
cat > "$1/nvim/init.lua" <<'LUA'
vim.g.user_config_loaded = true
vim.notify = function(msg) vim.g.notified = msg end
vim.api.nvim_create_autocmd('VimEnter', { callback = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = 'snacks_dashboard'
  vim.api.nvim_win_set_buf(0, buf)
end })
LUA
