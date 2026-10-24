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
-- What a breakpoint has beyond its line, by buffer and extmark: { condition, hit, log }.
local details = {}
-- Function breakpoints, by name (a method, `Type.Method` or `Namespace.Type.Method`).
local functions = {}

--- Every breakpoint, by file: { [path] = { { line, condition?, hit?, log? }, ... } }, the lines as they are now.
function M.breakpoints()
  local all = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local marks = vim.api.nvim_buf_get_extmarks(buf, breakpoints, 0, -1, {})
      if #marks > 0 then
        local list = {}
        for _, mark in ipairs(marks) do
          local extra = (details[buf] or {})[mark[1]] or {}
          table.insert(list, { line = mark[2] + 1, condition = extra.condition, hit = extra.hit, log = extra.log })
        end
        table.sort(list, function(a, b) return a.line < b.line end)
        all[vim.api.nvim_buf_get_name(buf)] = list
      end
    end
  end
  return all
end

--- The function breakpoints' names, sorted.
function M.functions()
  local names = vim.tbl_keys(functions)
  table.sort(names)
  return names
end

function M.report()
  notify('sill_breakpoints', M.breakpoints(), M.functions())
end

local function sign(extra)
  if extra.log then return '◇', 'SillLogpoint' end
  if extra.condition or extra.hit then return '◆', 'SillBreakpoint' end
  return '●', 'SillBreakpoint'
end

--- A breakpoint on the line, or none if it had one. With `extra` ({ condition, hit, log }), the line's breakpoint
--- becomes that one, whether it had one or not.
function M.toggle(buf, line, extra)
  buf = buf or vim.api.nvim_get_current_buf()
  line = line or vim.api.nvim_win_get_cursor(0)[1]
  local marks = vim.api.nvim_buf_get_extmarks(buf, breakpoints, { line - 1, 0 }, { line - 1, -1 }, {})
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_del_extmark(buf, breakpoints, mark[1])
    if details[buf] then details[buf][mark[1]] = nil end
  end
  if #marks == 0 or extra then
    extra = extra or {}
    local text, group = sign(extra)
    local id = vim.api.nvim_buf_set_extmark(buf, breakpoints, line - 1, 0, {
      sign_text = text, sign_hl_group = group, priority = 20,
    })
    details[buf] = details[buf] or {}
    details[buf][id] = extra
  end
  M.report()
end

--- A function breakpoint on `name`, or none if it had one.
function M.toggle_function(name)
  functions[name] = not functions[name] or nil
  vim.notify((functions[name] and 'Breakpoint on ' or 'No breakpoint on ') .. name, vim.log.levels.INFO)
  M.report()
end

--- The expression to evaluate: the selection in Visual mode, else the expression under the cursor.
function M.expression(opts)
  if opts and opts.range and opts.range > 0 then
    local from, to = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    local lines = vim.api.nvim_buf_get_text(0, from[2] - 1, from[3] - 1, to[2] - 1, to[3], {})
    return table.concat(lines, ' ')
  end
  return vim.fn.expand('<cexpr>')
end

--- Asks which .NET process to attach to: `processes` is { { pid, name }, ... }.
function M.pick_process(processes)
  vim.ui.select(processes, {
    prompt = 'Attach to',
    format_item = function(p) return p[2] .. '  (' .. p[1] .. ')' end,
  }, function(choice)
    if choice then notify('sill_debug', 'attach ' .. choice[1]) end
  end)
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

--- Shift-F9: a condition for the line's breakpoint, asked for.
function M.ask_condition()
  vim.ui.input({ prompt = 'Break when: ' }, function(condition)
    if condition and condition ~= '' then M.toggle(nil, nil, { condition = condition }) end
  end)
end

function M.setup()
  vim.api.nvim_set_hl(0, 'SillBreakpoint', { default = true, fg = '#ff6b6b' })
  vim.api.nvim_set_hl(0, 'SillLogpoint', { default = true, fg = '#ffc857' })
  vim.api.nvim_set_hl(0, 'SillDebugArrow', { default = true, fg = '#ffc857' })
  vim.api.nvim_set_hl(0, 'SillDebugLine', { default = true, bg = '#3a3320' })
  vim.api.nvim_create_user_command('SillDebug', function(opts)
    notify('sill_debug', opts.args ~= '' and opts.args or 'continue')
  end, {
    nargs = '*',
    complete = function(_, line)
      if line:match('exceptions%s+%S*$') then return { 'all', 'unhandled', 'none' } end
      return { 'start', 'continue', 'next', 'in', 'out', 'pause', 'stop', 'attach', 'exceptions' }
    end,
    desc = 'Debug: start or continue, next, in, out, pause, stop, attach (a running .NET process), ' ..
      'exceptions all|unhandled|none',
  })
  -- :SillBreakpoint toggles; `if <condition>`, `hits <count>` (=5, >=5, %5), `log <message with {expressions}>` set
  -- that kind on the line; `fn <method>` toggles a function breakpoint.
  vim.api.nvim_create_user_command('SillBreakpoint', function(opts)
    local kind, rest = opts.args:match('^(%S+)%s+(.+)$')
    if kind == 'if' then
      M.toggle(nil, nil, { condition = rest })
    elseif kind == 'hits' then
      M.toggle(nil, nil, { hit = rest })
    elseif kind == 'log' then
      M.toggle(nil, nil, { log = rest })
    elseif kind == 'fn' then
      M.toggle_function(rest)
    elseif opts.args == '' then
      M.toggle()
    else
      vim.notify('SillBreakpoint: if <condition>, hits <count>, log <message>, fn <method>, or nothing',
        vim.log.levels.WARN)
    end
  end, {
    nargs = '*',
    complete = function() return { 'if', 'hits', 'log', 'fn' } end,
    desc = 'A breakpoint on this line or none; if <condition>, hits <count>, log <message>, fn <method>',
  })
  vim.api.nvim_create_user_command('SillEval', function(opts)
    local expression = opts.args ~= '' and opts.args or M.expression(opts)
    if expression ~= '' then notify('sill_debug', 'eval ' .. expression) end
  end, { nargs = '*', range = true, desc = "Evaluate an expression (the cursor's or the selection) where it paused" })
  vim.api.nvim_create_user_command('SillWatch', function(opts)
    local expression = opts.args ~= '' and opts.args or M.expression(opts)
    if expression ~= '' then notify('sill_debug', (opts.bang and 'unwatch ' or 'watch ') .. expression) end
  end, { nargs = '*', range = true, bang = true, desc = 'Watch an expression at every pause (! stops watching it)' })
  -- Function keys, as debuggers have them: none is a core nvim key. A key the config maps stays its.
  local keys = {
    ['<F5>'] = 'SillDebug continue', ['<S-F5>'] = 'SillDebug stop', ['<F9>'] = 'SillBreakpoint',
    ['<S-F9>'] = 'lua require("sill.debug").ask_condition()',
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
