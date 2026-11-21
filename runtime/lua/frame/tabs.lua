-- Frame's tabs: the files open in nvim (its listed buffers with a file), told to the app as one `frame_tabs`
-- notification a moment after anything changes them, and what the app asks of them: select one, close one, go to the
-- next. Also the policy that keeps there from being too many: past `max`, the tabs nobody ever edited are closed, the
-- least recently used first. The options come from the app (its menu, `:FrameTabs`), which owns them.
local M = {}

local options = { max = 10, autoclose = true }
local edited = {} -- buffers seen with changes
local baseline = {} -- buffer -> its change counter when it was loaded: more now means it was edited
local used = {} -- buffer -> a counter, the larger the more recent
local clock = 0
local timer = nil
local group = vim.api.nvim_create_augroup('FrameTabs', { clear = true })

local function notify(method, ...)
  local channel = vim.g.sill_channel
  if channel then pcall(vim.rpcnotify, channel, method, ...) end
end

--- A buffer that is a tab: loaded or not, listed, a file with a name.
local function is_tab(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted and vim.bo[buf].buftype == ''
    and vim.api.nvim_buf_get_name(buf) ~= ''
end

--- Whether anything was written in the buffer since it was loaded: what its change counter says, which no event can
--- miss, or what was seen of it.
function M.is_edited(buf)
  if edited[buf] or vim.bo[buf].modified then return true end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if baseline[buf] == nil then
    baseline[buf] = tick
    return false
  end
  return tick > baseline[buf]
end

--- The tabs, in the order nvim lists the buffers.
function M.list()
  local current = vim.api.nvim_get_current_buf()
  local tabs = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if is_tab(buf) then
      tabs[#tabs + 1] = {
        id = buf,
        path = vim.api.nvim_buf_get_name(buf),
        modified = vim.bo[buf].modified,
        edited = M.is_edited(buf),
        current = buf == current,
      }
    end
  end
  return tabs
end

local function touch(buf)
  clock = clock + 1
  used[buf] = clock
end

--- Past the maximum, the tabs never edited and not showing go, the least recently used first.
function M.trim()
  if not options.autoclose or options.max <= 0 then return end
  local tabs = M.list()
  local over = #tabs - options.max
  if over <= 0 then return end
  local candidates = {}
  for _, tab in ipairs(tabs) do
    if not tab.edited and not tab.current and vim.fn.bufwinid(tab.id) == -1 then candidates[#candidates + 1] = tab.id end
  end
  table.sort(candidates, function(a, b) return (used[a] or 0) < (used[b] or 0) end)
  for i = 1, math.min(over, #candidates) do
    pcall(vim.api.nvim_buf_delete, candidates[i], {})
  end
end

local function send()
  timer = nil
  notify('frame_tabs', M.list())
end

local function soon()
  if timer then return end
  timer = vim.defer_fn(send, 20)
end

--- The tab with this number as the one shown here.
function M.select(buf)
  if not is_tab(buf) then return end
  pcall(vim.cmd, 'buffer ' .. buf)
end

--- The tab closed. One with changes is not: nvim says so, as `:bdelete` does. The one shown gives way to the tab used
--- last before it (or a new empty buffer when it was the only one), so the window stays.
function M.close(buf)
  if not is_tab(buf) then return end
  if vim.bo[buf].modified then
    vim.notify('No write since last change for buffer ' .. buf .. ' (use :bdelete! to discard)', vim.log.levels.ERROR)
    return
  end
  if buf == vim.api.nvim_get_current_buf() then
    local best, at = nil, -1
    for _, tab in ipairs(M.list()) do
      if tab.id ~= buf and (used[tab.id] or 0) > at then best, at = tab.id, used[tab.id] or 0 end
    end
    if best then pcall(vim.cmd, 'buffer ' .. best) else vim.cmd('enew') end
  end
  pcall(vim.api.nvim_buf_delete, buf, {})
  soon()
end

--- The next (or previous, with a negative step) tab, round again.
function M.step(step)
  local tabs = M.list()
  if #tabs == 0 then return end
  local at = 1
  for i, tab in ipairs(tabs) do if tab.current then at = i end end
  M.select(tabs[((at - 1 + step) % #tabs) + 1].id)
end

--- The options in force.
function M.options() return options end

--- The options, as the app has them.
function M.configure(opts)
  if opts.max ~= nil then options.max = opts.max end
  if opts.autoclose ~= nil then options.autoclose = opts.autoclose end
  M.trim()
  soon()
end

function M.start()
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    callback = function(args)
      if is_tab(args.buf) then
        touch(args.buf)
        if baseline[args.buf] == nil then baseline[args.buf] = vim.api.nvim_buf_get_changedtick(args.buf) end
      end
      M.trim()
      soon()
    end,
  })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufModifiedSet' }, {
    group = group,
    callback = function(args)
      if is_tab(args.buf) and vim.bo[args.buf].modified then edited[args.buf] = true end
      soon()
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufAdd', 'BufDelete', 'BufWipeout', 'BufFilePost', 'BufWritePost', 'BufUnload' }, {
    group = group,
    callback = function(args)
      if args.event == 'BufWipeout' or args.event == 'BufDelete' then
        edited[args.buf] = nil
        baseline[args.buf] = nil
        used[args.buf] = nil
      end
      soon()
    end,
  })
  touch(vim.api.nvim_get_current_buf())
  vim.api.nvim_create_user_command('FrameTabs', function(opts)
    local words = vim.split(opts.args, '%s+', { trimempty = true })
    local word = words[1] or 'toggle'
    if word == 'next' then M.step(1)
    elseif word == 'prev' or word == 'previous' then M.step(-1)
    elseif word == 'close' then M.close(tonumber(words[2]) or vim.api.nvim_get_current_buf())
    elseif tonumber(word) then
      local tab = M.list()[tonumber(word)]
      if tab then M.select(tab.id) end
    else
      -- Placement and options belong to the app: it keeps them, and tells this module back.
      notify('frame_tabs_option', word, words[2] or '')
    end
  end, {
    nargs = '*',
    complete = function()
      return { 'next', 'prev', 'close', 'top', 'bottom', 'right', 'tree', 'hide', 'show', 'toggle', 'autoclose', 'max' }
    end,
    desc = 'Tabs: next, prev, close, N; top|bottom|right|tree|hide|show|toggle; autoclose on|off; max N',
  })
  soon()
end

return M
