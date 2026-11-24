-- How markdown looks while it is edited (source stays source): headings in bigger type, inline code in a bordered box,
-- tables as grids, callouts and quotes as tinted blocks, checklists as boxes with a count, fenced code on a tint. A block
-- you are in (the cursor on one of its lines) shows its source, so editing is never in the way. Used for walkthroughs and
-- for any markdown buffer.
--
-- The app's grid draws two things from highlight attributes (see Highlight.scale / .boxed there): `altfont` is a row at
-- 2x, `altfont` with a `blend` of 1-99 is 1 + blend/100 times, and `altfont` with a `blend` of 100 is a box round the
-- cells. A scaled line has a blank virtual line under it that holds its lower half.
local M = {}
local api = vim.api
local blocks = require('trim.mdblocks')

M.ns = api.nvim_create_namespace('trim_md')
--- Buffer -> its blocks ({ first, last } lines) and the one the cursor was in when it was drawn.
M.blocks = {}
M.inside = {}

--- A colour a fraction of the way from `a` to `b` (both 0xRRGGBB).
local function mix(a, b, t)
  local function channel(shift)
    local x, y = bit.band(bit.rshift(a, shift), 255), bit.band(bit.rshift(b, shift), 255)
    return math.floor(x + (y - x) * t + 0.5)
  end
  return channel(16) * 65536 + channel(8) * 256 + channel(0)
end

--- The groups, from the colour scheme's own colours; made again when the scheme changes.
function M.define()
  local normal = api.nvim_get_hl(0, { name = 'Normal', link = false })
  local title = api.nvim_get_hl(0, { name = 'Title', link = false })
  local heading = api.nvim_get_hl(0, { name = '@markup.heading.2.markdown', link = false })
  local ok = api.nvim_get_hl(0, { name = 'DiagnosticOk', link = false })
  local bg, fg = normal.bg or 0x101010, normal.fg or 0xe0e0e0
  api.nvim_set_hl(0, 'TrimMdH1', { fg = title.fg or fg, bold = true, underline = true, altfont = true })
  api.nvim_set_hl(0, 'TrimMdH2', { fg = heading.fg or title.fg or fg, bold = true, altfont = true, blend = 50 })
  -- Inline code: a faint tint inside a rounded border, so it is a thing and not a highlight.
  api.nvim_set_hl(0, 'TrimMdCode', { fg = fg, bg = mix(bg, fg, 0.09), sp = mix(bg, fg, 0.5), altfont = true, blend = 100 })
  api.nvim_set_hl(0, 'TrimMdFence', { bg = mix(bg, fg, 0.055) })
  api.nvim_set_hl(0, 'TrimMdFenceLabel', { fg = mix(bg, fg, 0.5), bg = mix(bg, fg, 0.055), italic = true })
  api.nvim_set_hl(0, 'TrimMdBoxOpen', { fg = mix(bg, fg, 0.55) })
  api.nvim_set_hl(0, 'TrimMdBoxDone', { fg = ok.fg or 0x7ee787 })
  api.nvim_set_hl(0, 'TrimMdDoneText', { fg = mix(bg, fg, 0.55), strikethrough = true })
  api.nvim_set_hl(0, 'TrimMdCount', { fg = mix(bg, fg, 0.5), italic = true })
end
M.define()
api.nvim_create_autocmd('ColorScheme', {
  group = api.nvim_create_augroup('TrimMdStyle', { clear = true }),
  callback = function() M.define() blocks.define() end,
})

--- How wide a block is drawn in the window that shows `buf`: its text area, to a readable limit.
function M.width(buf)
  local win = vim.fn.bufwinid(buf)
  if win < 0 then return 80 end
  local info = vim.fn.getwininfo(win)[1]
  return math.max(30, math.min(info.width - info.textoff - 2, 100))
end

