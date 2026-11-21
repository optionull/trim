-- The colour scheme's word on what is selected (nvim's `Visual`, or the group `vim.g.frame_selection_group` names), told
-- to the app as `frame_theme` so the tree's selection and the tabs' are the one colour, the scheme's own.
local M = {}

local function notify(method, arg)
  local channel = vim.g.sill_channel
  if channel then pcall(vim.rpcnotify, channel, method, arg) end
end

--- The group's background, or nil when the scheme gives it none.
function M.selection()
  local group = vim.g.frame_selection_group or 'Visual'
  local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
  return hl.bg
end

function M.send()
  notify('frame_theme', { selection = M.selection() })
end

function M.start()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('FrameTheme', { clear = true }),
    callback = function() vim.schedule(M.send) end,
  })
  M.send()
end

return M
