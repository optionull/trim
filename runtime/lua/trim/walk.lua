-- Walkthroughs in the editor. A `*.walk.md` is an ordinary buffer: a tab like any file, monospaced, in the colour
-- scheme, edited and moved around with nvim's own keys. This module dresses it (steps, the code each anchor points at as
-- highlighted cards below its line, checkboxes, a header) from a model the app computes (anchors found, freshness), and
-- keeps a companion window on the code of the step the cursor is in.
local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('trim_walk')
local marks = api.nvim_create_namespace('trim_walk_code')
M.state = {}
M.shown = nil

for name, link in pairs({
  TrimWalkStep = 'Title', TrimWalkBorder = 'Comment', TrimWalkOk = 'DiagnosticOk', TrimWalkWarn = 'DiagnosticWarn',
  TrimWalkErr = 'DiagnosticError', TrimWalkHint = 'DiagnosticHint', TrimWalkRange = 'Visual', TrimWalkAdd = 'DiffAdd',
  TrimWalkDel = 'DiffDelete', TrimWalkMeta = 'Comment', TrimWalkAsk = 'DiagnosticInfo',
}) do
  api.nvim_set_hl(0, name, { link = link, default = true })
end
local groups = {}
--- A highlight group for a colour and weight, made the first time it is asked for.
local function group(c, bold, italic)
  local name = ('TrimWalkC%06x%s%s'):format(c or 0, bold and 'b' or '', italic and 'i' or '')
  if not groups[name] then
    groups[name] = true
    api.nvim_set_hl(0, name, { fg = c, bold = bold, italic = italic })
  end
  return name
end

