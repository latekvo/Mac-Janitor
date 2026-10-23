import XCTest
@testable import JanitorCore

/// Drives WorktreeJanitor against a real repo with backdated worktrees.
final class WorktreeIntegrationTests: XCTestCase {
    var root = ""
    var repo: String { root + "/repo" }
    var wts: String { root + "/wts" }

    @discardableResult
    func sh(_ args: [String], cwd: String? = nil) -> String {
        let r = Shell.run(args, cwd: cwd ?? repo)
        XCTAssertTrue(r.ok, "\(args.joined(separator: " ")): \(r.stderr)")
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ path: String, _ text: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func backdate(_ path: String, days: Double) {
        let t = time_t(Date().addingTimeInterval(-days * 86400).timeIntervalSince1970)
        var times = [timeval(tv_sec: t, tv_usec: 0), timeval(tv_sec: t, tv_usec: 0)]
        lutimes(path, &times)
        FS.walk(path) { p, _, _, _ in lutimes(p, &times); return true }
    }

    /// Backdates a worktree and the HEAD/index git keeps for it.
    func age(_ name: String, days: Double) {
        backdate(wts + "/" + name, days: days)
        backdate(repo + "/.git/worktrees/" + name, days: days)
    }

    func commit(_ msg: String, in dir: String) {
        sh(["git", "commit", "-q", "--allow-empty", "-m", msg], cwd: dir)
    }

    override func setUpWithError() throws {
        // Canonical, because git and the janitor report /private/var where temporaryDirectory says /var.
        root = FileManager.default.temporaryDirectory.appendingPathComponent("janitor-it-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: wts, withIntermediateDirectories: true)
        root = FS.canonical(root)
        sh(["git", "init", "-q", "--bare", "-b", "main", root + "/origin.git"], cwd: root)
        sh(["git", "clone", "-q", root + "/origin.git", repo], cwd: root)
        sh(["git", "config", "user.email", "t@example.com"])
        sh(["git", "config", "user.name", "t"])
        try write(repo + "/a.txt", "one\n")
        try write(repo + "/.gitignore", "node_modules\n")
        sh(["git", "add", "a.txt", ".gitignore"])
        sh(["git", "commit", "-q", "-m", "init"])
        sh(["git", "push", "-q", "origin", "main"])
        sh(["git", "remote", "set-head", "origin", "main"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    func testPlanGuardsAndExecution() throws {
        for name in ["merged", "fresh", "donor", "busy", "old"] {
            sh(["git", "worktree", "add", "-q", "--detach", wts + "/" + name])
        }
        sh(["git", "worktree", "add", "-q", "-b", "feature", wts + "/active"])
        commit("unpushed work", in: wts + "/active")
        sh(["git", "worktree", "add", "-q", "-b", "stale", wts + "/stale"])
        commit("unpushed work", in: wts + "/stale")
        commit("detached work", in: wts + "/old")
        let oldHead = sh(["git", "rev-parse", "HEAD"], cwd: wts + "/old")

        try write(wts + "/donor/node_modules/pkg/index.js", "x")
        try FileManager.default.createDirectory(atPath: wts + "/active/node_modules", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: wts + "/active/node_modules/pkg",
                                                   withDestinationPath: wts + "/donor/node_modules/pkg")
        try write(wts + "/stale/node_modules/pkg/index.js", "x")
        try write(wts + "/stale/packages/p/node_modules/q/index.js", "x")
        try FileManager.default.createDirectory(atPath: wts + "/merged/node_modules/.vite", withIntermediateDirectories: true)
        try write(wts + "/old/a.txt", "changed\n")
        try write(wts + "/old/new.txt", "untracked\n")
        try write(wts + "/copy/file.txt", "plain copy")
        try write(wts + "/foreign/.git/HEAD", "ref: refs/heads/main\n")

        age("merged", days: 2)
        age("donor", days: 2)
        age("busy", days: 2)
        age("stale", days: 5)
        age("old", days: 40)
        backdate(wts + "/copy", days: 40)
        backdate(wts + "/foreign", days: 40)

        // A test run's cache, written after the install, is not activity for the whole-worktree rules.
        try write(wts + "/merged/node_modules/.vite/results.json", "{}")

        let busyHandle = try XCTUnwrap(FileHandle(forReadingAtPath: wts + "/busy/a.txt"))
        defer { busyHandle.closeFile() }

        var cfg = Config()
        cfg.argentRepo = repo
        cfg.worktreeRoots = [wts]
        cfg.salvageDir = root + "/salvage"
        Safety.protectedPaths = [repo, wts, root]
        defer { Safety.protectedPaths = [] }

        let janitor = WorktreeJanitor(cfg: cfg, guards: Guards.gather())
        let plan = janitor.plan()

        let whole = Set(plan.filter { $0.action.category == .worktree }.map(\.action.target))
        XCTAssertEqual(whole, [wts + "/merged", wts + "/old", wts + "/copy"])
        let modules = Set(plan.filter { $0.action.category == .nodeModules }.map(\.action.target))
        XCTAssertEqual(modules, [wts + "/stale/node_modules", wts + "/stale/packages/p/node_modules"])

        let skips = Dictionary(uniqueKeysWithValues: janitor.skips.map { ($0.target, $0.reason) })
        XCTAssertTrue(skips[wts + "/donor"]?.contains("\(wts)/active links into it") == true, "\(skips)")
        XCTAssertTrue(skips[wts + "/busy"]?.contains("in use") == true, "\(skips)")
        XCTAssertTrue(skips[wts + "/foreign"]?.contains("not registered") == true, "\(skips)")
        XCTAssertEqual(skips.count, 3, "\(skips)")

        let results = plan.map(janitor.execute)
        XCTAssertEqual(results.filter { $0.status != .removed }.map(\.target), [])

        for gone in ["merged", "old", "copy", "stale/node_modules", "stale/packages/p/node_modules"] {
            XCTAssertFalse(FS.exists(wts + "/" + gone), gone)
        }
        for kept in ["fresh", "donor/node_modules/pkg/index.js", "active", "stale/.git", "busy", "foreign"] {
            XCTAssertTrue(FS.exists(wts + "/" + kept), kept)
        }
        let listed = sh(["git", "worktree", "list", "--porcelain"])
        XCTAssertFalse(listed.contains(wts + "/merged"))
        XCTAssertFalse(listed.contains(wts + "/old"))
        XCTAssertTrue(listed.contains(wts + "/stale"))

        // The detached commit, the edit and the untracked file all survive.
        let salvage = try XCTUnwrap(results.first { $0.target == wts + "/old" }?.salvage)
        let ref = try XCTUnwrap(sh(["git", "for-each-ref", "--format=%(refname)", "refs/janitor"]).split(separator: "\n").first)
        XCTAssertEqual(sh(["git", "rev-parse", String(ref)]), oldHead)
        let files = try FileManager.default.contentsOfDirectory(atPath: cfg.salvageDir)
        let patch = try XCTUnwrap(files.first { $0.hasSuffix(".patch") })
        XCTAssertTrue(try String(contentsOfFile: cfg.salvageDir + "/" + patch, encoding: .utf8).contains("+changed"))
        let tgz = try XCTUnwrap(files.first { $0.hasSuffix("-untracked.tgz") })
        XCTAssertEqual(sh(["tar", "-tzf", cfg.salvageDir + "/" + tgz], cwd: root), "new.txt")
        XCTAssertTrue(salvage.contains(String(ref)), salvage)
        // Merged and pushed: nothing to keep.
        XCTAssertNil(results.first { $0.target == wts + "/merged" }?.salvage)
    }
}
