-- Walkthroughs in the editor: the code a step points at, shown with its lines marked, and that code as the highlighted
-- blocks the walkthrough pane draws (in this editor's colour scheme, with its tree-sitter parsers).
local M = {}
local ns = vim.api.nvim_create_namespace('trim_walk')
vim.api.nvim_set_hl(0, 'TrimWalkRange', { link = 'Visual', default = true })

--- Takes the marks off the code last shown.
function M.clear()
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1) end
  M.buf = nil
end

--- Shows lines `from` to `to` of `path` in the current window: opened when it is not what is shown, marked, and scrolled
--- into view. The keyboard stays where it was.
function M.show(path, from, to)
  M.clear()
  if vim.fn.filereadable(path) == 0 then return false end
  local full = vim.fn.fnamemodify(path, ':p')
  if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p') ~= full then pcall(vim.cmd.edit, vim.fn.fnameescape(full)) end
  local buf = vim.api.nvim_get_current_buf()
  local last = vim.api.nvim_buf_line_count(buf)
  from = math.max(1, math.min(from, last))
  to = math.max(from, math.min(to, last))
  for line = from, to do
    vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, { line_hl_group = 'TrimWalkRange', priority = 5 })
  end
  M.buf = buf
  vim.api.nvim_win_set_cursor(0, { from, 0 })
  vim.cmd('normal! zz')
  return true
end

--- `text` as the highlighted blocks the pane draws, by the file type of `path` (JSON for `DocContent`).
function M.code(path, text)
  local filetype = vim.filetype.match({ filename = path }) or ''
  return require('trim.docs').encode('```' .. filetype .. '\n' .. text .. '\n```', filetype)
end

--- `markdown` as blocks (text, highlighted code, rules), the way hover documentation is.
function M.markdown(markdown)
  return require('trim.docs').encode(markdown, 'markdown')
end

return M
