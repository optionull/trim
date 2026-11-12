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
- **Runs:** `@run <Name>: <command>` on its own line offers a command to run from the repository's root (the tests
  that show the step working, the program); the person runs it from the notebook into a terminal.

## A review walkthrough

When sill asks for a walkthrough of changes to review, it names the baseline tree, the file to write (inside the
repository's `.sill` folder: a throwaway, never committed) and its `examples` folder. Then:

- **Front matter:** `base: <tree>` as sill gave it; the `@diff`s compare it with the worktree.
- **Sections:** one per idea of the change, not per file, in the order a reviewer should read them: what it does,
  why, what to look at closely. Keep it short.
- **`@diff <path>`** (from the repository's root) shows that file's change under the section about it.
- **`@example examples/<file>`** embeds a usage example: an isolated script beside the walkthrough that exercises
  what changed and prints what it shows. The person runs it in place; `walkthrough_check` runs them all.
  - C#: a .NET file-based app, `examples/total.cs`:
    ```csharp
    #:project /Users/me/code/shop/src/Orders/Orders.csproj
    using Orders;
    Console.WriteLine($"Total(4) = {Pricing.Total(4)}");
    ```
    (`#:package Name@Version` brings a package.) Reach the code by absolute paths in the worktree sill names: the
    review's folder, in `.sill`, is shared by every worktree of the repository.
  - TypeScript: `examples/total.ts`, run by node (types are stripped); import the code with a relative path
    ending in `.ts`.
  - Python: a script with PEP 723 metadata (`# /// script` … `# ///`) for what it needs.
  - Rust: cargo's script format, a `---cargo` manifest with `[dependencies] crate = { path = "…" }` at its top.
  - Swift: a script `swift` runs.

## When you write one

1. Read the code first and choose the path through it a newcomer needs. Usually that's an entry point, then the
   main flow, then the one or two places where the interesting decisions are. If sill's MCP tools are available,
   `code_map` gives the projects, what each references, their entry points and the files that change most, and
   `trace_symbol` who calls a symbol (or what it calls), a few levels deep.
2. Write the file.
3. If sill's MCP tools are available, call `walkthrough_check` with its path and fix every anchor it reports as not
   found and every example that fails. Then call `walkthrough_open` so the person sees it.
4. Tell the person the path, and that `:SillWalk` in sill opens it.

When sill asks you a question on a step, it gives you the step, its code, the walkthrough's path and the question's
line. Answer in a few sentences and call `walkthrough_answer` with that path, line and your answer.
