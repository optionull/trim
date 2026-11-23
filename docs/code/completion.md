---
navigation_title: "Completion and hover"
description: "The completion menu, its documentation panel, hover and signature help with overloads, drawn by the window."
---

# Completion and hover

Completion comes from the language server as you type. The menu, the documentation beside it, `K` and signature
help are drawn by Trim's window rather than by nvim's floating windows, so they never fight each other for room.

## The menu

The menu comes up on every letter, digit and `.`, matched fuzzily. Each candidate has an icon and a colour for its
kind (method, field, property, class...), and deprecated ones are struck through and muted.

| Key | What it does |
|---|---|
| Tab, Shift-Tab | Walk the menu, or a snippet's places. |
| Enter | Take the one chosen. |
| Ctrl-Space | Ask for the menu. |

The documentation of the chosen candidate is in a panel beside the menu, never over it. If there is no room beside
a wide menu it goes above or under.

## Hover and signatures

`K` shows what the server says about the symbol under the cursor, at the cursor. Ctrl-S shows the signature of what
is being called, and it comes up by itself on `(` and `,` with the parameter you are typing underlined. When there
are overloads the header says "2 of 6 overloads" and Alt-Down and Alt-Up step through them. The panel goes when the
cursor moves.

## Documentation

Documentation is cleaned of markdown escapes and HTML entities. Its code blocks are coloured by tree-sitter in
whatever language the fence names (the buffer's own when it names none), in the editor's colours. A language
without a parser shows its code uncoloured.
