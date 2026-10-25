-- Tracing a symbol (sill's trace pane asks): its call hierarchy from the language server, who calls it and what it
-- calls, a level at a time. Items stay here, by number; sill sees what it draws (a name, a file, a line) and asks for a
-- level by number. Answers come back asynchronously: `ask` starts a request and `take` collects it, so nvim never
-- waits on a server.
local M = {}

local items = {}
local answers = {}
local next_item, next_ask = 0, 0

-- An item as sill sees it, kept here with the client that gave it.
local function keep(item, client_id, ranges)
  next_item = next_item + 1
  items[next_item] = { item = item, client = client_id }
  local start = (item.selectionRange or item.range).start
  return {
    id = next_item,
    name = item.name,
    detail = item.detail or '',
    path = vim.uri_to_fname(item.uri),
    line = start.line + 1,
    col = start.character + 1,
    -- Where in the caller the calls are (incoming) or in this item (outgoing): their first line.
    at = ranges and ranges[1] and ranges[1].start.line + 1 or nil,
  }
end

local function finish(token, value)
  answers[token] = value
end

--- Starts preparing the item at `path`'s `line` and `col` (1-based): `take` answers { items = {...} } or
--- { problem = ... }.
function M.prepare(path, line, col)
  next_ask = next_ask + 1
  local token = next_ask
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  local clients = vim.tbl_filter(function(c) return c.server_capabilities.callHierarchyProvider end,
    vim.lsp.get_clients({ bufnr = buf }))
  if #clients == 0 then
    finish(token, { problem = 'No language server that traces calls is running for ' .. vim.fn.fnamemodify(path, ':t') })
    return token
  end
  local client = clients[1]
  client:request('textDocument/prepareCallHierarchy', {
    textDocument = { uri = vim.uri_from_fname(path) },
    position = { line = line - 1, character = col - 1 },
  }, function(err, result)
    if err then return finish(token, { problem = err.message }) end
    local kept = {}
    for _, item in ipairs(result or {}) do table.insert(kept, keep(item, client.id)) end
    if #kept == 0 then return finish(token, { problem = 'Nothing to trace there' }) end
    finish(token, { items = kept })
  end, buf)
  return token
end

--- Starts asking for the calls of item `id`: 'incoming' (who calls it) or 'outgoing' (what it calls).
function M.calls(id, direction)
  next_ask = next_ask + 1
  local token = next_ask
  local kept = items[id]
  local client = kept and vim.lsp.get_client_by_id(kept.client)
  if not client then
    finish(token, { problem = 'The language server that found it has stopped' })
    return token
  end
  local method = direction == 'incoming' and 'callHierarchy/incomingCalls' or 'callHierarchy/outgoingCalls'
  client:request(method, { item = kept.item }, function(err, result)
    if err then return finish(token, { problem = err.message }) end
    local out = {}
    for _, call in ipairs(result or {}) do
      table.insert(out, keep(direction == 'incoming' and call.from or call.to, client.id, call.fromRanges))
    end
    finish(token, { items = out })
  end)
  return token
end

--- The answer to `token`, once it has come (then forgotten); nil before.
function M.take(token)
  local answer = answers[token]
  answers[token] = nil
  return answer
end

--- The symbol under the cursor, for :SillTrace.
function M.here()
  local pos = vim.api.nvim_win_get_cursor(0)
  return { path = vim.api.nvim_buf_get_name(0), line = pos[1], col = pos[2] + 1 }
end

return M
