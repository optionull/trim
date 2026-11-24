-- The walkthrough's own nvim (headless): the document as a real buffer, so every motion, search, register and mode works
-- in it. It tells the app where the cursor is and in what mode, when the text changes, and which of Trim's keys was
-- pressed; the app draws the document and keeps the code beside it where the cursor is.
local M = {}
M.channel = nil

local function tell(method, ...)
  if M.channel then vim.rpcnotify(M.channel, method, ...) end
end

--- Where the cursor is: line (1-based), column (0-based) and the mode nvim is in.
function M.report()
  local position = vim.api.nvim_win_get_cursor(0)
  tell('walk_cursor', position[1], position[2], vim.api.nvim_get_mode().mode)
end

local function text()
  tell('walk_text', vim.api.nvim_buf_get_lines(0, 0, -1, false))
end

local function task(line)
  return vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1]:match('^%s*[-*] %[[ xX]%]') ~= nil
end

function M.setup(channel)
  M.channel = channel
  vim.o.swapfile = false
  vim.o.autoread = true
  vim.o.timeoutlen = 400
  vim.o.shortmess = vim.o.shortmess .. 'I'
  vim.o.laststatus = 0
  vim.o.cmdheight = 1
  local group = vim.api.nvim_create_augroup('TrimWalkDoc', { clear = true })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'ModeChanged' }, { group = group, callback = M.report })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufEnter' }, {
    group = group, callback = function() text(); M.report() end,
  })
  vim.api.nvim_create_autocmd('BufWritePost', { group = group, callback = function() tell('walk_saved') end })
  local function map(lhs, fn, desc) vim.keymap.set('n', lhs, fn, { silent = true, desc = desc }) end
  local function line() return vim.api.nvim_win_get_cursor(0)[1] end
  map(']]', function() vim.fn.search('^## ', 'W') end, 'Next step')
  map('[[', function() vim.fn.search('^## ', 'bW') end, 'Previous step')
  map('<CR>', function() tell('walk_action', 'jump', line()) end, 'Show the code, and go to it')
  map('gp', function() tell('walk_action', 'slides', line()) end, 'Present: one step at a time')
  map('gs', function() tell('walk_action', 'source', line()) end, 'Edit the source in the editor')
  map('ga', function() tell('walk_action', 'ask', line()) end, 'Ask about this step')
  map('gr', function() tell('walk_action', 'run', line()) end, 'Run this block')
  map('q', function() tell('walk_action', 'close', line()) end, 'Close the walkthrough')
  -- `x` ticks a checklist item; anywhere else it is nvim's.
  map('x', function()
    if task(line()) then tell('walk_action', 'toggle', line()) else vim.cmd('normal! x') end
  end, 'Tick or untick a checklist item')
end

return M
