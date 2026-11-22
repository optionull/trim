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
    if name ~= '' and vim.bo[buf].buftype == '' then
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

--- Diagnostics from a server can be stale: for a file that changed since (a build rewrites files, and workspace
--- diagnostics cover files that were never open), a line may be gone. nvim's handlers read the line with strict
--- indexing and throw when it is, at BufReadPost, with a prompt that holds nvim until a key is pressed. They are given
--- only the diagnostics whose lines exist, and an error in one is its own: it never reaches the person.
local waiting = {}
function M.harden()
  for name, handler in pairs(vim.diagnostic.handlers) do
    if type(handler) == 'table' and type(handler.show) == 'function' and not handler.frame_hardened then
      local show = handler.show
      handler.frame_hardened = true
      handler.show = function(namespace, bufnr, diagnostics, opts)
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        -- A file that is not loaded has no lines to measure against: shown when it is (nvim would show it then, with
        -- what it was given now).
        if not vim.api.nvim_buf_is_loaded(bufnr) then
          local key = namespace .. ':' .. bufnr
          if not waiting[key] then
            waiting[key] = true
            vim.api.nvim_create_autocmd('BufReadPost', {
              buffer = bufnr, once = true,
              callback = function()
                waiting[key] = nil
                vim.schedule(function() if vim.api.nvim_buf_is_valid(bufnr) then pcall(vim.diagnostic.show, namespace, bufnr) end end)
              end,
            })
          end
          return
        end
        local count = vim.api.nvim_buf_line_count(bufnr)
        diagnostics = vim.tbl_filter(function(d)
          return d.lnum < count and (d.end_lnum or d.lnum) < count
        end, diagnostics)
        local ok, err = pcall(show, namespace, bufnr, diagnostics, opts)
        if not ok then vim.schedule(function() vim.g.frame_diagnostic_error = name .. ': ' .. tostring(err) end) end
      end
    end
  end
end

local timer
local function schedule()
  if timer then timer:stop() end
  timer = timer or vim.uv.new_timer()
  timer:start(120, 0, vim.schedule_wrap(function() notify('frame_diag', M.worst()) end))
end

function M.start()
  M.harden()
  vim.api.nvim_create_autocmd({ 'DiagnosticChanged', 'BufDelete', 'BufWipeout' }, {
    group = vim.api.nvim_create_augroup('frame_diag', { clear = true }),
    callback = schedule,
  })
  schedule()
end

return M
