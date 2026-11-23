-- Frame's own base settings, on top of sill's: loaded before anything of the person's (~/.config/frame/init.lua), which
-- wins. Frame runs its own isolated nvim config: nothing of ~/.config/nvim (nor of any other config) is read. What
-- ~/.config/frame/settings.toml says arrives as vim.g.frame_settings (see Sources/Frame/FrameSettings.swift).
vim.g.frame = true
local settings = vim.g.frame_settings or {}
local editor = settings.editor or {}

-- The leader: `\` unless the settings say another.
vim.g.mapleader = editor.leader or '\\'
vim.g.maplocalleader = editor.localleader or '\\'

local o = vim.o
-- Indent with spaces, four wide (editorconfig, which nvim honours, says otherwise per project).
o.expandtab = true
o.tabstop = 4
o.shiftwidth = 4
o.softtabstop = 4
-- Yank and paste go to the system clipboard.
o.clipboard = 'unnamedplus'
-- Lines are not wrapped (a long one scrolls sideways) but break at words when they are.
o.wrap = false
o.linebreak = true
-- Scrolling goes by screen lines through a wrapped line, and a key sequence waits a moment for its next key.
o.smoothscroll = true
o.timeoutlen = 400
-- A wheel step is one line (Frame sends three per notch of a mouse wheel itself), so a trackpad moves the text exactly as far as
-- the finger does.
o.mousescroll = 'ver:1,hor:1'
-- What is hidden in a line is shown quietly; the end of the buffer is not a column of tildes.
o.list = true
o.listchars = 'tab:» ,trail:·,nbsp:␣'
o.fillchars = 'eob: ,fold: '
-- Folds from the syntax tree, all open.
o.foldmethod = 'expr'
o.foldexpr = 'v:lua.vim.treesitter.foldexpr()'
o.foldlevelstart = 99
o.confirm = true
o.pumheight = 12
-- Completion: a menu even for one candidate, matched fuzzily, nothing taken until it is chosen, with what the server says of
-- the candidate beside it.
-- No `popup`: the documentation is drawn by the window beside the menu (see lsp.lua).
o.completeopt = 'menu,menuone,noselect,fuzzy'
o.shortmess = o.shortmess .. 'cI'

-- What the settings' `[editor]` says (tab width, wrap, line numbers...) wins over the above.
require('frame.options').apply(editor)
-- The last line stays near the bottom of a window: scrolling does not take it to the top.
require('frame.scrollpast').setup(editor.scrollpast)

-- Taking a completion: Tab and Shift-Tab walk the menu (or a snippet's places), Enter takes the one chosen, Ctrl-Space asks
-- for the menu, Ctrl-S for the signature of what is being called.
local function pumvisible() return vim.fn.pumvisible() == 1 end
vim.keymap.set('i', '<Tab>', function()
  if pumvisible() then return '<C-n>' end
  if vim.snippet.active({ direction = 1 }) then return '<Cmd>lua vim.snippet.jump(1)<CR>' end
  return '<Tab>'
end, { expr = true, desc = 'Next completion, next snippet place, or a tab' })
vim.keymap.set('i', '<S-Tab>', function()
  if pumvisible() then return '<C-p>' end
  if vim.snippet.active({ direction = -1 }) then return '<Cmd>lua vim.snippet.jump(-1)<CR>' end
  return '<S-Tab>'
end, { expr = true, desc = 'Previous completion or snippet place' })
vim.keymap.set('i', '<CR>', function()
  if pumvisible() and vim.fn.complete_info({ 'selected' }).selected >= 0 then return '<C-y>' end
  return '<CR>'
end, { expr = true, desc = 'Take the completion chosen, or a new line' })
vim.keymap.set('i', '<C-Space>', function() vim.lsp.completion.get() end, { desc = 'Complete' })
vim.keymap.set({ 'i', 's' }, '<C-s>', function() vim.lsp.buf.signature_help() end, { desc = 'Signature help' })

-- The plugins Frame carries: in the app (`runtime/pack/frame/start/*`), or in the source tree (`Vendor/plugins/*`). A
-- name in `plugins.disabled` of the settings is left out.
local disabled = {}
for _, name in ipairs((settings.plugins or {}).disabled or {}) do disabled[name] = true end
local runtime = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
for _, folder in ipairs({ runtime .. '/pack/frame/start', vim.fn.fnamemodify(runtime, ':h') .. '/Vendor/plugins' }) do
  for _, dir in ipairs(vim.fn.glob(folder .. '/*', true, true)) do
    if vim.fn.isdirectory(dir) == 1 and not disabled[vim.fn.fnamemodify(dir, ':t')] then
      vim.opt.runtimepath:append(dir)
    end
  end
end
return {}
