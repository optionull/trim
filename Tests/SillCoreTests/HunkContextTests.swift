@testable import SillCore
import Testing

@Suite("a hunk's context")
struct HunkContextTests {
    func hunk(_ header: String) -> Review.Hunk {
        Review.Hunk(header: header, oldStart: 5, oldCount: 1, newStart: 5, newCount: 1, lines: [])
    }

    @Test("what git names after the second @@, else nothing")
    func context() {
        #expect(hunk("@@ -5 +5 @@ public static decimal Of(decimal net)").context ==
            "public static decimal Of(decimal net)")
        #expect(hunk("@@ -5,2 +5,3 @@").context == nil)
        #expect(hunk("@@ -1 +1 @@   ").context == nil)
        #expect(hunk("").context == nil)
    }
}
