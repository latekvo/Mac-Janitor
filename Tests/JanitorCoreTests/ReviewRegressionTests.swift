import XCTest
@testable import JanitorCore

/// Regressions from review: each drives the planner against real fixture repos.
final class ReviewRegressionTests: XCTestCase {
    var root = ""

    @discardableResult
    func sh(_ args: [String], cwd: String) -> String {
        let r = Shell.run(args, cwd: cwd)
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

    func link(_ path: String, to dest: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: dest)
    }

    /// A repo `<root>/<name>` with origin and `<name>-worktrees`.
    func makeRepo(_ name: String) throws -> String {
        let repo = root + "/" + name
        try FileManager.default.createDirectory(atPath: repo + "-worktrees", withIntermediateDirectories: true)
        sh(["git", "init", "-q", "--bare", "-b", "main", root + "/\(name)-origin.git"], cwd: root)
        sh(["git", "clone", "-q", root + "/\(name)-origin.git", repo], cwd: root)
        sh(["git", "config", "user.email", "t@example.com"], cwd: repo)
        sh(["git", "config", "user.name", "t"], cwd: repo)
        try write(repo + "/a.txt", "one\n")
        try write(repo + "/.gitignore", "node_modules\n")
        sh(["git", "add", "a.txt", ".gitignore"], cwd: repo)
        sh(["git", "commit", "-q", "-m", "init"], cwd: repo)
        sh(["git", "push", "-q", "origin", "main"], cwd: repo)
        sh(["git", "remote", "set-head", "origin", "main"], cwd: repo)
        return repo
    }

    func addWT(_ repo: String, _ path: String) {
        sh(["git", "worktree", "add", "-q", "--detach", path], cwd: repo)
    }

