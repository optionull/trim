-- Frame's own base settings, on top of sill's: loaded before anything of the person's (~/.config/frame/init.lua), which
-- wins. Frame runs its own isolated nvim config: nothing of ~/.config/nvim (nor of any other config) is read.
vim.g.frame = true
return {}
