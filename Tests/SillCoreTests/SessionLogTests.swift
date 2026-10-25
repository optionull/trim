import SillCore
import Testing

@Suite struct SessionLogTests {
    let log = """
    {"at":"2026-10-25T18:36:37Z","hook_event_name":"UserPromptSubmit","permission_mode":"plan","prompt":"Make the tax round once"}
    {"at":"2026-10-25T18:36:37Z","of":"UserPromptSubmit","tree":"aaa"}
    {"at":"2026-10-25T18:36:38Z","hook_event_name":"PostToolUse","tool_name":"Read","file_path":"/repo/Tax.cs"}
    {"at":"2026-10-25T18:36:40Z","hook_event_name":"PreToolUse","tool_name":"ExitPlanMode"}
    {"at":"2026-10-25T18:36:40Z","hook_event_name":"PostToolUse","tool_name":"ExitPlanMode"}
    {"at":"2026-10-25T18:36:41Z","hook_event_name":"PreToolUse","tool_name":"Edit","file_path":"/repo/Pricing.cs"}
    {"at":"2026-10-25T18:36:41Z","hook_event_name":"PostToolUse","tool_name":"Edit","file_path":"/repo/Pricing.cs"}
    {"at":"2026-10-25T18:36:42Z","hook_event_name":"PostToolUse","tool_name":"Edit","file_path":"/repo/Pricing.cs"}
    {"at":"2026-10-25T18:36:43Z","hook_event_name":"PostToolUse","tool_name":"Bash","command":"dotnet test"}
    {"at":"2026-10-25T18:36:44Z","hook_event_name":"Stop"}
    {"at":"2026-10-25T18:36:44Z","of":"Stop","tree":"bbb"}
    not json
    {"at":"2026-10-25T18:40:00Z","hook_event_name":"UserPromptSubmit","prompt":"And the tests"}
    """

    @Test func turnsFromPrompts() throws {
        let session = SessionLog(log, root: "/repo")
        #expect(session.turns.count == 2)
        #expect(session.title == "Make the tax round once")
        let first = session.turns[0]
        #expect(first.mode == "plan" && first.before == "aaa" && first.after == "bbb" && first.ended != nil)
        #expect(first.steps.map(\.tool) == ["Read", "plan", "approved", "Edit", "Edit", "Bash"])
        #expect(first.steps.map(\.detail) == [
            "Tax.cs", "presented for approval", "the plan", "Pricing.cs", "Pricing.cs", "dotnet test",
        ])
        #expect(first.written == ["Pricing.cs"])
        #expect(session.turns[1].prompt == "And the tests" && session.turns[1].ended == nil)
    }

    @Test func toolsBeforeAnyPromptAreATurnWithout() {
        let session = SessionLog("""
        {"hook_event_name":"PostToolUse","tool_name":"Write","file_path":"/elsewhere/a.txt"}
        """, root: "/repo")
        #expect(session.turns.count == 1 && session.turns[0].prompt.isEmpty)
        #expect(session.turns[0].written == ["/elsewhere/a.txt"])
        #expect(session.title == "A session")
    }
}
