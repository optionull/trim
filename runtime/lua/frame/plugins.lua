-- Frame's bundled plugins, set up. A plugin that is not there (left out in the settings' `plugins.disabled`, or not carried)
-- is skipped; one whose setup fails says so and the rest go on. What a plugin binds is described, so which-key shows it.
local M = {}

local function present(module)
  local path = module:gsub('%.', '/')
  return #vim.api.nvim_get_runtime_file('lua/' .. path .. '.lua', false) > 0
    or #vim.api.nvim_get_runtime_file('lua/' .. path .. '/init.lua', false) > 0
end

--- { plugin folder, a module that tells it is there, how it is set up }
M.specs = {
  {
    name = 'which-key.nvim',
    module = 'which-key',
    setup = function(settings)
      local wk = require('which-key')
      wk.setup({
        preset = 'modern',
        -- How long a key sequence waits before the hints show (the settings' `whichkey.delay`, in milliseconds).
        delay = (settings.whichkey or {}).delay or 300,
        icons = { mappings = false },
        win = { border = 'rounded', padding = { 1, 2 } },
        sort = { 'local', 'order', 'group', 'alphanum' },
      })
      wk.add(require('frame.keys').groups)
    end,
  },
  {
    name = 'mini.nvim',
    module = 'mini.pairs',
    setup = function()
      -- Pairs, surround (sa, sd, sr), more text objects (a and i), and [ ] jumps.
      require('mini.pairs').setup()
      require('mini.surround').setup()
      require('mini.ai').setup()
      require('mini.bracketed').setup()
    end,
  },
  {
    name = 'gitsigns.nvim',
    module = 'gitsigns',
    setup = function()
      require('gitsigns').setup({
        signs = { add = { text = '▎' }, change = { text = '▎' }, delete = { text = '' }, topdelete = { text = '' }, changedelete = { text = '▎' } },
        on_attach = function(buffer)
          local gs = package.loaded.gitsigns
          local function map(lhs, rhs, desc) vim.keymap.set('n', lhs, rhs, { buffer = buffer, desc = desc }) end
          map(']h', function() gs.nav_hunk('next') end, 'Next change')
          map('[h', function() gs.nav_hunk('prev') end, 'Previous change')
          map('<leader>gs', gs.stage_hunk, 'Stage the change')
          map('<leader>gr', gs.reset_hunk, 'Reset the change')
          map('<leader>gp', gs.preview_hunk, 'Preview the change')
          map('<leader>gb', function() gs.blame_line({ full = true }) end, 'Blame the line')
          map('<leader>gd', gs.diffthis, 'Diff against the index')
        end,
      })
    end,
  },
}

function M.setup()
  local settings = vim.g.frame_settings or {}
  for _, spec in ipairs(M.specs) do
    if present(spec.module) then
      local ok, err = pcall(spec.setup, settings)
      if not ok then vim.notify('Frame: ' .. spec.name .. ' did not start: ' .. tostring(err), vim.log.levels.WARN) end
    end
  end
end

return M
