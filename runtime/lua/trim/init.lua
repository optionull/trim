-- What Trim's nvim sets up once the person's own additions (~/.config/trim/init.lua) have run: tree-sitter, the
-- colour scheme, how diagnostics show. Defaults that a config should override are in trim.base, which runs before.
local M = {}

--- The tree-sitter parsers the app carries (`treesitter` beside the runtime in Trim.app; `Vendor/treesitter` in the
--- source tree), then sill's way of starting them for each buffer that has one.
local function syntax()
  local runtime = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
  for _, folder in ipairs({ vim.fn.fnamemodify(runtime, ':h') .. '/Vendor/treesitter' }) do
    if vim.fn.isdirectory(folder) == 1 then vim.opt.runtimepath:append(folder) end
  end
  require('sill.syntax').setup()
end

local function theme()
  -- The person's init.lua may have chosen one (a colorscheme command of theirs): that stays.
  if vim.g.colors_name and vim.g.colors_name ~= 'default' then return end
  local name = ((vim.g.trim_settings or {}).theme or {}).colorscheme or 'tokyonight-night'
  if not pcall(vim.cmd.colorscheme, name) then pcall(vim.cmd.colorscheme, 'tokyonight-night') end
end

local function diagnostics()
  vim.diagnostic.config({
    virtual_text = { prefix = '●', spacing = 2 },
    severity_sort = true,
    underline = true,
    float = { border = 'rounded', source = true },
    signs = true,
  })
end

function M.setup()
  if vim.g.loaded_frame then return end
  vim.g.loaded_frame = true
  syntax()
  theme()
  diagnostics()
  require('trim.plugins').setup()
  require('trim.lsp').setup()
end

return M
