import XCTest
@testable import JanitorCore

/// Drives WorktreeJanitor against a real repo with backdated worktrees.
final class WorktreeIntegrationTests: XCTestCase {
    var root = ""
    var repo: String { root + "/repo" }
    var wts: String { root + "/repo-worktrees" }

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
        Safety.protectedPaths = []
        try? FileManager.default.removeItem(atPath: root)
    }

    func config() -> Config {
        var cfg = Config()
        cfg.repos = [repo]
        cfg.salvageDir = root + "/salvage"
        Safety.protectedPaths = [repo, wts, root]
        return cfg
    }

    func link(_ path: String, to dest: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: dest)
    }

    func testDonorLinksKeepAndOnly() throws {
        for name in ["donor", "donor2", "donor3", "idleHolder", "activeHolder", "busyHolder", "pinned"] {
            sh(["git", "worktree", "add", "-q", "--detach", wts + "/" + name])
        }
        try write(wts + "/donor/node_modules/a/index.js", "x")
        try write(wts + "/donor/packages/p/node_modules/b/index.js", "x")
        try write(wts + "/donor2/node_modules/@s/c/index.js", "x")
        // An idle borrower: its node_modules is only a link, so it is not planned itself.
        try link(wts + "/idleHolder/node_modules", to: wts + "/donor/node_modules")
        // An active borrower of a package-level node_modules, not the root one.
        try link(wts + "/activeHolder/packages/p/node_modules", to: wts + "/donor/packages/p/node_modules")
        // An idle borrower whose own node_modules is in use, so it stays and keeps its link live.
        try write(wts + "/busyHolder/node_modules/open.txt", "x")
        try link(wts + "/busyHolder/node_modules/@s/c", to: wts + "/donor2/node_modules/@s/c")
        try write(wts + "/pinned/node_modules/d/index.js", "x")
        // The main checkout borrows too, and is never idle.
        try write(wts + "/donor3/node_modules/e/index.js", "x")
        try link(repo + "/node_modules", to: wts + "/donor3/node_modules")
        for name in ["donor", "donor2", "donor3", "idleHolder", "busyHolder", "pinned"] { age(name, days: 5) }
        let busy = try XCTUnwrap(FileHandle(forReadingAtPath: wts + "/busyHolder/node_modules/open.txt"))
        defer { busy.closeFile() }

        var cfg = config()
        cfg.disabled = [.worktree]
        cfg.keep = [wts + "/pinned"]
        let janitor = WorktreeJanitor(cfg: cfg, guards: Guards.gather())
        let plan = janitor.plan()

        XCTAssertEqual(plan.map(\.action.target), [wts + "/donor/node_modules"])
        XCTAssertTrue(plan.allSatisfy { $0.action.bytes > 0 })
        let skips = Dictionary(uniqueKeysWithValues: janitor.skips.map { ($0.target, $0) })
        XCTAssertEqual(Set(skips.keys), [wts + "/donor/packages/p/node_modules", wts + "/donor2/node_modules",
                                         wts + "/busyHolder/node_modules", wts + "/pinned/node_modules",
                                         wts + "/donor3/node_modules"])
        XCTAssertTrue(skips[wts + "/donor3/node_modules"]!.reason.hasSuffix("\(repo) links into it"))
        XCTAssertTrue(skips[wts + "/donor/packages/p/node_modules"]!.reason.hasSuffix("\(wts)/activeHolder links into it"))
        XCTAssertTrue(skips[wts + "/donor2/node_modules"]!.reason.hasSuffix("\(wts)/busyHolder links into it"))
        XCTAssertTrue(skips[wts + "/busyHolder/node_modules"]!.reason.contains("in use"))
        XCTAssertEqual(skips[wts + "/pinned/node_modules"]!.kept, true)
        XCTAssertGreaterThan(skips[wts + "/pinned/node_modules"]!.bytes, 0)
        XCTAssertEqual(skips.values.filter(\.kept).count, 1)

        // `only` narrows a run to the ids the caller saw; links it never saw still release donors.
        let id = "node_modules:\(wts)/donor/node_modules"
        let narrowed = WorktreeJanitor(cfg: cfg, guards: Guards.gather(), only: [id]).plan()
        XCTAssertEqual(narrowed.map(\.action.id), [id])
        XCTAssertEqual(WorktreeJanitor(cfg: cfg, guards: Guards.gather(), only: []).plan().count, 0)

        // Removing node_modules must not make the worktree look recently used.
        XCTAssertEqual(plan.map(janitor.execute).map(\.status), [.removed])
        XCTAssertTrue(FS.exists(wts + "/donor/packages/p/node_modules/b/index.js"))
        let tree = janitor.scanTree(wts + "/donor", nested: [])
        XCTAssertGreaterThan(janitor.idleDays(wts + "/donor", newestFile: tree.newest), 4.9)
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

        let cfg = config()
        let janitor = WorktreeJanitor(cfg: cfg, guards: Guards.gather())
        let plan = janitor.plan()
        XCTAssertEqual(janitor.issues.map(\.message).filter { !$0.hasPrefix("gh pr list") }, [])

        let whole = Set(plan.filter { $0.action.category == .worktree }.map(\.action.target))
        XCTAssertEqual(whole, [wts + "/merged", wts + "/old", wts + "/copy"])
        let modules = Set(plan.filter { $0.action.category == .nodeModules }.map(\.action.target))
        XCTAssertEqual(modules, [wts + "/stale/node_modules", wts + "/stale/packages/p/node_modules"])

        let skips = Dictionary(uniqueKeysWithValues: janitor.skips.map { ($0.target, $0.reason) })
        XCTAssertTrue(skips[wts + "/donor"]?.contains("\(wts)/active links into it") == true, "\(skips)")
        XCTAssertTrue(skips[wts + "/busy"]?.contains("in use") == true, "\(skips)")
        XCTAssertTrue(skips[wts + "/foreign"]?.contains("checkout of another repo") == true, "\(skips)")
        XCTAssertEqual(skips.count, 3, "\(skips)")

        let results = plan.map(janitor.execute)
        XCTAssertEqual(results.filter { $0.status != .removed }.map(\.target), [])

        for gone in ["merged", "old", "copy", "stale/node_modules", "stale/packages/p/node_modules"] {
            XCTAssertFalse(FS.exists(wts + "/" + gone), gone)
        }
        for kept in ["fresh", "donor/node_modules/pkg/index.js", "active", "stale/.git", "busy", "foreign"] {
            XCTAssertTrue(FS.exists(wts + "/" + kept), kept)
        }
        // Removing stale/packages/p/node_modules bumped stale/packages/p; that is not use.
        let stale = janitor.scanTree(wts + "/stale", nested: [])
        XCTAssertGreaterThan(janitor.idleDays(wts + "/stale", newestFile: stale.newest), 4.9)
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
