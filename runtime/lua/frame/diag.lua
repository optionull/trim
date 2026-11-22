-- Diagnostics for the frame: the worst level of each file nvim has them for (for the tree's wavy lines), sent a moment
-- after they change, and every diagnostic as rows (for the problems list). nvim holds them for the files it has open.
local M = {}

local function notify(...)
  local channel = vim.g.sill_channel
  if channel then pcall(vim.rpcnotify, channel, ...) end
end

--- { [path] = worst severity (1 error ... 4 hint) } of the files that have any.
function M.worst()
  local files = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= '' and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' then
      local counts = vim.diagnostic.count(buf)
      for severity = 1, 4 do
        if (counts[severity] or 0) > 0 then
          files[name] = severity
          break
        end
      end
    end
  end
  return files
end

--- Every diagnostic: path, line, column (from 1), severity, message (its first line), source and code.
function M.list()
  local rows = {}
  for _, d in ipairs(vim.diagnostic.get()) do
    local name = vim.api.nvim_buf_get_name(d.bufnr)
    if name ~= '' then
      rows[#rows + 1] = {
        path = name, line = d.lnum + 1, col = d.col + 1, severity = d.severity,
        message = (d.message or ''):gsub('\n.*', ''), source = d.source or '', code = tostring(d.code or ''),
      }
    end
  end
  return rows
end

local timer
local function schedule()
  if timer then timer:stop() end
  timer = timer or vim.uv.new_timer()
  timer:start(120, 0, vim.schedule_wrap(function() notify('frame_diag', M.worst()) end))
end

function M.start()
  vim.api.nvim_create_autocmd({ 'DiagnosticChanged', 'BufDelete', 'BufWipeout' }, {
    group = vim.api.nvim_create_augroup('frame_diag', { clear = true }),
    callback = schedule,
  })
  schedule()
end

return M