--- `text` as lines of virtual-text chunks, coloured by tree-sitter in `path`'s language, each after `prefix`.
local function code_lines(text, path, prefix)
  local lang = vim.filetype.match({ filename = path }) or ''
  local ok, spans = pcall(require('trim.docs').highlight, text, lang)
  spans = ok and spans or {}
  local out, offset = {}, 0
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    local colours = {}
    for _, s in ipairs(spans) do
      for b = math.max(s.b, offset), math.min(s.e, offset + #line) - 1 do
        colours[b - offset + 1] = { s.c, s.bold, s.italic }
      end
    end
    local chunks, from = { prefix }, 1
    while from <= #line do
      local current, to = colours[from], from
      while to < #line and (colours[to + 1] == nil) == (current == nil)
        and (current == nil or (colours[to + 1][1] == current[1] and colours[to + 1][2] == current[2] and colours[to + 1][3] == current[3])) do
        to = to + 1
      end
      local piece = line:sub(from, to)
      chunks[#chunks + 1] = current and { piece, group(current[1], current[2], current[3]) } or { piece }
      from = to + 1
    end
    out[#out + 1] = chunks
    offset = offset + #line + 1
  end
  return out
end

--- The line the front matter ends on (0 when there is none).
function M.front_range(lines)
  if lines[1] ~= '---' then return 0 end
  for number = 2, #lines do
    if lines[number] == '---' then return number end
  end
  return 0
end

local front_ns = api.nvim_create_namespace('trim_walk_front')
--- The front matter is hidden, and all of it shows while the cursor is in it.
function M.front(buf)
  if not api.nvim_buf_is_loaded(buf) then return end
  api.nvim_buf_clear_namespace(buf, front_ns, 0, -1)
  local last = M.front_range(api.nvim_buf_get_lines(buf, 0, -1, false))
  if last == 0 then return end
  local current = api.nvim_get_current_buf() == buf and api.nvim_win_get_cursor(0)[1] or 0
  if current >= 1 and current <= last then return end
  for number = 1, last do
    pcall(api.nvim_buf_set_extmark, buf, front_ns, number - 1, 0, { conceal_lines = '' })
  end
end

local levels = { ok = 'TrimWalkOk', warn = 'TrimWalkWarn', err = 'TrimWalkErr' }

--- Draws the model the app computed for the buffer of `path`: the header, a card of code under each `@code`, the change under
--- each `@diff`, the steps, checkboxes and what asks or runs.
function M.render(path, json)
  local buf = vim.fn.bufnr(path)
  if buf < 0 or not api.nvim_buf_is_loaded(buf) then return end
  local ok, model = pcall(vim.json.decode, json)
  if not ok then return end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local steps, jumps, at = {}, {}, {}
  for _, item in ipairs(model.items or {}) do at[item.line] = item end
  local function set(line, col, opts) pcall(api.nvim_buf_set_extmark, buf, ns, line - 1, col, opts) end
  -- The front matter collapses to nothing (open while the cursor is in it) and leaves one quiet line above the title.
  local front_end, title_line = M.front_range(lines), nil
  for number = front_end + 1, #lines do
    if lines[number]:match('^# ') then title_line = number break end
    if lines[number]:match('^## ') then break end
  end
  local meta = { { model.meta or '', 'TrimWalkMeta' } }
  if (model.stale or 0) > 0 then meta[#meta + 1] = { ('  ·  %d need a look'):format(model.stale), 'TrimWalkWarn' } end
  set(title_line or (front_end + 1), 0, { virt_lines = { meta }, virt_lines_above = true })
  -- Headings in bigger type and inline code in a box, as in any markdown buffer.
  require('trim.mdstyle').apply(buf, ns, lines, front_end)
  M.front(buf)
  for number, text in ipairs(lines) do
    local item = at[number]
    if text:match('^## ') and number > front_end then
      steps[#steps + 1] = number
    elseif text:match('^@ask') then
      set(number, 0, { end_col = #text, hl_group = 'TrimWalkAsk', priority = 10 })
    elseif text:match('^@run') then
      set(number, 0, { end_col = #text, hl_group = 'TrimWalkHint', virt_text = { { '   ↵ run', 'TrimWalkMeta' } }, priority = 10 })
    elseif text:match('^>') then
      set(number, 0, { end_col = #text, hl_group = 'TrimWalkMeta', priority = 5 })
    end
    local prefix, box = text:match('^(%s*[-*]%s)%[([ xX])%]')
    if prefix then
      set(number, #prefix, {
        end_col = #prefix + 3, virt_text = { { box == ' ' and '☐ ' or '☑ ', box == ' ' and 'TrimWalkMeta' or 'TrimWalkOk' } },
        virt_text_pos = 'overlay', conceal = nil,
      })
    end
    if item and item.kind == 'code' then
      local where = item.path and ('%s:%d-%d'):format(item.relative or item.path, item.from, item.to) or ''
      local note = item.badge and ('  ' .. item.badge) or ''
      set(number, 0, { virt_text = { { '   ' .. where, 'TrimWalkMeta' }, { note, levels[item.level] or 'TrimWalkMeta' } } })
      local card = { { { '  ╭─ ' .. (item.heading or ''), 'TrimWalkBorder' } } }
      if item.code then
        for _, chunks in ipairs(code_lines(item.code, item.path or '', { '  │ ', 'TrimWalkBorder' })) do card[#card + 1] = chunks end
      elseif item.message then
        card[#card + 1] = { { '  │ ', 'TrimWalkBorder' }, { item.message, 'TrimWalkErr' } }
      end
      card[#card + 1] = { { '  ╰─', 'TrimWalkBorder' } }
      set(number, 0, { virt_lines = card })
      if item.path then jumps[#jumps + 1] = { line = number, path = item.path, from = item.from, to = item.to } end
    elseif item and item.kind == 'diff' then
      local card = { { { '  ╭─ diff ' .. (item.heading or ''), 'TrimWalkBorder' } } }
      for _, row in ipairs(vim.split(item.text or '', '\n', { plain = true })) do
        if not row:match('^diff %-%-git') and not row:match('^index ') and row ~= '' then
          local hl = (row:match('^%+') and not row:match('^%+%+%+')) and 'TrimWalkAdd'
            or (row:match('^%-') and not row:match('^%-%-%-')) and 'TrimWalkDel' or 'TrimWalkMeta'
          card[#card + 1] = { { '  │ ', 'TrimWalkBorder' }, { row, hl } }
        end
      end
      card[#card + 1] = { { '  ╰─', 'TrimWalkBorder' } }
      set(number, 0, { virt_lines = card })
    end
  end
  M.state[buf] = { steps = steps, jumps = jumps, stale = model.stale or 0, title = model.title }
end

--- The code a cursor line belongs to: the last anchor above it in its step, else the step's first.
local function jump_for(state, line)
  local start, stop = 0, math.huge
  for _, s in ipairs(state.steps) do
    if s <= line then start = s elseif s < stop then stop = s end
  end
  local first, best
  for _, j in ipairs(state.jumps) do
    if j.line > start and j.line < stop then
      first = first or j
      if j.line <= line then best = j end
    end
  end
  return best or first
end

--- Shows lines of a file in the companion window beside the walkthrough (made when there is none), marked and in view.
local function show(jump, enter)
  local here = api.nvim_get_current_win()
  if not (M.win and api.nvim_win_is_valid(M.win)) or M.win == here then
    vim.cmd('rightbelow vsplit')
    M.win = api.nvim_get_current_win()
    api.nvim_set_current_win(here)
  end
  if M.marked and api.nvim_buf_is_valid(M.marked) then api.nvim_buf_clear_namespace(M.marked, marks, 0, -1) end
  api.nvim_win_call(M.win, function()
    local full = vim.fn.fnamemodify(jump.path, ':p')
    if vim.fn.fnamemodify(api.nvim_buf_get_name(0), ':p') ~= full then pcall(vim.cmd.edit, vim.fn.fnameescape(full)) end
    local buf = api.nvim_get_current_buf()
    local last = api.nvim_buf_line_count(buf)
    local from, to = math.max(1, math.min(jump.from, last)), math.max(1, math.min(jump.to, last))
    for line = from, to do
      api.nvim_buf_set_extmark(buf, marks, line - 1, 0, { line_hl_group = 'TrimWalkRange', priority = 5 })
    end
    api.nvim_win_set_cursor(0, { from, 0 })
    vim.cmd('normal! zz')
    M.marked = buf
  end)
  M.shown = jump
  if enter then api.nvim_set_current_win(M.win) end
end

--- Moves the companion to the code of the step the cursor is in, when one is open.
function M.follow()
  local state = M.state[api.nvim_get_current_buf()]
  if not state or not (M.win and api.nvim_win_is_valid(M.win)) then return end
  local jump = jump_for(state, api.nvim_win_get_cursor(0)[1])
  if jump and (not M.shown or M.shown.path ~= jump.path or M.shown.from ~= jump.from or M.shown.to ~= jump.to) then show(jump, false) end
end

local function step(direction)
  local state = M.state[api.nvim_get_current_buf()]
  local line = api.nvim_win_get_cursor(0)[1]
  local target
  if state then
    for _, s in ipairs(state.steps) do
      if direction > 0 and s > line then target = s break end
      if direction < 0 and s < line then target = s end
    end
  end
  if not target then return end
  api.nvim_win_set_cursor(0, { target, 0 })
  local jump = jump_for(state, target)
  if jump then show(jump, false) end
end

--- Enter: on a `@code` the code in the companion, with the keyboard there; on a `@run` its command in the Run pane, only
--- on this key press; elsewhere what Enter does.
local function enter(tell)
  local buf = api.nvim_get_current_buf()
  local state, line = M.state[buf], api.nvim_win_get_cursor(0)[1]
  local text = api.nvim_get_current_line()
  local name, command = text:match('^@run%s+(.-):%s*(.+)$')
  if command then return tell('trim_walk_run', name .. '\t' .. command) end
  if text:match('^@code') or text:match('^## ') then
    local jump = state and jump_for(state, line)
    if jump then return show(jump, true) end
  end
  api.nvim_feedkeys(api.nvim_replace_termcodes('<CR>', true, false, true), 'n', false)
end

--- Ticks or unticks the checklist item on the line.
local function toggle()
  local buf, line = api.nvim_get_current_buf(), api.nvim_win_get_cursor(0)[1]
  local text = api.nvim_get_current_line()
  local prefix, box = text:match('^(%s*[-*]%s)%[([ xX])%]')
  if not prefix then return api.nvim_feedkeys('x', 'n', false) end
  api.nvim_buf_set_text(buf, line - 1, #prefix + 1, line - 1, #prefix + 2, { box == ' ' and 'x' or ' ' })
end

local timers = {}
local function request(tell, buf)
  if not api.nvim_buf_is_loaded(buf) then return end
  local timer = timers[buf] or vim.uv.new_timer()
  timers[buf] = timer
  timer:stop()
  timer:start(150, 0, vim.schedule_wrap(function()
    if not api.nvim_buf_is_loaded(buf) then return end
    tell('trim_walk_model', vim.json.encode({
      path = api.nvim_buf_get_name(buf), text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n'),
    }))
  end))
end

--- Keys and window options of a walkthrough buffer, bound where it is shown.
local function bind(tell, buf)
  if vim.b[buf].trim_walk_bound then return end
  vim.b[buf].trim_walk_bound = true
  -- Opened past the front matter, on the title.
  if api.nvim_get_current_buf() == buf and api.nvim_win_get_cursor(0)[1] == 1 then
    local last = M.front_range(api.nvim_buf_get_lines(buf, 0, -1, false))
    if last > 0 then pcall(api.nvim_win_set_cursor, 0, { math.min(last + 1, api.nvim_buf_line_count(buf)), 0 }) end
  end
  local function map(lhs, fn, desc) vim.keymap.set('n', lhs, fn, { buffer = buf, silent = true, desc = desc }) end
  map(']]', function() step(1) end, 'Walkthrough: next step')
  map('[[', function() step(-1) end, 'Walkthrough: previous step')
  map('<CR>', function() enter(tell) end, 'Walkthrough: the code, or run')
  map('x', toggle, 'Walkthrough: tick the item')
end

--- Starts watching for walkthroughs: dressing them as they open and change, and the companion following the cursor.
function M.setup(tell)
  local g = api.nvim_create_augroup('TrimWalk', { clear = true })
  api.nvim_create_autocmd({ 'BufReadPost', 'BufEnter', 'BufWritePost', 'FileChangedShellPost', 'TextChanged', 'InsertLeave' }, {
    group = g, pattern = '*.walk.md',
    callback = function(event)
      bind(tell, event.buf)
      if event.event == 'BufEnter' then
        vim.wo.wrap, vim.wo.linebreak, vim.wo.breakindent = true, true, true
        vim.wo.conceallevel = 2
      end
      request(tell, event.buf)
    end,
  })
  -- The code a walkthrough points at changed: its marks (changed since written) are drawn again.
  api.nvim_create_autocmd('BufWritePost', {
    group = g,
    callback = function(event)
      if event.file:match('%.walk%.md$') then return end
      for buf in pairs(M.state) do request(tell, buf) end
    end,
  })
  api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = g, pattern = '*.walk.md', callback = function(event) M.front(event.buf) end,
  })
  api.nvim_create_autocmd('CursorMoved', { group = g, pattern = '*.walk.md', callback = M.follow })
  api.nvim_create_autocmd('BufWipeout', {
    group = g, pattern = '*.walk.md', callback = function(event) M.state[event.buf] = nil end,
  })
  api.nvim_create_user_command('TrimWalk', function(opts) tell('trim_walk', opts.args) end, {
    nargs = '?', complete = 'file', desc = 'Walkthroughs: choose one, or open a file',
  })
  vim.keymap.set('n', '<Plug>(trim-walk)', function() tell('trim_walk', '') end, { desc = 'Walkthroughs' })
  -- Walkthroughs already open (restored before this ran) are dressed too.
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and api.nvim_buf_get_name(buf):match('%.walk%.md$') then
      bind(tell, buf)
      request(tell, buf)
    end
  end
end

--- `text` as the highlighted blocks the hover documentation draws (JSON), by the file type of `path`.
function M.code(path, text)
  local filetype = vim.filetype.match({ filename = path }) or ''
  return require('trim.docs').encode('```' .. filetype .. '\n' .. text .. '\n```', filetype)
end

return M
