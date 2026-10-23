import XCTest
@testable import JanitorCore

final class RulesTests: XCTestCase {
    let cfg = Config()

    func facts(idle: Double, git: Bool = true, configure: (inout WorktreeFacts) -> Void = { _ in }) -> WorktreeFacts {
        var f = WorktreeFacts(path: "/x/wt", isGit: git, idleDays: idle)
        configure(&f)
        return f
    }

    func testMergedNeedsNothingPendingAndTheGracePeriod() {
        let merged = facts(idle: 2) { $0.mergedPR = 7 }
        XCTAssertEqual(WorktreeRules.removalReason(merged, cfg),
                       "merged (PR #7 merged), nothing left to push, untouched for 2.0 days")
        XCTAssertNil(WorktreeRules.removalReason(facts(idle: 0.5) { $0.mergedPR = 7 }, cfg))
        XCTAssertNil(WorktreeRules.removalReason(facts(idle: 2) { $0.mergedPR = 7; $0.dirty = true }, cfg))
        // In main but with local commits beyond it is impossible; in main and pushed is the normal case.
        XCTAssertNotNil(WorktreeRules.removalReason(facts(idle: 2) { $0.mergedIntoMain = true; $0.headOnRemote = true }, cfg))
        XCTAssertNil(WorktreeRules.removalReason(facts(idle: 2) { $0.mergedIntoMain = true; $0.headOnRemote = false }, cfg))
    }

    func testOpenPRNeedsThreeIdleDays() {
        XCTAssertEqual(WorktreeRules.removalReason(facts(idle: 3.5) { $0.openPR = 9 }, cfg),
                       "PR #9 is open and the worktree is untouched for 3.5 days")
        XCTAssertNil(WorktreeRules.removalReason(facts(idle: 2.9) { $0.openPR = 9 }, cfg))
    }

    func testAbandonedIgnoresStateButNotTheMonth() {
        XCTAssertEqual(WorktreeRules.removalReason(facts(idle: 31) { $0.dirty = true; $0.locked = true }, cfg),
                       "abandoned: untouched for 31.0 days")
        XCTAssertEqual(WorktreeRules.removalReason(facts(idle: 31, git: false), cfg), "abandoned: untouched for 31.0 days")
        XCTAssertNil(WorktreeRules.removalReason(facts(idle: 29, git: false), cfg))
        XCTAssertNil(WorktreeRules.removalReason(facts(idle: 29), cfg))
    }

    func testLockedWorktreesOnlyGoWhenAbandoned() {
        XCTAssertNil(WorktreeRules.removalReason(facts(idle: 10) { $0.locked = true; $0.openPR = 1 }, cfg))
    }

    func testForkPRsMatchOnlyByCommit() {
        let fork = PRInfo(number: 5, state: "OPEN", headRefName: "fix-typo", headRefOid: "aaa", isCrossRepository: true)
        XCTAssertNil(WorktreeRules.matchPRs(branch: "fix-typo", head: "bbb", prs: [fork]) { _ in false }.open)
        XCTAssertEqual(WorktreeRules.matchPRs(branch: nil, head: "aaa", prs: [fork]) { _ in false }.open, 5)
        let own = PRInfo(number: 6, state: "OPEN", headRefName: "fix-typo", headRefOid: "ccc", isCrossRepository: false)
        XCTAssertEqual(WorktreeRules.matchPRs(branch: "fix-typo", head: "bbb", prs: [own]) { _ in false }.open, 6)
    }

    func testMergedByNameRequiresHeadInsideThePR() {
        let pr = PRInfo(number: 8, state: "MERGED", headRefName: "feat", headRefOid: "ddd", isCrossRepository: false)
        XCTAssertNil(WorktreeRules.matchPRs(branch: "feat", head: "eee", prs: [pr]) { _ in false }.merged)
        XCTAssertEqual(WorktreeRules.matchPRs(branch: "feat", head: "eee", prs: [pr]) { $0 == "ddd" }.merged, 8)
    }

    func testSafetyRefusesBroadPaths() {
        let home = Paths.home.path
        for p in ["/", "/Users", home, home + "/dev", home + "/dev/engineering", "/private/tmp", "/tmp/x"] {
            XCTAssertThrowsError(try Safety.check(p), p)
        }
        Safety.protectedPaths = ["/Users/x/a/repo"]
        XCTAssertThrowsError(try Safety.check("/Users/x/a/repo"))
        XCTAssertThrowsError(try Safety.check("/Users/x/a"))
        XCTAssertNoThrow(try Safety.check("/Users/x/a/repo/.claude/worktrees/a"))
        Safety.protectedPaths = ["/private/tmp/claude-501"]
        XCTAssertThrowsError(try Safety.check("/private/tmp/claude-501"))
        XCTAssertThrowsError(try Safety.check("/private/tmp/claude-501/x/.."))
        XCTAssertNoThrow(try Safety.check("/private/tmp/claude-501/proj/session"))
        Safety.protectedPaths = []
    }

    func testNormalizeKeepsPrivate() {
        XCTAssertEqual(FS.normalize("/private/var/a/./b/../c"), "/private/var/a/c")
    }

    func testDockerDates() {
        XCTAssertNil(parseDockerDate("0001-01-01T00:00:00Z"))
        XCTAssertEqual(parseDockerDate("2026-10-01T12:00:00.123456789Z")?.timeIntervalSince1970, 1_790_856_000)
    }

    func testPartialConfigKeepsDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("janitor-cfg-\(UUID()).json")
        try Data(#"{"paused": true, "openPRIdleDays": 5}"#.utf8).write(to: url)
        let c = Config.load(from: url)
        XCTAssertTrue(c.paused)
        XCTAssertEqual(c.openPRIdleDays, 5)
        XCTAssertEqual(c.abandonedIdleDays, 30)
        try Config.setPaused(false, at: url)
        XCTAssertFalse(Config.load(from: url).paused)
        XCTAssertEqual(Config.load(from: url).openPRIdleDays, 5)
    }
}
