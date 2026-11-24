-- Shim's nvim: what runs once nvim has started and the person's own config has had its turn (plugin/sill.lua, and
-- EditorSession after attaching). Trim has its own (trim.init) and stands down here.
local M = {}

function M.setup()
  if vim.g.trim or vim.g.loaded_sill then return end
  vim.g.loaded_sill = true
  -- Files changed on disk (by a tool, a build) are read again.
  vim.o.autoread = true
  -- Shim draws messages, the command line and the start screen itself: what the person's plugins draw too is turned
  -- off once they have loaded (and again a moment later, for what loads lazily on VimEnter).
  local function compat() require('sill.compat').apply() end
  if vim.v.vim_did_enter == 1 then
    compat()
  else
    vim.api.nvim_create_autocmd('VimEnter', {
      once = true,
      callback = function()
        compat()
        vim.defer_fn(compat, 300)
      end,
    })
  end
end

return M
