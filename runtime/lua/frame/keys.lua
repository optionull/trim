-- Frame's default keys. Every mode of the window (the tree, its filter, the workspace switcher, the list of open files)
-- has one on the leader (lowercase for the common jumps: e, w, t, o), set only where the config has bound nothing there: your own keys are never replaced, and
-- `<Plug>` mappings are there to bind any of them to others. Each says what it is for, so which-key shows them.
local M = {}

--- { key, what it does (a <Plug> mapping), its description }
M.defaults = {
  { '<leader>e', '<Plug>(frame-tree-toggle)', 'File tree' },
  { '<C-w>e', '<Plug>(frame-tree-focus)', 'File tree' },
  { '<leader>E', '<Plug>(frame-tree-filter)', 'Filter the file tree' },
  { '<leader>w', '<Plug>(frame-workspace)', 'Switch workspace' },
  { '<leader>t', '<Plug>(frame-tabs-list)', 'Open files (tabs)' },
  { '<leader>c', '<Plug>(frame-theme)', 'Colour scheme' },
  { '<leader>F', '<Plug>(frame-font)', 'Font' },
  { '<leader>P', '<Plug>(frame-packages)', 'Packages' },
  { '<leader>ff', '<Plug>(frame-find)', 'Find file' },
  { '<leader>fg', '<Plug>(frame-grep)', 'Find in files' },
  { '<leader>rr', '<Plug>(frame-run)', 'Run' },
  { '<leader>rb', '<Plug>(frame-build)', 'Build' },
  { '<leader>rp', '<Plug>(frame-run-pick)', 'Choose what to run' },
  { '<leader>rq', '<Plug>(frame-problems)', 'Problems from the terminal' },
  { '<leader>lp', '<Plug>(frame-lsp)', 'Language servers panel' },
  { '<leader>uz', '<Plug>(frame-zen)', 'Zen mode' },
  { '<leader>rt', '<Plug>(frame-terminal)', 'Terminal pane' },
  { '<leader>rx', '<Plug>(frame-terminal-close)', 'Close the terminal pane' },
  { '<leader>o', '<Plug>(frame-tabs-list)', 'Open files (tabs)' },
  { '<leader>fw', '<Plug>(frame-workspace)', 'Switch workspace' },
  { '<leader>fo', '<Plug>(frame-tabs-list)', 'Open files' },
}

--- The groups which-key names: what follows each prefix of Frame's own keys (a spec for `which-key.add`).
M.groups = {
  { '<leader>f', group = 'files' },
  { '<leader>g', group = 'git' },
  { '<leader>l', group = 'language' },
  { '<leader>r', group = 'run and build' },
  { '<leader>u', group = 'ui' },
  { 'g', group = 'goto' },
  { 'z', group = 'folds and view' },
  { '[', group = 'previous' },
  { ']', group = 'next' },
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
  -- which-key reads the mappings once it has loaded: keys bound after that (these, a config's) need it told.
  if package.loaded['which-key.buf'] then
    pcall(function() require('which-key.buf').clear() end)
    pcall(function() require('which-key.state').setup() end)
  end
  return bound
end

return M
