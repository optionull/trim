-- The editor options Trim's settings file sets (`[editor]`): applied when nvim starts (trim.base) and live when the settings
-- window changes one. Window options go to every window that is open, not only the current one.
local M = {}

local function each_window(name, value)
  vim.go[name] = value
  for _, win in ipairs(vim.api.nvim_list_wins()) do vim.wo[win][name] = value end
end

--- `editor` is the table of the settings: tabwidth, expandtab, wrap, number, relativenumber, scrolloff.
function M.apply(editor)
  editor = editor or {}
  if type(editor.tabwidth) == 'number' and editor.tabwidth >= 1 and editor.tabwidth <= 16 then
    vim.o.tabstop, vim.o.shiftwidth, vim.o.softtabstop = editor.tabwidth, editor.tabwidth, editor.tabwidth
  end
  if type(editor.expandtab) == 'boolean' then vim.o.expandtab = editor.expandtab end
  if type(editor.scrolloff) == 'number' then vim.o.scrolloff = math.max(0, math.min(editor.scrolloff, 20)) end
  for _, name in ipairs({ 'wrap', 'number', 'relativenumber' }) do
    if type(editor[name]) == 'boolean' then each_window(name, editor[name]) end
  end
end

--- What nvim has now, for the settings window to show.
function M.current()
  return {
    tabwidth = vim.o.shiftwidth, expandtab = vim.o.expandtab, wrap = vim.wo.wrap, number = vim.wo.number,
    relativenumber = vim.wo.relativenumber, scrolloff = vim.o.scrolloff,
  }
end

return M