local function cursor_line(buf)
  local win = vim.fn.bufwinid(buf)
  if win < 0 then return 0 end
  return api.nvim_win_get_cursor(win)[1]
end

--- Inline code of a line in a box, its backticks as spaces inside it (drawn in the box's own highlight, not Conceal's).
function M.inline_code(set, number, text)
  local from = 1
  while true do
    local first, last = text:find('`[^`\n]+`', from)
    if not first then break end
    set(number, first - 1, { end_col = last, hl_group = 'TrimMdCode', priority = 200 })
    set(number, first - 1, { end_col = first, conceal = ' ', hl_group = 'TrimMdCode', priority = 210 })
    set(number, last - 1, { end_col = last, conceal = ' ', hl_group = 'TrimMdCode', priority = 210 })
    from = last + 1
  end
end

--- A block drawn: its source lines hidden and the drawn lines under the line before it.
function M.show(set, first, last, front_end, drawn)
  for line = first, last do set(line, 0, { conceal_lines = '' }) end
  if first - 1 > (front_end or 0) then
    set(first - 1, 0, { virt_lines = drawn })
  else
    set(first, 0, { virt_lines = drawn, virt_lines_above = true })
  end
end

--- Decorates `lines` (1-based, of buffer `buf`): headings, inline code, checklists, tables, callouts and quotes, fenced
--- blocks; outside the front matter (lines 1 to `front_end`, when there is any).
function M.apply(buf, lines, front_end)
  api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  M.blocks[buf] = {}
  local width, cursor = M.width(buf), cursor_line(buf)
  local function set(line, col, opts) pcall(api.nvim_buf_set_extmark, buf, M.ns, line - 1, col, opts) end
  local fence
  local list = nil -- the checklist being read: { first, done, total }
  local function end_list()
    if not list then return end
    local all = list.done == list.total
    local text = all and ('  all %d done'):format(list.total) or ('  %d of %d'):format(list.done, list.total)
    set(list.first, 0, { virt_text = { { text, all and 'TrimMdBoxDone' or 'TrimMdCount' } } })
    list = nil
  end
  local number = (front_end or 0) + 1
  while number <= #lines do
    local text = lines[number]
    local marker = text:match('^%s*(```)') or text:match('^%s*(~~~)')
    if marker then
      end_list()
      local label
      if not fence then
        fence = marker
        local language = text:match('^%s*```(%S+)') or text:match('^%s*~~~(%S+)') or ''
        if language ~= '' then label = { { '  ' .. language, 'TrimMdFenceLabel' } } end
      else
        fence = nil
      end
      set(number, 0, { line_hl_group = 'TrimMdFence', priority = 5, virt_text = label })
      number = number + 1
    elseif fence then
      set(number, 0, { line_hl_group = 'TrimMdFence', priority = 5 })
      number = number + 1
    else
      local hashes, rest = text:match('^(#+) (.*)$')
      local group = hashes and ({ [1] = 'TrimMdH1', [2] = 'TrimMdH2' })[#hashes]
      local box_prefix, box = text:match('^(%s*[-*+]%s)%[([ xX])%]')
      local advanced = false
      if text:match('^%s*|') then
        -- A table: this line and the ones after it that begin with a bar.
        end_list()
        local last = number
        while last < #lines and lines[last + 1]:match('^%s*|') do last = last + 1 end
        local block = { unpack(lines, number, last) }
        if blocks.is_table(block) then
          M.blocks[buf][#M.blocks[buf] + 1] = { first = number, last = last }
          if cursor < number or cursor > last then M.show(set, number, last, front_end, blocks.table_lines(block, width)) end
          number = last + 1
          advanced = true
        end
      elseif text:match('^%s*>') then
        end_list()
        local last = number
        while last < #lines and lines[last + 1]:match('^%s*>') do last = last + 1 end
        local block = { unpack(lines, number, last) }
        M.blocks[buf][#M.blocks[buf] + 1] = { first = number, last = last }
        if cursor < number or cursor > last then M.show(set, number, last, front_end, (blocks.quote_lines(block, width))) end
        number = last + 1
        advanced = true
      elseif group and rest ~= '' then
        end_list()
        -- The marks are hidden (the cursor on the line shows them), the text drawn big, and a blank line under it.
        set(number, 0, { end_col = #hashes + 1, conceal = '' })
        set(number, #hashes + 1, { end_col = #text, hl_group = group, priority = 200 })
        set(number, 0, { virt_lines = { { { ' ' } } } })
      elseif box then
        local done = box ~= ' '
        if not list then list = { first = number, done = 0, total = 0 } end
        list.total = list.total + 1
        if done then list.done = list.done + 1 end
        set(number, #box_prefix, {
          end_col = #box_prefix + 3, conceal = done and '☑' or '☐', hl_group = done and 'TrimMdBoxDone' or 'TrimMdBoxOpen',
          priority = 210,
        })
        if done then set(number, #box_prefix + 3, { end_col = #text, hl_group = 'TrimMdDoneText', priority = 150 }) end
        M.inline_code(set, number, text)
      else
        if not text:match('^%s*[-*+]%s') then end_list() end
        M.inline_code(set, number, text)
      end
      if not advanced then number = number + 1 end
    end
  end
  end_list()
end

local function front_range(lines)
  if lines[1] ~= '---' then return 0 end
  for number = 2, #lines do
    if lines[number] == '---' then return number end
  end
  return 0
end

--- The index of the block that has `line`, or nil.
function M.block_at(buf, line)
  for index, block in ipairs(M.blocks[buf] or {}) do
    if line >= block.first and line <= block.last then return index end
  end
end

--- Draws `buf` again from its text.
function M.restyle(buf)
  if not api.nvim_buf_is_loaded(buf) then return end
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  M.apply(buf, lines, front_range(lines))
  M.inside[buf] = M.block_at(buf, cursor_line(buf))
end

local timers = {}
local function later(buf, ms)
  local timer = timers[buf] or vim.uv.new_timer()
  timers[buf] = timer
  timer:stop()
  timer:start(ms, 0, vim.schedule_wrap(function() M.restyle(buf) end))
end

local function is_walk(buf) return api.nvim_buf_get_name(buf):match('%.walk%.md$') ~= nil end

--- Any markdown buffer gets this, as it is edited; a walkthrough's text is dressed by trim.walk, which calls `apply` with
--- what it knows, and this keeps blocks in step with the cursor in both.
function M.setup()
  local group = api.nvim_create_augroup('TrimMdBuffers', { clear = true })
  local function markdown(buf) return vim.bo[buf].filetype == 'markdown' end
  api.nvim_create_autocmd({ 'FileType', 'BufWinEnter' }, {
    group = group, pattern = { 'markdown', '*.md' },
    callback = function(event)
      if not markdown(event.buf) then return end
      vim.wo.conceallevel = 2
      if not is_walk(event.buf) then M.restyle(event.buf) end
    end,
  })
  api.nvim_create_autocmd({ 'TextChanged', 'InsertLeave', 'BufEnter' }, {
    group = group,
    callback = function(event)
      if markdown(event.buf) and not is_walk(event.buf) then later(event.buf, 120) end
    end,
  })
  -- Moving into or out of a table or callout shows its source or draws it.
  api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = group,
    callback = function(event)
      if not markdown(event.buf) or not M.blocks[event.buf] then return end
      if M.block_at(event.buf, cursor_line(event.buf)) ~= M.inside[event.buf] then M.restyle(event.buf) end
    end,
  })
  api.nvim_create_autocmd('WinResized', {
    group = group,
    callback = function()
      for buf in pairs(M.blocks) do
        if api.nvim_buf_is_loaded(buf) and markdown(buf) then later(buf, 60) end
      end
    end,
  })
end

return M
