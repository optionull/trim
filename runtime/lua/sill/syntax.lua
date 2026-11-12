-- Tree-sitter highlighting in sill's own nvim: for every buffer whose language has a parser, nvim's own (C, Lua,
-- Vim script, Markdown) or one Sill.app ships (Contents/Resources/treesitter, beside this runtime: built ahead of time
-- by scripts/treesitter.lua). For a language without one, nvim's syntax files colour the buffer as they always did.
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

--- The parsers Sill.app ships: `treesitter` beside the runtime this file is in.
local function shipped()
  local here = debug.getinfo(1, 'S').source:gsub('^@', '')
  return vim.fn.fnamemodify(here, ':p:h:h:h:h') .. '/treesitter'
end

function M.setup()
  local folder = shipped()
  if vim.fn.isdirectory(folder) == 1 then vim.opt.runtimepath:append(folder) end
  vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('sill_syntax', {}),
    callback = function(args) start(args.buf) end,
  })
end

return M
