-- Markdown blocks drawn as they are meant to read, as lines of virtual-text chunks: tables as aligned grids, callouts
-- (`> [!warning] ...`) and quotes as a tinted block with an accent bar. Pure layout: given the source lines and a width,
-- the chunks; trim.mdstyle puts them on the screen and shows the source while the cursor is in the block.
local M = {}
local api = vim.api

local function mix(a, b, t)
  local function channel(shift)
    local x, y = bit.band(bit.rshift(a, shift), 255), bit.band(bit.rshift(b, shift), 255)
    return math.floor(x + (y - x) * t + 0.5)
  end
  return channel(16) * 65536 + channel(8) * 256 + channel(0)
end

--- What a callout of each kind is called, drawn with, and coloured by.
local function icon(code) return vim.fn.nr2char(code) end
M.kinds = {
  note = { 'Note', icon(0xF05A), 'Info' }, tip = { 'Tip', icon(0xF0EB), 'Ok' }, important = { 'Important', icon(0xF06A), 'Hint' },
  warning = { 'Warning', icon(0xF071), 'Warn' }, caution = { 'Caution', icon(0xF057), 'Error' },
  danger = { 'Danger', icon(0xF057), 'Error' }, risk = { 'Risk', icon(0xF057), 'Error' },
  question = { 'Question', icon(0xF059), 'Info' }, verified = { 'Verified', icon(0xF058), 'Ok' },
  asserted = { 'Asserted', icon(0xF06A), 'Warn' },
}

--- The groups, from the colour scheme; made again when it changes.
function M.define()
  local normal = api.nvim_get_hl(0, { name = 'Normal', link = false })
  local bg, fg = normal.bg or 0x101010, normal.fg or 0xe0e0e0
  local tint = mix(bg, fg, 0.055)
  api.nvim_set_hl(0, 'TrimTableEdge', { fg = mix(bg, fg, 0.4) })
  api.nvim_set_hl(0, 'TrimTableHead', { fg = fg, bg = tint, bold = true })
  api.nvim_set_hl(0, 'TrimTableCell', { fg = fg })
  api.nvim_set_hl(0, 'TrimQuoteBar', { fg = mix(bg, fg, 0.4) })
  api.nvim_set_hl(0, 'TrimQuoteText', { fg = mix(bg, fg, 0.75), italic = true })
  api.nvim_set_hl(0, 'TrimInlineBold', { bold = true })
  api.nvim_set_hl(0, 'TrimInlineItalic', { italic = true })
  api.nvim_set_hl(0, 'TrimInlineLink', { underline = true })
  for _, level in ipairs({ 'Info', 'Ok', 'Hint', 'Warn', 'Error' }) do
    local colour = api.nvim_get_hl(0, { name = 'Diagnostic' .. level, link = false }).fg or fg
    local back = mix(bg, colour, 0.1)
    api.nvim_set_hl(0, 'TrimCallout' .. level .. 'Bar', { fg = colour, bg = back })
    api.nvim_set_hl(0, 'TrimCallout' .. level .. 'Head', { fg = colour, bg = back, bold = true })
    api.nvim_set_hl(0, 'TrimCallout' .. level, { fg = fg, bg = back })
  end
end
M.define()
api.nvim_create_autocmd('ColorScheme', { group = api.nvim_create_augroup('TrimMdBlocks', { clear = true }), callback = M.define })

local function width_of(text) return vim.fn.strdisplaywidth(text) end

