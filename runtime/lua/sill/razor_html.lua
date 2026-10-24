-- Razor's HTML, answered by the HTML language server (plan §5's bridge), as VS Code's Razor extension does. Roslyn's
-- cohosted Razor sends each .razor and .cshtml file's HTML as `razor/updateHtml` (the file's text with its C# masked,
-- line for line), and asks the client what it would ask of HTML (hover, completion, colours, formatting, …) as the
-- request it wraps with the file and the HTML's checksum. Here each file's HTML is a virtual document open in
-- vscode-html-language-server, which knows the CSS in <style> and the JavaScript in <script> too, and each question
-- goes to it about that document. Server requests run in a coroutine, so a question waits for the HTML server's
-- answer without holding nvim up.
local M = {}

-- Each Razor file's HTML as last sent, by the file's URI: { checksum, text, version, uri (the virtual document's) }.
local documents = {}
-- Questions waiting for a file's HTML at a checksum they name, by the file's URI.
local waiting = {}
-- The HTML server's client: nil before it is asked for, false when it could not be had.
local client_id
local starting = false
local queued = {}

local function virtual(uri)
  return uri .. '__virtual.html'
end

local function client()
  return client_id and vim.lsp.get_client_by_id(client_id) or nil
end

local function send(document)
  local html = client()
  if not html then
    return
  end
  if document.opened then
    html:notify('textDocument/didChange', {
      textDocument = { uri = document.uri, version = document.version },
      contentChanges = { { text = document.text } },
    })
  else
    document.opened = true
    html:notify('textDocument/didOpen', {
      textDocument = { uri = document.uri, languageId = 'html', version = document.version, text = document.text },
    })
  end
end

--- Starts the HTML server the first time a Razor file's HTML comes: sill finds or provisions it as for .html files.
local function start(path)
  if client_id ~= nil or starting then
    return
  end
  starting = true
  require('sill.servers').want('html', path, function(cmd)
    starting = false
    if not cmd then
      client_id = false
      return
    end
    client_id = vim.lsp.start({
      name = 'sill_razor_html',
      cmd = cmd,
      root_dir = vim.fn.getcwd(),
      init_options = { provideFormatter = true, embeddedLanguages = { css = true, javascript = true } },
    }, { attach = false }) or false
    for _, document in pairs(documents) do
      send(document)
    end
    for _, fn in ipairs(queued) do
      fn()
    end
    queued = {}
  end)
end

--- `razor/updateHtml`: a file's HTML now.
function M.update(params)
  local uri = params.textDocument.uri
  local document = documents[uri] or { uri = virtual(uri), version = 0 }
  documents[uri] = document
  document.checksum = params.checksum
  document.text = params.text
  document.version = document.version + 1
  start(vim.uri_to_fname(uri))
  send(document)
  for _, resume in ipairs(waiting[uri] or {}) do
    resume()
  end
  waiting[uri] = nil
  return vim.NIL
end

--- Whether the bridge can answer: false when there is no HTML server to be had.
function M.available()
  return client_id ~= false
end

-- Within a coroutine: waits until `ready()` or `seconds` pass, `on` registering how it is woken.
local function wait_for(ready, seconds, on)
  if ready() then
    return true
  end
  local co = coroutine.running()
  if not co then
    return false
  end
  local woken = false
  local function wake()
    if not woken then
      woken = true
      coroutine.resume(co)
    end
  end
  on(wake)
  vim.defer_fn(wake, seconds * 1000)
  coroutine.yield()
  return ready()
end

-- URIs of the virtual document in an answer, made the Razor file's again.
local function restore(value, from, to)
  if type(value) == 'string' then
    return value == from and to or value
  elseif type(value) == 'table' then
    local out = {}
    for key, item in pairs(value) do
      out[key == from and to or key] = restore(item, from, to)
    end
    return setmetatable(out, getmetatable(value))
  end
  return value
end

--- Razor's question about a file's HTML (`params`: { textDocument, checksum, request }), answered by the HTML server;
--- `empty` when it cannot be (no server, or its HTML never came).
function M.ask(method, params, empty)
  local uri = params.textDocument and params.textDocument.uri
  if not uri or not coroutine.running() or not M.available() then
    return empty
  end
  -- The HTML the question is about: it may still be on its way.
  local document = documents[uri]
  local current = wait_for(function()
    document = documents[uri]
    return document ~= nil and document.checksum == params.checksum
  end, 2, function(wake)
    waiting[uri] = waiting[uri] or {}
    table.insert(waiting[uri], wake)
  end)
  if not current then
    return empty
  end
  if not client() then
    wait_for(function() return client() ~= nil or client_id == false end, 30, function(wake)
      table.insert(queued, wake)
    end)
  end
  local html = client()
  if not html then
    return empty
  end
  local request = vim.deepcopy(params.request or {})
  if type(request.textDocument) == 'table' then
    request.textDocument.uri = document.uri
  end
  local co = coroutine.running()
  local answer, failed
  local done = false
  html:request(method, request, function(err, result)
    answer, failed, done = result, err, true
    coroutine.resume(co)
  end)
  if not done then
    coroutine.yield()
  end
  if failed or answer == nil then
    return empty
  end
  -- A hover's pictures are inline SVG (a browser-support badge): text in an editor, so left out.
  if method == 'textDocument/hover' and type(answer.contents) == 'table' and type(answer.contents.value) == 'string' then
    answer.contents.value = answer.contents.value:gsub('!%[[^%]]*%]%(data:[^%)]*%)', ''):gsub('\n\n\n+', '\n\n')
  end
  return restore(answer, document.uri, uri)
end

--- The HTML server's client id, for the self-check.
function M.client_id()
  return client_id
end

return M
