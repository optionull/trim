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
-- Diagnostics of files that are not open (a server's workspace diagnostics): kept here, as counts and short rows, and
-- never as buffers. A buffer for each of thousands of files makes everything that looks at the buffers slow, and nvim's
-- own handling of a report makes one per file. Opening the file hands it to nvim's own diagnostics.
local remote = {}
local pending_paths = {}

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
  local n = M.remote_files()
  for _, entry in pairs(per_buf) do
    if entry.counts[1] + entry.counts[2] + entry.counts[3] + entry.counts[4] > 0 then n = n + 1 end
  end
  return n
end

--- A path with its links followed: a server's and nvim's names for a file can differ by one (/var and /private/var).
local function canonical(path) return vim.uv.fs_realpath(path) or path end

--- Whether a path is in a scope of the list: 'file' (the active one), 'folder' (its folder) or all of it.
local function in_scope(path, scope, active)
  if not active or not scope or scope == 'project' then return true end
  if scope == 'file' then return path == active end
  return vim.fs.dirname(path) == vim.fs.dirname(active)
end

--- Diagnostics for the problems list: path, line, column (from 1), severity, message (its first line), source and code,
--- those of the open files and those the servers gave for the rest, the worst first and no more than `limit` (so a
--- project with tens of thousands never sends tens of thousands), in a scope ('file', 'folder', 'project' with the
--- active file's path).
function M.list(opts)
  opts = opts or {}
  local limit = opts.limit or 3000
  local rows = {}
  for _, d in ipairs(vim.diagnostic.get()) do
    local name = vim.api.nvim_buf_get_name(d.bufnr)
    if name ~= '' and in_scope(name, opts.scope, opts.active) then
      rows[#rows + 1] = {
        path = name, line = d.lnum + 1, col = d.col + 1, severity = d.severity,
        message = (d.message or ''):gsub('\n.*', ''), source = d.source or '', code = tostring(d.code or ''),
      }
    end
  end
  for path, entry in pairs(remote) do
    if in_scope(path, opts.scope, opts.active and canonical(opts.active)) then
      for _, row in ipairs(entry.rows) do
        rows[#rows + 1] = {
          path = path, line = row.line, col = row.col, severity = row.severity,
          message = row.message, source = row.source, code = row.code,
        }
      end
    end
  end
  if #rows > limit then
    table.sort(rows, function(a, b) return a.severity < b.severity end)
    for index = #rows, limit + 1, -1 do rows[index] = nil end
  end
  return rows
end

--- What a server said about a file that is not open (LSP diagnostics, or none): counted, kept short, no buffer made.
function M.set_remote(path, diagnostics, owner)
  path = canonical(path)
  local old = remote[path]
  if old then
    for severity = 1, 4 do totals[severity] = totals[severity] - old.counts[severity] end
  end
  if not diagnostics or #diagnostics == 0 then
    remote[path] = nil
  else
    local counts, rows = { 0, 0, 0, 0 }, {}
    for _, d in ipairs(diagnostics) do
      local severity = d.severity or 1
      if severity < 1 or severity > 4 then severity = 1 end
      counts[severity] = counts[severity] + 1
      local start = d.range and d.range.start or { line = 0, character = 0 }
      local code = d.code
      rows[#rows + 1] = {
        line = start.line + 1, col = start.character + 1, severity = severity,
        message = ((d.message or ''):gsub('\n.*', '')), source = d.source or '',
        code = tostring(type(code) == 'table' and code.value or code or ''),
      }
    end
    remote[path] = { counts = counts, rows = rows, owner = owner }
    for severity = 1, 4 do totals[severity] = totals[severity] + counts[severity] end
  end
  pending_paths[path] = true
  M.schedule()
end

--- The file was opened: nvim's own diagnostics have it now.
function M.forget_remote(path)
  path = canonical(path)
  if remote[path] then M.set_remote(path, nil) end
end

--- A server has gone (stopped, or died): what it said of files that are not open goes with it.
function M.clear_remote(owner)
  local gone = {}
  for path, entry in pairs(remote) do
    if entry.owner == owner then gone[#gone + 1] = path end
  end
  for _, path in ipairs(gone) do M.set_remote(path, nil) end
end

function M.remote_files()
  local n = 0
  for _ in pairs(remote) do n = n + 1 end
  return n
end

--- Diagnostics from a server can be stale: for a file that changed since (a build rewrites files, and workspace
--- diagnostics cover files that were never open), a line may be gone. nvim's handlers read the line with strict
--- indexing and throw when it is, at BufReadPost, with a prompt that holds nvim until a key is pressed. They are given
--- only the diagnostics whose lines exist, and an error in one is its own: it never reaches the person.
local waiting = {}
function M.harden()
  for name, handler in pairs(vim.diagnostic.handlers) do
    if type(handler) == 'table' and type(handler.show) == 'function' and not handler.trim_hardened then
      local show = handler.show
      handler.trim_hardened = true
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
        if not ok then vim.schedule(function() vim.g.trim_diagnostic_error = name .. ': ' .. tostring(err) end) end
      end
    end
  end
end

local timer
local first = true
function M.schedule(buf)
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
      for path, entry in pairs(remote) do files[path] = files[path] or worst_of(entry.counts) end
    else
      for path in pairs(pending_paths) do
        files[path] = remote[path] and worst_of(remote[path].counts) or 0
      end
      for changed in pairs(pending) do
        local name, level = recount(changed)
        if name ~= '' then files[name] = level end
      end
    end
    pending, pending_paths = {}, {}
    notify('trim_diag', { files = files, counts = M.totals() })
    pcall(function() require('trim.lsp').diagnostics_changed() end)
  end))
end
local schedule = M.schedule

function M.start()
  M.harden()
  vim.api.nvim_create_autocmd({ 'DiagnosticChanged', 'BufDelete', 'BufWipeout' }, {
    group = vim.api.nvim_create_augroup('trim_diag', { clear = true }),
    callback = function(args) schedule(args.buf) end,
  })
  -- A file that is opened is nvim's now: what was kept of it here goes.
  vim.api.nvim_create_autocmd('BufReadPost', {
    group = vim.api.nvim_create_augroup('trim_diag_open', { clear = true }),
    callback = function(args)
      local name = vim.api.nvim_buf_get_name(args.buf)
      if name ~= '' then M.forget_remote(name) end
    end,
  })
  schedule()
end

return M
