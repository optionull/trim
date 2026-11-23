-- sill's runtime; see lua/sill/init.lua. Not in Trim, which has its own (plugin/trim.lua).
if vim.g.trim then return end
require('sill').setup()
