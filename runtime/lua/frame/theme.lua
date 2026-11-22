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

--- Every highlight group as it is, and the scheme's name and background, to put back exactly: a scheme with variants
--- (rose-pine) remembers the last one, so applying its name again would not.
function M.snapshot()
  M.saved = { groups = vim.api.nvim_get_hl(0, {}), name = vim.g.colors_name, background = vim.o.background }
end

--- What `snapshot` took, put back.
function M.restore()
  local saved = M.saved
  if not saved then return end
  vim.cmd('highlight clear')
  for name, attrs in pairs(saved.groups) do pcall(vim.api.nvim_set_hl, 0, name, attrs) end
  vim.o.background = saved.background
  vim.g.colors_name = saved.name
  M.send()
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
