-- The packages Frame knows: the ones it carries (bundled: a plugin folder in the app, left out with the settings'
-- `plugins.disabled`), the ones it can install (a tarball of a pinned tag, its commit checked, into Frame's own data folder, not
-- the config's), and which of those are installed. The package browser lists this; Frame (Swift) downloads.
local M = {}

--- Name, what it is, and for an installable one where it comes from (repo, tag, the commit that tag must be) and how it is
--- set up once it is there (a plugin that does nothing until `setup()` is called).
M.packages = {
  { name = 'tokyonight.nvim', kind = 'colour scheme', description = 'Tokyo Night, with storm, moon and day', bundled = true },
  { name = 'catppuccin', kind = 'colour scheme', description = 'Soothing pastels: latte, frappe, macchiato, mocha', bundled = true },
  { name = 'rose-pine', kind = 'colour scheme', description = 'Soho vibes: main, moon and dawn', bundled = true },
  { name = 'which-key.nvim', kind = 'interface', description = 'Shows what can follow a key', bundled = true },
  { name = 'mini.nvim', kind = 'editing', description = 'Pairs, surround, more text objects, [ ] jumps', bundled = true },
  { name = 'gitsigns.nvim', kind = 'git', description = 'Changes in the gutter, stage and reset hunks', bundled = true },
  {
    name = 'gruvbox.nvim', kind = 'colour scheme', description = 'Retro groove colours',
    repo = 'ellisonleao/gruvbox.nvim', tag = '2.0.0', commit = '61b0b3be2f0cfd521667403a0367298144d6c165',
  },
  {
    name = 'nightfox.nvim', kind = 'colour scheme', description = 'Nightfox, dayfox, dawnfox, duskfox, nordfox, terafox, carbonfox',
    repo = 'EdenEast/nightfox.nvim', tag = 'v3.10.0', commit = 'd3e8b1acc095baf57af81bb5e89fe7c4359eb619',
  },
  {
    name = 'flash.nvim', kind = 'motion', description = 'Jump anywhere in view with a few keys (s, S)',
    repo = 'folke/flash.nvim', tag = 'v2.1.0', commit = 'ec0bf2842189f65f60fd40bf3557cac1029cc932',
    setup = "require('flash').setup()",
    keys = { { 's', "require('flash').jump()", 'Flash', { 'n', 'x', 'o' } }, { 'S', "require('flash').treesitter()", 'Flash treesitter', { 'n', 'x', 'o' } } },
  },
  {
    name = 'conform.nvim', kind = 'formatting', description = 'Format with the programs you have (prettier, stylua, ...)',
    repo = 'stevearc/conform.nvim', tag = 'v9.1.0', commit = '3543d000dafbc41cc7761d860cfdb24e82154f75',
    setup = "require('conform').setup({ default_format_opts = { lsp_format = 'fallback' } })",
    keys = { { '<leader>lF', "require('conform').format({ async = true })", 'Format with conform', { 'n', 'x' } } },
  },
  {
    name = 'indent-blankline.nvim', kind = 'interface', description = 'Indentation guides',
    repo = 'lukas-reineke/indent-blankline.nvim', tag = 'v3.10.1', commit = 'f1e186e44d3b7f9ae918008e2c28ce37c6023d2d',
    setup = "require('ibl').setup({ scope = { enabled = false } })",
  },
  {
    name = 'trouble.nvim', kind = 'diagnostics', description = 'A list of diagnostics, references, symbols',
    repo = 'folke/trouble.nvim', tag = 'v3.7.1', commit = '748ca2789044607f19786b1d837044544c55e80a',
    setup = "require('trouble').setup()",
    keys = { { '<leader>lt', "vim.cmd('Trouble diagnostics toggle')", 'Trouble: diagnostics', { 'n' } } },
  },
}

--- Where installed packages go: nvim's data folder for Frame (a `start` pack, loaded at startup).
function M.dir(name)
  return vim.fn.stdpath('data') .. '/site/pack/frame/start/' .. name
end

local function by_name(name)
  for _, p in ipairs(M.packages) do
    if p.name == name then return p end
  end
end

local function disabled(name)
  local plugins = (vim.g.frame_settings or {}).plugins or {}
  return vim.tbl_contains(plugins.disabled or {}, name)
end

--- 'bundled', 'disabled' (a bundled one left out), 'installed' or 'available'.
function M.status(p)
  if p.bundled then return disabled(p.name) and 'disabled' or 'bundled' end
  return vim.uv.fs_stat(M.dir(p.name)) and 'installed' or 'available'
end

--- The packages with what the browser shows: [{ name, kind, description, version, status, dir, repo, tag, commit }].
function M.list()
  local rows = {}
  for _, p in ipairs(M.packages) do
    rows[#rows + 1] = {
      name = p.name, kind = p.kind, description = p.description, version = p.tag or '', status = M.status(p),
      dir = p.bundled and '' or M.dir(p.name), repo = p.repo or '', tag = p.tag or '', commit = p.commit or '',
    }
  end
  return rows
end

local function run(code)
  local chunk = load('return function() ' .. code .. ' end')
  if chunk then pcall(chunk()) end
end

--- Sets up an installed package: its setup call, its keys (unless the config bound them).
local function configure(p)
  if p.setup then run(p.setup) end
  for _, key in ipairs(p.keys or {}) do
    local lhs, body, desc, modes = key[1], key[2], key[3], key[4]
    if vim.fn.maparg(lhs, modes[1]) == '' then
      vim.keymap.set(modes, lhs, function() run(body) end, { desc = desc })
    end
  end
end

--- The installed packages, set up (at startup, once they are on the runtime path).
function M.setup_installed()
  for _, p in ipairs(M.packages) do
    if not p.bundled and vim.uv.fs_stat(M.dir(p.name)) then configure(p) end
  end
end

--- A package was just installed: on the runtime path, its plugin files run, set up, without a restart.
function M.loaded(name)
  local p = by_name(name)
  local dir = M.dir(name)
  if not p or not vim.uv.fs_stat(dir) then return end
  vim.opt.runtimepath:append(dir)
  for _, file in ipairs(vim.fn.glob(dir .. '/plugin/**/*.{lua,vim}', false, true)) do pcall(vim.cmd.source, file) end
  configure(p)
end

--- A package was removed: off the runtime path (what it already set up stays until nvim restarts).
function M.unloaded(name)
  vim.opt.runtimepath:remove(M.dir(name))
end

return M
