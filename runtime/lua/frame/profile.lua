-- A sampling profile of nvim's Lua, for finding what holds nvim up (LuaJIT's own profiler: where the time goes, by line).
-- Not on unless asked: the self-check's load group starts it, runs a while, and reads the file.
local M = {}

function M.start(path)
  local ok, p = pcall(require, 'jit.p')
  if ok then p.start(vim.env.FRAME_PROFILE_MODE or 'li1', path) end
  return ok
end

function M.stop()
  local ok, p = pcall(require, 'jit.p')
  if ok then p.stop() end
end

return M
