-- How markdown looks while it is edited (source stays source): headings in bigger type, inline code in a bordered box
-- rather than a tint that reads as a cursor or a selection. Used for walkthroughs and for any markdown buffer.
--
-- The app's grid draws two things from highlight attributes (see Highlight.scale / .boxed there): `altfont` is a row at
-- 2x, `altfont` with a `blend` of 1-99 is 1 + blend/100 times, and `altfont` with a `blend` of 100 is a box round the
-- cells. A scaled line has a blank virtual line under it that holds its lower half.
local M = {}
local api = vim.api

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
  local bg, fg = normal.bg or 0x101010, normal.fg or 0xe0e0e0
  api.nvim_set_hl(0, 'TrimMdH1', { fg = title.fg or fg, bold = true, underline = true, altfont = true })
  api.nvim_set_hl(0, 'TrimMdH2', { fg = heading.fg or title.fg or fg, bold = true, altfont = true, blend = 50 })
  -- Inline code: a faint tint inside a rounded border, so it is a thing and not a highlight.
  api.nvim_set_hl(0, 'TrimMdCode', { fg = fg, bg = mix(bg, fg, 0.09), sp = mix(bg, fg, 0.5), altfont = true, blend = 100 })
end
M.define()
api.nvim_create_autocmd('ColorScheme', { group = api.nvim_create_augroup('TrimMdStyle', { clear = true }), callback = M.define })

--- Decorates `lines` (1-based, of buffer `buf`) in namespace `ns`: headings and inline code, outside the front matter
--- (lines 1 to `front_end`, when there is any) and outside fenced blocks.
function M.apply(buf, ns, lines, front_end)
  local fence
  for number = (front_end or 0) + 1, #lines do
    local text = lines[number]
    local marker = text:match('^%s*(```)') or text:match('^%s*(~~~)')
    if marker then
      if not fence then fence = marker elseif fence == marker then fence = nil end
    elseif not fence then
      local hashes, rest = text:match('^(#+) (.*)$')
      local group = hashes and ({ [1] = 'TrimMdH1', [2] = 'TrimMdH2' })[#hashes]
      if group and rest ~= '' then
        -- The marks are hidden (the cursor on the line shows them), the text drawn big, and a blank line under it.
        pcall(api.nvim_buf_set_extmark, buf, ns, number - 1, 0, { end_col = #hashes + 1, conceal = '' })
        pcall(api.nvim_buf_set_extmark, buf, ns, number - 1, #hashes + 1, { end_col = #text, hl_group = group, priority = 200 })
        pcall(api.nvim_buf_set_extmark, buf, ns, number - 1, 0, { virt_lines = { { { ' ' } } } })
      elseif not hashes then
        local from = 1
        while true do
          local first, last = text:find('`[^`\n]+`', from)
          if not first then break end
          -- The backticks stay, as spaces inside the box: its padding.
          pcall(api.nvim_buf_set_extmark, buf, ns, number - 1, first - 1, { end_col = last, hl_group = 'TrimMdCode', priority = 200 })
          pcall(api.nvim_buf_set_extmark, buf, ns, number - 1, first - 1, { end_col = first, conceal = ' ', priority = 210 })
          pcall(api.nvim_buf_set_extmark, buf, ns, number - 1, last - 1, { end_col = last, conceal = ' ', priority = 210 })
          from = last + 1
        end
      end
    end
  end
end

local timers = {}
--- Any markdown buffer that is not a walkthrough (those are dressed by trim.walk) gets the same decoration, as it is
--- edited.
function M.setup()
  local ns = api.nvim_create_namespace('trim_md')
  local group = api.nvim_create_augroup('TrimMdBuffers', { clear = true })
  local function style(buf)
    if not api.nvim_buf_is_loaded(buf) or api.nvim_buf_get_name(buf):match('%.walk%.md$') then return end
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local front_end = 0
    if lines[1] == '---' then
      for number = 2, #lines do
        if lines[number] == '---' then front_end = number break end
      end
    end
    M.apply(buf, ns, lines, front_end)
  end
  api.nvim_create_autocmd('FileType', {
    group = group, pattern = 'markdown',
    callback = function(event)
      vim.wo.conceallevel = 2
      style(event.buf)
    end,
  })
  api.nvim_create_autocmd({ 'TextChanged', 'InsertLeave', 'BufEnter' }, {
    group = group,
    callback = function(event)
      if vim.bo[event.buf].filetype ~= 'markdown' then return end
      local timer = timers[event.buf] or vim.uv.new_timer()
      timers[event.buf] = timer
      timer:stop()
      timer:start(120, 0, vim.schedule_wrap(function() style(event.buf) end))
    end,
  })
end

return M
