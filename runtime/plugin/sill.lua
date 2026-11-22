-- sill's runtime; see lua/sill/init.lua. Not in Frame, which has its own (plugin/frame.lua).
if vim.g.frame then return end
require('sill').setup()
