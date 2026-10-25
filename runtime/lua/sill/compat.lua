-- The person's own nvim config inside sill (`[nvim] config = "yours"`): what sill draws itself is turned off in their
-- plugins, once they have loaded, so nothing is there twice. Each step is a guess at a plugin's own off switch, and
-- does nothing when the plugin is not there. `vim.g.sill` tells a config it runs inside sill, for its own conditions.
local M = {}

local function try(f) pcall(f) end

function M.apply()
  -- Messages and the command line are sill's: a notifier or noice drawing them again is turned off.
  try(function() require('noice').disable() end)
  local base = package.loaded['sill.base']
  if base and base.notify then vim.notify = base.notify end
  try(function() Snacks.config.notifier.enabled = false end)
  -- The explorer is sill's: snacks' does not take over a folder opened.
  try(function() Snacks.config.explorer.replace_netrw = false end)
  -- No start screen: a dashboard buffer goes, an empty one in its place.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local filetype = vim.bo[buf].filetype
    if filetype == 'snacks_dashboard' or filetype == 'dashboard' or filetype == 'alpha' or filetype == 'starter' then
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        vim.api.nvim_win_call(win, function() vim.cmd('enew') end)
      end
      try(function() vim.api.nvim_buf_delete(buf, { force = true }) end)
    end
  end
  -- Its explorer windows (snacks, neo-tree, nvim-tree), if one opened at start.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local filetype = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
    if filetype == 'snacks_layout_box' or filetype == 'snacks_picker_list' or filetype == 'neo-tree'
      or filetype == 'NvimTree' then
      try(function() vim.api.nvim_win_close(win, true) end)
    end
  end
end

return M
