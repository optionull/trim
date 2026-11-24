-- The cards of a walkthrough: the code (or the change) an anchor points at, as a tinted block of virtual lines under the
-- line that anchors it. A card has a header bar (what, where, whether it is still true), an accent stripe in the colour of
-- that answer, the code with its own line numbers, wrapped to the width it is given at word boundaries, and is open or
-- closed to a peek of its first lines.
local M = {}
local api = vim.api

M.PEEK = 4
--- Longer than this many rows, a card opens as a peek.
M.OPEN_LIMIT = 14

local function mix(a, b, t)
  local function channel(shift)
    local x, y = bit.band(bit.rshift(a, shift), 255), bit.band(bit.rshift(b, shift), 255)
    return math.floor(x + (y - x) * t + 0.5)
  end
  return channel(16) * 65536 + channel(8) * 256 + channel(0)
end

local tint = 0
local codes = {}

--- The groups, from the colour scheme: a tint a little off the background for the card, a stronger one for its header.
function M.define()
  local normal = api.nvim_get_hl(0, { name = 'Normal', link = false })
  local bg, fg = normal.bg or 0x101010, normal.fg or 0xe0e0e0
  tint = mix(bg, fg, 0.05)
  local head = mix(bg, fg, 0.1)
  local muted = mix(bg, fg, 0.5)
  api.nvim_set_hl(0, 'TrimCardBody', { fg = fg, bg = tint })
  api.nvim_set_hl(0, 'TrimCardHead', { fg = fg, bg = head })
  api.nvim_set_hl(0, 'TrimCardTitle', { fg = fg, bg = head, bold = true })
  api.nvim_set_hl(0, 'TrimCardMeta', { fg = muted, bg = head })
  api.nvim_set_hl(0, 'TrimCardGutter', { fg = mix(bg, fg, 0.32), bg = tint })
  api.nvim_set_hl(0, 'TrimCardMore', { fg = muted, bg = tint, italic = true })
  local add = api.nvim_get_hl(0, { name = 'DiffAdd', link = false })
  local del = api.nvim_get_hl(0, { name = 'DiffDelete', link = false })
  api.nvim_set_hl(0, 'TrimCardAdd', { fg = add.fg or 0x7ee787, bg = add.bg or mix(tint, 0x2ea043, 0.25) })
  api.nvim_set_hl(0, 'TrimCardDel', { fg = del.fg or 0xff7b72, bg = del.bg or mix(tint, 0xf85149, 0.25) })
  api.nvim_set_hl(0, 'TrimCardErr', { fg = api.nvim_get_hl(0, { name = 'DiagnosticError', link = false }).fg or fg, bg = tint })
  -- The accent stripe (on the body and on the header) and the chip, in the colour of whether the code is still as written.
  for _, level in ipairs({ { 'Ok', 'DiagnosticOk' }, { 'Warn', 'DiagnosticWarn' }, { 'Err', 'DiagnosticError' } }) do
    local colour = api.nvim_get_hl(0, { name = level[2], link = false }).fg or fg
    api.nvim_set_hl(0, 'TrimCardBar' .. level[1], { fg = colour, bg = tint })
    api.nvim_set_hl(0, 'TrimCardHeadBar' .. level[1], { fg = colour, bg = head })
    api.nvim_set_hl(0, 'TrimCard' .. level[1], { fg = colour, bg = head, bold = true })
  end
  api.nvim_set_hl(0, 'TrimCardBar', { fg = mix(bg, fg, 0.3), bg = tint })
  api.nvim_set_hl(0, 'TrimCardHeadBar', { fg = mix(bg, fg, 0.3), bg = head })
  -- Syntax colours were made against the old tint.
  for name, spec in pairs(codes) do api.nvim_set_hl(0, name, { fg = spec[1], bg = tint, bold = spec[2], italic = spec[3] }) end
end
M.define()
api.nvim_create_autocmd('ColorScheme', { group = api.nvim_create_augroup('TrimWalkCard', { clear = true }), callback = M.define })

