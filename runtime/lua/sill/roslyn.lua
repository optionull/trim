-- C# and Razor through Roslyn's language server, which sill's sidecar downloads to the user's machine (plan §5: never in
-- the app). nvim's own LSP client talks to it; on starting, the server is told which solution (or projects) to open, as
-- roslyn.nvim does. Razor is cohosted in the server: .razor and .cshtml files go to it as `aspnetcorerazor`, and Razor's
-- questions about their HTML go to the HTML server (`sill.razor_html`, as VS Code's Razor extension does), or get empty
-- answers when there is none, so Razor's own (components, directives, the C#) stand alone. A config that already runs a
-- C# server keeps its own.
local M = {}

-- The Roslyn clients whose projects have loaded: asked before that, a question waits for the load.
M.loaded = {}

M.filetypes = { 'cs', 'razor' }

vim.filetype.add({ extension = { razor = 'razor', cshtml = 'razor' } })

--- What Razor asks the client about a file's HTML, wrapped with the file and its HTML's checksum: lists answer empty,
--- resolves answer the item they were given, the rest null.
local html_lists = {
  'textDocument/formatting', 'textDocument/rangeFormatting', 'textDocument/onTypeFormatting', 'textDocument/codeAction',
  'textDocument/documentHighlight', 'textDocument/references', 'textDocument/foldingRange',
  'textDocument/documentColor', 'textDocument/colorPresentation',
}
local html_nulls = {
  'textDocument/hover', 'textDocument/signatureHelp', 'textDocument/definition', 'textDocument/implementation',
  'textDocument/prepareRename', 'textDocument/rename', 'textDocument/linkedEditingRange',
  'textDocument/_vs_onAutoInsert',
}

--- Whether a message is Razor asking about HTML (its params carry the HTML's checksum), not a reply to the client.
local function from_razor(params)
  return type(params) == 'table' and params.checksum ~= nil
end

--- A handler for a method Razor also asks the client: Razor's question answered by the HTML server, else
--- `answer(params)`; anything else as nvim would have handled it.
local function html(method, answer)
  return function(err, result, ctx, config)
    if from_razor(result) then
      return require('sill.razor_html').ask(method, result, answer(result))
    end
    local default = vim.lsp.handlers[method]
    if default then
      return default(err, result, ctx, config)
    end
  end
end

local function html_handlers()
  local handlers = {
    ['razor/updateHtml'] = function(_, params) return require('sill.razor_html').update(params) end,
    ['textDocument/completion'] = html('textDocument/completion', function()
      return { isIncomplete = false, items = {} }
    end),
    ['completionItem/resolve'] = html('completionItem/resolve', function(params) return params.request or vim.NIL end),
    ['codeAction/resolve'] = html('codeAction/resolve', function(params) return params.request or vim.NIL end),
  }
  for _, method in ipairs(html_lists) do
    handlers[method] = html(method, function() return {} end)
  end
  for _, method in ipairs(html_nulls) do
    handlers[method] = html(method, function() return vim.NIL end)
  end
  return handlers
end

--- The handlers Razor's cohosting needs of a client (its questions about HTML answered, its diagnostics taken once), for
--- another host of Roslyn's server (Frame) to use as sill does.
function M.razor_handlers()
  return vim.tbl_extend('force', html_handlers(), {
    ['workspace/_roslyn_projectNeedsRestore'] = function() return vim.NIL end,
    ['textDocument/diagnostic'] = function(err, result, ctx, config)
      local identifier = ctx.params and ctx.params.identifier
      if identifier ~= nil and ctx.bufnr and vim.api.nvim_buf_is_valid(ctx.bufnr) and vim.bo[ctx.bufnr].filetype == 'razor' then
        return
      end
      return vim.lsp.diagnostic.on_diagnostic(err, result, ctx, config)
    end,
  })
end

--- The language id a document goes to Roslyn with.
function M.language_id(_, filetype)
  return filetype == 'razor' and 'aspnetcorerazor' or filetype == 'cs' and 'csharp' or filetype
end

local function notify(method, ...)
  local channel = vim.g.sill_channel
  if channel then
    vim.rpcnotify(channel, method, ...)
  end
end

local function state(status)
  notify('sill_lsp', { name = 'Roslyn', status = status })
end

--- The solution (or projects) a file belongs to: the nearest folder up with a .sln or .slnx, else with projects.
function M.target(path)
  local dir = vim.fs.dirname(path)
  local solution = vim.fs.find(function(name) return name:match('%.slnx?$') end,
    { path = dir, upward = true, type = 'file', limit = 1 })[1]
  if solution then
    return vim.fs.dirname(solution), { solution = solution }
  end
  local project = vim.fs.find(function(name) return name:match('%.csproj$') end,
    { path = dir, upward = true, type = 'file', limit = 1 })[1]
  if project then
    return vim.fs.dirname(project), { projects = { project } }
  end
end

local function others(buf)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    if client.name ~= 'roslyn' and (client.name:match('roslyn') or client.name:match('omnisharp') or client.name == 'csharp_ls') then
      return true
    end
  end
  return false
end

--- Roslyn's client for the solution (or projects) `target` in `root`.
local function config(root, target, dll, logs)
  return {
    name = 'roslyn',
    cmd = { 'dotnet', dll, '--logLevel=Information', '--extensionLogDirectory=' .. logs, '--stdio' },
    root_dir = root,
    -- No file watching offered: Roslyn then watches the solution itself, in its own process. Offered, nvim matched
    -- every file a build or a clean touched against Roslyn's patterns, in Lua, and paused for seconds.
    capabilities = vim.tbl_deep_extend('force', vim.lsp.protocol.make_client_capabilities(), {
      workspace = { didChangeWatchedFiles = { dynamicRegistration = false } },
    }),
    get_language_id = function(_, filetype)
      return filetype == 'razor' and 'aspnetcorerazor' or filetype == 'cs' and 'csharp' or filetype
    end,
    on_init = function(client)
      if target.solution then
        client:notify('solution/open', { solution = vim.uri_from_fname(target.solution) })
      else
        client:notify('project/open', { projects = vim.tbl_map(vim.uri_from_fname, target.projects) })
      end
    end,
    handlers = vim.tbl_extend('force', html_handlers(), {
      ['workspace/projectInitializationComplete'] = function(_, _, ctx)
        M.loaded[ctx.client_id] = true
        state('ready')
        -- Pull diagnostics again for what is open, now the projects are loaded.
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(b) and vim.tbl_contains(M.filetypes, vim.bo[b].filetype) then
            pcall(vim.lsp.diagnostic._refresh, b, ctx.client_id)
          end
        end
      end,
      ['workspace/_roslyn_projectNeedsRestore'] = function() return vim.NIL end,
      -- Roslyn's diagnostic sources are registered for every document, so a Razor file is pulled once for each, and
      -- Razor answers each with the same: its diagnostics are Razor's own pull (the one with no identifier) alone.
      ['textDocument/diagnostic'] = function(err, result, ctx, config)
        local identifier = ctx.params and ctx.params.identifier
        if identifier ~= nil and ctx.bufnr and vim.api.nvim_buf_is_valid(ctx.bufnr)
          and vim.bo[ctx.bufnr].filetype == 'razor' then
          return
        end
        return vim.lsp.diagnostic.on_diagnostic(err, result, ctx, config)
      end,
    }),
    on_exit = function() state('stopped') end,
  }
end

function M.attach(buf, dll, logs)
  local path = vim.api.nvim_buf_get_name(buf)
  local root, target = M.target(path)
  if not root or others(buf) then
    return
  end
  -- The one started ahead for this root is reused: same name, same root.
  if #vim.lsp.get_clients({ name = 'roslyn' }) == 0 then state('starting') end
  vim.lsp.start(config(root, target, dll, logs), { bufnr = buf })
end

--- Roslyn started before any C# file opens, for the solution at the root of the folder sill opened: its projects
--- load (about 15 s on a large solution) while the person looks around, so the first file has it ready.
function M.prestart(dll, logs)
  local root = vim.fn.getcwd()
  local solutions = vim.fn.glob(root .. '/*.slnx', false, true)
  if #solutions == 0 then solutions = vim.fn.glob(root .. '/*.sln', false, true) end
  if #solutions ~= 1 or #vim.lsp.get_clients({ name = 'roslyn' }) > 0 then return end
  state('starting')
  vim.lsp.start(config(root, { solution = solutions[1] }, dll, logs), { attach = false })
end

--- Starts Roslyn for every C# and Razor buffer, now and as they open. `dll` is the server sill provisioned.
function M.setup(dll, logs)
  vim.fn.mkdir(logs, 'p')
  local group = vim.api.nvim_create_augroup('sill_roslyn', {})
  vim.api.nvim_create_autocmd('FileType', {
    group = group, pattern = M.filetypes,
    callback = function(args) M.attach(args.buf, dll, logs) end,
  })
  local open = false
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.tbl_contains(M.filetypes, vim.bo[buf].filetype) then
      M.attach(buf, dll, logs)
      open = true
    end
  end
  if not open then M.prestart(dll, logs) end
end

return M
