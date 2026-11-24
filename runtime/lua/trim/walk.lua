-- Walkthroughs in the editor. A `*.walk.md` is an ordinary buffer: a tab like any file, monospaced, in the colour
-- scheme, edited and moved around with nvim's own keys. This module dresses it (steps, the code each anchor points at as
-- highlighted cards below its line, checkboxes, a header) from a model the app computes (anchors found, freshness), and
-- keeps a companion window on the code of the step the cursor is in.
local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('trim_walk')
local marks = api.nvim_create_namespace('trim_walk_code')
M.state = {}
M.models = {}
M.fold = {}
local walkcard = require('trim.walkcard')
M.shown = nil

for name, link in pairs({
  TrimWalkStep = 'Title', TrimWalkBorder = 'Comment', TrimWalkOk = 'DiagnosticOk', TrimWalkWarn = 'DiagnosticWarn',
  TrimWalkErr = 'DiagnosticError', TrimWalkHint = 'DiagnosticHint', TrimWalkRange = 'Visual', TrimWalkAdd = 'DiffAdd',
  TrimWalkDel = 'DiffDelete', TrimWalkMeta = 'Comment', TrimWalkAsk = 'DiagnosticInfo',
}) do
  api.nvim_set_hl(0, name, { link = link, default = true })
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

--- The cursor's line in the window that shows `buf` (0 when none does).
function M.cursor_line(buf)
  local win = vim.fn.bufwinid(buf)
  if win < 0 then return 0 end
  return api.nvim_win_get_cursor(win)[1]
end


--- How wide the cards are: the window's text area, to a readable limit.
function M.card_width(buf)
  local win = vim.fn.bufwinid(buf)
  if win < 0 then return 80 end
  local info = vim.fn.getwininfo(win)[1]
  return math.max(30, math.min(info.width - info.textoff - 2, 110))
end

--- Draws the buffer's last model again (the cards' width or open state changed).
function M.refresh(buf)
  local model = M.models[buf]
  if model then M.render(model.path, model.json) end
end

--- Opens or closes the card the cursor is at (`mode` 'toggle', 'open', 'close'), or all of them ('open_all', 'close_all').
function M.fold_cards(mode)
  local buf = api.nvim_get_current_buf()
  local state = M.state[buf]
  if not state then return end
  M.fold[buf] = M.fold[buf] or {}
  if mode == 'open_all' or mode == 'close_all' then
    for _, card in ipairs(state.cards) do M.fold[buf][card.key] = mode == 'open_all' end
  else
    local line, found, start = api.nvim_win_get_cursor(0)[1], nil, 0
    for _, s in ipairs(state.steps) do if s <= line then start = s end end
    for _, card in ipairs(state.cards) do if card.line <= line and card.line > start then found = card end end
    if not found then return end
    M.fold[buf][found.key] = mode == 'open' or (mode == 'toggle' and not found.open)
  end
  M.refresh(buf)
end

--- Draws the model the app computed for the buffer of `path`: the header, a card of code under each `@code`, the change under
--- each `@diff`, the steps, checkboxes and what asks or runs.
function M.render(path, json)
  local buf = vim.fn.bufnr(path)
  if buf < 0 or not api.nvim_buf_is_loaded(buf) then return end
  local ok, model = pcall(vim.json.decode, json)
  if not ok then return end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local steps, jumps, cards, seen, at = {}, {}, {}, {}, {}
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
  require('trim.mdstyle').apply(buf, lines, front_end)
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
    if item and (item.kind == 'code' or item.kind == 'diff') then
      local key = (item.heading or '') .. '#' .. (seen[item.heading or ''] or 0)
      seen[item.heading or ''] = (seen[item.heading or ''] or 0) + 1
      local width = M.card_width(buf)
      M.last_width = M.last_width or {}
      M.last_width[buf] = width
      local card, total = walkcard.lines(item, width, true)
      local open = (M.fold[buf] or {})[key]
      if open == nil then open = total <= walkcard.OPEN_LIMIT end
      if not open then card = walkcard.lines(item, width, false) end
      set(number, 0, { virt_lines = card })
      -- The directive is the card's source: its text is hidden (the line stays, as the card's top margin) and shows, to
      -- edit, while the cursor is on the line.
      if #text > 0 then set(number, 0, { end_col = #text, conceal = '', priority = 300 }) end
      cards[#cards + 1] = { line = number, key = key, open = open, total = total }
      if item.kind == 'code' and item.path then
        jumps[#jumps + 1] = { line = number, path = item.path, from = item.from, to = item.to }
      end
    end
  end
  M.state[buf] = { steps = steps, jumps = jumps, cards = cards, stale = model.stale or 0, title = model.title }
  M.models[buf] = { path = path, json = json }
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
  map('za', function() M.fold_cards('toggle') end, 'Walkthrough: open or close the card')
  map('zo', function() M.fold_cards('open') end, 'Walkthrough: open the card')
  map('zc', function() M.fold_cards('close') end, 'Walkthrough: close the card')
  map('zR', function() M.fold_cards('open_all') end, 'Walkthrough: open all cards')
  map('zM', function() M.fold_cards('close_all') end, 'Walkthrough: close all cards')
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
  -- The cards are as wide as the window: drawn again when it changes (or a split opens beside it).
  api.nvim_create_autocmd({ 'WinResized', 'WinNew', 'WinClosed' }, {
    group = g,
    callback = function()
      vim.schedule(function()
        for buf in pairs(M.models) do
          if api.nvim_buf_is_loaded(buf) and M.last_width and M.last_width[buf] ~= M.card_width(buf) then M.refresh(buf) end
        end
      end)
    end,
  })
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
