-- Three-way merge (board 5): ours | result | theirs, in nvim's diff mode, the result being the file git asks to be
-- resolved, with its conflict markers. ]x and [x walk the conflicts; <localleader>o, t and b take ours, theirs or both
-- (plan §11: nothing shadows a core key). :SillMergeBase shows the base under the result.
local M = {}

local function notify(method, ...)
  local channel = vim.g.sill_channel
  if channel then
    vim.rpcnotify(channel, method, ...)
  end
end

-- A marker: seven of the character at the start of the line, then a space or nothing (a CR at most), so that a line
-- of eight `=` in Markdown is no separator. The same rules as SillCore's MergeConflicts.
local function marker(line, char)
  local rest = line:sub(8)
  return line:sub(1, 7) == string.rep(char, 7) and (rest == '' or rest == '\r' or rest:sub(1, 1) == ' ')
end

--- The conflicts in `buf`: each {start, base (its marker's line, or nil), separator, finish}, 1-based lines.
function M.conflicts(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local result, open = {}, nil
  for i, line in ipairs(lines) do
    if marker(line, '<') then
      open = { start = i }
    elseif open and not open.separator and marker(line, '|') then
      open.base = i
    elseif open and (line == '=======' or line == '=======\r') then
      open.separator = i
    elseif open and open.separator and marker(line, '>') then
      open.finish = i
      table.insert(result, open)
      open = nil
    end
  end
  return result
end

local function report()
  local buf = vim.g.sill_merge_result
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local conflicts = M.conflicts(buf)
  local cursor = vim.api.nvim_get_current_buf() == buf and vim.api.nvim_win_get_cursor(0)[1] or 0
  local current = 0
  for i, c in ipairs(conflicts) do
    if cursor >= c.start and cursor <= c.finish then
      current = i
    end
  end
  notify('sill_merge', { left = #conflicts, current = current, file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':t') })
end

--- Moves to the next (`step` 1) or previous (-1) conflict in the result.
function M.jump(step)
  local conflicts = M.conflicts(0)
  if #conflicts == 0 then
    vim.notify('No conflicts left', vim.log.levels.INFO)
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local target
  if step > 0 then
    for _, c in ipairs(conflicts) do
      if c.start > line then target = c.start break end
    end
    target = target or conflicts[1].start
  else
    for i = #conflicts, 1, -1 do
      if conflicts[i].start < line then target = conflicts[i].start break end
    end
    target = target or conflicts[#conflicts].start
  end
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  report()
end

--- Resolves the conflict under the cursor with `side`: 'ours', 'theirs' or 'both'.
function M.take(side)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  for _, c in ipairs(M.conflicts(0)) do
    if line >= c.start and line <= c.finish then
      local lines = vim.api.nvim_buf_get_lines(0, c.start - 1, c.finish, false)
      local ours_end = (c.base or c.separator) - c.start
      local ours = vim.list_slice(lines, 2, ours_end)
      local theirs = vim.list_slice(lines, c.separator - c.start + 2, #lines - 1)
      local chosen = side == 'ours' and ours or side == 'theirs' and theirs or vim.list_extend(vim.list_extend({}, ours), theirs)
      vim.api.nvim_buf_set_lines(0, c.start - 1, c.finish, false, chosen)
      vim.api.nvim_win_set_cursor(0, { math.min(c.start, vim.api.nvim_buf_line_count(0)), 0 })
      report()
      return
    end
  end
  vim.notify('The cursor is not in a conflict', vim.log.levels.WARN)
end

local function readonly(path, name)
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.cmd('diffthis')
  return buf
end

--- Opens a merge: `local` (ours), `base`, `remote` (theirs) and `merged` (the result, written back), as git's
--- mergetool passes them.
function M.open(localpath, base, remote, merged)
  vim.cmd('silent! only')
  vim.cmd('edit ' .. vim.fn.fnameescape(merged))
  local result = vim.api.nvim_get_current_buf()
  vim.g.sill_merge_result = result
  vim.g.sill_merge_base = base
  vim.cmd('diffthis')
  vim.cmd('leftabove vsplit')
  readonly(localpath, 'Ours: ' .. vim.fn.fnamemodify(merged, ':t'))
  vim.cmd('wincmd l')
  vim.cmd('rightbelow vsplit')
  readonly(remote, 'Theirs: ' .. vim.fn.fnamemodify(merged, ':t'))
  vim.cmd('wincmd h')
  vim.cmd('wincmd =')
  for lhs, fn in pairs({
    [']x'] = function() M.jump(1) end,
    ['[x'] = function() M.jump(-1) end,
    ['<localleader>o'] = function() M.take('ours') end,
    ['<localleader>t'] = function() M.take('theirs') end,
    ['<localleader>b'] = function() M.take('both') end,
  }) do
    vim.keymap.set('n', lhs, fn, { buffer = result })
  end
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'TextChanged', 'TextChangedI', 'BufWritePost' }, {
    buffer = result, callback = report,
  })
  local first = M.conflicts(result)[1]
  if first then
    vim.api.nvim_win_set_cursor(0, { first.start, 0 })
  end
  report()
end

--- Shows the base under the result, read-only, or hides it.
function M.toggle_base()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.b[vim.api.nvim_win_get_buf(win)].sill_merge_base then
      vim.api.nvim_win_close(win, true)
      return
    end
  end
  local base = vim.g.sill_merge_base
  if not base then
    return
  end
  vim.cmd('belowright split')
  local buf = readonly(base, 'Base: ' .. vim.fn.fnamemodify(base, ':t'))
  vim.b[buf].sill_merge_base = true
  vim.cmd('diffoff')
  vim.cmd('wincmd p')
end

--- Opens a two-way diff of `a` and `b`, as git's difftool passes them.
function M.diff(a, b)
  vim.cmd('silent! only')
  vim.cmd('edit ' .. vim.fn.fnameescape(a))
  vim.cmd('diffthis')
  vim.cmd('rightbelow vsplit ' .. vim.fn.fnameescape(b))
  vim.cmd('diffthis')
end

return M
