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
        var edited = c
        edited.paused = false
        edited.disabled = [.avd]
        try edited.save(to: url)
        // Only what differs from the defaults is written, so later default changes still apply.
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(saved.keys.sorted(), ["disabled", "openPRIdleDays"])
        XCTAssertEqual(saved["disabled"] as? [String], ["avd"])
        XCTAssertEqual(Config.load(from: url), edited)
        XCTAssertFalse(Config.load(from: url).enabled(.avd))
        XCTAssertTrue(Config.load(from: url).enabled(.worktree))
    }

    func testKeepMatchesTargetsAndTheirContents() {
        var c = Config()
        c.keep = ["/a/wt", "img:latest (abc)"]
        XCTAssertTrue(c.isKept("/a/wt"))
        XCTAssertTrue(c.isKept("/a/wt/node_modules"))
        XCTAssertFalse(c.isKept("/a/wt2"))
        XCTAssertTrue(c.isKept("img:latest (abc)"))
    }

    func testScheduledRunsOnIntervalOrLowDisk() {
        var c = Config()
        let now = Date()
        let hour: TimeInterval = 3600
        XCTAssertNil(Janitor.scheduledSkipReason(c, lastStart: nil, freeBytes: 100_000_000_000, now: now))
        XCTAssertNotNil(Janitor.scheduledSkipReason(c, lastStart: now - 5 * hour, freeBytes: 100_000_000_000, now: now))
        XCTAssertNil(Janitor.scheduledSkipReason(c, lastStart: now - 6.1 * hour, freeBytes: 100_000_000_000, now: now))
        XCTAssertNil(Janitor.scheduledSkipReason(c, lastStart: now - hour, freeBytes: 19_000_000_000, now: now))
        c.paused = true
        XCTAssertEqual(Janitor.scheduledSkipReason(c, lastStart: nil, freeBytes: 1, now: now), "paused")
    }

    func testSalvageOutlivesItsWorktreeByTheAbandonedThreshold() throws {
        let dir = FS.canonical(FileManager.default.temporaryDirectory.path) + "/janitor-salvage-\(UUID())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for (name, days) in [("old.patch", 31.0), ("new.patch", 29.0)] {
            FileManager.default.createFile(atPath: dir + "/" + name, contents: Data())
            let t = time_t(Date().addingTimeInterval(-days * 86400).timeIntervalSince1970)
            var times = [timeval(tv_sec: t, tv_usec: 0), timeval(tv_sec: t, tv_usec: 0)]
            utimes(dir + "/" + name, &times)
        }
        var c = Config()
        c.salvageDir = dir
        var logged: [String] = []
        Janitor.pruneSalvage(c, now: Date()) { logged.append($0) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["new.patch"])
        XCTAssertEqual(logged, ["removed salvage \(dir)/old.patch"])
    }
}
