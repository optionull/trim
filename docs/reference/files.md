---
navigation_title: "Files"
description: "Where Trim keeps its settings, config, data and caches."
---

# Files

| Path | What it is |
|---|---|
| `~/.config/trim/settings.toml` | [Settings](../configuration/settings.md). |
| `~/.config/trim/init.lua` | [Your additions](../configuration/your-config.md). |
| `~/.local/share/trim` | nvim's data for Trim: installed packages (`site/pack/trim/start`). |
| `~/.local/state/trim` | nvim's state for Trim. |
| `~/Library/Application Support/trim/run` | Your own run configurations, per project. |
| `~/Library/Caches/trim/servers` | Language servers Trim downloaded. |
| `~/.config/nvim` | **Never read** by Trim. Shim runs it. |

`$XDG_CONFIG_HOME` moves the config folder, and `$TRIM_SETTINGS` names a settings file explicitly.
