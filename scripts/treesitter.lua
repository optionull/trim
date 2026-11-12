-- Tree-sitter's parsers for sill's own nvim, built ahead of time and shipped in Sill.app (Contents/Resources/
-- treesitter), so a person needs no compiler: each grammar at the revision nvim-treesitter pins at $TREESITTER_COMMIT,
-- compiled with cc, and nvim-treesitter's queries beside them. Run by nvim, which the build needs anyway:
--
--   nvim -l scripts/treesitter.lua <folder>          build into <folder> (Vendor/treesitter), unless it holds that
--                                                     commit's already
--   nvim -l scripts/treesitter.lua --latest           print nvim-treesitter's newest commit (to bump the pin with)
--   nvim -l scripts/treesitter.lua --plan <parsers.lua>  print what would be built, as JSON (the tests)
--
-- Swift's grammar does not commit its parser.c (it is generated); its repository tags the generated files, and the
-- newest such tag is built instead.

-- The languages sill highlights: those it has language servers for, and what a repository is mostly made of.
local languages = {
  'c_sharp', 'razor', 'fsharp', 'typescript', 'tsx', 'javascript', 'json', 'yaml', 'toml', 'bash', 'rust', 'swift',
  'python', 'go', 'html', 'css', 'xml', 'dockerfile', 'diff', 'gitcommit', 'sql', 'java', 'kotlin', 'ruby',
}
-- nvim's own: never built.
local bundled = { c = true, lua = true, vim = true, vimdoc = true, query = true, markdown = true, markdown_inline = true }

--- What `languages` need from `entries` (parsers.lua): the parsers to build (each wanted language with a grammar,
--- and those its queries build on) and every language whose queries to copy, what they require first.
local function plan(entries)
  local queries, seen = {}, {}
  local function visit(language)
    local entry = entries[language]
    if bundled[language] or not entry or seen[language] then return end
    seen[language] = true
    for _, required in ipairs(entry.requires or {}) do visit(required) end
    table.insert(queries, language)
  end
  for _, language in ipairs(languages) do visit(language) end
  local parsers = vim.tbl_filter(function(language)
    local info = entries[language].install_info
    return info ~= nil and info.url ~= nil
  end, queries)
  return { parsers = parsers, queries = queries }
end

local function run(command, cwd)
  local result = vim.system(command, { cwd = cwd, text = true }):wait()
  if result.code ~= 0 then
    error(table.concat(command, ' ') .. ' failed: ' .. (result.stderr or ''), 0)
  end
  return result.stdout or ''
end

--- An archive of a GitHub repository at a revision, unpacked into `folder`.
local function unpack(url, revision, folder)
  local repository = url:gsub('^https://github.com/', ''):gsub('%.git$', '')
  vim.fn.mkdir(folder, 'p')
  local archive = folder .. '.tar.gz'
  run({ 'curl', '-fsSL', '-o', archive,
    ('https://codeload.github.com/%s/tar.gz/%s'):format(repository, revision) })
  run({ 'tar', 'xzf', archive, '-C', folder, '--strip-components', '1' })
  os.remove(archive)
end

local function latest()
  local head = run({ 'git', 'ls-remote', 'https://github.com/nvim-treesitter/nvim-treesitter', 'refs/heads/main' })
  return head:match('^(%x+)')
end

--- The newest `<version>-with-generated-files` tag of a grammar's repository.
local function generated_tag(url)
  local function older(a, b)
    for i = 1, math.max(#a, #b) do
      if (a[i] or 0) ~= (b[i] or 0) then return (a[i] or 0) < (b[i] or 0) end
    end
    return false
  end
  local best, best_version
  for ref in run({ 'git', 'ls-remote', '--tags', url }):gmatch('refs/tags/(%S+)') do
    local version = ref:match('^([%d.]+)%-with%-generated%-files$')
    if version then
      local parts = vim.tbl_map(tonumber, vim.split(version, '.', { plain = true }))
      if not best_version or older(best_version, parts) then best, best_version = ref, parts end
    end
  end
  return best
end

local function build(out, commit)
  local stamp = out .. '/commit'
  local file = io.open(stamp)
  if file then
    local built = file:read('*l')
    file:close()
    if built == commit then
      print('treesitter: ' .. out .. ' is built from ' .. commit)
      return
    end
  end
  local work = vim.fn.tempname()
  vim.fn.mkdir(work, 'p')
  local source = work .. '/nvim-treesitter'
  unpack('https://github.com/nvim-treesitter/nvim-treesitter', commit, source)
  local entries = dofile(source .. '/lua/nvim-treesitter/parsers.lua')
  local wanted = plan(entries)
  local parsers = out .. '.new/parser'
  vim.fn.delete(out .. '.new', 'rf')
  vim.fn.mkdir(parsers, 'p')
  for _, language in ipairs(wanted.parsers) do
    local info = entries[language].install_info
    local revision = info.generate and generated_tag(info.url) or info.revision
    local folder = work .. '/' .. language
    unpack(info.url, revision, folder)
    local src = folder .. '/' .. (info.location and (info.location .. '/') or '') .. 'src'
    local sources, libraries = { src .. '/parser.c' }, {}
    if vim.uv.fs_stat(src .. '/scanner.c') then
      table.insert(sources, src .. '/scanner.c')
    elseif vim.uv.fs_stat(src .. '/scanner.cc') then
      -- An old grammar's C++ scanner: clang compiles each file by its extension; the C++ library links in.
      table.insert(sources, src .. '/scanner.cc')
      libraries = { '-lc++' }
    end
    local command = { 'cc', '-shared', '-fPIC', '-Os', '-I', src }
    vim.list_extend(command, sources)
    vim.list_extend(command, libraries)
    vim.list_extend(command, { '-o', parsers .. '/' .. language .. '.so' })
    run(command, src)
    print(('treesitter: %s at %s'):format(language, revision))
  end
  vim.fn.mkdir(out .. '.new/queries', 'p')
  for _, language in ipairs(wanted.queries) do
    local from = source .. '/runtime/queries/' .. language
    if vim.uv.fs_stat(from) then run({ 'cp', '-R', from, out .. '.new/queries/' .. language }, nil) end
  end
  local written = io.open(out .. '.new/commit', 'w')
  written:write(commit .. '\n')
  written:close()
  vim.fn.delete(out, 'rf')
  run({ 'mv', out .. '.new', out })
  vim.fn.delete(work, 'rf')
  print(('treesitter: %d parsers from nvim-treesitter %s in %s'):format(#wanted.parsers, commit, out))
end

local first = arg[1]
if first == '--plan' then
  io.stdout:write(vim.json.encode(plan(dofile(arg[2]))) .. '\n')
elseif first == '--latest' then
  print(latest())
elseif first then
  local commit = vim.env.TREESITTER_COMMIT
  if not commit or commit == '' then error('treesitter: set TREESITTER_COMMIT (mise.toml)', 0) end
  build(first, commit)
else
  error('usage: nvim -l scripts/treesitter.lua <folder> | --latest | --plan <parsers.lua>', 0)
end
