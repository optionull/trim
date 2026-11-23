-- nvim's prompts, answered by Trim's own views: `vim.ui.select` (code actions, a choice among references, anything a
-- plugin asks) goes to the list of choices over the window, where it can be filtered; the answer comes back here.
local M = { pending = {}, last = 0 }

local function notify(...)
  local channel = vim.g.sill_channel
  if channel then pcall(vim.rpcnotify, channel, ...) end
end

--- A list of ready rows (`{ title, detail, file }`): `on_choice(index)`, or `on_choice(nil)` when put away.
function M.pick(title, rows, on_choice)
  if not vim.g.sill_channel or #rows == 0 then return on_choice(nil) end
  local sent = {}
  for index, row in ipairs(rows) do sent[index] = { tostring(index), row.title, row.detail or '', row.file or '' } end
  M.last = M.last + 1
  M.pending[M.last] = { items = rows, on_choice = function(_, index) on_choice(index) end }
  notify('trim_select', M.last, title, sent)
end

--- `vim.ui.select(items, opts, on_choice)`: `on_choice(item, index)`, or `on_choice(nil, nil)` when put away.
function M.select(items, opts, on_choice)
  opts = opts or {}
  if not vim.g.sill_channel or #items == 0 then return on_choice(nil, nil) end
  local format = opts.format_item or tostring
  local rows = {}
  for index, item in ipairs(items) do rows[index] = { tostring(index), tostring(format(item)):gsub('\n.*', '') } end
  M.last = M.last + 1
  M.pending[M.last] = { items = items, on_choice = on_choice }
  local prompt = opts.kind == 'codeaction' and 'Code actions' or (opts.prompt or 'Choose'):gsub('[:%s]+$', '')
  notify('trim_select', M.last, prompt, rows)
end

--- Trim's answer: the row chosen (its index), or nothing.
function M.chosen(id, index)
  local ask = M.pending[id]
  M.pending[id] = nil
  if not ask then return end
  local item = index and ask.items[index] or nil
  vim.schedule(function() ask.on_choice(item, item and index or nil) end)
end

function M.setup() vim.ui.select = M.select end

return M
