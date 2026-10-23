-- C# through Roslyn's language server, which sill's sidecar downloads to the user's machine (plan §5: never in the
-- app). nvim's own LSP client talks to it; on starting, the server is told which solution (or projects) to open, as
-- roslyn.nvim does. A config that already runs a C# server keeps its own.
local M = {}

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

function M.attach(buf, dll, logs)
  local path = vim.api.nvim_buf_get_name(buf)
  local root, target = M.target(path)
  if not root or others(buf) then
    return
  end
  state('starting')
  vim.lsp.start({
    name = 'roslyn',
    cmd = { 'dotnet', dll, '--logLevel=Information', '--extensionLogDirectory=' .. logs, '--stdio' },
    root_dir = root,
    on_init = function(client)
      if target.solution then
        client:notify('solution/open', { solution = vim.uri_from_fname(target.solution) })
      else
        client:notify('project/open', { projects = vim.tbl_map(vim.uri_from_fname, target.projects) })
      end
    end,
    handlers = {
      ['workspace/projectInitializationComplete'] = function(_, _, ctx)
        state('ready')
        -- Pull diagnostics again for what is open, now the projects are loaded.
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == 'cs' then
            pcall(vim.lsp.diagnostic._refresh, b, ctx.client_id)
          end
        end
      end,
      ['workspace/_roslyn_projectNeedsRestore'] = function() return vim.NIL end,
    },
    on_exit = function() state('stopped') end,
  }, { bufnr = buf })
end

--- Starts Roslyn for every C# buffer, now and as they open. `dll` is the server sill provisioned.
function M.setup(dll, logs)
  vim.fn.mkdir(logs, 'p')
  local group = vim.api.nvim_create_augroup('sill_roslyn', {})
  vim.api.nvim_create_autocmd('FileType', {
    group = group, pattern = 'cs',
    callback = function(args) M.attach(args.buf, dll, logs) end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == 'cs' then
      M.attach(buf, dll, logs)
    end
  end
end

return M
