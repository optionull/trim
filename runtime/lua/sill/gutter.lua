-- What changed in a file, beside its lines: a bar in the sign column for lines added or changed, a mark where lines
-- went, and the line number tinted. Against where the branch left its base (the merge base with the repository's
-- default branch; HEAD on the default branch itself), so what an agent committed on the branch stays marked, not only
-- what it has not committed yet. git runs off nvim's loop; the marks follow the file on disk (read, written, changed by
-- an agent). ]h and [h go to the next and previous change.
local M = {}

local ns = vim.api.nvim_create_namespace('sill_gutter')
local bases = {}

--- The commit to compare a checkout's files with, once per checkout.
local function base(root, done)
  if bases[root] then return done(bases[root]) end
  vim.system({ 'git', 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD' }, { cwd = root, text = true }, function(head)
    local default = vim.trim(head.stdout or '')
    if head.code ~= 0 or default == '' then default = 'main' end
    vim.system({ 'git', 'merge-base', 'HEAD', default }, { cwd = root, text = true }, function(merge)
      local found = merge.code == 0 and vim.trim(merge.stdout) or 'HEAD'
      bases[root] = found
      done(found)
    end)
  end)
end

--- `git diff -U0`'s hunks as {kind, first, count} in the new file's lines.
function M.hunks(diff)
  local hunks = {}
  for old, new in diff:gmatch('\n@@ %-(%S+) %+(%S+) @@') do
    local removed = tonumber(old:match(',(%d+)') or '1')
    local first, added = new:match('^(%d+),?(%d*)')
    first, added = tonumber(first), tonumber(added ~= '' and added or '1')
    if added == 0 then
      table.insert(hunks, { kind = 'delete', first = math.max(first, 1), count = 1 })
    elseif removed == 0 then
      table.insert(hunks, { kind = 'add', first = first, count = added })
    else
      table.insert(hunks, { kind = 'change', first = first, count = added })
    end
  end
  return hunks
end

local signs = {
  add = { '▎', 'SillGutterAdd' },
  change = { '▎', 'SillGutterChange' },
  delete = { '▁', 'SillGutterDelete' },
}

local function draw(buf, hunks)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local last = vim.api.nvim_buf_line_count(buf)
  for _, hunk in ipairs(hunks) do
    local sign = signs[hunk.kind]
    for line = hunk.first, math.min(hunk.first + hunk.count - 1, last) do
      -- Under a problem's or a breakpoint's sign: the line number keeps the colour.
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, line - 1, 0, {
        sign_text = sign[1], sign_hl_group = sign[2], number_hl_group = sign[2], priority = 5,
      })
    end
  end
  vim.b[buf].sill_hunks = hunks
end

function M.update(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= '' then return end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == '' or vim.fn.filereadable(path) == 0 then return end
  local root = vim.fs.root(path, '.git')
  if not root then return end
  base(root, function(commit)
    vim.system({ 'git', 'diff', '-U0', '--no-color', '--no-ext-diff', commit, '--', path },
      { cwd = root, text = true }, function(result)
        local hunks = result.code == 0 and M.hunks('\n' .. (result.stdout or '')) or {}
        if result.code ~= 0 or (result.stdout or '') ~= '' then
          return vim.schedule(function() draw(buf, hunks) end)
        end
        -- No difference, or a file git does not know yet (new on the branch): then all of it is added.
        vim.system({ 'git', 'ls-files', '--error-unmatch', '--', path }, { cwd = root }, function(known)
          if known.code ~= 0 then hunks = { { kind = 'add', first = 1, count = math.huge } } end
          vim.schedule(function() draw(buf, hunks) end)
        end)
      end)
  end)
end

--- To the next (1) or previous (-1) change from the cursor.
function M.jump(direction)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local hunks = vim.b.sill_hunks or {}
  local target
  for _, hunk in ipairs(hunks) do
    if direction > 0 and hunk.first > line then target = target or hunk.first end
    if direction < 0 and hunk.first < line then target = hunk.first end
  end
  if target then vim.api.nvim_win_set_cursor(0, { math.min(target, vim.api.nvim_buf_line_count(0)), 0 }) end
end

function M.setup()
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufWritePost', 'FileChangedShellPost', 'FocusGained' }, {
    group = vim.api.nvim_create_augroup('sill_gutter', {}),
    callback = function(args)
      if args.event == 'FocusGained' then
        bases = {}
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(buf) then M.update(buf) end
        end
      else
        M.update(args.buf)
      end
    end,
  })
  vim.keymap.set('n', ']h', function() M.jump(1) end, { desc = 'Next change' })
  vim.keymap.set('n', '[h', function() M.jump(-1) end, { desc = 'Previous change' })
end

return M
