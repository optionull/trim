-- Trim's language servers, supervised. A server is started the first time a file of its kind opens (unless the person's
-- config already runs one for that kind); Trim (Swift) finds or provisions the program and answers with its command; nvim's
-- own client talks to it. A server that dies is started again, after a wait that doubles (1 s, 2 s, 4 s ... 30 s), and given up
-- on after five deaths inside a minute: it crashes alone, never nvim, and `:TrimLsp restart` starts it afresh.
local M = {}

local function notify(method, ...)
  local channel = vim.g.sill_channel
  if channel then pcall(vim.rpcnotify, channel, method, ...) end
end

-- A solution beats a project for where a .NET server is rooted (a list of markers is in order of priority): a file in
-- src/Proc/ belongs to the solution at the top, so every file of it, and the folder at launch, share one server.
local function solution_root(name) return name:match('%.slnx?$') end
local function csproj_root(name) return name:match('%.csproj$') end
local function fsproj_root(name) return name:match('%.fsproj$') end

--- Roslyn starts empty: it is told which solution (or else which projects) to load, as the client of an editor does.
local function open_projects(client)
  local root = client.root_dir
  if not root then return end
  local solutions = vim.fn.glob(root .. '/*.sln', true, true)
  vim.list_extend(solutions, vim.fn.glob(root .. '/*.slnx', true, true))
  if #solutions > 0 then
    client:notify('solution/open', { solution = vim.uri_from_fname(solutions[1]) })
  else
    local projects = vim.tbl_map(vim.uri_from_fname, vim.fn.glob(root .. '/*.csproj', true, true))
    if #projects > 0 then client:notify('project/open', { projects = projects }) end
  end
end

--- Roslyn looks at the files it has open unless told the whole solution is to be analysed: it asks the client for
--- settings (`workspace/configuration`), and says when its projects are loaded.
local roslyn_settings = {
  ['csharp|background_analysis.dotnet_analyzer_diagnostics_scope'] = 'fullSolution',
  ['csharp|background_analysis.dotnet_compiler_diagnostics_scope'] = 'fullSolution',
}
local roslyn_handlers = {
  ['workspace/configuration'] = function(_, params)
    local answer = {}
    for index, item in ipairs(params.items or {}) do answer[index] = roslyn_settings[item.section] or vim.NIL end
    return answer
  end,
  ['workspace/projectInitializationComplete'] = function(_, _, ctx)
    vim.defer_fn(function()
      local client = vim.lsp.get_client_by_id(ctx.client_id)
      if client then require('trim.lsp').workspace_diagnostics(client) end
    end, 100)
  end,
}

--- Each server: the file types it serves, how its folder is found, what the person's config may call it, and what it
--- is started with (`init_options`, `on_init`).
M.specs = {
  csharp = { filetypes = { 'cs', 'razor' }, root = { solution_root, csproj_root, '.git' }, aliases = { 'roslyn', 'roslyn_ls', 'omnisharp', 'csharp_ls' }, on_init = open_projects, handlers = roslyn_handlers, razor = true },
  -- Without AutomaticWorkspaceInit fsautocomplete waits for the client to pick a workspace.
  fsautocomplete = {
    filetypes = { 'fsharp' }, root = { solution_root, fsproj_root, '.git' }, aliases = { 'fsautocomplete', 'ionide' },
    init_options = { AutomaticWorkspaceInit = true },
  },
  rust_analyzer = { filetypes = { 'rust' }, root = { 'Cargo.toml', '.git' }, aliases = { 'rust_analyzer', 'rust-analyzer' } },
  sourcekit = { filetypes = { 'swift' }, root = { 'Package.swift', '.git' }, aliases = { 'sourcekit' } },
  gopls = { filetypes = { 'go', 'gomod', 'gowork', 'gotmpl' }, root = { 'go.work', 'go.mod', '.git' }, aliases = { 'gopls' } },
  marksman = { filetypes = { 'markdown' }, root = { '.marksman.toml', '.git' }, aliases = { 'marksman' } },
  html = { filetypes = { 'html' }, root = { 'package.json', '.git' }, aliases = { 'html' } },
  cssls = { filetypes = { 'css', 'scss', 'less' }, root = { 'package.json', '.git' }, aliases = { 'cssls' } },
  jsonls = { filetypes = { 'json', 'jsonc' }, root = { 'package.json', '.git' }, aliases = { 'jsonls' } },
  typescript = {
    filetypes = { 'typescript', 'javascript', 'typescriptreact', 'javascriptreact' },
    root = { 'tsconfig.json', 'jsconfig.json', 'package.json', '.git' },
    aliases = { 'ts_ls', 'tsserver', 'vtsls', 'typescript-tools', 'denols' },
  },
}

