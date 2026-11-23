---
navigation_title: "Plugins"
description: "The plugins Trim bundles, leaving one out, and installing more from the catalog."
---

# Plugins

Trim bundles a small set of pinned plugins:

| Plugin | What for |
|---|---|
| tokyonight, catppuccin, rose-pine | Colour schemes. |
| which-key | The hints after the leader, `g`, `z`, `[` and `]`. |
| mini.nvim | Auto pairs, surround (`sa` `sd` `sr`), more text objects and `[` `]` jumps. |
| gitsigns | Git in the gutter: `]h` `[h`, `<leader>gs` `gr` `gp` `gb` `gd`. |

Leave one out of the next start:

```toml
[plugins]
disabled = ["gitsigns.nvim"]
```

## Packages

`<leader>P`, View ▸ Packages… or `:TrimPackages` lists the bundled plugins and ones Trim can install. Return installs
one (a tarball of a pinned tag from GitHub, its commit checked against the pinned one, into
`~/.local/share/trim/site/pack/trim/start`, loaded at once, no git needed) or leaves a bundled one out of the next
start. `x` removes an installed one. The catalog is `runtime/lua/trim/catalog.lua`.
