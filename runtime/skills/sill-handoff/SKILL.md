---
name: sill-handoff
description: Hand a finished coding task to the person in the sill editor, as a short walkthrough of what changed and the commands that show it working. Use whenever you finish a task in a repository the person reads in sill, before telling them you are done.
---

# Handing off to sill

sill is the editor the person keeps open to see what agents did. When you finish a task, leave them a handoff: what
you changed and why, the files to read in the order that makes sense, and what to run to see it work. sill marks it
new on its Home, opens it as a walkthrough, and offers its runs first in the Run pane (`⇧⌘R`).

## With sill's tools

If you have sill's MCP tools, call `sill_handoff`:

- `title`: what you did, as a title ("The tax is rounded once").
- `summary`: a short paragraph, what changed and why.
- `read`: the files, in reading order, each `{path, from, to, why}`. The path is from the checkout's root; `from`
  and `to` are the lines that matter; `why` is one sentence on what to look for there.
- `run`: what shows it working, each `{name, command}`, run from the checkout's root: the tests you added or touched
  (narrowed to them), the program if you changed what it does.
- `by`: who you are.

## Without them

Write the file yourself, into the repository's `.sill/handoffs/` folder at its main checkout (shared by every
worktree of the repository; git ignores it), named `<yyyyMMdd-HHmmss>-<slug>.walk.md`:

```markdown
---
title: The tax is rounded once
worktree: /Users/me/code/shop-tax
by: claude
status: handoff
---
Tax.Of no longer rounds; Pricing.Total rounds the sum once, so a basket of many items is no longer a cent off.

## Read in this order

Where the rounding was.
@code src/Shop/Tax.cs:3-11

Where it is now.
@code src/Shop/Pricing.cs:20-34

## Run it
@run Pricing tests: dotnet test tests/Shop.Tests --filter Pricing
@run Shop: dotnet run --project src/Shop
```

`worktree:` is the checkout you worked in, so sill shows the handoff with it.

## Keep it useful

- A handoff is for the person reading the change after the fact, not a log of what you tried.
- Three to eight files; name the ones that carry the change, not every file touched.
- Every run should finish or start what it names; prefer a filtered test run over the whole suite.
