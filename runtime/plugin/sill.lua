-- sill's runtime. Loaded from the runtimepath sill starts nvim with.
--
-- Terminal panes. nvim owns the window layout, so a terminal pane is an ordinary nvim window showing a placeholder
-- buffer; sill draws a Ghostty surface over that window's cells. :split, <C-w>hjkl, resizing and :only all work on
-- it like on any window. As with nvim's own :terminal, the window is in normal mode until `i` (or a, I, A) hands the
-- keyboard to the terminal; <C-\><C-n> in the terminal hands it back.
if vim.g.loaded_sill then
  return
end
vim.g.loaded_sill = true

local next_pane = 0

local function notify(method, ...)
  local channel = vim.g.sill_channel
  if channel then
    vim.rpcnotify(channel, method, ...)
  end
end

-- Reports every window that shows a pane's placeholder, as a list of {window, pane}, across all tab pages.
local function report()
  local panes = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local pane = vim.b[vim.api.nvim_win_get_buf(win)].sill_pane
    if pane then
      table.insert(panes, { win, pane })
    end
  end
  notify('sill_panes', panes)
end

local scheduled = false
local function report_soon()
  if scheduled then
    return
  end
  scheduled = true
  vim.schedule(function()
    scheduled = false
    report()
  end)
end

local function focus_terminal()
  notify('sill_terminal', vim.b.sill_pane)
end

local function placeholder(buf)
  next_pane = next_pane + 1
  vim.b[buf].sill_pane = next_pane
  vim.bo[buf].buftype = 'nofile'
  -- The pane lives as long as its buffer: closing the last window on it closes the terminal.
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'sillterminal'
  for _, key in ipairs({ 'i', 'a', 'I', 'A', '<Insert>' }) do
    vim.keymap.set('n', key, focus_terminal, { buffer = buf, desc = 'Type into the terminal' })
  end
end

-- :SillTerminal opens a terminal pane in a new window. Modifiers place it as they place :new
-- (:vertical SillTerminal, :botright SillTerminal); without one it opens to the right.
vim.api.nvim_create_user_command('SillTerminal', function(opts)
  local mods = opts.mods ~= '' and opts.mods or 'vertical rightbelow'
  vim.cmd(mods .. ' new')
  placeholder(vim.api.nvim_get_current_buf())
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = 'no'
  vim.wo.foldcolumn = '0'
  vim.wo.spell = false
  report()
end, { desc = 'Open a terminal pane' })

vim.api.nvim_create_autocmd({ 'WinNew', 'WinClosed', 'BufWinEnter', 'BufWipeout', 'TabEnter', 'TabClosed' }, {
  group = vim.api.nvim_create_augroup('sill_panes', {}),
  callback = report_soon,
})
