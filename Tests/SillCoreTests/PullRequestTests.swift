import Foundation
import SillCore
import Testing

@Suite struct PullRequestTests {
    let json = """
    [{"number": 12, "title": "Round the tax once", "url": "https://example.test/pr/12", "state": "OPEN",
      "headRefName": "round-tax-once",
      "isDraft": false, "baseRefName": "main", "mergeable": "CONFLICTING", "reviewDecision": "CHANGES_REQUESTED",
      "updatedAt": "2026-10-25T12:00:00Z",
      "statusCheckRollup": [
        {"__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "FAILURE",
         "detailsUrl": "https://example.test/run/1"},
        {"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "SUCCESS"},
        {"__typename": "CheckRun", "name": "test", "status": "IN_PROGRESS", "conclusion": ""},
        {"__typename": "CheckRun", "name": "label", "status": "COMPLETED", "conclusion": "SKIPPED"},
        {"__typename": "StatusContext", "context": "ci/legacy", "state": "ERROR", "targetUrl": "https://example.test/s"}
      ],
      "latestReviews": [{"author": {"login": "ana"}, "state": "CHANGES_REQUESTED", "body": "Round in one place.",
                         "submittedAt": "2026-10-25T11:00:00Z"}],
      "comments": [{"author": {"login": "bot"}, "body": "Thanks!", "createdAt": "2026-10-25T10:00:00Z"}]},
     {"number": 9, "title": "Older", "url": "", "state": "MERGED", "baseRefName": "main",
      "updatedAt": "2026-10-01T12:00:00Z"}]
    """

    @Test func readsGhsJSON() throws {
        let prs = PullRequest.parse(Data(json.utf8))
        #expect(prs.map(\.number) == [12, 9])
        let pr = try #require(prs.first)
        #expect(pr.checks.map(\.state) == [.failed, .passed, .pending, .skipped, .failed])
        #expect(pr.checks.last?.name == "ci/legacy" && pr.checks.first?.link == "https://example.test/run/1")
        #expect(pr.remarks.map(\.author) == ["bot", "ana"])
        #expect(PullRequest.parse(Data("not json".utf8)).isEmpty)
    }

    @Test func insightsMostPressingFirst() throws {
        let pr = try #require(PullRequest.parse(Data(json.utf8)).first)
        let insights = pr.insights(PullRequest.Branch(name: "tax", unpushed: 1, behind: 3, uncommitted: 2))
        #expect(insights.map(\.text) == [
            "2 checks failing: build, ci/legacy",
            "Changes requested by ana",
            "Conflicts with main: it cannot merge as it is",
            "1 commit here not pushed: the pull request does not have it",
            "1 check running",
            "3 commits behind main (as of the last fetch)",
            "2 files changed, not committed",
        ])
        #expect(pr.label(nil) == "#12 · 2 checks failing")
        let text = pr.text(nil)
        #expect(text.contains("Failing: build https://example.test/run/1"))
        #expect(text.contains("- ana (changes requested): Round in one place."))
    }

    /// Home: each PR's branch, to find its checkout by; the PR in a few words, as loud as its worst.
    @Test func forHome() throws {
        let prs = PullRequest.parse(Data(json.utf8))
        #expect(prs.map(\.head) == ["round-tax-once", ""])
        let (said, level) = HomeList.pullRequest(prs[0])
        #expect(said.hasPrefix("PR #12 · 2 checks failing") && level == .attention)
        #expect(HomeList.pullRequest(prs[1]).level == .fine)
    }

    @Test func mergedSaysSo() throws {
        let merged = try #require(PullRequest.parse(Data(json.utf8)).last)
        #expect(merged.insights(PullRequest.Branch(name: "x", unpushed: 4)).map(\.text) == ["Merged into main"])
    }

    @Test func bodiesWithoutTheirHTMLComments() throws {
        let json = """
        [{"number": 1, "latestReviews": [{"author": {"login": "bot"}, "state": "COMMENTED",
          "body": "Looks fine.\\n<!-- bot-id: 42\\nrun: 7 -->\\n"}]}]
        """
        let pr = try #require(PullRequest.parse(Data(json.utf8)).first)
        #expect(pr.remarks.first?.body == "Looks fine.")
    }
}
