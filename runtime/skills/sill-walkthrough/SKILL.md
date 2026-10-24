---
name: sill-walkthrough
description: Write a walkthrough (a *.walk.md file) that walks a person through code step by step in the sill editor. Use when asked to explain how something in a codebase works, to onboard someone to unfamiliar code, or for a walkthrough or tour of code.
---

# Writing a sill walkthrough

A walkthrough is a Markdown file ending in `.walk.md`, anywhere in the repository (next to the code it explains, or
under `docs/`). sill shows it step by step: each step's prose beside the code it points at, as that code is now.

## The format

```markdown
---
title: How an order reaches the database
for: Orders.slnx
---
One or two sentences on what this walks through and why it matters.

## The request comes in
What happens here, in a few sentences. Name things in `code spans`.
@code OrdersController.Create

## Pricing
@code Pricing.Total
@code src/Orders/Pricing.cs:40-52
@ask Why is the total not cached?
```

- **Front matter:** `title` (what it explains, as a sentence a person would search for) and `for` (the solution,
  project or folder).
- **Steps:** each `## heading` is one step, in the order a person should read the code. 4 to 10 steps; one idea each.
- **Prose:** short and concrete. Say what the code does and why, what to notice, and what connects it to the next
  step. Don't repeat the code in prose.
- **Anchors:** `@code` on its own line.
  - **A symbol first:** `@code Pricing.Total` (`Type.Member`, or just `Type`). sill finds it with the language server,
    so the anchor survives edits. `@code Pricing.Total lines 3-9` shows only those lines of it, counted from its
    first.
  - **A file and lines** when there is no symbol (configuration, markup, a script): `@code appsettings.json:1-20`,
    relative to the walkthrough's folder or the repository's root.
- **Questions:** `@ask <question>` on its own line marks a question worth asking about the step. When one is asked,
  the answer is written right under it as a `>` quote. Don't write answers yourself unless asked.

## When you write one

1. Read the code first and choose the path through it a newcomer needs. Usually that's an entry point, then the
   main flow, then the one or two places where the interesting decisions are.
2. Write the file.
3. If sill's MCP tools are available, call `walkthrough_check` with its path and fix every anchor it reports as not
   found. Then call `walkthrough_open` so the person sees it.
4. Tell the person the path, and that `:SillWalk` in sill opens it.

When sill asks you a question on a step, it gives you the step, its code, the walkthrough's path and the question's
line. Answer in a few sentences and call `walkthrough_answer` with that path, line and your answer.