--- The group for a syntax colour on the card's tint.
local function code_group(c, bold, italic)
  local name = ('TrimCardC%06x%s%s'):format(c or 0, bold and 'b' or '', italic and 'i' or '')
  if not codes[name] then
    codes[name] = { c, bold, italic }
    api.nvim_set_hl(0, name, { fg = c, bg = tint, bold = bold, italic = italic })
  end
  return name
end

-- One UTF-8 character (LuaJIT has no utf8 library).
local CHAR = '[%z\1-\127\194-\244][\128-\191]*'

local function width_of(text) return vim.fn.strdisplaywidth(text) end

--- Characters a line may be broken after: the carried-over part reads better from there.
local BREAKS = { [' '] = true, [','] = true, [';'] = true, [')'] = true, [']'] = true, ['}'] = true, ['.'] = true }

--- A source line's cells cut into rows of at most `width` cells, at a word boundary when there is one in the second half of
--- the row (else mid-word); each row after the first is indented by two. `cells` is a list of { char, colour, width }.
local function cut(cells, width)
  local rows, row, used = {}, {}, 0
  for _, cell in ipairs(cells) do
    if used + cell[3] > width then
      local at
      for j = #row, math.floor(width / 2), -1 do
        if BREAKS[row[j][1]] then at = j break end
      end
      local carry = {}
      if at and at < #row then
        for j = at + 1, #row do carry[#carry + 1] = row[j] end
        for j = #row, at + 1, -1 do row[j] = nil end
      end
      rows[#rows + 1] = row
      row, used = { { ' ', false, 1 }, { ' ', false, 1 } }, 2
      for _, c in ipairs(carry) do
        row[#row + 1] = c
        used = used + c[3]
      end
    end
    row[#row + 1] = cell
    used = used + cell[3]
  end
  rows[#rows + 1] = row
  return rows
end

--- `text` as rows of chunks no wider than `width` cells, coloured by tree-sitter for `path`'s language, with the number of
--- its source line (counted from `first`) on the first row of each: { chunks, cells, number }.
function M.layout(text, path, width, first)
  local lang = vim.filetype.match({ filename = path or '' }) or ''
  local ok, spans = pcall(require('trim.docs').highlight, text, lang)
  spans = ok and spans or {}
  local rows, offset = {}, 0
  for index, line in ipairs(vim.split(text, '\n', { plain = true })) do
    line = line:gsub('\t', '    ')
    local colours = {}
    for _, s in ipairs(spans) do
      for b = math.max(s.b, offset), math.min(s.e, offset + #line) - 1 do colours[b - offset + 1] = { s.c, s.bold, s.italic } end
    end
    local cells, pos = {}, 1
    for ch in line:gmatch(CHAR) do
      cells[#cells + 1] = { ch, colours[pos], width_of(ch) }
      pos = pos + #ch
    end
    for k, row in ipairs(cut(cells, width)) do
      local chunks, used = {}, 0
      for _, cell in ipairs(row) do
        local hl = cell[2] and code_group(cell[2][1], cell[2][2], cell[2][3]) or 'TrimCardBody'
        local last = chunks[#chunks]
        if last and last[2] == hl then last[1] = last[1] .. cell[1] else chunks[#chunks + 1] = { cell[1], hl } end
        used = used + cell[3]
      end
      rows[#rows + 1] = { chunks, used, k == 1 and (first or 1) + index - 1 or nil }
    end
    offset = offset + #line + 1
  end
  return rows
end

local levels = { ok = 'Ok', warn = 'Warn', err = 'Err' }

--- A line of the card: the stripe, the gutter, the chunks and the padding that makes it `width` cells.
local function body(bar, gutter, chunks, cells, inner, hl)
  local line = { { '▎', bar }, { gutter, 'TrimCardGutter' } }
  for _, chunk in ipairs(chunks) do line[#line + 1] = chunk end
  line[#line + 1] = { string.rep(' ', inner - cells) .. ' ', hl or 'TrimCardBody' }
  return line
end

--- The card for an item of the model (a `code` or a `diff`) as `width` cells wide virtual lines; `open` false shows its
--- header, a peek of its first rows and how many more there are. Returns the lines and how many rows the content has.
function M.lines(item, width, open)
  local level = levels[item.level]
  local bar = 'TrimCardBar' .. (level or '')
  local digits = (item.kind == 'code' and item.from) and #tostring((item.to or item.from) + 1) or 0
  local gutter_width = digits > 0 and digits + 1 or 1
  local inner = width - 1 - gutter_width - 1
  local rows
  if item.kind == 'diff' then
    rows = {}
    -- What git says before the first hunk is the header of the file, which the card's own header says; with no hunk
    -- at all (a message, or no change) all of it is shown.
    local text_all = item.text or ''
    local started = not (text_all:match('^@@') or text_all:find('\n@@', 1, true))
    for _, row in ipairs(vim.split(text_all, '\n', { plain = true })) do
      if row:match('^@@') then started = true end
      if started and row ~= '' then
        local hl = row:match('^%+') and 'TrimCardAdd' or row:match('^%-') and 'TrimCardDel' or 'TrimCardMore'
        local text = row:gsub('\t', '    ')
        local at = 1
        repeat
          local piece, cells = '', 0
          for ch in text:sub(at):gmatch(CHAR) do
            local w = width_of(ch)
            if cells + w > inner then break end
            piece, cells = piece .. ch, cells + w
          end
          rows[#rows + 1] = { { { piece, hl } }, cells, nil, hl }
          at = at + #piece
        until at > #text or #piece == 0
      end
    end
  elseif item.code then
    rows = M.layout(item.code, item.path, inner, item.from)
  else
    rows = { { { { item.message or '', 'TrimCardErr' } }, width_of(item.message or '') } }
  end
  -- The header bar: what, then where and whether it is still true.
  local title = (item.kind == 'diff' and 'diff  ' or '') .. (item.heading or '')
  local where = item.path and ('%s:%d-%d'):format(item.relative or item.path, item.from, item.to) or ''
  local badge = item.badge or ''
  local function head(with_where)
    -- The stripe, a space, the title and fill, what is on the right, a space.
    local used = 2 + width_of(title) + 1
    local right = {}
    if with_where and where ~= '' then right[#right + 1] = { where, 'TrimCardMeta' } end
    if badge ~= '' then right[#right + 1] = { (#right > 0 and '  ' or '') .. badge, 'TrimCard' .. (level or 'Meta') } end
    for _, chunk in ipairs(right) do used = used + width_of(chunk[1]) end
    return right, width - used
  end
  local right, fill = head(true)
  if fill < 1 then right, fill = head(false) end
  local top = {
    { '▎', 'TrimCardHeadBar' .. (level or '') }, { ' ', 'TrimCardHead' }, { title, 'TrimCardTitle' },
    { string.rep(' ', math.max(fill, 1)), 'TrimCardHead' },
  }
  for _, chunk in ipairs(right) do top[#top + 1] = chunk end
  top[#top + 1] = { ' ', 'TrimCardHead' }
  local lines = { top }
  local limit = (open or #rows <= M.PEEK + 1) and #rows or M.PEEK
  for i = 1, limit do
    local number = rows[i][3]
    local gutter = ' '
    if digits > 0 then gutter = number and (string.rep(' ', digits - #tostring(number)) .. number .. ' ') or string.rep(' ', digits + 1) end
    lines[#lines + 1] = body(bar, gutter, rows[i][1], rows[i][2], inner, rows[i][4])
  end
  if limit < #rows then
    local more = ('⋯ %d more line%s   za to open'):format(#rows - limit, #rows - limit == 1 and '' or 's')
    lines[#lines + 1] = body(bar, string.rep(' ', gutter_width), { { more, 'TrimCardMore' } }, width_of(more), inner)
  end
  lines[#lines + 1] = body(bar, string.rep(' ', gutter_width), {}, 0, inner)
  return lines, #rows
end

return M
