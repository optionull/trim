-- How far past the end of the buffer a window may scroll. nvim lets a wheel or a trackpad take the last line all the
-- way up to the top of a window; Frame keeps it near the bottom: at most `past` rows of the window are empty.
local M = { past = 2 }

--- Scroll `win` back, if it has gone further than allowed.
function M.clamp(win)
  if not vim.api.nvim_win_is_valid(win) then return end
  local height = vim.api.nvim_win_get_height(win)
  local want = height - math.min(math.max(M.past, 0), height - 1)
  local top = vim.api.nvim_win_call(win, function() return vim.fn.winsaveview().topline end)
  local function below(line) return vim.api.nvim_win_text_height(win, { start_row = line - 1 }).all end
  if top <= 1 or below(top) >= want then return end
  while top > 1 and below(top) < want do top = top - 1 end
  vim.api.nvim_win_call(win, function() vim.fn.winrestview({ topline = top, skipcol = 0 }) end)
end

function M.setup(past)
  M.past = past or M.past
  -- A wheel step down scrolls the window under the mouse by a line, and is put back if that went too far. (The event
  -- below alone is not enough: nvim does not report a scroll that ends where its last report did.)
  vim.keymap.set({ 'n', 'v', 'i' }, '<ScrollWheelDown>', function()
    local win = vim.fn.getmousepos().winid
    if win == 0 or not vim.api.nvim_win_is_valid(win) then return end
    vim.api.nvim_win_call(win, function() vim.cmd([[exe "normal! \<C-e>"]]) end)
    M.clamp(win)
  end, { desc = 'Scroll down, not past the end' })
  vim.api.nvim_create_autocmd('WinScrolled', {
    group = vim.api.nvim_create_augroup('frame_scrollpast', { clear = true }),
    callback = function()
      for key in pairs(vim.v.event) do
        local win = tonumber(key)
        if win and win > 0 then M.clamp(win) end
      end
    end,
  })
end

return M
