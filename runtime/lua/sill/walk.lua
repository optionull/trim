-- Walkthroughs' anchors, found in the code (sill's walkthrough pane asks): a symbol through the language servers that
-- run (`workspace/symbol`), else by its declaration in the files git knows; a file as written. Each found anchor is a
-- file and the lines to show: from the symbol's line to where its braces close (or its indentation ends), at most 60.
local M = {}

-- `Pricing.Total` against a server's answer: the name (before any parameters) is the last part, and the container,
-- when there is one, ends with the parts before it.
local function matches(symbol, wanted)
  local parts = vim.split(wanted, '.', { plain = true })
  local name = (symbol.name or ''):gsub('%(.*$', ''):gsub('<.*$', '')
  if name ~= parts[#parts] then return false end
  if #parts == 1 then return true end
  local container = table.concat(parts, '.', 1, #parts - 1)
  -- Roslyn says `in Pricing (project Debuggee (net10.0))`; others say `Orders.Pricing`.
  local have = (symbol.containerName or ''):gsub('^in ', ''):gsub('%s*%(project .*$', '')
  return have == container or have:sub(-#container - 1) == '.' .. container
end

local function by_servers(wanted)
  local parts = vim.split(wanted, '.', { plain = true })
  for _, client in ipairs(vim.lsp.get_clients()) do
    -- Roslyn still loading its projects (started ahead, before any C# file) would make this wait: the text, then.
    local loading = client.name == 'roslyn' and not require('sill.roslyn').loaded[client.id]
    if client.server_capabilities.workspaceSymbolProvider and not loading then
      local answer = client:request_sync('workspace/symbol', { query = parts[#parts] }, 8000)
      for _, symbol in ipairs(answer and answer.result or {}) do
        if matches(symbol, wanted) and symbol.location and symbol.location.uri then
          return vim.uri_to_fname(symbol.location.uri), symbol.location.range.start.line + 1, client.name
        end
      end
    end
  end
end

-- The declaration of `Pricing.Total` by text: a line naming `Total` as it is declared (followed by `(`, `<`, `{`, `:`
-- or `=`), in a file that also names `Pricing` when there is a container.
local function by_text(wanted, root)
  local parts = vim.split(wanted, '.', { plain = true })
  local name = parts[#parts]
  -- git grep's extended expressions have no \b or \s: POSIX classes instead.
  local found = vim.fn.systemlist({ 'git', '-C', root, 'grep', '-n', '-E',
    '(class|struct|record|interface|enum|fn|func|def|function|void|static|public|private|internal|protected)[^=;]*'
      .. '[^A-Za-z0-9_]' .. name .. '[[:space:]]*[(<{:=]' })
  for _, line in ipairs(found) do
    local path, number = line:match('^([^:]+):(%d+):')
    if path then
      local full = root .. '/' .. path
      if #parts == 1 or table.concat(vim.fn.readfile(full), '\n'):find(parts[#parts - 1], 1, true) then
        return full, tonumber(number), 'text'
      end
    end
  end
end

-- Where a declaration starting at `line` ends: its braces closed, else its indentation back.
local function extent(lines, line)
  local depth, opened = 0, false
  for i = line, math.min(#lines, line + 59) do
    local text = lines[i]:gsub('//.*$', ''):gsub('"[^"]*"', '')
    for c in text:gmatch('[{}]') do
      depth = depth + (c == '{' and 1 or -1)
      opened = true
    end
    if opened and depth <= 0 then return i end
    -- An arrow body (or a field) ends with its semicolon, on its first line or a later one.
    if not opened and text:find(';%s*$') then return i end
  end
  if not opened then
    local indent = #(lines[line]:match('^%s*'))
    for i = line + 1, math.min(#lines, line + 59) do
      if lines[i]:match('%S') and #(lines[i]:match('^%s*')) <= indent then return i - 1 end
    end
  end
  return math.min(#lines, line + 59)
end

--- Finds each anchor: { kind = 'symbol'|'file', name, from, to } (from/to lines of the symbol or the file), relative
--- paths to `folder`, else to `root` (the worktree sill is open on, for what is in .sill), else the folder's
--- repository. Answers { path, from, to, by } for each, or { problem } when it is not found.
function M.resolve(anchors, folder, root)
  if not root then
    root = vim.fn.systemlist({ 'git', '-C', folder, 'rev-parse', '--show-toplevel' })[1] or folder
    if vim.v.shell_error ~= 0 then root = folder end
  end
  local out = {}
  for i, anchor in ipairs(anchors) do
    local path, line, by
    if anchor.kind == 'file' then
      path = anchor.name:sub(1, 1) == '/' and anchor.name or (folder .. '/' .. anchor.name)
      if vim.fn.filereadable(path) == 0 then
        local in_root = root .. '/' .. anchor.name
        path = vim.fn.filereadable(in_root) == 1 and in_root or nil
      end
      line, by = 1, 'path'
    else
      path, line, by = by_servers(anchor.name)
      if not path then path, line, by = by_text(anchor.name, root) end
    end
    if not path or vim.fn.filereadable(path) == 0 then
      out[i] = { problem = (anchor.kind == 'file' and 'no file ' or 'no symbol ') .. anchor.name }
    else
      local lines = vim.fn.readfile(path)
      local from, to
      if anchor.kind == 'file' then
        from = anchor.from or 1
        to = anchor.to or math.min(#lines, from + 39)
      else
        local last = extent(lines, line)
        from = anchor.from and (line + anchor.from - 1) or line
        to = anchor.to and (line + anchor.to - 1) or last
      end
      if from > #lines then
        out[i] = { problem = anchor.name .. ' has no line ' .. from .. ' (the file has ' .. #lines .. ')' }
      else
        out[i] = { path = path, from = from, to = math.min(to, #lines), by = by }
      end
    end
  end
  return out
end

--- The walkthroughs in the project: every *.walk.md git knows of or that is new, else under the folder.
function M.find(folder)
  local found = vim.fn.systemlist({ 'git', '-C', folder, 'ls-files', '--cached', '--others', '--exclude-standard',
    '*.walk.md', '**/*.walk.md' })
  if vim.v.shell_error ~= 0 then
    found = vim.fs.find(function(name) return name:match('%.walk%.md$') end, { path = folder, type = 'file', limit = 200 })
  else
    found = vim.tbl_map(function(p) return folder .. '/' .. p end, found)
  end
  -- sill's own: reviews' walkthroughs and tours in the repository's .sill (at the main worktree, which git does not
  -- see).
  local common = vim.fn.systemlist({ 'git', '-C', folder, 'rev-parse', '--path-format=absolute', '--git-common-dir' })[1]
  if vim.v.shell_error == 0 and common then
    local main = common:match('^(.*)/%.git$') or vim.fn.systemlist({ 'git', '-C', folder, 'rev-parse', '--show-toplevel' })[1]
    vim.list_extend(found, vim.fn.glob(main .. '/.sill/**/*.walk.md', false, true))
  end
  table.sort(found)
  return vim.fn.uniq(found)
end

function M.setup()
  vim.api.nvim_create_user_command('SillWalk', function(opts)
    local channel = vim.g.sill_channel
    local function open(path)
      if channel then vim.rpcnotify(channel, 'sill_walk', 'open', vim.fn.fnamemodify(path, ':p')) end
    end
    if opts.args == 'skill' then
      if channel then vim.rpcnotify(channel, 'sill_walk', 'skill', '') end
    elseif opts.args ~= '' then
      open(opts.args)
    elseif vim.api.nvim_buf_get_name(0):match('%.walk%.md$') then
      open(vim.api.nvim_buf_get_name(0))
    else
      local walks = M.find(vim.fn.getcwd())
      if #walks == 0 then
        return vim.notify('No walkthroughs (*.walk.md) here yet: ask an agent for one.', vim.log.levels.INFO)
      end
      vim.ui.select(walks, { prompt = 'Walkthrough', format_item = function(p) return vim.fn.fnamemodify(p, ':.') end },
        function(choice) if choice then open(choice) end end)
    end
  end, {
    nargs = '?', complete = 'file',
    desc = 'Open a walkthrough (*.walk.md): this one, a path, or pick; skill installs the skill that writes them',
  })
end

return M
