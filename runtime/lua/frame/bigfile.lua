-- Opening a file is always instant: a file that is big (or has lines too long to colour) is opened plain. Tree-sitter,
-- syntax, folds, undo history and language servers are left off for that buffer; everything else works as it does.
-- `editor.big_file_kb` of the settings says how big (default 1024); 0 turns the policy off.
local M = {}

local settings = (vim.g.frame_settings or {}).editor or {}
M.limit = (tonumber(settings.big_file_kb) or 1024) * 1024
M.long_line = 10000

--- Whether a file is big, by its size on disk.
function M.is_big(path)
  if M.limit <= 0 or path == '' then return false end
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == 'file' and stat.size > M.limit
end

--- Makes a buffer plain.
function M.plain(buf)
  vim.b[buf].frame_big = true
  vim.bo[buf].undolevels = -1
  vim.bo[buf].swapfile = false
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.wo[win].foldmethod = 'manual'
    vim.wo[win].spell = false
    vim.wo[win].wrap = false
  end
  vim.api.nvim_buf_call(buf, function()
    pcall(vim.treesitter.stop, buf)
    vim.cmd('syntax clear')
    vim.cmd('setlocal syntax=off')
  end)
end

function M.setup()
  -- Whoever starts tree-sitter (Sill's syntax module, a plugin), a plain buffer is left without it.
  local start = vim.treesitter.start
  vim.treesitter.start = function(buf, ...)
    if vim.b[buf or vim.api.nvim_get_current_buf()].frame_big then return end
    return start(buf, ...)
  end
  local group = vim.api.nvim_create_augroup('FrameBigFile', { clear = true })
  -- Before the file is read: the size says it, and nothing that reacts to the file type (language servers, tree-sitter)
  -- gets to start.
  vim.api.nvim_create_autocmd('BufReadPre', {
    group = group,
    callback = function(args)
      if M.is_big(vim.api.nvim_buf_get_name(args.buf)) then
        vim.b[args.buf].frame_big = true
        vim.bo[args.buf].undolevels = -1
        vim.bo[args.buf].swapfile = false
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'FileType' }, {
    group = group,
    callback = function(args)
      if vim.b[args.buf].frame_big then
        M.plain(args.buf)
        return
      end
      -- A minified file is small and still slow: one very long line.
      if args.event == 'BufReadPost' and M.limit > 0 then
        local first = vim.api.nvim_buf_get_lines(args.buf, 0, 3, false)
        for _, line in ipairs(first) do
          if #line > M.long_line then
            M.plain(args.buf)
            return
          end
        end
      end
    end,
  })
end

return M
