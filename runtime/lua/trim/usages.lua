-- Where a symbol is used, defined or implemented, and a file's or the workspace's symbols: the answers of the server as
-- Trim's own list (the line, its file beside it), Return going there, instead of nvim's quickfix window. One answer is
-- gone to at once.
local M = {}

local function jump(item)
  vim.cmd("normal! m'")
  local path = item.filename
  if vim.api.nvim_buf_get_name(0) ~= path then vim.cmd.edit(vim.fn.fnameescape(path)) end
  pcall(vim.api.nvim_win_set_cursor, 0, { item.lnum, math.max((item.col or 1) - 1, 0) })
  vim.cmd('normal! zv')
end

--- What a language server answered (as `on_list` is given it), as a list to choose from.
function M.show(title, answer)
  local items = answer.items or {}
  if #items == 0 then return vim.notify('Trim: no ' .. title:lower() .. ' found', vim.log.levels.INFO) end
  if #items == 1 then return jump(items[1]) end
  local rows = {}
  for index, item in ipairs(items) do
    local name = item.filename or ''
    rows[index] = {
      title = vim.trim((item.text or ''):gsub('\t', ' ')),
      detail = vim.fn.fnamemodify(name, ':.') .. ':' .. (item.lnum or 1),
      file = vim.fn.fnamemodify(name, ':t'),
    }
  end
  require('trim.ui').pick(title .. ' (' .. #items .. ')', rows, function(index)
    if index then jump(items[index]) end
  end)
end

local function on(title) return { on_list = function(answer) M.show(title, answer) end } end

function M.definition() vim.lsp.buf.definition(on('Definitions')) end
function M.type_definition() vim.lsp.buf.type_definition(on('Type definitions')) end
function M.implementation() vim.lsp.buf.implementation(on('Implementations')) end
function M.references() vim.lsp.buf.references(nil, on('References')) end
function M.symbols() vim.lsp.buf.document_symbol(on('Symbols')) end
function M.workspace_symbols()
  local query = vim.fn.input('Symbol: ')
  if query ~= '' then vim.lsp.buf.workspace_symbol(query, on('Workspace symbols')) end
end

return M
