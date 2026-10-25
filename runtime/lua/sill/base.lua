-- sill's base settings: loaded before the user's own config (which wins), or alone when there is none.
local o = vim.o
o.number = true
o.signcolumn = 'yes'
o.termguicolors = true
o.mouse = 'a'
o.ignorecase = true
o.smartcase = true
o.splitright = true
o.splitbelow = true
o.scrolloff = 4
o.updatetime = 250
o.undofile = true
o.cursorline = true
vim.g.sill_base = true
-- Inside sill, for a config's own conditions (`cond = not vim.g.sill`).
vim.g.sill = true
-- nvim's own notify, before a plugin replaces it: sill draws messages itself.
return { notify = vim.notify }