--- Inline Markdown as spans { text, hl }: `code` (boxed), **bold**, *italic*, [text](url).
function M.inline(text)
  local spans, pos = {}, 1
  local function plain(piece) if piece ~= '' then spans[#spans + 1] = { piece, false } end end
  while pos <= #text do
    local starts = {}
    for _, p in ipairs({ { '`[^`]+`', 'code' }, { '%*%*[^*]+%*%*', 'bold' }, { '%*[^*]+%*', 'italic' }, { '%[[^%]]+%]%([^)]+%)', 'link' } }) do
      local a, b = text:find(p[1], pos)
      if a then starts[#starts + 1] = { a, b, p[2] } end
    end
    table.sort(starts, function(x, y) return x[1] < y[1] end)
    local first = starts[1]
    if not first then plain(text:sub(pos)) break end
    plain(text:sub(pos, first[1] - 1))
    local inner = text:sub(first[1], first[2])
    if first[3] == 'code' then spans[#spans + 1] = { ' ' .. inner:sub(2, -2) .. ' ', 'TrimMdCode' }
    elseif first[3] == 'bold' then spans[#spans + 1] = { inner:sub(3, -3), 'TrimInlineBold' }
    elseif first[3] == 'italic' then spans[#spans + 1] = { inner:sub(2, -2), 'TrimInlineItalic' }
    else spans[#spans + 1] = { inner:match('^%[([^%]]+)%]'), 'TrimInlineLink' } end
    pos = first[2] + 1
  end
  return spans
end

--- Spans cut into words (a code span is one word): a list of { chunks, width }.
local function words(spans)
  local out, current, w = {}, {}, 0
  local function flush() if #current > 0 then out[#out + 1] = { current, w } current, w = {}, 0 end end
  for _, span in ipairs(spans) do
    if span[2] == 'TrimMdCode' then
      current[#current + 1] = span
      w = w + width_of(span[1])
    else
      for piece, space in span[1]:gmatch('(%S*)(%s*)') do
        if piece ~= '' then current[#current + 1] = { piece, span[2] } w = w + width_of(piece) end
        if space ~= '' then flush() end
        if piece == '' and space == '' then break end
      end
    end
  end
  flush()
  return out
end

--- Spans wrapped to lines of at most `width` cells at word boundaries (a longer word is cut): a list of
--- { chunks, cells }.
function M.wrap(spans, width)
  local lines, row, cells = {}, {}, 0
  for _, word in ipairs(words(spans)) do
    local chunks, w = word[1], word[2]
    if w > width then
      -- Too long for any line: cut it by characters.
      if cells > 0 then lines[#lines + 1] = { row, cells } row, cells = {}, 0 end
      for _, chunk in ipairs(chunks) do
        for ch in chunk[1]:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
          local cw = width_of(ch)
          if cells + cw > width then lines[#lines + 1] = { row, cells } row, cells = {}, 0 end
          row[#row + 1] = { ch, chunk[2] }
          cells = cells + cw
        end
      end
    else
      if cells > 0 and cells + 1 + w > width then lines[#lines + 1] = { row, cells } row, cells = {}, 0 end
      if cells > 0 then row[#row + 1] = { ' ', false } cells = cells + 1 end
      for _, chunk in ipairs(chunks) do row[#row + 1] = chunk end
      cells = cells + w
    end
  end
  if #row > 0 or #lines == 0 then lines[#lines + 1] = { row, cells } end
  return lines
end

--- The cells of a table row: `| a | b |` as { 'a', 'b' } (escaped bars are kept).
local function split_row(line)
  local text = line:gsub('^%s*|', ''):gsub('|%s*$', '')
  local cells, current = {}, ''
  local i = 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == '\\' and text:sub(i + 1, i + 1) == '|' then current = current .. '|' i = i + 1
    elseif c == '|' then cells[#cells + 1] = vim.trim(current) current = ''
    else current = current .. c end
    i = i + 1
  end
  cells[#cells + 1] = vim.trim(current)
  return cells
end

--- Whether `lines` (a block starting at its first line) is a table: a row, a separator row, then rows.
function M.is_table(lines)
  if #lines < 2 or not lines[1]:match('^%s*|') then return false end
  local sep = split_row(lines[2])
  if #sep == 0 then return false end
  for _, cell in ipairs(sep) do if not cell:match('^:?%-+:?$') then return false end end
  return true
end

local function pad(chunks, cells, width, align)
  local space = math.max(width - cells, 0)
  local left = align == 'right' and space or align == 'center' and math.floor(space / 2) or 0
  local out = {}
  if left > 0 then out[#out + 1] = { string.rep(' ', left), 'TrimTableCell' } end
  for _, c in ipairs(chunks) do out[#out + 1] = c end
  if space - left > 0 then out[#out + 1] = { string.rep(' ', space - left), 'TrimTableCell' } end
  return out
end

--- A table as a grid no wider than `width`: rounded corners, a header on a tint, columns aligned as the separator row
--- says, cells wrapped when the table is wider than the window. A list of lines of chunks.
function M.table_lines(lines, width)
  local head = split_row(lines[1])
  local aligns = {}
  for i, cell in ipairs(split_row(lines[2])) do
    aligns[i] = (cell:match('^:.*:$') and 'center') or (cell:match(':$') and 'right') or 'left'
  end
  local rows = { head }
  for i = 3, #lines do rows[#rows + 1] = split_row(lines[i]) end
  local cols = #head
  local spans, natural = {}, {}
  for r, row in ipairs(rows) do
    spans[r] = {}
    for c = 1, cols do
      spans[r][c] = M.inline(row[c] or '')
      local w = 0
      for _, s in ipairs(spans[r][c]) do w = w + width_of(s[1]) end
      natural[c] = math.max(natural[c] or 3, w)
    end
  end
  -- Each column's width: as wide as its widest cell, the widest ones shrunk to fit when the table is too wide.
  local widths, budget = {}, width - (cols * 3 + 1)
  for c = 1, cols do widths[c] = natural[c] end
  local function total() local t = 0 for c = 1, cols do t = t + widths[c] end return t end
  while total() > budget do
    local widest = 1
    for c = 2, cols do if widths[c] > widths[widest] then widest = c end end
    if widths[widest] <= 6 then break end
    widths[widest] = widths[widest] - 1
  end
  local function rule(left, mid, right)
    local line = { { left, 'TrimTableEdge' } }
    for c = 1, cols do
      line[#line + 1] = { string.rep('─', widths[c] + 2), 'TrimTableEdge' }
      line[#line + 1] = { c < cols and mid or right, 'TrimTableEdge' }
    end
    return line
  end
  local out = { rule('╭', '┬', '╮') }
  for r, row in ipairs(rows) do
    local wrapped, height = {}, 1
    for c = 1, cols do
      wrapped[c] = M.wrap(spans[r][c], widths[c])
      height = math.max(height, #wrapped[c])
    end
    for h = 1, height do
      local line = { { '│', 'TrimTableEdge' } }
      for c = 1, cols do
        local piece = wrapped[c][h] or { {}, 0 }
        local chunks = {}
        for _, chunk in ipairs(piece[1]) do
          chunks[#chunks + 1] = { chunk[1], chunk[2] or (r == 1 and 'TrimTableHead' or 'TrimTableCell') }
        end
        local cell = pad(chunks, piece[2], widths[c], aligns[c])
        if r == 1 then for _, chunk in ipairs(cell) do chunk[2] = chunk[2] == 'TrimTableCell' and 'TrimTableHead' or chunk[2] end end
        line[#line + 1] = { r == 1 and ' ' or ' ', r == 1 and 'TrimTableHead' or 'TrimTableCell' }
        for _, chunk in ipairs(cell) do line[#line + 1] = chunk end
        line[#line + 1] = { ' ', r == 1 and 'TrimTableHead' or 'TrimTableCell' }
        line[#line + 1] = { '│', 'TrimTableEdge' }
      end
      out[#out + 1] = line
    end
    if r == 1 then out[#out + 1] = rule('├', '┼', '┤') end
  end
  out[#out + 1] = rule('╰', '┴', '╯')
  return out
end

--- A callout or quote block: `lines` are its source lines (each starting with `>`). Returns the lines of chunks, `width`
--- cells wide, and the kind ('warning'... or nil for a plain quote).
function M.quote_lines(lines, width)
  local text = {}
  for _, line in ipairs(lines) do text[#text + 1] = (line:gsub('^%s*>%s?', '')) end
  local kind, title = text[1]:match('^%[!(%w+)%]%s*(.*)$')
  kind = kind and kind:lower()
  local spec = kind and M.kinds[kind]
  if not spec then kind = nil end
  local level = spec and spec[3] or nil
  local bar = level and ('TrimCallout' .. level .. 'Bar') or 'TrimQuoteBar'
  local body = level and ('TrimCallout' .. level) or 'TrimQuoteText'
  local out = {}
  local inner = width - 3
  local function line(chunks, cells, hl)
    local row = { { level and '▎ ' or '▎ ', bar } }
    for _, c in ipairs(chunks) do row[#row + 1] = { c[1], c[2] or hl or body } end
    row[#row + 1] = { string.rep(' ', math.max(inner - cells, 0)) .. ' ', hl or body }
    return row
  end
  local first = 1
  if spec then
    -- The head row names the kind; what follows `[!kind]` on its line is where the text starts (agents write the whole
    -- callout there), so it is a paragraph, wrapped, not a title.
    local label = spec[2] .. ' ' .. spec[1]
    out[#out + 1] = line({ { label, 'TrimCallout' .. level .. 'Head' } }, width_of(label), 'TrimCallout' .. level)
    if title ~= '' then text[1] = title else first = 2 end
  end
  local paragraph = {}
  local function flush()
    if #paragraph == 0 then return end
    for _, wrapped in ipairs(M.wrap(M.inline(table.concat(paragraph, ' ')), inner)) do out[#out + 1] = line(wrapped[1], wrapped[2]) end
    paragraph = {}
  end
  for i = first, #text do
    if text[i] == '' then flush() out[#out + 1] = line({}, 0) else paragraph[#paragraph + 1] = text[i] end
  end
  flush()
  return out, kind
end

return M
