-- What only nvim knows, for Frame's status bar: where the cursor is, the buffer's state, diagnostics, the language
-- servers, a recording. Sent as one `frame_status` notification, a moment after whatever changed it (the bar draws it
-- natively). nvim's own status line, ruler and mode message are off while the bar shows, and put back when it hides;
-- `vim.g.frame_statusline = false` keeps the bar away.
local M = {}

local saved = nil
local timer = nil
local enabled = false
local group = vim.api.nvim_create_augroup('FrameStatus', { clear = true })

local function notify(method, arg)
  local channel = vim.g.sill_channel
  if channel then pcall(vim.rpcnotify, channel, method, arg) end
end

--- The facts, for the buffer and window the person is in.
function M.snapshot()
  local buf = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local counts = vim.diagnostic.count(buf)
  local clients = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do clients[#clients + 1] = client.name end
  local bo = vim.bo[buf]
  return {
    path = vim.api.nvim_buf_get_name(buf),
    buftype = bo.buftype,
    ft = bo.filetype,
    enc = bo.fileencoding ~= '' and bo.fileencoding or vim.o.encoding,
    ff = bo.fileformat,
    modified = bo.modified,
    readonly = bo.readonly or not bo.modifiable,
    line = pos[1],
    col = vim.fn.virtcol('.'),
    lines = vim.api.nvim_buf_line_count(buf),
    top = vim.fn.line('w0'),
    bottom = vim.fn.line('w$'),
    errors = counts[vim.diagnostic.severity.ERROR] or 0,
    warnings = counts[vim.diagnostic.severity.WARN] or 0,
    infos = counts[vim.diagnostic.severity.INFO] or 0,
    hints = counts[vim.diagnostic.severity.HINT] or 0,
    lsp = clients,
    recording = vim.fn.reg_recording(),
  }
end

local function send()
  timer = nil
  if enabled then notify('frame_status', M.snapshot()) end
end

--- Soon, once, however many things changed meanwhile.
local function soon()
  if timer or not enabled then return end
  timer = vim.defer_fn(send, 20)
end

local function hide_nvims()
  vim.o.laststatus = 0
  vim.o.ruler = false
  vim.o.showmode = false
end

--- The bar on or off. On: nvim's own are off (a plugin turning its status line back on is put back, whenever it
--- does it); off: they are as they were.
function M.enable(on)
  if on == enabled then return end
  enabled = on
  if on then
    saved = saved or { laststatus = vim.o.laststatus, ruler = vim.o.ruler, showmode = vim.o.showmode }
    hide_nvims()
    vim.api.nvim_create_autocmd('OptionSet', {
      group = group,
      pattern = { 'laststatus', 'ruler', 'showmode' },
      callback = function()
        -- Only when something is not as it should be: setting them fires this again.
        if vim.o.laststatus == 0 and not vim.o.ruler and not vim.o.showmode then return end
        vim.schedule(function() if enabled then hide_nvims() end end)
      end,
    })
    soon()
  else
    vim.api.nvim_clear_autocmds({ group = group, event = 'OptionSet' })
    if saved then
      vim.o.laststatus, vim.o.ruler, vim.o.showmode = saved.laststatus, saved.ruler, saved.showmode
      saved = nil
    end
  end
  notify('frame_statusline', on and 'on' or 'off')
end

function M.start()
  local events = {
    'CursorMoved', 'CursorMovedI', 'BufEnter', 'BufModifiedSet', 'TextChanged', 'TextChangedI', 'DiagnosticChanged',
    'LspAttach', 'LspDetach', 'FileType', 'RecordingEnter', 'RecordingLeave', 'WinEnter', 'WinScrolled', 'VimResized',
  }
  vim.api.nvim_create_autocmd(events, { group = vim.api.nvim_create_augroup('FrameStatusEvents', { clear = true }), callback = soon })
  vim.api.nvim_create_user_command('FrameStatusline', function(opts)
    local arg = opts.args
    if arg == 'show' then M.enable(true)
    elseif arg == 'hide' then M.enable(false)
    elseif arg == 'editor' or arg == 'window' then notify('frame_statusbar', arg)
    else M.enable(not enabled) end
  end, {
    nargs = '?',
    complete = function() return { 'toggle', 'show', 'hide', 'editor', 'window' } end,
    desc = "Show or hide Frame's status bar (nvim's own comes back while it is hidden); `editor` puts it under the grid beside the sidebar, `window` across the window",
  })
  M.enable(vim.g.frame_statusline ~= false)
end

return M
