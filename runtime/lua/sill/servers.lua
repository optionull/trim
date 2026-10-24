-- The language servers sill starts (M7) beside Roslyn: rust-analyzer, sourcekit-lsp, marksman, HTML, CSS and JSON
-- (vscode-langservers-extracted), and TypeScript (its own `tsc --lsp`). A server starts the first time a file of its
-- kind opens, unless the person's config already runs one for that kind. sill finds each (on the PATH, from Xcode) or
-- provisions it into its cache (marksman downloaded, the web servers with npm); nvim's own client talks to it.
local M = {}

local function notify(method, ...)
  local channel = vim.g.sill_channel
  if channel then
    vim.rpcnotify(channel, method, ...)
  end
end

--- Each server: the file types it serves, how its folder is found, what the person's config may call it.
M.specs = {
  rust_analyzer = { filetypes = { 'rust' }, root = { 'Cargo.toml', '.git' }, aliases = { 'rust_analyzer', 'rust-analyzer' } },
  sourcekit = { filetypes = { 'swift' }, root = { 'Package.swift', '.git' }, aliases = { 'sourcekit' } },
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

--- Commands sill resolved, by server; false for one it could not.
M.commands = {}
local asked = {}

--- Whether the person's config already serves the file type: a server of theirs enabled for one of its names, or a
--- client of theirs attached to the buffer.
local function theirs(spec, buf)
  for _, alias in ipairs(spec.aliases) do
    local ok, enabled = pcall(vim.lsp.is_enabled, alias)
    if ok and enabled then
      return true
    end
  end
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    if not client.name:match('^sill_') and client.name ~= 'roslyn' then
      for _, alias in ipairs(spec.aliases) do
        if client.name == alias then
          return true
        end
      end
    end
  end
  return false
end

local function start(name, buf)
  local spec, cmd = M.specs[name], M.commands[name]
  if not cmd or not vim.api.nvim_buf_is_valid(buf) or theirs(spec, buf) then
    return
  end
  local root = vim.fs.root(buf, spec.root) or vim.fn.getcwd()
  vim.lsp.start({ name = 'sill_' .. name, cmd = cmd, root_dir = root }, { bufnr = buf })
end

--- A file of some kind opened: its server started, or asked of sill the first time.
local function opened(buf)
  local filetype = vim.bo[buf].filetype
  for name, spec in pairs(M.specs) do
    if vim.tbl_contains(spec.filetypes, filetype) and not theirs(spec, buf) then
      if M.commands[name] then
        start(name, buf)
      elseif M.commands[name] == nil and not asked[name] then
        asked[name] = true
        notify('sill_server', name, vim.api.nvim_buf_get_name(buf))
      end
    end
  end
end

-- Callers waiting for a server's command (Razor's HTML bridge), by server.
local waiting = {}

--- Calls `fn` with the command that runs `name`, at once when sill has it, else once sill has found or provisioned
--- it (asked for `path`'s sake); with false when it could not be had.
function M.want(name, path, fn)
  if M.commands[name] ~= nil then
    return fn(M.commands[name])
  end
  waiting[name] = waiting[name] or {}
  table.insert(waiting[name], fn)
  if not asked[name] then
    asked[name] = true
    notify('sill_server', name, path)
  end
end

--- sill's answer: the command that runs `name` (a list), or nil when it could not be had; then every open file it
--- serves gets it.
function M.ready(name, cmd)
  M.commands[name] = cmd or false
  for _, fn in ipairs(waiting[name] or {}) do
    fn(cmd or false)
  end
  waiting[name] = nil
  if not cmd then
    return
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.tbl_contains(M.specs[name].filetypes, vim.bo[buf].filetype) then
      start(name, buf)
    end
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup('sill_servers', {})
  local filetypes = {}
  for _, spec in pairs(M.specs) do
    vim.list_extend(filetypes, spec.filetypes)
  end
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = filetypes,
    -- After the person's config had its turn (its servers start on FileType too).
    callback = function(args) vim.schedule(function() opened(args.buf) end) end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      opened(buf)
    end
  end
end

return M
