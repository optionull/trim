-- The debugger's editor side (M8): breakpoints as signs that move with the text, the line a paused program is at,
-- and the keys. sill's app runs the session (the debug adapter, over the Debug Adapter Protocol); nvim says what the
-- breakpoints are and what was asked, and is told where the program stopped.
local M = {}

local function notify(method, ...)
  local channel = vim.g.sill_channel
  if channel then
    vim.rpcnotify(channel, method, ...)
  end
end

local breakpoints = vim.api.nvim_create_namespace('sill.breakpoints')
local current = vim.api.nvim_create_namespace('sill.debug')

--- Every breakpoint, by file: { [path] = { line, ... } }, the lines as they are now.
function M.breakpoints()
  local all = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local marks = vim.api.nvim_buf_get_extmarks(buf, breakpoints, 0, -1, {})
      if #marks > 0 then
        local lines = {}
        for _, mark in ipairs(marks) do
          table.insert(lines, mark[2] + 1)
        end
        table.sort(lines)
        all[vim.api.nvim_buf_get_name(buf)] = lines
      end
    end
  end
  return all
end

function M.report()
  notify('sill_breakpoints', M.breakpoints())
end

--- A breakpoint on the line, or none if it had one.
function M.toggle(buf, line)
  buf = buf or vim.api.nvim_get_current_buf()
  line = line or vim.api.nvim_win_get_cursor(0)[1]
  local marks = vim.api.nvim_buf_get_extmarks(buf, breakpoints, { line - 1, 0 }, { line - 1, -1 }, {})
  if #marks > 0 then
    for _, mark in ipairs(marks) do
      vim.api.nvim_buf_del_extmark(buf, breakpoints, mark[1])
    end
  else
    vim.api.nvim_buf_set_extmark(buf, breakpoints, line - 1, 0, {
      sign_text = '●', sign_hl_group = 'SillBreakpoint', priority = 20,
    })
  end
  M.report()
end

--- The program paused at `path`:`line`: the file shown there, the line marked.
function M.at(path, line)
  M.clear()
  require('sill').open(path, line)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 then
    vim.api.nvim_buf_set_extmark(buf, current, line - 1, 0, {
      sign_text = '▶', sign_hl_group = 'SillDebugArrow', line_hl_group = 'SillDebugLine', priority = 30,
    })
  end
end

--- The program runs again (or ended): no line marked.
function M.clear()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, current, 0, -1)
    end
  end
end

--- The line marked as where the program is, if one is: { path, line }.
function M.where()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local marks = vim.api.nvim_buf_get_extmarks(buf, current, 0, -1, {})
      if #marks > 0 then
        return { vim.api.nvim_buf_get_name(buf), marks[1][2] + 1 }
      end
    end
  end
end

function M.setup()
  vim.api.nvim_set_hl(0, 'SillBreakpoint', { default = true, fg = '#ff6b6b' })
  vim.api.nvim_set_hl(0, 'SillDebugArrow', { default = true, fg = '#ffc857' })
  vim.api.nvim_set_hl(0, 'SillDebugLine', { default = true, bg = '#3a3320' })
  vim.api.nvim_create_user_command('SillDebug', function(opts)
    notify('sill_debug', opts.args ~= '' and opts.args or 'continue')
  end, {
    nargs = '?',
    complete = function() return { 'start', 'continue', 'next', 'in', 'out', 'pause', 'stop' } end,
    desc = 'Debug the project: start or continue, next, in, out, pause, stop',
  })
  vim.api.nvim_create_user_command('SillBreakpoint', function() M.toggle() end,
    { desc = 'A breakpoint on this line, or none' })
  -- Function keys, as debuggers have them: none is a core nvim key. A key the config maps stays its.
  local keys = {
    ['<F5>'] = 'SillDebug continue', ['<S-F5>'] = 'SillDebug stop', ['<F9>'] = 'SillBreakpoint',
    ['<F10>'] = 'SillDebug next', ['<F11>'] = 'SillDebug in', ['<S-F11>'] = 'SillDebug out',
  }
  for key, command in pairs(keys) do
    if vim.fn.maparg(key, 'n') == '' then
      vim.keymap.set('n', key, '<Cmd>' .. command .. '<CR>', { desc = command })
    end
  end
  -- Breakpoints move with the text: what a save leaves is told again.
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = vim.api.nvim_create_augroup('sill_debug', {}),
    callback = function(args)
      if #vim.api.nvim_buf_get_extmarks(args.buf, breakpoints, 0, -1, { limit = 1 }) > 0 then
        M.report()
      end
    end,
  })
end

return M
