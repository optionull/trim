-- Asking an agent about code (after M9): `:SillAsk` on lines (a selection, or the line the cursor is on) sends them
-- and the question to the agent working here; its answer comes back through sill's annotate tool and shows under the
-- lines, beside the code it is about, until `:SillAsk clear`.
local M = {}

local ns = vim.api.nvim_create_namespace('sill.annotations')

local function notify(method, ...)
  local channel = vim.g.sill_channel
  if channel then vim.rpcnotify(channel, method, ...) end
end

--- An answer under `line` of `path`: its lines wrapped to the window, marked as the agent's.
function M.annotate(path, line, text)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  line = math.max(1, math.min(line, vim.api.nvim_buf_line_count(buf)))
  local width = math.max(40, math.min(100, vim.o.columns - 20))
  local virt = { { { '╭ agent', 'SillAnnotationHead' } } }
  for _, paragraph in ipairs(vim.split(text, '\n', { plain = true })) do
    local row = ''
    for word in paragraph:gmatch('%S+') do
      if #row + #word + 1 > width then
        table.insert(virt, { { '│ ' .. row, 'SillAnnotation' } })
        row = word
      else
        row = row == '' and word or (row .. ' ' .. word)
      end
    end
    table.insert(virt, { { '│ ' .. row, 'SillAnnotation' } })
  end
  vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, { virt_lines = virt })
end

--- The answers shown, for the self-check: { { line, text }, ... } of a buffer.
function M.annotations(buf)
  local out = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf or 0, ns, 0, -1, { details = true })) do
    local lines = {}
    for _, chunk in ipairs(mark[4].virt_lines or {}) do table.insert(lines, chunk[1][1]) end
    table.insert(out, { mark[2] + 1, table.concat(lines, '\n') })
  end
  return out
end

function M.setup()
  vim.api.nvim_set_hl(0, 'SillAnnotation', { default = true, fg = '#c4a7f5', italic = true })
  vim.api.nvim_set_hl(0, 'SillAnnotationHead', { default = true, fg = '#8b93a1' })
  vim.api.nvim_create_user_command('SillAsk', function(opts)
    if opts.args == 'clear' then
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
      end
      return
    end
    local from, to = opts.line1, opts.line2
    local path = vim.api.nvim_buf_get_name(0)
    local lines = vim.api.nvim_buf_get_lines(0, from - 1, to, false)
    local function send(question)
      if question and question ~= '' then
        notify('sill_ask', { path = path, from = from, to = to, lines = lines, question = question })
      end
    end
    if opts.args ~= '' then send(opts.args) else vim.ui.input({ prompt = 'Ask the agent: ' }, send) end
  end, { nargs = '*', range = true, desc = 'Ask the agent about these lines; the answer shows under them (clear removes)' })
end

return M
