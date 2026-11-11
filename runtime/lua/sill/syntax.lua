-- Tree-sitter highlighting in sill's own nvim: for every buffer whose language has a parser, nvim's own (C, Lua,
-- Vim script, Markdown) or one sill built into its cache (~/Library/Caches/sill/treesitter, built by the app's
-- SyntaxParsers, which says when they are there). Until then, and for a language without one, nvim's syntax
-- files colour the buffer as they always did.
local M = {}

-- Filetypes whose parser has another name.
local languages = {
  c_sharp = { 'cs' },
  bash = { 'sh', 'zsh' },
  tsx = { 'typescriptreact' },
  javascript = { 'javascriptreact' },
  json = { 'jsonc' },
  xml = { 'xsd', 'xslt', 'svg' },
}
for language, filetypes in pairs(languages) do
  vim.treesitter.language.register(language, filetypes)
end

local function start(buf)
  if not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= '' then return end
  local language = vim.treesitter.language.get_lang(vim.bo[buf].filetype)
  if not language or not pcall(vim.treesitter.language.add, language) then return end
  -- A query that does not fit the parser (an error in it) leaves the buffer to its syntax file.
  pcall(vim.treesitter.start, buf, language)
end

local added = false
local function add(folder)
  if added or vim.fn.isdirectory(folder) == 0 then return end
  added = true
  vim.opt.runtimepath:append(folder)
end

--- The parsers are in `folder`: every buffer open highlights with them, and every one opened later.
function M.ready(folder)
  add(folder)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not vim.b[buf].ts_highlight then start(buf) end
  end
end

function M.setup()
  -- What an earlier start built is there at once; the app says when a build is done.
  add(vim.fn.expand('~/Library/Caches/sill/treesitter'))
  vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('sill_syntax', {}),
    callback = function(args) start(args.buf) end,
  })
end

return M
