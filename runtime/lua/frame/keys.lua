-- Frame's default keys. Every mode of the window (the tree, its filter, the workspace switcher, the list of open files)
-- has one on the leader, set only where the config has bound nothing there: your own keys are never replaced, and
-- `<Plug>` mappings are there to bind any of them to others. Each says what it is for, so which-key shows them.
local M = {}

--- { key, what it does (a <Plug> mapping), its description }
M.defaults = {
  { '<leader>e', '<Plug>(frame-tree-toggle)', 'File tree' },
  { '<C-w>e', '<Plug>(frame-tree-focus)', 'File tree' },
  { '<leader>E', '<Plug>(frame-tree-filter)', 'Filter the file tree' },
  { '<leader>o', '<Plug>(frame-workspace)', 'Switch workspace' },
  { '<leader>O', '<Plug>(frame-tabs-list)', 'Open files' },
  { '<leader>fw', '<Plug>(frame-workspace)', 'Switch workspace' },
  { '<leader>fo', '<Plug>(frame-tabs-list)', 'Open files' },
}

--- Binds those the config has not bound, and returns the keys it bound.
function M.apply()
  local bound = {}
  for _, key in ipairs(M.defaults) do
    if vim.fn.maparg(key[1], 'n') == '' then
      vim.keymap.set('n', key[1], key[2], { remap = true, desc = key[3] })
      bound[#bound + 1] = key[1]
    end
  end
  return bound
end

return M
