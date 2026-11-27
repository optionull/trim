/// The skill that teaches an agent to write a walkthrough Trim can show: printed by `trim walk format` and installed by
/// `trim skill install` as `trim-walkthrough/SKILL.md`.
public enum WalkSkill {
    public static let name = "trim-walkthrough"

    public static let text = #"""
    ---
    name: trim-walkthrough
    description: Write a walkthrough (a *.walk.md file) that explains code to a person step by step in Trim, anchored to the real code, with diagrams and checklists. Use when asked to explain how something works, to onboard someone to unfamiliar code, to walk through a change or a pull request for review, to investigate a failing test, or for a handoff at the end of a session.
    ---

    # Writing a Trim walkthrough

    A walkthrough is a Markdown file ending in `.walk.md` that Trim shows as a guided reading: each step's prose beside the
    code it points at, as that code is now, with diagrams and checklists. A person reads it in Trim and can ask questions
    back. Write it for someone who has not seen this code.

    ## Where to write it, and the loop

    1. `trim walk new "<title>"` makes a skeleton and prints its path. It goes in the `.trim/walkthroughs/` of the
       repository's main checkout, shared by all its worktrees (private, never committed); that is expected, whichever
       worktree you are in. To write one that is meant to be committed, put the file anywhere in the repository instead
       (docs/, next to the code).
    2. Replace the skeleton: its placeholder paragraph, its `@code <...>` line and `for:` are examples. Keep the shape of the
       front matter and the `# Title` line. Trim picks the file up as soon as it is saved and shows it as new.
    3. `trim walk check <file>` and fix everything it reports: anchors that are not found, diagrams of no known kind, steps
       that show no code, two anchors that land on the same code. Repeat until it says ok. `check` proves the anchors exist,
       not that they mean what you wrote.
    4. `trim walk resolve <file>` prints where each anchor lands: the file, the lines and the first line of code. Read every
       line of it. If a symbol name occurs in more than one type (an `open` on two classes), qualify it with the type
       (`TrimWindowController.open`) and look again; an anchor that lands on a different type's member is wrong even though
       `check` is happy.
    5. `trim walk stamp <file>` records what each anchor looked like now and the commit, so a later reader is told which steps
       went stale. Never write fingerprints yourself. `trim walk stamp` leaves recorded fingerprints alone; after you have read
       the steps `check` calls changed and found them still true, `trim walk stamp --refresh` records them again.

    ## The format

    ```markdown
    ---
    for: Orders.slnx
    by: claude
    ---
    # How an order reaches the database

    One or two sentences on what this explains and why it matters.

    ## The request comes in
    What happens here, in a few sentences. Name things in `code spans`.
    @code OrdersController.Create

    ## Pricing
    @code Pricing.Total
    @code src/Orders/Pricing.cs:40-52
    @ask Why is the total not cached?

    ## The call path
    ```mermaid
    sequenceDiagram
      Client->>Orders: POST /orders
      Orders->>Pricing: Total
    ```
    @link Orders -> OrdersController.Create
    @link Pricing -> Pricing.Total

    ## Before you merge
    - [ ] Tests pass
    - [ ] Pricing change reviewed
    @run Tests: dotnet test
    ```

    - **Title:** the first line after the front matter is `# Title`, a sentence a person would search for. Do not put `title:` in the front matter.
    - **Front matter:** `for` (solution, project or folder), `by` (you), `model`. `trim walk stamp` adds `commit` and `created`.
    - **Steps:** each `## heading` is one step, in the order a person should read. 3 to 10 steps (the shapes below say how many suit each), one idea each. Open with
      the headline sentence, then the detail.
    - **Prose:** short and concrete: what the code does and why, what to notice, what connects it to the next step. Do not
      paste code into prose; anchor it.
    - **Anchors:** `@code` on its own line.
      - A symbol first: `@code Pricing.Total` (`Type.Member`, or `Type`). It survives edits. `@code Pricing.Total lines 3-9`
        shows only those lines of it, counted from its first.
      - A file and lines when there is no symbol: `@code appsettings.json:1-20` (relative to the walkthrough's folder or the
        repository's root).
    - **Diagrams:** a ```` ```mermaid ```` fence inside a step (give a diagram that frames the whole thing its own first step,
      `## The shape of it`; do not put one before the first step), only when the picture carries weight: a sequence diagram for a call path, a
      state diagram for a lifecycle, a flowchart for a pipeline. Keep it under about 15 nodes. After it, `@link Node -> anchor`
      lines make nodes jump to code when chosen.
      A diagram may move: an `animate` block at the end of the fence (see Mermaider.Animate) plays in Trim while it is on screen; use it
      only when the movement is the explanation (a request's path, a failure spreading).
    - **Tables and callouts:** ordinary Markdown tables for comparisons (Trim draws them as aligned grids). Callouts are
      `> [!kind] text` with the kind one of note, tip, important, warning, caution, risk, question, verified, asserted: `warning`
      or `risk` for what to be careful of, `verified` for a claim you checked by running it, `asserted` for one you only read
      in the code. Write the text on the same line; it is wrapped for you.
    - **Questions:** `@ask <question>` marks a question worth asking about the step. When one is asked the answer is written
      under it as a `>` quote. Do not write answers yourself.
    - **Checklists:** `- [ ] item`. The person ticks them in Trim; the file keeps the state.
    - **Runs:** `@run <Name>: <command>` offers a command (tests, a repro) from the repository's root. Trim shows it as a
      button-like line; the person chooses to run it (Enter on the line, output in the Run pane), so never write one that
      changes anything.
    - **Evidence:** if you ran something to learn this, say what you ran and what it printed (`@run`, or a table of the
      numbers). Mark claims you checked ("verified by running ...") apart from ones you read in the code.

    ## Shapes that work

    - **Explain how X works:** 3 to 6 steps, a call-path diagram, an `@ask` on the step that is least obvious.
    - **Review a change (a worktree, a pull request):** group by *intent*, not by file: what it does, why, what to look at
      closely. Per group: prose, `@diff <path>` for the files, a `> [!warning]` for the risk, a checklist at the end.
    - **Onboard to a repository:** an architecture diagram first, 8 to 10 steps, "read next" at the end.
    - **Understand a failing test:** the failing assertion, the call path as a sequence diagram, where behaviour diverges,
      the evidence, and the hypothesis stated as verified or not.
    - **Handoff at the end of a session:** what you did and in what order, the files to read first with a line on why each,
      what to run, what you are unsure of.

    ## Rules

    - Anchor to code that exists now; `trim walk check` proves it. Do not invent symbols.
    - One idea per step. If a step needs three diagrams it is three steps.
    - Never put secrets or credentials in a walkthrough.
    """#
}
