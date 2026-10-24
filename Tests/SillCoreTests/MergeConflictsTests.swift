import SillCore
import Testing

@Suite("merge conflicts")
struct MergeConflictsTests {
    @Test("git's markers, with a base section or not, CRLF, and look-alikes that are no conflict")
    func count() {
        #expect(MergeConflicts.count(in: "a\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> theirs\nb\n") == 1)
        #expect(MergeConflicts.count(in: "<<<<<<< HEAD\no\n||||||| base\nb\n=======\nt\n>>>>>>> x\n" +
                "<<<<<<< HEAD\no2\n=======\nt2\n>>>>>>> x\n") == 2)
        #expect(MergeConflicts.count(in: "<<<<<<< HEAD\r\no\r\n=======\r\nt\r\n>>>>>>> x\r\n") == 1)
        #expect(MergeConflicts.count(in: "Title\n========\n<<<<<<<< not\n>>>>>>>> not\n") == 0)
        #expect(MergeConflicts.count(in: "<<<<<<< HEAD\no\n========\nt\n>>>>>>> x\n") == 0, "eight = is no separator")
        #expect(MergeConflicts.count(in: "resolved\n") == 0)
    }
}
