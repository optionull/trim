-- sill's runtime: what sill needs of nvim, loaded from the runtimepath sill starts nvim with.
--
-- Panes. nvim owns the window layout, so everything sill draws inside it (a terminal, the sidebar, the bottom panel)
-- is an ordinary nvim window showing a placeholder buffer, with sill's view drawn over the window's cells. :split,
-- <C-w>hjkl, resizing and :only work on them like on any window. A terminal is in normal mode until `i` (or a, I, A)
-- hands it the keyboard, as nvim's own :terminal is; <C-\><C-n> in the terminal hands it back.
local M = {}

local next_pane = 0

local function notify(method, ...)
  local channel = vim.g.sill_channel
  if channel then
    vim.rpcnotify(channel, method, ...)
  end
end

--- Every window that shows a pane's placeholder, as a list of {window, pane, kind}, across all tab pages.
local function report()
  local panes = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local pane = vim.b[buf].sill_pane
    if pane then
      table.insert(panes, { win, pane, vim.b[buf].sill_kind or 'terminal' })
    end
  end
  notify('sill_panes', panes)
end

--- The current buffer, for the status bar: its name, path, file type and whether it is modified.
local function report_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  notify('sill_buffer', {
    path = path,
    name = path ~= '' and vim.fn.fnamemodify(path, ':t') or '',
    filetype = vim.bo[buf].filetype,
    modified = vim.bo[buf].modified,
    kind = vim.b[buf].sill_kind or '',
  })
end

--- Every diagnostic, for the Problems panel: severity (1 error to 4 hint), message, source, code, file and position.
local function report_diagnostics()
  local list = {}
  for _, d in ipairs(vim.diagnostic.get(nil)) do
    -- A pane's placeholder is not a file anyone edits.
    if vim.api.nvim_buf_is_valid(d.bufnr) and not vim.b[d.bufnr].sill_pane then
      table.insert(list, {
        severity = d.severity, message = d.message, source = d.source or '', code = tostring(d.code or ''),
        path = vim.api.nvim_buf_get_name(d.bufnr), buffer = d.bufnr, line = d.lnum + 1, col = d.col + 1,
      })
    end
  end
  notify('sill_diagnostics', list)
end