    func age(_ repo: String, _ wt: String, days: Double) {
        backdate(wt, days: days)
        let gitFile = try! String(contentsOfFile: wt + "/.git", encoding: .utf8)
        let gitdir = gitFile.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
        backdate(gitdir, days: days)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("janitor-rr-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        root = FS.canonical(root)
    }

    override func tearDownWithError() throws {
        Safety.protectedPaths = []
        try? FileManager.default.removeItem(atPath: root)
    }

    func cfg(protecting repos: [String]) -> Config {
        var c = Config()
        c.worktreeSearchRoot = root
        c.salvageDir = root + "/salvage"
        Safety.protectedPaths = (repos + repos.map(WorktreeJanitor.root) + [root]).map(FS.canonical)
        return c
    }

    func testNestedWorktreeKeepsItsParent() throws {
        let repo = try makeRepo("repo")
        let outer = repo + "-worktrees/outer"
        addWT(repo, outer)
        let inner = outer + "/.claude/worktrees/inner"
        addWT(repo, inner)
        sh(["git", "commit", "-q", "--allow-empty", "-m", "fresh unpushed"], cwd: inner)
        // Abandoned: the one rule that ignores state, so only nesting can save it.
        for f in ["/a.txt", "/.gitignore", "/.git"] { backdate(outer + f, days: 40) }
        let og = try String(contentsOfFile: outer + "/.git", encoding: .utf8).dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
        backdate(og, days: 40)
        let j = WorktreeJanitor(cfg: cfg(protecting: [repo]), guards: try Guards.gather())
        XCTAssertEqual(j.plan().map(\.action.target), [])
        XCTAssertTrue(j.skips.contains { $0.target == outer && $0.reason.hasSuffix("it contains the worktree \(inner)") }, "\(j.skips)")
    }

    func testKeepingAChildOrASloppySpellingKeepsTheWorktree() throws {
        let repo = try makeRepo("repo")
        let wt = repo + "-worktrees/w"
        addWT(repo, wt)
        try write(wt + "/node_modules/x/index.js", "x")
        age(repo, wt, days: 40)
        for keep in [wt + "/node_modules", wt + "/", wt.replacingOccurrences(of: "/private/var/", with: "/var/")] {
            var c = cfg(protecting: [repo])
            c.keep = [keep]
            let j = WorktreeJanitor(cfg: c, guards: try Guards.gather())
            XCTAssertEqual(j.plan().map(\.action.target), [], keep)
            XCTAssertEqual(j.skips.filter(\.kept).map(\.target), [wt], keep)
        }
    }

    func testProcessInsideTheWorktreeKeepsItsNodeModules() throws {
        let repo = try makeRepo("repo")
        let wt = repo + "-worktrees/w"
        addWT(repo, wt)
        sh(["git", "commit", "-q", "--allow-empty", "-m", "unpushed"], cwd: wt)
        try write(wt + "/node_modules/x/index.js", "x")
        age(repo, wt, days: 5)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["60"]
        p.currentDirectoryURL = URL(fileURLWithPath: wt)
        try p.run()
        defer { p.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        let j = WorktreeJanitor(cfg: cfg(protecting: [repo]), guards: try Guards.gather())
        XCTAssertEqual(j.plan().map(\.action.target), [])
        XCTAssertTrue(j.skips.contains { $0.target == wt + "/node_modules" && $0.reason.contains("in use") }, "\(j.skips)")
    }

    func testDonorPackagesReachedThroughWorkspaceLinksStay() throws {
        let repo = try makeRepo("repo")
        let d = repo + "-worktrees/donor", h = repo + "-worktrees/holder"
        addWT(repo, d); addWT(repo, h)
        try write(d + "/node_modules/dep/index.js", "x")
        try write(d + "/packages/p/node_modules/esr/index.js", "x")
        try write(d + "/packages/q/node_modules/other/index.js", "x")
        try link(d + "/node_modules/@s/p", to: "../../packages/p")
        try link(h + "/node_modules", to: d + "/node_modules")
        age(repo, d, days: 5)
        var c = cfg(protecting: [repo])
        c.disabled = [.worktree]
        let j = WorktreeJanitor(cfg: c, guards: try Guards.gather())
        // Only the package no borrower can reach goes.
        XCTAssertEqual(j.plan().map(\.action.target), [d + "/packages/q/node_modules"])
        XCTAssertTrue(j.skips.contains { $0.target == d + "/packages/p/node_modules" && $0.reason.hasSuffix("\(h) links into it") })
    }

    func testSameNamedWorktreesGetSeparateSalvage() throws {
        let a = try makeRepo("alpha"), b = try makeRepo("beta")
        let wa = a + "-worktrees/dup", wb = b + "-worktrees/dup", wc = a + "/.claude/worktrees/dup"
        addWT(a, wa); addWT(b, wb); addWT(a, wc)
        try write(wa + "/a.txt", "ALPHA EDIT\n")
        try write(wb + "/a.txt", "BETA EDIT\n")
        sh(["git", "commit", "-q", "--allow-empty", "-m", "one"], cwd: wa)
        sh(["git", "commit", "-q", "--allow-empty", "-m", "two"], cwd: wc)
        let heads = [sh(["git", "rev-parse", "HEAD"], cwd: wa), sh(["git", "rev-parse", "HEAD"], cwd: wc)]
        for (r, w) in [(a, wa), (b, wb), (a, wc)] { age(r, w, days: 40) }
        let c = cfg(protecting: [a, b])
        let j = WorktreeJanitor(cfg: c, guards: try Guards.gather())
        let res = j.plan().map(j.execute)
        XCTAssertEqual(res.map(\.status), [.removed, .removed, .removed])
        let patches = try FileManager.default.contentsOfDirectory(atPath: c.salvageDir).filter { $0.hasSuffix(".patch") }
        let texts = try patches.map { try String(contentsOfFile: c.salvageDir + "/" + $0, encoding: .utf8) }
        XCTAssertEqual(texts.filter { $0.contains("ALPHA") }.count, 1)
        XCTAssertEqual(texts.filter { $0.contains("BETA") }.count, 1)
        let refs = sh(["git", "for-each-ref", "--format=%(objectname)", "refs/janitor"], cwd: a)
        XCTAssertEqual(Set(refs.split(separator: "\n").map(String.init)), Set(heads))
    }

    func testDiscoveryFindsEveryRepoWithWorktreesAndEveryOrphan() throws {
        let claude = try makeRepo("claude"), sibling = try makeRepo("sibling"), plain = try makeRepo("plain")
        try FileManager.default.removeItem(atPath: plain + "-worktrees")
        try FileManager.default.removeItem(atPath: claude + "-worktrees")
        addWT(claude, claude + "/.claude/worktrees/agent")
        try write(plain + "/node_modules/pkg/.git/HEAD", "ref: refs/heads/main\n")
        try FileManager.default.createDirectory(atPath: plain + "/node_modules/pkg-worktrees", withIntermediateDirectories: true)
        let local = root + "/local"
        sh(["git", "init", "-q", "-b", "main", local], cwd: root)
        sh(["git", "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], cwd: local)
        addWT(local, local + "-worktrees/w")
        // A gone repo's worktrees: one among a live repo's plain copies, one only discovery finds.
        let moved = try makeRepo("moved")
        let inRoot = sibling + "-worktrees/old", outside = root + "/elsewhere/.claude/worktrees/old"
        addWT(moved, inRoot)
        addWT(moved, outside)
        addWT(sibling, sibling + "-worktrees/live")
        let rel = sibling + "-worktrees/rel"
        addWT(sibling, rel)
        try write(rel + "/.git", "gitdir: ../../sibling/.git/worktrees/rel\n")
        // Plain copies alone make a repo managed.
        let copies = try makeRepo("copies")
        try write(copies + "-worktrees/snapshot/a.txt", "x")
        backdate(copies + "-worktrees/snapshot", days: 40)
        try FileManager.default.removeItem(atPath: moved + "/.git")
        for p in [inRoot, outside] { backdate(p, days: 40) }
        // Another volume is not walked.
        let dmg = root + "/v.dmg", volume = root + "/volume"
        sh(["hdiutil", "create", "-quiet", "-size", "2m", "-fs", "APFS", "-volname", "v", dmg], cwd: root)
        sh(["hdiutil", "attach", "-quiet", "-nobrowse", "-mountpoint", volume, dmg], cwd: root)
        defer { Shell.run(["hdiutil", "detach", "-quiet", "-force", volume]) }
        try FileManager.default.createDirectory(atPath: volume + "/r/.git/worktrees", withIntermediateDirectories: true)

        let j = WorktreeJanitor(cfg: cfg(protecting: [claude, copies, sibling, plain, local]), guards: try Guards.gather())
        XCTAssertEqual(j.repos, [claude, copies, local, sibling])
        XCTAssertEqual(j.orphans, [inRoot, outside].sorted())
        XCTAssertEqual(Set(j.plan().filter { $0.action.category == .worktree }.map(\.action.target)),
                       [inRoot, outside, copies + "-worktrees/snapshot"])
        // Without a remote there is nothing to fetch or ask GitHub about.
        XCTAssertEqual(j.issues.filter { $0.message.contains(local) }.map(\.message), [])
    }

    func testNonUTF8EditsSalvageByteForByte() throws {
        let repo = try makeRepo("repo")
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: URL(fileURLWithPath: repo + "/l.txt"))
        sh(["git", "add", "l.txt"], cwd: repo)
        sh(["git", "commit", "-q", "-m", "latin"], cwd: repo)
        sh(["git", "push", "-q", "origin", "main"], cwd: repo)
        let wt = repo + "-worktrees/w"
        addWT(repo, wt)
        try Data([0x6E, 0x61, 0xEF, 0x76, 0x65, 0x0A]).write(to: URL(fileURLWithPath: wt + "/l.txt"))
        age(repo, wt, days: 40)
        let c = cfg(protecting: [repo])
        let j = WorktreeJanitor(cfg: c, guards: try Guards.gather())
        XCTAssertEqual(j.plan().map(j.execute).map(\.status), [.removed])
        let patch = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: c.salvageDir).first { $0.hasSuffix(".patch") })
        XCTAssertTrue(Shell.run(["git", "apply", "--check", c.salvageDir + "/" + patch], cwd: repo).ok)
    }

    func testUntrackedWorkIsPendingAndTooMuchOfItBlocksRemoval() throws {
        let repo = try makeRepo("repo")
        let merged = repo + "-worktrees/merged", big = repo + "-worktrees/big"
        addWT(repo, merged); addWT(repo, big)
        try write(merged + "/new-feature.swift", "untracked work\n")
        try Data(count: Int(WorktreeJanitor.salvageCap) + 1).write(to: URL(fileURLWithPath: big + "/blob.bin"))
        age(repo, merged, days: 2)
        age(repo, big, days: 40)
        let j = WorktreeJanitor(cfg: cfg(protecting: [repo]), guards: try Guards.gather())
        XCTAssertEqual(j.plan().map(\.action.target), [])
        XCTAssertTrue(j.skips.contains { $0.target == big && $0.reason.hasSuffix("too big to salvage") }, "\(j.skips)")
    }
}
