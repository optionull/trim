---
navigation_title: "Language servers"
description: "How Trim finds, starts, isolates and restarts language servers."
---

# Language servers

Servers run on their own and come back when they crash. They also start when you open a folder, from its
project files and without a file open, so the problems list and the tree's marks fill in from the start.

| Project file | Server |
|---|---|
| `.sln`, `.slnx`, `.csproj` | Roslyn (C#), loaded on the solution |
| `.fsproj` | fsautocomplete (F#) |
| `Cargo.toml` | rust-analyzer |
| `Package.swift` | sourcekit-lsp |
| `tsconfig.json`, `package.json` | TypeScript |

A server also starts the first time a file of its kind opens: C#, F#, Rust, Swift, Markdown, HTML, CSS, JSON,
TypeScript and JavaScript, unless your own config already runs one.

## Where they come from

Trim uses the program on your `PATH` (also rustup's, Xcode's and mise's), or else downloads it into its own cache
at a pinned version with the checksum checked (marksman, rust-analyzer), installs it as a .NET tool (Roslyn,
fsautocomplete: the **.NET SDK must be installed**) or with npm (the web servers: **Node must be installed**).
Trim says so when either is missing.

## When one dies

A server that dies is started again after a wait that doubles (1 second up to 30) and given up on after five deaths
inside a minute. The status bar shows `name ↻` while it waits and `name ✗` once given up on. nvim itself is never
touched.

```
:TrimLsp status
:TrimLsp restart csharp
:TrimLsp stop csharp
```

`<leader>lR` restarts them. `[lsp] autostart = false` in the settings leaves starting to opening a file.

## What they are busy with

Indexing, loading projects and analysing files appear as rows in a progress toast at the bottom left of the code.
Servers that can report diagnostics for the whole workspace are asked to, so the problems list covers files you
never opened. A server that only reports for open files (sourcekit-lsp) needs the file open, or a build.

## Keys on a buffer with a server

`gd` `gy` `gr` `gI` go to the definition, type, usages and implementations. `<leader>ls` and `lS` list the symbols
of the file and the workspace. `<leader>la`, Alt+Enter or ⌘. offers code actions, `lr` renames, `lf` formats,
`ld` `ll` show diagnostics. Lists of answers are drawn by Trim in its own list: type `/` to filter, Return goes
there, and one answer is gone to at once.
