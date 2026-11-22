-- Diagnostics for the frame: the worst level of each file nvim has them for (for the tree's wavy lines), sent a moment
-- after they change, and every diagnostic as rows (for the problems list). nvim holds them for the files it has open.
local M = {}

local function notify(...)
  local channel = vim.g.sill_channel
  if channel then pcall(vim.rpcnotify, channel, ...) end
end

-- What is known of each buffer, kept as diagnostics change, so a change costs the buffer that changed and not every
-- file that has any (workspace diagnostics can be thousands): the counts of each severity, and their sum.
local per_buf = {}
local totals = { 0, 0, 0, 0 }
local pending = {}

local function worst_of(counts)
  for severity = 1, 4 do
    if counts[severity] > 0 then return severity end
  end
  return 0
end

--- Counts what a buffer has now; the path and its worst severity (0: none).
local function recount(buf)
  local old = per_buf[buf]
  if old then
    for severity = 1, 4 do totals[severity] = totals[severity] - old.counts[severity] end
  end
  local name = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or ''
  local counts = { 0, 0, 0, 0 }
  if name ~= '' and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == '' then
    local found = vim.diagnostic.count(buf)
    for severity = 1, 4 do counts[severity] = found[severity] or 0 end
  end
  per_buf[buf] = { name = name ~= '' and name or (old and old.name) or '', counts = counts }
  for severity = 1, 4 do totals[severity] = totals[severity] + counts[severity] end
  return per_buf[buf].name, worst_of(counts)
end

--- { [path] = worst severity (1 error ... 4 hint) } of the files that have any.
function M.worst()
  local files = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name, level = recount(buf)
    if level > 0 then files[name] = level end
  end
  return files
end

--- How many diagnostics of each severity there are in all files, in a list (1 error ... 4 hint).
function M.totals() return { totals[1], totals[2], totals[3], totals[4] } end

--- How many files have any.
function M.files_with_problems()
  local n = 0
  for _, entry in pairs(per_buf) do
    if entry.counts[1] + entry.counts[2] + entry.counts[3] + entry.counts[4] > 0 then n = n + 1 end
  end
  return n
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
local first = true
local function schedule(buf)
  if buf then pending[buf] = true end
  if timer then timer:stop() end
  timer = timer or vim.uv.new_timer()
  timer:start(150, 0, vim.schedule_wrap(function()
    -- The first time everything is counted; after that, what changed since the last time.
    local files = {}
    if first then
      first = false
      files = M.worst()
      for _, entry in pairs(per_buf) do if entry.name ~= '' and not files[entry.name] then files[entry.name] = 0 end end
    else
      for changed in pairs(pending) do
        local name, level = recount(changed)
        if name ~= '' then files[name] = level end
      end
    end
    pending = {}
    notify('frame_diag', { files = files, counts = M.totals() })
    pcall(function() require('frame.lsp').diagnostics_changed() end)
  end))
end

function M.start()
  M.harden()
  vim.api.nvim_create_autocmd({ 'DiagnosticChanged', 'BufDelete', 'BufWipeout' }, {
    group = vim.api.nvim_create_augroup('frame_diag', { clear = true }),
    callback = function(args) schedule(args.buf) end,
  })
  schedule()
end

return M
