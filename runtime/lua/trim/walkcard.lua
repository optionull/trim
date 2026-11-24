-- The cards of a walkthrough: the code (or the change) an anchor points at, as a bordered, tinted block of virtual lines
-- under the line that anchors it. A card has a header bar (what, where, whether it is still true), the code wrapped to the
-- width it is given, and is open or closed to a peek of its first lines.
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

--- The groups, from the colour scheme: a tint a little off the background for the card, an edge a little brighter.
function M.define()
  local normal = api.nvim_get_hl(0, { name = 'Normal', link = false })
  local bg, fg = normal.bg or 0x101010, normal.fg or 0xe0e0e0
  tint = mix(bg, fg, 0.055)
  api.nvim_set_hl(0, 'TrimCardBody', { fg = fg, bg = tint })
  api.nvim_set_hl(0, 'TrimCardEdge', { fg = mix(bg, fg, 0.42), bg = tint })
  api.nvim_set_hl(0, 'TrimCardTitle', { fg = fg, bg = tint, bold = true })
  api.nvim_set_hl(0, 'TrimCardMeta', { fg = mix(bg, fg, 0.5), bg = tint, italic = true })
  local add = api.nvim_get_hl(0, { name = 'DiffAdd', link = false })
  local del = api.nvim_get_hl(0, { name = 'DiffDelete', link = false })
  api.nvim_set_hl(0, 'TrimCardAdd', { fg = add.fg or 0x7ee787, bg = add.bg or mix(tint, 0x2ea043, 0.25) })
  api.nvim_set_hl(0, 'TrimCardDel', { fg = del.fg or 0xff7b72, bg = del.bg or mix(tint, 0xf85149, 0.25) })
  for _, level in ipairs({ { 'Ok', 'DiagnosticOk' }, { 'Warn', 'DiagnosticWarn' }, { 'Err', 'DiagnosticError' } }) do
    local hl = api.nvim_get_hl(0, { name = level[2], link = false })
    api.nvim_set_hl(0, 'TrimCard' .. level[1], { fg = hl.fg or fg, bg = tint, bold = true })
  end
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

--- `text` as rows of chunks no wider than `width` cells, coloured by tree-sitter for `path`'s language; a row that is
--- too long carries on in the next one. Each row is { chunks, cells }.
function M.layout(text, path, width)
  local lang = vim.filetype.match({ filename = path or '' }) or ''
  local ok, spans = pcall(require('trim.docs').highlight, text, lang)
  spans = ok and spans or {}
  local rows, offset = {}, 0
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    line = line:gsub('\t', '    ')
    local colours = {}
    for _, s in ipairs(spans) do
      for b = math.max(s.b, offset), math.min(s.e, offset + #line) - 1 do colours[b - offset + 1] = { s.c, s.bold, s.italic } end
    end
    local row, cells, pos = {}, 0, 1
    local function put(piece, colour, w)
      local hl = colour and code_group(colour[1], colour[2], colour[3]) or 'TrimCardBody'
      local last = row[#row]
      if last and last[2] == hl then last[1] = last[1] .. piece else row[#row + 1] = { piece, hl } end
      cells = cells + w
    end
    if line == '' then rows[#rows + 1] = { {}, 0 } end
    for ch in line:gmatch(CHAR) do
      local w = width_of(ch)
      if cells + w > width then
        rows[#rows + 1] = { row, cells }
        row, cells = {}, 0
      end
      put(ch, colours[pos], w)
      pos = pos + #ch
    end
    if line ~= '' then rows[#rows + 1] = { row, cells } end
    offset = offset + #line + 1
  end
  return rows
end

--- A line of the card: the edges, the chunks and the padding that makes it `width` cells.
local function body(chunks, cells, inner, hl)
  local line = { { '│ ', 'TrimCardEdge' } }
  for _, chunk in ipairs(chunks) do line[#line + 1] = chunk end
  line[#line + 1] = { string.rep(' ', inner - cells) .. ' ', hl or 'TrimCardBody' }
  line[#line + 1] = { '│', 'TrimCardEdge' }
  return line
end

local levels = { ok = 'TrimCardOk', warn = 'TrimCardWarn', err = 'TrimCardErr' }

--- The card for an item of the model (a `code` or a `diff`) as `width` cells wide virtual lines; `open` false shows its
--- header, a peek of its first rows and how many more there are. Returns the lines and how many rows the content has.
function M.lines(item, width, open)
  local inner = width - 4
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
        local hl = row:match('^%+') and 'TrimCardAdd' or row:match('^%-') and 'TrimCardDel' or 'TrimCardMeta'
        local text = row:gsub('\t', '    ')
        local at = 1
        repeat
          local piece, cells = '', 0
          for ch in text:sub(at):gmatch(CHAR) do
            local w = width_of(ch)
            if cells + w > inner then break end
            piece, cells = piece .. ch, cells + w
          end
          rows[#rows + 1] = { { { piece, hl } }, cells, hl }
          at = at + #piece
        until at > #text or #piece == 0
      end
    end
  elseif item.code then
    rows = M.layout(item.code, item.path, inner)
  else
    rows = { { { { item.message or '', 'TrimCardErr' } }, width_of(item.message or '') } }
  end
  -- The header bar: what, then where and whether it is still true, on a line of rule.
  local title = (item.kind == 'diff' and 'diff  ' or '') .. (item.heading or '')
  local where = item.path and ('%s:%d-%d'):format(item.relative or item.path, item.from, item.to) or ''
  local badge = item.badge or ''
  local function head(with_where)
    local left = '╭─ '
    local right = ' ─╮'
    local mid = { { title, 'TrimCardTitle' } }
    local used = width_of(left) + width_of(title) + width_of(right) + 1
    local meta = {}
    if with_where and where ~= '' then meta[#meta + 1] = { where, 'TrimCardMeta' } used = used + width_of(where) + 1 end
    if badge ~= '' then meta[#meta + 1] = { (#meta > 0 and '  ' or '') .. badge, levels[item.level] or 'TrimCardMeta' } used = used + width_of(badge) + (#meta > 1 and 2 or 1) end
    return left, mid, meta, right, width - used
  end
  local left, mid, meta, right, fill = head(true)
  if fill < 1 then left, mid, meta, right, fill = head(false) end
  local top = { { left, 'TrimCardEdge' }, mid[1], { ' ' .. string.rep('─', math.max(fill, 1)) .. ' ', 'TrimCardEdge' } }
  for _, m in ipairs(meta) do top[#top + 1] = m end
  top[#top + 1] = { right, 'TrimCardEdge' }
  local lines = { top }
  local limit = (open or #rows <= M.PEEK + 1) and #rows or M.PEEK
  for i = 1, limit do lines[#lines + 1] = body(rows[i][1], rows[i][2], inner, rows[i][3]) end
  if limit < #rows then
    local more = ('⋯ %d more line%s   za to open'):format(#rows - limit, #rows - limit == 1 and '' or 's')
    lines[#lines + 1] = body({ { more, 'TrimCardMeta' } }, width_of(more), inner)
  end
  lines[#lines + 1] = { { '╰' .. string.rep('─', width - 2) .. '╯', 'TrimCardEdge' } }
  return lines, #rows
end

return M
