-- sill's own nvim (the default; `[nvim] config = "yours"` runs the person's instead): an editor for reading code and
-- steering agents, set up so it needs no setting up. Nothing is downloaded: it uses what nvim has built in (the
-- language servers sill starts, their completion through sill's native menu, fuzzy finding, the diagnostics), in
-- sill's colours. Your own additions go in ~/.config/sill/init.lua, which loads after this.
local o, map = vim.o, vim.keymap.set

vim.g.mapleader = ' '
vim.g.maplocalleader = '\\'
vim.g.sill_config = true

-- Reading.
o.wrap = false
o.breakindent = true
o.linebreak = true
o.sidescrolloff = 8
o.smartindent = true
o.virtualedit = 'block'
o.confirm = true
o.showmode = false
o.timeoutlen = 400
o.clipboard = 'unnamedplus'
o.inccommand = 'nosplit'
o.fillchars = 'eob: ,fold: ,foldsep: ,diff:╱'
o.shortmess = o.shortmess .. 'IcC'

-- Completing: what the language server knows, in sill's menu, as you type.
o.completeopt = 'menuone,noselect,fuzzy,popup'
o.pumheight = 12
o.wildoptions = 'pum,fuzzy'
o.wildmode = 'noselect:lastused,full'
vim.api.nvim_create_autocmd('LspAttach', {
  group = vim.api.nvim_create_augroup('sill_config_lsp', {}),
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if client and client:supports_method('textDocument/completion') then
      vim.lsp.completion.enable(true, client.id, args.buf, { autotrigger = true })
    end
  end,
})

-- Finding: `:find` (and <leader>ff) fuzzy over the files git knows, the whole tree when it is not a repository.
local files
local function list()
  if files then return files end
  files = vim.fn.systemlist({ 'git', 'ls-files', '--cached', '--others', '--exclude-standard' })
  if vim.v.shell_error ~= 0 then files = vim.fn.globpath('.', '**', false, true) end
  return files
end
vim.api.nvim_create_autocmd({ 'BufWritePost', 'FocusGained', 'DirChanged' }, {
  group = vim.api.nvim_create_augroup('sill_config_find', {}),
  callback = function() files = nil end,
})
function _G.SillFind(arg, _)
  return arg == '' and list() or vim.fn.matchfuzzy(list(), arg)
end
o.findfunc = 'v:lua.SillFind'
if vim.fn.executable('rg') == 1 then
  o.grepprg = 'rg --vimgrep --smart-case'
  o.grepformat = '%f:%l:%c:%m'
end

-- Problems: underlined where they are, the line's own shown under it while the cursor is there, worst first.
vim.diagnostic.config({
  underline = true,
  virtual_text = false,
  virtual_lines = { current_line = true },
  severity_sort = true,
  signs = { text = { '●', '●', '●', '·' } },
  float = { border = 'rounded', source = 'if_many' },
})

-- Keys: nvim's own (LSP's grn, gra, grr, gri, gO, K, [d, ]d), and a few for finding and moving.
map('n', '<leader>ff', ':find ', { desc = 'Find a file' })
map('n', '<leader>/', ':silent grep! ', { desc = 'Search the code' })
map('n', '<leader>e', function() require('sill').toggle('sidebar') end, { desc = 'Explorer' })
map('n', '<Esc>', '<Cmd>nohlsearch<CR><Esc>')
for _, key in ipairs({ 'h', 'j', 'k', 'l' }) do
  map('n', '<C-' .. key .. '>', '<C-w>' .. key, { desc = 'Window ' .. key })
end
map('n', '<leader>q', '<Cmd>copen<CR>', { desc = 'Search results' })
map('v', '<', '<gv')
map('v', '>', '>gv')

vim.cmd.colorscheme('sill')
