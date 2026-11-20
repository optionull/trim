-- Frame's hold on which-key.nvim: its window in the sidebar's colours, so the two sit together. which-key.nvim itself
-- does the rest (it draws in the grid like any floating window); nothing here changes what it does or when.
--
-- The app hands over the colours (0xRRGGBB) with `style`, and they are put on the groups its window is drawn with, again
-- each time a colour scheme is applied, which resets them. `vim.g.frame_style_whichkey = false` turns it off.
local M = {}

M.colors = nil

function M.restyle()
  local colors = M.colors
  if not colors or vim.g.frame_style_whichkey == false then return end
  vim.api.nvim_set_hl(0, 'WhichKeyNormal', { bg = colors.background, fg = colors.foreground })
  vim.api.nvim_set_hl(0, 'WhichKeyBorder', { bg = colors.background, fg = colors.muted })
  vim.api.nvim_set_hl(0, 'WhichKeyTitle', { bg = colors.background, fg = colors.foreground, bold = true })
end

function M.style(background, foreground, muted)
  M.colors = { background = background, foreground = foreground, muted = muted }
  if not M.styled then
    M.styled = true
    vim.api.nvim_create_autocmd('ColorScheme', {
      group = vim.api.nvim_create_augroup('FrameWhichKey', {}),
      callback = M.restyle,
    })
  end
  M.restyle()
end

return M
