-- What the language server knows about a piece of a basket (sill asks as it goes in): the symbol around its lines,
-- that symbol's hover, the tests that reach it (references in test folders, by the test around each) and the problems
-- in the lines. Asked without making nvim wait: `ask` starts it, `take` collects the answer.
local M = {}

local answers = {}
local next_ask = 0

local function client_for(buf, capability)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    if client.server_capabilities[capability] then return client end
  end
end

-- The innermost symbol whose range holds `line` (0-based), from a documentSymbol answer.
local function innermost(symbols, line, best)
  for _, symbol in ipairs(symbols or {}) do
    local range = symbol.range or (symbol.location and symbol.location.range)
    if range and range.start.line <= line and range['end'].line >= line then
      best = symbol
      best = innermost(symbol.children, line, best)
    end
  end
  return best
end

local function loaded(path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  return buf
end

--- Starts collecting for `path`'s lines `from`-`to` (1-based); `tests` are the folders tests live in. `take` answers
--- { symbol, hover, tests = { { name, path, line } }, problems = { ... } }, what could be had.
function M.ask(path, from, to, tests)
  next_ask = next_ask + 1
  local token, out = next_ask, { tests = {}, problems = {} }
  local buf = loaded(path)
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    if d.lnum + 1 >= from and d.lnum + 1 <= to and d.severity <= vim.diagnostic.severity.WARN then
      table.insert(out.problems, (d.code and (d.code .. ' ') or '') .. d.message:gsub('\n.*', ''))
    end
  end
  local client = client_for(buf, 'documentSymbolProvider')
  if not client then
    answers[token] = out
    return token
  end
  local uri = vim.uri_from_fname(path)
  client:request('textDocument/documentSymbol', { textDocument = { uri = uri } }, function(_, symbols)
    local symbol = innermost(symbols, from - 1)
    if not symbol then
      answers[token] = out
      return
    end
    out.symbol = symbol.name
    local at = (symbol.selectionRange or symbol.range or symbol.location.range).start
    local position = { textDocument = { uri = uri }, position = at }
    client:request('textDocument/hover', position, function(_, hover)
      local contents = hover and hover.contents
      out.hover = type(contents) == 'table' and (contents.value or contents[1] and (contents[1].value or contents[1]))
        or contents
      if type(out.hover) ~= 'string' then out.hover = nil end
      client:request('textDocument/references', vim.tbl_extend('force', position, {
        context = { includeDeclaration = false },
      }), function(_, references)
        -- References in test folders, by file; the test around each found in that file's symbols.
        local files = {}
        for _, ref in ipairs(references or {}) do
          local file = vim.uri_to_fname(ref.uri)
          for _, folder in ipairs(tests or {}) do
            if file:sub(1, #folder + 1) == folder .. '/' then
              files[file] = files[file] or {}
              table.insert(files[file], ref.range.start.line)
            end
          end
        end
        local pending = 0
        for _ in pairs(files) do pending = pending + 1 end
        if pending == 0 then
          answers[token] = out
          return
        end
        for file, lines in pairs(files) do
          local test_buf = loaded(file)
          local test_client = client_for(test_buf, 'documentSymbolProvider') or client
          test_client:request('textDocument/documentSymbol', { textDocument = { uri = vim.uri_from_fname(file) } },
            function(_, test_symbols)
              for _, line in ipairs(lines) do
                local around = innermost(test_symbols, line)
                table.insert(out.tests, { name = around and around.name or vim.fn.fnamemodify(file, ':t'),
                  path = file, line = line + 1 })
              end
              pending = pending - 1
              if pending == 0 then answers[token] = out end
            end, test_buf)
        end
      end, buf)
    end, buf)
  end, buf)
  return token
end

--- The answer to `token`, once it has come (then forgotten); nil before.
function M.take(token)
  local answer = answers[token]
  answers[token] = nil
  return answer
end

return M
