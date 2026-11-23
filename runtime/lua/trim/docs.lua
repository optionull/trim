-- Documentation for the window to draw (hover, signature help, completion): the markdown the server sent, cleaned up
-- (escapes, entities, headings), cut into text and code, with the code coloured by tree-sitter in whatever language its
-- fence names (or the buffer's own), in the colours the editor uses. The window gets it as JSON blocks.
local M = {}

local ENTITIES = { nbsp = ' ', lt = '<', gt = '>', amp = '&', quot = '"', apos = "'", ['#39'] = "'" }

--- Text as it should read: markdown's backslashes and HTML entities gone, headings and emphasis made plain.
function M.clean(line)
  line = line:gsub('&(#?%w+);', function(name) return ENTITIES[name] end)
  line = line:gsub('\\([\\`*_{}%[%]()#+%-.!|<>~])', '%1')
  line = line:gsub('%*%*(.-)%*%*', '%1')
  line = line:gsub('^%s*#+%s*', '')
  line = line:gsub('%[([^%]]*)%]%([^)]*%)', '%1')
  return line
end

local color_cache = {}

--- The colour (and weight) of a tree-sitter capture in `lang`: its own group, else the more general ones.
local function style(capture, lang)
  local key = capture .. '|' .. lang
  if color_cache[key] ~= nil then return color_cache[key] or nil end
  local names = { '@' .. capture .. '.' .. lang }
  local name = capture
  while name ~= '' do
    names[#names + 1] = '@' .. name
    name = name:match('^(.*)%.[^.]*$') or ''
  end
  for _, group in ipairs(names) do
    local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
    if hl and (hl.fg or hl.bold or hl.italic) then
      color_cache[key] = { c = hl.fg, bold = hl.bold, italic = hl.italic }
      return color_cache[key]
    end
  end
  color_cache[key] = false
end

--- The coloured spans of `code` in `lang` ({ b = first byte, e = after the last, c = colour ... }), later ones over
--- earlier ones as in the editor; none when there is no parser for the language.
function M.highlight(code, lang)
  if not lang or lang == '' then return {} end
  local language = vim.treesitter.language.get_lang(lang) or lang
  local ok_lang = pcall(vim.treesitter.language.add, language)
  if not ok_lang then return {} end
  local ok, parser = pcall(vim.treesitter.get_string_parser, code, language)
  if not ok or not parser then return {} end
  local trees = parser:parse()
  local query = vim.treesitter.query.get(language, 'highlights')
  if not trees or not trees[1] or not query then return {} end
  local lines, starts, offset = vim.split(code, '\n', { plain = true }), {}, 0
  for i, text in ipairs(lines) do
    starts[i - 1] = offset
    offset = offset + #text + 1
  end
  local spans = {}
  for id, node in query:iter_captures(trees[1]:root(), code) do
    local capture = query.captures[id]
    if capture:sub(1, 1) ~= '_' and capture ~= 'spell' and capture ~= 'nospell' then
      local found = style(capture, language)
      if found then
        local sr, sc, er, ec = node:range()
        spans[#spans + 1] = {
          b = starts[sr] + sc, e = (starts[er] or #code) + ec, c = found.c, bold = found.bold, italic = found.italic,
        }
      end
    end
  end
  return spans
end

--- Markdown into blocks: { t = 'text', s }, { t = 'code', s, h = spans }, { t = 'rule' }.
function M.blocks(markdown, default_lang)
  local blocks, text, code, lang = {}, {}, nil, nil
  local function flush_text()
    local joined = table.concat(text, '\n'):gsub('\n\n\n+', '\n\n'):gsub('^%s+', ''):gsub('%s+$', '')
    if joined ~= '' then blocks[#blocks + 1] = { t = 'text', s = joined } end
    text = {}
  end
  for _, line in ipairs(vim.split(markdown or '', '\r?\n')) do
    local fence = line:match('^%s*```%s*([%w_#+%-%.]*)')
    if fence ~= nil and not code then
      flush_text()
      code, lang = {}, (fence ~= '' and fence or default_lang)
    elseif fence ~= nil and code then
      local source = table.concat(code, '\n')
      blocks[#blocks + 1] = { t = 'code', s = source, h = M.highlight(source, lang) }
      code = nil
    elseif code then
      code[#code + 1] = line
    elseif line:match('^%s*%-%-%-+%s*$') or line:match('^%s*%*%*%*+%s*$') then
      flush_text()
      blocks[#blocks + 1] = { t = 'rule' }
    else
      text[#text + 1] = M.clean(line)
    end
  end
  if code then
    local source = table.concat(code, '\n')
    blocks[#blocks + 1] = { t = 'code', s = source, h = M.highlight(source, lang) }
  end
  flush_text()
  return blocks
end

--- What is sent to the window: the blocks as JSON ('' for nothing).
function M.encode(markdown, default_lang)
  local blocks = M.blocks(markdown, default_lang)
  if #blocks == 0 then return '' end
  return vim.json.encode(blocks)
end

return M
