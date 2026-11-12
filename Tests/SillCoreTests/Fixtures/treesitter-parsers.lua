-- nvim-treesitter's lua/nvim-treesitter/parsers.lua, cut down: for TreesitterBuildTests.
return {
  c_sharp = { install_info = { revision = 'v0.23.5', url = 'https://github.com/tree-sitter/tree-sitter-c-sharp' } },
  tsx = {
    install_info = { location = 'tsx', revision = '75b3874', url = 'https://github.com/tree-sitter/tree-sitter-typescript' },
    requires = { 'ecma', 'jsx', 'typescript' },
  },
  typescript = {
    install_info = { location = 'typescript', revision = '75b3874',
      url = 'https://github.com/tree-sitter/tree-sitter-typescript' },
    requires = { 'ecma' },
  },
  ecma = { readme_note = 'queries required by javascript, typescript, tsx' },
  jsx = { readme_note = 'queries required by javascript, tsx' },
  swift = { install_info = { generate = true, revision = '9e3b87f', url = 'https://github.com/alex-pinkus/tree-sitter-swift' } },
  lua = { install_info = { revision = '10fe005', url = 'https://github.com/tree-sitter-grammars/tree-sitter-lua' } },
  ada = { install_info = { revision = 'b1d2035', url = 'https://github.com/briot/tree-sitter-ada' } },
}
