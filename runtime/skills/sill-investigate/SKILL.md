---
name: sill-investigate
description: Investigate a question about a codebase through the sill editor (why something happens, where a bug comes from, how something works, what a change would touch), collecting the evidence in a sill basket the person watches fill, and concluding with findings. Use when asked to investigate, dig into, find out why, or find the cause of something, and sill's MCP tools are available.
---

# Investigating through sill

An investigation answers one question from the code, with the evidence in view. You keep it in a **basket**: a
notebook in sill (`.sill/baskets/*.basket.md`, private to the repository) that the person sees fill as you work, and
that ends with your findings. Investigating is **read-only**: do not change code, build files or configuration. Fixing
comes after the person has read the findings.

## How

1. **Start the basket.** Call `basket_create` with a short title (what is being found out, as a sentence) and the
   question as asked. sill opens it. Every later `basket_*` call names it with the file name `basket_create` returned.
2. **Orient.** `code_map` for the projects, what each builds on and where they start, if the code is new to you.
   Then from the symptom: `trace_symbol` to see who calls the code involved (or what it calls).
3. **Collect evidence as you go.** Each place that matters goes in with `basket_add`: a symbol (`Type.Member`) or a
   file and lines, and a note saying why it matters, in a sentence. Group them with `section` (a heading per thread
   of the investigation: "Where the total is computed", "Who calls it"). Add a call tree with `basket_note` and
   `@trace Symbol callers 2` on a line of its own when the path matters. Add what you ruled out too, briefly: it saves
   the person checking it.
4. **Look at it running when reading is not enough**, with sill's tools (each asks the person first):
   - `debug_start` or `debug_attach`, `debug_breakpoint`, `debug_step`, `debug_state`, `debug_evaluate`: the state
     at the moment it goes wrong. Put what you saw in a note.
   - `profile_start`, `profile_snapshot`, `profile_compare`: where the time or memory goes.
   - `telemetry_watch`, `telemetry_logs`, `telemetry_traces`, `telemetry_metrics`: what a running program logs and
     how long its requests take.
   - `problems` for what the compiler says.
5. **Reproduce it when you can**: an isolated script beside the basket (`.sill/baskets/examples/<file>`), shown with
   `basket_note` and `@example examples/<file>` on a line of its own. The forms are the walkthrough skill's: for C# a
   .NET 10 file-based app with `#:project <path to the .csproj, relative to the script>`.
6. **Conclude** with `basket_conclude`: the answer first, in a sentence or two; then why you are sure (or how sure you
   are, and what would settle it); what is still open; and the next steps you suggest. Name code in `code spans`.
   Keep it short: the evidence is above it.

Tell the person the basket's name, and that `:SillBasket` in sill opens it. If they add pieces and send it back with a
question, answer the same way: `basket_conclude` again replaces the findings.