--- What the program is, by server, as Trim answered: a command, or false for one it could not find or provision.
M.commands = {}
--- Each server's life: { status = 'starting' | 'ready' | 'restarting' | 'failed' | 'stopped', deaths = { times }, wait = ms }
M.state = {}
M.wait_first = 1000
M.wait_max = 30000
M.max_deaths = 5
M.window = 60000
local asked = {}
local stopping = {}

local function state_of(name)
  M.state[name] = M.state[name] or { status = 'idle', deaths = {}, wait = M.wait_first }
  return M.state[name]
end

local function set(name, status)
  state_of(name).status = status
  notify('trim_lsp', { name = name, status = status })
  pcall(function() require('trim.status').poke() end)
end

--- Whether the person's config already serves this kind of file with a server of its own.
local function theirs(spec, buf)
  for _, alias in ipairs(spec.aliases) do
    local ok, enabled = pcall(vim.lsp.is_enabled, alias)
    if ok and enabled then return true end
  end
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    if not client.name:match('^trim_') then
      for _, alias in ipairs(spec.aliases) do
        if client.name == alias then return true end
      end
    end
  end
  return false
end

local function root_of(spec, buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local found = vim.fs.root(name ~= '' and name or vim.uv.cwd(), spec.root)
  return found or vim.uv.cwd()
end

--- What the client says it can do. It does not watch files for the server: nvim does that in Lua, matching every change
--- the file system reports against every pattern the server registered, and a build touches thousands of files in bin
--- and obj, which holds nvim for tens of seconds. Told it does not, a server watches for itself (Roslyn, rust-analyzer
--- and the others all do).
function M.capabilities()
  local capabilities = vim.lsp.protocol.make_client_capabilities()
  capabilities.workspace = capabilities.workspace or {}
  capabilities.workspace.didChangeWatchedFiles = { dynamicRegistration = false, relativePatternSupport = false }
  capabilities.workspace.diagnostics = { refreshSupport = true }
  return capabilities
end

local function config_at(name, spec, root, command)
  return {
    capabilities = M.capabilities(),
    name = 'trim_' .. name,
    -- At a lower priority than the editor: a server analysing a solution (and what it starts) takes every core it is
    -- given, and the window and nvim must still answer at once.
    cmd = vim.list_extend({ '/usr/bin/nice', '-n', '6' }, command),
    root_dir = root,
    init_options = spec.init_options,
    on_init = spec.on_init,
    get_language_id = spec.razor and require('sill.roslyn').language_id or nil,
    handlers = vim.tbl_extend('force', spec.razor and require('sill.roslyn').razor_handlers() or {}, spec.handlers or {}, {
      ['textDocument/publishDiagnostics'] = function(...) return M.publish(...) end,
      ['workspace/diagnostic/refresh'] = function(_, _, ctx)
        M.refresh(ctx.client_id)
        return vim.NIL
      end,
    }),
    on_exit = function(code, signal)
      vim.schedule(function() M.exited(name, code, signal) end)
    end,
  }
end

local function config(name, spec, buf, command) return config_at(name, spec, root_of(spec, buf), command) end

--- Whether a file is open in nvim (loaded), by its path.
local function buffer_loaded(path)
  for _, name in ipairs({ path, vim.uv.fs_realpath(path) or path }) do
    local buf = vim.fn.bufnr('^' .. vim.fn.escape(name, '\\.*$^~[]') .. '$')
    if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then return true end
  end
  return false
end

--- What a server pushes about a file: nvim's own for one that is open; for the rest kept as counts and rows, not as a
--- buffer (see `trim.diag`).
function M.publish(err, result, ctx, config)
  if not result or not result.uri then return end
  local path = vim.uri_to_fname(result.uri)
  if buffer_loaded(path) then return vim.lsp.handlers['textDocument/publishDiagnostics'](err, result, ctx, config) end
  local client = ctx and ctx.client_id and vim.lsp.get_client_by_id(ctx.client_id)
  require('trim.diag').set_remote(path, result.diagnostics, client and client.name)
end

local pulling = {}

--- The diagnostics of every file, not only the open ones, when the server can give them (LSP's workspace diagnostics):
--- asked for here and kept by `trim.diag`, in slices so that nvim is never held up by a report of thousands of files.
function M.workspace_diagnostics(client)
  local provider = client.server_capabilities and client.server_capabilities.diagnosticProvider
  -- Offered when the server starts or registered later (Roslyn does it later), which `supports_method` knows of.
  local offered = (provider and provider.workspaceDiagnostics) or client:supports_method('workspace/diagnostic')
  if not offered then return end
  if pulling[client.id] then
    pulling[client.id] = 'again'
    return
  end
  pulling[client.id] = true
  M.track_analysis(client)
  local params = { identifier = provider and provider.identifier, previousResultIds = {} }
  local attempts = 0
  local function ask()
    client:request('workspace/diagnostic', params, function(err, result)
      -- The server cancels a request it cannot answer yet (its projects are still loading): asked again, as nvim does.
      if err and err.code == -32802 and (err.data == nil or err.data.retriggerRequest ~= false) and attempts < 60 then
        attempts = attempts + 1
        return vim.defer_fn(ask, 500)
      end
      local again = pulling[client.id] == 'again'
      pulling[client.id] = nil
      local items = (not err and result and result.items) or {}
      local index = 1
      local function slice()
        local stop = math.min(index + 299, #items)
        for i = index, stop do
          local report = items[i]
          if report.uri and (report.items or report.kind == 'full') then
            local path = vim.uri_to_fname(report.uri)
            if not buffer_loaded(path) then require('trim.diag').set_remote(path, report.items, client.name) end
          end
        end
        index = stop + 1
        if index <= #items then
          vim.schedule(slice)
        else
          M.analysis_done(client)
          if again then M.workspace_diagnostics(client) end
        end
      end
      slice()
    end)
  end
  ask()
end

--- The server says its diagnostics changed (it asks the client to pull again): once, a moment after the last time.
local refreshing = {}
function M.refresh(client_id)
  if refreshing[client_id] then return end
  refreshing[client_id] = true
  vim.defer_fn(function()
    refreshing[client_id] = nil
    local client = vim.lsp.get_client_by_id(client_id)
    if client then M.workspace_diagnostics(client) end
  end, 800)
end

--- What the language server says of the word under the cursor, shown by the window in a panel at the cursor (nvim's own
--- floating window is not used). It goes when the cursor moves or insert mode is entered.
local function show_hover(markdown)
  notify('trim_hover', markdown and markdown ~= '' and require('trim.docs').encode(markdown, vim.bo.filetype) or '')
end

local function dismiss_hover(events)
  vim.api.nvim_create_autocmd(events, {
    group = vim.api.nvim_create_augroup('frame.hover', { clear = true }),
    once = true,
    callback = function()
      M.signatures = nil
      show_hover('')
    end,
  })
end

local function request(method, handle)
  local buf = vim.api.nvim_get_current_buf()
  vim.lsp.buf_request_all(buf, method, function(client)
    return vim.lsp.util.make_position_params(0, client.offset_encoding)
  end, function(results)
    for _, response in pairs(results or {}) do
      if response.result and handle(response.result) then return end
    end
    M.signatures = nil
    show_hover('')
  end)
end

--- `K`: the server's hover (type, signature and documentation of the word under the cursor).
function M.hover()
  local shown = false
  request('textDocument/hover', function(result)
    local lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
    local text = table.concat(lines, '\n')
    if text:match('^%s*$') then return false end
    show_hover(text)
    shown = true
    -- Armed after this has been shown, so the key that asked does not dismiss it.
    vim.schedule(function() dismiss_hover({ 'CursorMoved', 'InsertEnter', 'BufLeave' }) end)
    return true
  end)
  vim.defer_fn(function()
    if not shown then vim.notify('No information available', vim.log.levels.INFO) end
  end, 1500)
end

--- The signature in turn (of the overloads there are), the parameter being typed marked, and which of how many.
local function show_signature()
  local state = M.signatures
  if not state then return end
  local signature = state.list[state.index]
  local label = signature.label
  local markdown = '```\n' .. label .. '\n```'
  local parameter = signature.parameters and signature.parameters[(signature.activeParameter or state.parameter or 0) + 1]
  local spans
  if parameter then
    local first, last
    if type(parameter.label) == 'string' then
      first, last = label:find(parameter.label, 1, true)
      if first then first = first - 1 end
    elseif type(parameter.label) == 'table' then
      first, last = parameter.label[1], parameter.label[2]
    end
    if first then spans = { b = first, e = last } end
  end
  local docs = require('trim.docs')
  local blocks = docs.blocks(markdown, vim.bo.filetype)
  if blocks[1] and blocks[1].t == 'code' and spans then
    -- The parameter in turn, over the colours of the code (the window reads u as underline and bold).
    table.insert(blocks[1].h, { b = spans.b, e = spans.e, bold = true, u = true })
  end
  local doc = signature.documentation
  doc = type(doc) == 'table' and doc.value or doc
  local extra = docs.blocks(doc or '', vim.bo.filetype)
  vim.list_extend(blocks, extra)
  if #state.list > 1 then
    table.insert(blocks, 1, { t = 'text', s = ('%d of %d overloads  (Alt-Up / Alt-Down)'):format(state.index, #state.list), faint = true })
  end
  notify('trim_hover', vim.json.encode(blocks))
end

--- Ctrl-S, and on `(` and `,`: the signature of the call being typed, with every overload there is.
function M.signature()
  request('textDocument/signatureHelp', function(result)
    if not result.signatures or #result.signatures == 0 then return false end
    local previous = M.signatures
    M.signatures = {
      list = result.signatures,
      index = (result.activeSignature or 0) + 1,
      parameter = result.activeParameter,
    }
    -- Typing on within the same call keeps the overload that was chosen by hand.
    if previous and previous.chosen and #previous.list == #result.signatures then
      M.signatures.index = previous.index
      M.signatures.chosen = true
    end
    show_signature()
    vim.schedule(function() dismiss_hover({ 'InsertLeave', 'BufLeave' }) end)
    return true
  end)
end

--- Alt-Down / Alt-Up while the signature shows: the next or previous overload.
function M.signature_step(step)
  local state = M.signatures
  if not state then return end
  state.index = (state.index - 1 + step) % #state.list + 1
  state.chosen = true
  show_signature()
end

-- Anything that asks for a hover (a mapping of a config, nvim's own K) gets this one.
vim.lsp.buf.hover = M.hover
vim.lsp.buf.signature_help = M.signature

-- The signature comes up by itself on the characters the server names, and is made again as the call is typed.
vim.api.nvim_create_autocmd('InsertCharPre', {
  group = vim.api.nvim_create_augroup('frame.signature', { clear = true }),
  callback = function()
    local char = vim.v.char
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0, method = 'textDocument/signatureHelp' })) do
      local provider = client.server_capabilities.signatureHelpProvider or {}
      local triggers = vim.list_extend(vim.list_extend({}, provider.triggerCharacters or {}), provider.retriggerCharacters or {})
      if vim.list_contains(triggers, char) then
        vim.schedule(M.signature)
        return
      end
    end
  end,
})

--- What the servers are busy with (indexing, loading projects, analysing), by client and token, newest last.
M.progress = {}
local progress_stamp = 0

--- Completion as you type, from the server: the list comes up on the characters the server names and on every letter,
--- digit and underscore (so a word being typed is completed without asking), and a snippet is expanded when taken.
function M.complete(client, buf)
  local provider = client.server_capabilities and client.server_capabilities.completionProvider
  if not provider then return end
  local triggers = vim.deepcopy(provider.triggerCharacters or {})
  local have = {}
  for _, c in ipairs(triggers) do have[c] = true end
  for code = 33, 126 do
    local c = string.char(code)
    if (c:match('[%w_]') or c == '.') and not have[c] then triggers[#triggers + 1] = c end
  end
  provider.triggerCharacters = triggers
  vim.lsp.completion.enable(true, client.id, buf, {
    autotrigger = true,
    -- A deprecated item says so after its kind (the menu draws it struck through; nothing else sees the mark).
    convert = function(item)
      local deprecated = item.deprecated or vim.list_contains(item.tags or {}, 1)
      if not deprecated then return {} end
      local kind = vim.lsp.protocol.CompletionItemKind[item.kind] or ''
      return { kind = kind .. '\u{2063}deprecated' }
    end,
  })
  M.completion_docs()
end

--- The documentation of the completion chosen is drawn by the window, beside the menu (nvim's own preview window is
--- not used: it does not know where the menu is). It comes with the item when the server sent it, and later when the
--- server has resolved it.
function M.completion_docs()
  if M.docs_ready then return end
  M.docs_ready = true
  local last
  local function send(text)
    text = text or ''
    if text == last then return end
    last = text
    notify('trim_completion_doc', require('trim.docs').encode(text, vim.bo.filetype))
  end
  -- A candidate's documentation: what the server sent with it, with its detail (the signature) above.
  local function text_of(entry, fallback)
    local doc = entry.documentation
    local text = type(doc) == 'table' and doc.value or doc
    if (text or '') == '' then text = fallback end
    if entry.detail and entry.detail ~= '' and not (text or ''):find(entry.detail, 1, true) then
      text = ('```\n%s\n```\n%s'):format(entry.detail, text or '')
    end
    return text
  end
  local chosen = 0
  vim.api.nvim_create_autocmd('CompleteChanged', {
    group = vim.api.nvim_create_augroup('frame.completion_docs', { clear = true }),
    callback = function()
      local item = vim.v.event.completed_item or {}
      local lsp_item = vim.tbl_get(item, 'user_data', 'nvim', 'lsp', 'completion_item') or {}
      local text = text_of(lsp_item, item.info)
      last = nil
      send(text)
      chosen = chosen + 1
      if (text or '') ~= '' or not next(lsp_item) then return end
      -- Most servers send the documentation only when asked for the one candidate (nvim's own resolve is for its
      -- preview window, which is not used): asked after a moment, so walking the menu is not a request for each.
      local mine, client_id = chosen, vim.tbl_get(item, 'user_data', 'nvim', 'lsp', 'client_id')
      vim.defer_fn(function()
        if mine ~= chosen then return end
        local client = client_id and vim.lsp.get_client_by_id(client_id)
        if not client or not client:supports_method('completionItem/resolve') then return end
        client:request('completionItem/resolve', lsp_item, function(err, result)
          if err or not result or mine ~= chosen then return end
          send(text_of(result))
        end, vim.api.nvim_get_current_buf())
      end, 60)
    end,
  })
  vim.api.nvim_create_autocmd({ 'CompleteDone', 'InsertLeave' }, {
    group = 'frame.completion_docs',
    callback = function()
      last = nil
      send('')
    end,
  })
  -- What the server resolves later is handed to nvim's preview window, which there is none of (and nvim refuses the
  -- call without one): the documentation goes to the window instead, and nvim is told there is no window.
  vim.api.nvim__complete_set = function(_, opts)
    if opts and opts.info then send(opts.info) end
    return {}
  end
end

local function push_progress()
  if M.progress_timer then return end
  M.progress_timer = vim.defer_fn(function()
    M.progress_timer = nil
    notify('trim_progress', M.progress_items())
  end, 80)
end

--- Everything the servers are busy with, oldest first, for the window's progress toast: { id, client, title, message,
--- percentage (-1 when it has none) }.
function M.progress_items()
  local items = {}
  for key, entry in pairs(M.progress) do
    items[#items + 1] = {
      id = key, client = entry.client, title = entry.title or '', message = entry.message or '',
      percentage = entry.percentage or -1, stamp = entry.stamp,
    }
  end
  table.sort(items, function(a, b) return a.stamp < b.stamp end)
  return items
end

--- Analysing files: a server that gives workspace diagnostics says nothing while it works through them, so it is shown
--- as busy from the request until diagnostics have stopped arriving for a while (`analysis_quiet`), counting the files
--- with problems found so far.
M.analysis_quiet = 3000
local analysis_timers = {}

local function analysis_quiet_timer(key)
  if analysis_timers[key] then analysis_timers[key]:stop() end
  analysis_timers[key] = analysis_timers[key] or vim.uv.new_timer()
  analysis_timers[key]:start(M.analysis_quiet, 0, vim.schedule_wrap(function()
    M.progress[key] = nil
    push_progress()
  end))
end

function M.track_analysis(client)
  local key = 'analysis:' .. client.id
  progress_stamp = progress_stamp + 1
  M.progress[key] = { client = (client.name:gsub('^trim_', '')), title = 'Analysing files', stamp = progress_stamp }
  push_progress()
  analysis_quiet_timer(key)
end

--- The server has given all it has: the analysis is over (a moment on, so that it is seen).
function M.analysis_done(client)
  local key = 'analysis:' .. client.id
  if analysis_timers[key] then analysis_timers[key]:stop() end
  vim.defer_fn(function()
    M.progress[key] = nil
    push_progress()
  end, 600)
end

--- Diagnostics arrived (told by `trim.diag`): an analysis going on has found more.
function M.diagnostics_changed()
  for key, entry in pairs(M.progress) do
    if key:match('^analysis:') then
      entry.message = ('%d files with problems'):format(require('trim.diag').files_with_problems())
      analysis_quiet_timer(key)
      push_progress()
    end
  end
end

--- Starts the server for a buffer (attaches it, if already running).
function M.start(name, buf)
  local spec, command = M.specs[name], M.commands[name]
  if not spec or not command or not vim.api.nvim_buf_is_valid(buf) then return end
  local st = state_of(name)
  if st.status == 'failed' or st.status == 'stopped' then return end
  if #vim.lsp.get_clients({ name = 'trim_' .. name }) == 0 and st.status ~= 'restarting' then set(name, 'starting') end
  local id = vim.lsp.start(config(name, spec, buf, command), { bufnr = buf })
  if id and st.status ~= 'restarting' then set(name, 'ready') end
end

--- Folders a server was started for before any file of its kind was open (see `autostart`), by server.
M.warm = {}

--- Starts the server for a folder, attached to nothing (a file opened later finds it there).
function M.start_warm(name, dir)
  local spec, command = M.specs[name], M.commands[name]
  if not spec or not command then return end
  local st = state_of(name)
  if st.status == 'failed' or st.status == 'stopped' then return end
  if #vim.lsp.get_clients({ name = 'trim_' .. name }) == 0 and st.status ~= 'restarting' then set(name, 'starting') end
  local id = vim.lsp.start(config_at(name, spec, dir, command), { attach = false })
  if id and st.status ~= 'restarting' then set(name, 'ready') end
end

local function attach_all(name)
  local spec = M.specs[name]
  for dir in pairs(M.warm[name] or {}) do M.start_warm(name, dir) end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.tbl_contains(spec.filetypes, vim.bo[buf].filetype) then
      M.start(name, buf)
    end
  end
end

--- Callbacks waiting for a server's program (what Razor's HTML bridge asks for: the HTML server).
local wanted = {}

--- The program of a server, when it is known: `fn(command)` now if it is, else once Trim has answered (nil: none).
function M.want(name, fn)
  if M.commands[name] ~= nil then return fn(M.commands[name] or nil) end
  wanted[name] = wanted[name] or {}
  table.insert(wanted[name], fn)
  if not asked[name] then
    asked[name] = true
    set(name, 'starting')
    notify('trim_lsp_ask', name, vim.uv.cwd())
  end
end

--- Trim's answer to what was asked: the command, or nothing if there is none.
function M.ready(name, command)
  M.commands[name] = command or false
  for _, fn in ipairs(wanted[name] or {}) do fn(command or nil) end
  wanted[name] = nil
  if not command then return set(name, 'failed') end
  state_of(name).status = 'idle'
  attach_all(name)
end

--- A server's process ended. Told it was stopped on purpose, that is the end; else it crashed.
function M.exited(name, code, signal)
  require('trim.diag').clear_remote('trim_' .. name)
  for key, entry in pairs(M.progress) do
    if entry.client == name then M.progress[key] = nil end
  end
  push_progress()
  if (stopping[name] or 0) > 0 then
    stopping[name] = stopping[name] - 1
    return
  end
  if (code == 0) and (signal == 0 or signal == nil) then return set(name, 'stopped') end
  local st = state_of(name)
  local now = vim.uv.now()
  st.deaths[#st.deaths + 1] = now
  st.deaths = vim.tbl_filter(function(t) return now - t < M.window end, st.deaths)
  if #st.deaths >= M.max_deaths then
    set(name, 'failed')
    vim.notify(('Trim: %s kept dying (%d times in a minute); :TrimLsp restart tries again'):format(name, #st.deaths), vim.log.levels.WARN)
    return
  end
  set(name, 'restarting')
  local wait = st.wait
  st.wait = math.min(st.wait * 2, M.wait_max)
  vim.defer_fn(function()
    if state_of(name).status ~= 'restarting' then return end
    state_of(name).status = 'idle'
    attach_all(name)
    if state_of(name).status == 'idle' then set(name, 'ready') end
    -- Alive for a minute: the wait starts over.
    vim.defer_fn(function()
      if state_of(name).status == 'ready' then state_of(name).wait = M.wait_first end
    end, M.window)
  end, wait)
end

--- Stops the server (its clients), for good until started again.
function M.stop(name)
  require('trim.diag').clear_remote('trim_' .. name)
  -- Each client stopped will report its end: those are not crashes.
  for _, client in ipairs(vim.lsp.get_clients({ name = 'trim_' .. name })) do
    stopping[name] = (stopping[name] or 0) + 1
    client:stop(true)
  end
  set(name, 'stopped')
end

--- Stopped and started afresh, the count of deaths forgotten.
function M.restart(name)
  M.stop(name)
  local st = state_of(name)
  st.deaths, st.wait = {}, M.wait_first
  vim.defer_fn(function()
    st.status = 'idle'
    attach_all(name)
    if st.status == 'idle' then set(name, 'ready') end
  end, 300)
end

local function ask(name)
  asked[name] = true
  set(name, 'starting')
  notify('trim_lsp_ask', name, vim.uv.cwd())
end

--- Which project files say a server is wanted for a folder, by server (first match wins, in this order).
local warm_patterns = {
  csharp = { '%.slnx$', '%.sln$', '%.csproj$' },
  fsautocomplete = { '%.fsproj$' },
  rust_analyzer = { '^Cargo%.toml$' },
  sourcekit = { '^Package%.swift$' },
  gopls = { '^go%.mod$', '^go%.work$' },
  typescript = { '^tsconfig%.json$', '^jsconfig%.json$', '^package%.json$' },
}
local not_projects = { node_modules = true, bin = true, obj = true, target = true, build = true, dist = true, vendor = true, Pods = true }

--- The folders to look in for project files: the folder, what is directly in it, and what is directly in src.
local function project_folders(root)
  local function children(dir)
    local out = {}
    for name, kind in vim.fs.dir(dir) do
      if kind == 'directory' and not name:match('^%.') and not not_projects[name] and #out < 200 then out[#out + 1] = dir .. '/' .. name end
    end
    return out
  end
  local folders = { root }
  local first = children(root)
  vim.list_extend(folders, first)
  for _, dir in ipairs(first) do
    if ({ src = true, source = true, sources = true })[vim.fs.basename(dir)] then vim.list_extend(folders, children(dir)) end
  end
  return folders
end

--- What a folder is, from its project files: { [server] = the file that says so }.
function M.detect(root)
  local found = {}
  for _, dir in ipairs(project_folders(root)) do
    for name, kind in vim.fs.dir(dir) do
      if kind == 'file' then
        for server, patterns in pairs(warm_patterns) do
          if not found[server] then
            for _, pattern in ipairs(patterns) do
              if name:match(pattern) then
                found[server] = dir .. '/' .. name
                break
              end
            end
          end
        end
      end
    end
  end
  return found
end

--- Starts, at launch, the servers a folder's project files call for, without a file open: they begin on the project
--- (Roslyn on the solution) and report what is wrong with it, to the problems list and the tree, in the background.
--- `[lsp] autostart = false` in the settings leaves it to a file being opened.
function M.autostart(root)
  if ((vim.g.trim_settings or {}).lsp or {}).autostart == false then return end
  for name, marker in pairs(M.detect(root)) do
    local spec = M.specs[name]
    local served = false
    for _, alias in ipairs(spec and spec.aliases or {}) do
      local ok, enabled = pcall(vim.lsp.is_enabled, alias)
      if ok and enabled then served = true end
    end
    if spec and not served then
      local dir = vim.fs.root(marker, spec.root) or vim.fs.dirname(marker)
      M.warm[name] = M.warm[name] or {}
      M.warm[name][dir] = true
      if M.commands[name] then M.start_warm(name, dir) elseif not asked[name] then ask(name) end
    end
  end
end

--- A file of a served kind opened: ask Trim for the program the first time, start the server.
local function opened(args)
  local buf = args.buf
  if vim.b[buf].trim_big then return end
  local ft = vim.bo[buf].filetype
  for name, spec in pairs(M.specs) do
    if vim.tbl_contains(spec.filetypes, ft) and not theirs(spec, buf) and vim.bo[buf].buftype == '' then
      if M.commands[name] ~= nil then
        if M.commands[name] then M.start(name, buf) end
      elseif not asked[name] then
        ask(name)
      end
    end
  end
end

--- Restarts the server(s) serving a buffer.
function M.restart_for(buf)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    local name = client.name:gsub('^trim_', '')
    if M.specs[name] then M.restart(name) end
  end
end

--- What the language server panel shows: each server that has been wanted, how it is, where it is rooted, what it is
--- busy with, and the program (to find its process).
function M.rows()
  local rows = {}
  for name, spec in pairs(M.specs) do
    local st = M.state[name]
    local client = vim.lsp.get_clients({ name = 'trim_' .. name })[1]
    if st or client then
      local busy = {}
      for _, entry in pairs(M.progress) do
        if entry.client == name then
          local text = entry.title or ''
          if entry.message and entry.message ~= '' then text = text .. ' ' .. entry.message end
          if entry.percentage then text = text .. (' %d%%'):format(entry.percentage) end
          busy[#busy + 1] = text
        end
      end
      local command = M.commands[name]
      rows[#rows + 1] = {
        name = name, status = st and st.status or 'idle', root = client and client.root_dir or '',
        buffers = client and vim.tbl_count(client.attached_buffers or {}) or 0, deaths = st and #st.deaths or 0,
        busy = table.concat(busy, ' · '), program = command and command[1] or '', filetypes = table.concat(spec.filetypes, ', '),
      }
    end
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return rows
end

--- A summary of the servers, for `:TrimLsp`.
function M.report()
  local lines = {}
  for name in pairs(M.specs) do
    local st = M.state[name]
    if st then lines[#lines + 1] = ('%s: %s (%d deaths in the last minute)'):format(name, st.status, #st.deaths) end
  end
  table.sort(lines)
  return #lines > 0 and table.concat(lines, '\n') or 'no language server has been asked for yet'
end

function M.setup()
  vim.filetype.add({ extension = { razor = 'razor', cshtml = 'razor' } })
  -- Razor's HTML bridge (sill.razor_html) asks `sill.servers` for the HTML server: here Trim's own way of having one.
  package.loaded['sill.servers'] = package.loaded['sill.servers'] or { want = function(name, _, fn) M.want(name, fn) end }
  local group = vim.api.nvim_create_augroup('TrimLsp', { clear = true })
  vim.api.nvim_create_autocmd('FileType', { group = group, callback = opened })
  -- Keys for what a server offers, on the buffers it is attached to (not over one the config bound).
  vim.api.nvim_create_autocmd('LspProgress', {
    group = group,
    callback = function(args)
      local data = args.data or {}
      local client = vim.lsp.get_client_by_id(data.client_id)
      local value = data.params and data.params.value
      if not client or type(value) ~= 'table' then return end
      local key = data.client_id .. ':' .. tostring(data.params.token)
      if value.kind == 'end' then
        M.progress[key] = nil
      else
        progress_stamp = progress_stamp + 1
        local previous = M.progress[key] or {}
        M.progress[key] = {
          client = (client.name:gsub('^trim_', '')), title = value.title or previous.title, message = value.message,
          percentage = value.percentage, stamp = progress_stamp,
        }
      end
      push_progress()
    end,
  })
  vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(args)
      -- Servers other than Roslyn say what is wrong with every file once they are up.
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client and client.name:match('^trim_') then M.complete(client, args.buf) end
      if client and client.name:match('^trim_') and client.name ~= 'trim_csharp' and not client.trim_scanned then
        client.trim_scanned = true
        vim.defer_fn(function() M.workspace_diagnostics(client) end, 500)
      end
      local function map(lhs, rhs, desc)
        if vim.fn.maparg(lhs, 'n', false, true).buffer ~= 1 then vim.keymap.set('n', lhs, rhs, { buffer = args.buf, desc = desc }) end
      end
      local usages = require('trim.usages')
      map('gd', usages.definition, 'Go to definition')
      map('gy', usages.type_definition, 'Go to type definition')
      map('gr', usages.references, 'References')
      map('gI', usages.implementation, 'Go to implementation')
      map('<leader>ls', usages.symbols, 'Symbols in this file')
      map('<leader>lS', usages.workspace_symbols, 'Symbols in the workspace')
      map('K', M.hover, 'Hover')
      map('<leader>la', vim.lsp.buf.code_action, 'Code action')
      -- Alt+Enter (ReSharper, Rider) and Cmd+. (Xcode, VS Code): what can be done here.
      for _, lhs in ipairs({ '<M-CR>', '<D-.>' }) do
        for _, mode in ipairs({ 'n', 'v', 'i' }) do
          if vim.fn.maparg(lhs, mode, false, true).buffer ~= 1 then
            vim.keymap.set(mode, lhs, vim.lsp.buf.code_action, { buffer = args.buf, desc = 'Code action' })
          end
        end
      end
      map('<leader>lr', vim.lsp.buf.rename, 'Rename')
      map('<leader>lf', function() vim.lsp.buf.format({ async = true }) end, 'Format')
      map('<leader>ld', vim.diagnostic.open_float, 'Line diagnostics')
      map('<leader>ll', vim.diagnostic.setloclist, 'Diagnostics list')
      map('<leader>lR', function() require('trim.lsp').restart_for(args.buf) end, 'Restart the language server')
    end,
  })
  vim.api.nvim_create_user_command('TrimLsp', function(opts)
    local verb, name = opts.fargs[1] or 'status', opts.fargs[2]
    local function each(fn)
      if name then
        if M.specs[name] then fn(name) else vim.notify('TrimLsp: no server named ' .. name, vim.log.levels.ERROR) end
      else
        for n in pairs(M.specs) do if M.state[n] then fn(n) end end
      end
    end
    if verb == 'restart' then each(M.restart)
    elseif verb == 'stop' then each(M.stop)
    else vim.notify(M.report()) end
  end, {
    nargs = '*',
    complete = function(_, line)
      local words = vim.split(line, '%s+')
      if #words <= 2 then return { 'status', 'restart', 'stop' } end
      return vim.tbl_keys(M.specs)
    end,
    desc = 'Language servers: status, restart [name], stop [name]',
  })
end

return M