-- Tabs per split: each editor window keeps the files opened in it, as an editor group does, and sill draws them as
-- a strip over the window's winbar row.
local function is_file_buffer(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted and vim.bo[buf].buftype == ''
    and not vim.b[buf].sill_pane
end

local function editor_windows()
  local wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not vim.b[vim.api.nvim_win_get_buf(win)].sill_pane and vim.api.nvim_win_get_config(win).relative == '' then
      table.insert(wins, win)
    end
  end
  return wins
end

--- Adds the buffer a window shows to its tabs, and gives the window a winbar row for sill's strip.
local function track(win)
  local buf = vim.api.nvim_win_get_buf(win)
  if not vim.g.sill_chrome or vim.b[buf].sill_pane or vim.api.nvim_win_get_config(win).relative ~= '' then
    return
  end
  if vim.wo[win].winbar == '' then
    vim.wo[win].winbar = ' '
  end
  if not is_file_buffer(buf) or (vim.api.nvim_buf_get_name(buf) == '' and not vim.bo[buf].modified) then
    return
  end
  local tabs = vim.w[win].sill_tabs or {}
  if not vim.tbl_contains(tabs, buf) then
    table.insert(tabs, buf)
    vim.w[win].sill_tabs = tabs
  end
end

--- Each editor window's tabs: {window, current buffer, {{buffer, name, modified}, ...}}.
local function report_tabs()
  local result = {}
  for _, win in ipairs(editor_windows()) do
    local tabs = {}
    -- An unnamed buffer is a tab once something is typed into it; an empty one (after the last tab closed) is not.
    local shown = vim.api.nvim_win_get_buf(win)
    if is_file_buffer(shown) and vim.api.nvim_buf_get_name(shown) == '' and vim.bo[shown].modified then
      track(win)
    end
    for _, buf in ipairs(vim.w[win].sill_tabs or {}) do
      if is_file_buffer(buf) and (vim.api.nvim_buf_get_name(buf) ~= '' or vim.bo[buf].modified) then
        local path = vim.api.nvim_buf_get_name(buf)
        table.insert(tabs, { buf, path ~= '' and vim.fn.fnamemodify(path, ':t') or '[No Name]', vim.bo[buf].modified })
      end
    end
    table.insert(result, { win, vim.api.nvim_win_get_buf(win), tabs })
  end
  notify('sill_tabs', result)
end

--- Shows tab `buf` in window `win`.
function M.select_tab(win, buf)
  if vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_buf(win, buf)
  end
end

--- Closes tab `buf` in window `win`: the window shows the tab beside it, or an empty buffer if it was the last. The
--- buffer stays loaded (another window may show it); unsaved changes are kept.
function M.close_tab(win, buf)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local tabs = vim.w[win].sill_tabs or {}
  local index
  for i, b in ipairs(tabs) do
    if b == buf then
      index = i
    end
  end
  if not index then
    return
  end
  table.remove(tabs, index)
  vim.w[win].sill_tabs = tabs
  if vim.api.nvim_win_get_buf(win) == buf then
    local next = tabs[math.min(index, #tabs)]
    if next then
      vim.api.nvim_win_set_buf(win, next)
    else
      vim.api.nvim_win_call(win, function() vim.cmd('enew') end)
    end
  end
  report_tabs()
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
    report_buffer()
    report_tabs()
  end)
end

local function focus_terminal()
  notify('sill_terminal', vim.b.sill_pane)
end

--- Makes `buf` the placeholder for a pane of `kind`: 'terminal', 'sidebar' or 'panel'.
local function placeholder(buf, kind)
  next_pane = next_pane + 1
  vim.b[buf].sill_pane = next_pane
  vim.b[buf].sill_kind = kind
  vim.bo[buf].buftype = 'nofile'
  -- A terminal lives as long as its buffer: closing its last window closes it. The sidebar and the panel come back.
  vim.bo[buf].bufhidden = kind == 'terminal' and 'wipe' or 'hide'
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'sill' .. kind
  -- A name for the tab line and the window list: "Terminal 2", "Profile".
  local title = kind:sub(1, 1):upper() .. kind:sub(2)
  pcall(vim.api.nvim_buf_set_name, buf, kind == 'terminal' and (title .. ' ' .. next_pane) or title)
  if kind == 'terminal' then
    for _, key in ipairs({ 'i', 'a', 'I', 'A', '<Insert>' }) do
      vim.keymap.set('n', key, focus_terminal, { buffer = buf, desc = 'Type into the terminal' })
    end
  end
  return next_pane
end

--- Window options for a pane: nothing of nvim's own drawn in it.
local function bare(win)
  for option, value in pairs({
    number = false, relativenumber = false, signcolumn = 'no', foldcolumn = '0', spell = false, list = false,
    cursorline = false, winbar = '',
  }) do
    vim.wo[win][option] = value
  end
end

--- The hidden buffer of a sidebar or panel pane, to show again rather than make another.
local function hidden_pane_buffer(kind)
  if kind == 'terminal' then
    return nil
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[buf].sill_kind == kind and vim.fn.bufwinid(buf) == -1 then
      return buf
    end
  end
end

--- Opens a pane of `kind` in a new window placed by `mods` (as :new takes them), and returns the window. A sidebar or
--- panel that was hidden comes back as the same pane.
function M.open_pane(kind, mods)
  local buf = hidden_pane_buffer(kind)
  if buf then
    vim.cmd(mods .. ' split')
    vim.api.nvim_win_set_buf(0, buf)
    local win = vim.api.nvim_get_current_win()
    bare(win)
    report()
    return win
  end
  vim.cmd(mods .. ' new')
  local win = vim.api.nvim_get_current_win()
  placeholder(vim.api.nvim_get_current_buf(), kind)
  bare(win)
  report()
  return win
end

-- :SillTerminal opens a terminal pane. Modifiers place it as they place :new (:vertical SillTerminal,
-- :botright SillTerminal); without one it opens to the right.
vim.api.nvim_create_user_command('SillTerminal', function(opts)
  M.open_pane('terminal', opts.mods ~= '' and opts.mods or 'vertical rightbelow')
end, { desc = 'Open a terminal pane' })

-- Editor windows: the last one used is where the sidebar opens files.
local function is_pane(win)
  return vim.b[vim.api.nvim_win_get_buf(win)].sill_pane ~= nil
end

function M.editor_window()
  local last = vim.g.sill_editor_win
  if last and vim.api.nvim_win_is_valid(last) and not is_pane(last)
    and vim.api.nvim_win_get_tabpage(last) == vim.api.nvim_get_current_tabpage() then
    return last
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not is_pane(win) and vim.api.nvim_win_get_config(win).relative == '' then
      return win
    end
  end
end

--- Opens `path` in the last editor window used, at `line` and `col` if given.
function M.open(path, line, col)
  local win = M.editor_window()
  if win then
    vim.api.nvim_set_current_win(win)
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
  if line then
    pcall(vim.api.nvim_win_set_cursor, 0, { line, math.max((col or 1) - 1, 0) })
  end
end

--- Shows buffer `buf` in the last editor window used, at `line` and `col`: where a problem is, named file or not.
function M.goto(buf, line, col)
  local win = M.editor_window()
  if win then
    vim.api.nvim_set_current_win(win)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_win_set_buf(0, buf)
    pcall(vim.api.nvim_win_set_cursor, 0, { line, math.max((col or 1) - 1, 0) })
  end
end

--- Compares the current file with its version at `ref` (HEAD by default), in nvim's diff mode: the old version
--- read-only on the left. The bones of boards 4 to 6; ]c and [c move between changes, do and dp take them.
function M.diff(ref)
  ref = (ref and ref ~= '') and ref or 'HEAD'
  local path = vim.api.nvim_buf_get_name(0)
  if path == '' then
    vim.notify('SillDiff: this buffer is not a file', vim.log.levels.WARN)
    return
  end
  local dir = vim.fn.fnamemodify(path, ':h')
  local root = vim.fn.systemlist({ 'git', '-C', dir, 'rev-parse', '--show-toplevel' })[1]
  if vim.v.shell_error ~= 0 or not root then
    vim.notify('SillDiff: ' .. path .. ' is not in a git repository', vim.log.levels.WARN)
    return
  end
  local relative = path:sub(#root + 2)
  local old = vim.fn.systemlist({ 'git', '-C', root, 'show', ref .. ':' .. relative })
  if vim.v.shell_error ~= 0 then
    old = {}
  end
  local filetype = vim.bo.filetype
  -- Side by side in this tab page if there is room, else in a tab page of its own.
  if vim.api.nvim_win_get_width(0) < 2 * math.max(vim.o.winwidth, 20) + 1 then
    vim.cmd('tab split')
  end
  vim.cmd('diffthis')
  vim.cmd('leftabove vnew')
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, old)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = filetype
  pcall(vim.api.nvim_buf_set_name, buf, relative .. ' @ ' .. ref)
  vim.cmd('diffthis')
  vim.cmd('wincmd p')
end

--- A language server action ('definition', 'references', 'rename') where one is attached, else a notice.
function M.lsp(action)
  if #vim.lsp.get_clients({ bufnr = 0 }) == 0 then
    vim.notify('No language server for this file', vim.log.levels.INFO)
    return
  end
  vim.lsp.buf[action]()
end

--- Who last changed the cursor's line, and in which commit, as a notification.
function M.blame()
  local path = vim.api.nvim_buf_get_name(0)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local out = vim.fn.systemlist({ 'git', '-C', vim.fn.fnamemodify(path, ':h'), 'blame', '-L', line .. ',' .. line,
    '--porcelain', '--', path })
  if vim.v.shell_error ~= 0 or #out == 0 then
    vim.notify('No blame: ' .. path .. ' is not committed', vim.log.levels.INFO)
    return
  end
  local fields = { commit = out[1]:match('^(%x+)'):sub(1, 8) }
  for _, l in ipairs(out) do
    local key, value = l:match('^(%S+) (.*)$')
    if key == 'author' or key == 'summary' or key == 'author-time' then
      fields[key] = value
    end
  end
  local when = fields['author-time'] and os.date('%Y-%m-%d', tonumber(fields['author-time'])) or ''
  vim.notify(string.format('%s  %s, %s: %s', fields.commit, fields.author or '?', when, fields.summary or ''))
end

--- The window showing the pane of `kind` in this tab page, if there is one.
function M.pane_window(kind)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.b[vim.api.nvim_win_get_buf(win)].sill_kind == kind then
      return win
    end
  end
end

--- Shows the sidebar (`kind` 'sidebar') or the bottom panel ('panel'), or hides it if it shows.
function M.toggle(kind)
  local win = M.pane_window(kind)
  if win then
    vim.api.nvim_win_hide(win)
  elseif kind == 'sidebar' then
    M.open_pane('sidebar', 'topleft vertical ' .. (vim.g.sill_sidebar_width or 32))
    vim.wo.winfixwidth = true
  else
    local editor = M.editor_window()
    if editor then
      vim.api.nvim_set_current_win(editor)
    end
    M.open_pane('panel', 'botright ' .. (vim.g.sill_panel_height or 8))
    vim.wo.winfixheight = true
  end
  report()
end

--- Goes to the window of the pane of `kind`, opening it if it is hidden.
function M.focus(kind)
  if not M.pane_window(kind) then
    M.toggle(kind)
  end
  vim.api.nvim_set_current_win(M.pane_window(kind))
end

-- The board's colours, for what nvim still draws: the text, line numbers, separators.
local colours = {
  Normal = { fg = '#d9dce3', bg = '#121418' },
  NormalNC = { fg = '#d9dce3', bg = '#121418' },
  LineNr = { fg = '#5d6572' },
  CursorLineNr = { fg = '#d9dce3' },
  CursorLine = { bg = '#181b21' },
  Visual = { bg = '#2a3140' },
  WinSeparator = { fg = '#2a2f38', bg = '#121418' },
  StatusLine = { fg = '#2a2f38', bg = '#121418' },
  StatusLineNC = { fg = '#2a2f38', bg = '#121418' },
  EndOfBuffer = { fg = '#121418' },
  WinBar = { fg = '#d9dce3', bg = '#181b21' },
  WinBarNC = { fg = '#8b93a1', bg = '#181b21' },
}

--- The rule between stacked windows, where nvim would put a status line: sill's status bar says what it said.
function M.rule()
  return string.rep('─', vim.api.nvim_win_get_width(vim.g.statusline_winid or 0))
end

--- sill's window: its status bar replaces nvim's status lines, its colours, the sidebar on the left and the panel
--- under the editor.
function M.chrome()
  vim.g.sill_chrome = true
  vim.o.laststatus = 0
  -- sill's status bar replaces nvim's status lines; a plugin turning them back on (lualine sets laststatus) is put
  -- back, whenever it does it.
  vim.api.nvim_create_autocmd('OptionSet', {
    group = vim.api.nvim_create_augroup('sill_chrome', {}),
    pattern = 'laststatus',
    callback = function()
      if vim.o.laststatus ~= 0 then
        vim.schedule(function() vim.o.laststatus = 0 end)
      end
    end,
  })
  vim.o.statusline = "%{v:lua.require'sill'.rule()}"
  vim.o.ruler = false
  vim.o.showmode = false
  vim.opt.fillchars = { eob = ' ', vert = '│', horiz = '─', horizup = '┴', horizdown = '┬', vertleft = '┤',
    vertright = '├', verthoriz = '┼' }
  -- The board's colours, unless the user's config chose a colour scheme: theirs wins.
  if vim.g.colors_name == nil or vim.g.colors_name == 'default' then
    for group, spec in pairs(colours) do
      vim.api.nvim_set_hl(0, group, spec)
    end
  end
  local editor = vim.api.nvim_get_current_win()
  vim.g.sill_editor_win = editor
  M.toggle('panel')
  vim.api.nvim_set_current_win(editor)
  M.toggle('sidebar')
  vim.api.nvim_set_current_win(editor)
  for _, win in ipairs(editor_windows()) do
    track(win)
  end
  report_tabs()
end

function M.setup()
  if vim.g.loaded_sill then
    return
  end
  vim.g.loaded_sill = true
  vim.api.nvim_create_user_command('SillChrome', M.chrome, { desc = "sill's window: sidebar, panel, colours" })
  vim.api.nvim_create_user_command('SillProfile', function()
    M.open_pane('profile', 'tab')
  end, { desc = 'Open the profiler (a synthetic profile until M6)' })
  vim.api.nvim_create_user_command('SillMerge', function(opts)
    if #opts.fargs ~= 4 then
      vim.notify(':SillMerge takes four files: local base remote merged', vim.log.levels.ERROR)
      return
    end
    require('sill.merge').open(unpack(opts.fargs))
  end, { nargs = '+', complete = 'file', desc = 'Three-way merge: local base remote merged' })
  vim.api.nvim_create_user_command('SillMergeBase', function()
    require('sill.merge').toggle_base()
  end, { desc = 'Show or hide the base of a merge' })
  vim.api.nvim_create_user_command('SillDiffFiles', function(opts)
    if #opts.fargs ~= 2 then
      vim.notify(':SillDiffFiles takes two files', vim.log.levels.ERROR)
      return
    end
    require('sill.merge').diff(unpack(opts.fargs))
  end, { nargs = '+', complete = 'file', desc = 'Two-way diff of two files' })
  vim.api.nvim_create_user_command('SillDiff', function(opts)
    M.diff(opts.args)
  end, { nargs = '?', desc = 'Compare the file with its version at a ref (HEAD)' })
  local group = vim.api.nvim_create_augroup('sill', {})
  vim.api.nvim_create_autocmd({ 'WinNew', 'WinClosed', 'BufWinEnter', 'BufWipeout', 'TabEnter', 'TabClosed',
    'BufEnter', 'FileType', 'BufModifiedSet', 'BufWritePost' }, { group = group, callback = report_soon })
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinNew' }, {
    group = group,
    callback = function()
      track(vim.api.nvim_get_current_win())
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    group = group,
    callback = function(args)
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local tabs = vim.w[win].sill_tabs
        if tabs then
          vim.w[win].sill_tabs = vim.tbl_filter(function(b) return b ~= args.buf end, tabs)
        end
      end
      report_soon()
    end,
  })
  vim.api.nvim_create_autocmd('DiagnosticChanged', { group = group, callback = vim.schedule_wrap(report_diagnostics) })
  vim.api.nvim_create_autocmd('WinEnter', {
    group = group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if not is_pane(win) and vim.api.nvim_win_get_config(win).relative == '' then
        vim.g.sill_editor_win = win
      end
      report_soon()
    end,
  })
end

return M
