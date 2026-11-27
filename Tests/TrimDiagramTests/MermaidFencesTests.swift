import Testing
@testable import TrimDiagram

@Suite("Mermaid blocks of a Markdown text")
struct MermaidFencesTests {
    @Test("a block is its fence lines and its diagram, before the first step or after, among other fences")
    func finds() {
        let text = """
        # Title

        ```mermaid
        graph TD
          A-->B
        ```

        ## Step
        ```swift
        let x = 1
        ```
          ```mermaid
          sequenceDiagram
            A->>B: hi
          ```
        """
        let found = MermaidFences.find(in: text)
        #expect(found.count == 2)
        #expect(found[0] == MermaidFence(first: 3, last: 6, source: "graph TD\n  A-->B"))
        #expect(
            found[1].first == 12 && found[1].last == 15 && found[1].source.contains("sequenceDiagram"),
            "an indented fence is one"
        )
    }

    @Test("a mermaid fence shown inside another fenced block is not a diagram, and an unclosed one is not either")
    func skips() {
        let shown = "````text\n```mermaid\ngraph TD\n```\n````"
        // (A fence of four backticks closes at the first line of backticks here: the text is a Markdown example, not a
        // diagram.)
        #expect(MermaidFences.find(in: "```text\n```mermaid\ngraph TD\n  A-->B\n```\n").isEmpty)
        #expect(MermaidFences.find(in: "```mermaid\ngraph TD\n  A-->B").isEmpty)
        #expect(MermaidFences.find(in: "no fences here").isEmpty)
    }
}
