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
        XCTAssertTrue(j.skips.contains { $0.target == outer && $0.reason.hasSuffix("it contains the checkout \(inner)") }, "\(j.skips)")
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
        try FileManager.default.createDirectory(atPath: root + "/Library/r/.git/worktrees", withIntermediateDirectories: true)
        // Another volume is not walked.
        let dmg = root + "/v.dmg", volume = root + "/volume"
        sh(["hdiutil", "create", "-quiet", "-size", "2m", "-fs", "APFS", "-volname", "v", dmg], cwd: root)
        sh(["hdiutil", "attach", "-quiet", "-nobrowse", "-mountpoint", volume, dmg], cwd: root)
        defer { Shell.run(["hdiutil", "detach", "-quiet", "-force", volume]) }
        try FileManager.default.createDirectory(atPath: volume + "/r/.git/worktrees", withIntermediateDirectories: true)

        let j = WorktreeJanitor(cfg: cfg(protecting: [claude, copies, sibling, plain, local]), guards: try Guards.gather())
        XCTAssertEqual(j.repos, [claude, copies, local, sibling])
        XCTAssertEqual(j.orphans, [inRoot, outside].sorted())
        XCTAssertEqual(j.plan().filter { $0.action.category == .worktree }.map(\.action.target), [copies + "-worktrees/snapshot"])
        // Never removed whole: their repo may only be out of reach.
        XCTAssertEqual(j.skips.filter { [inRoot, outside].contains($0.target) }.map(\.target).sorted(), [inRoot, outside].sorted())
        // Without a remote there is nothing to fetch or ask GitHub about.
        XCTAssertEqual(j.issues.filter { $0.message.contains(local) }.map(\.message), [])
    }

    func testMovedReposWorktreesAndCheckoutsInsideOthersStay() throws {
        // A repo moved with its worktrees inside: both sides of the link point at the old place.
        let orig = try makeRepo("orig")
        addWT(orig, orig + "/.claude/worktrees/w")
        let moved = root + "/new"
        try FileManager.default.moveItem(atPath: orig, toPath: moved)
        let w = moved + "/.claude/worktrees/w"
        backdate(w, days: 40)
        // An orphan holding a clone with commits nowhere else.
        let gone = try makeRepo("gone")
        let orphan = root + "/elsewhere/o"
        addWT(gone, orphan)
        sh(["git", "init", "-q", orphan + "/vendor/lib"], cwd: root)
        try FileManager.default.removeItem(atPath: gone + "/.git")
        backdate(orphan, days: 40)
        // A submodule of a gone worktree is not a worktree.
        try write(root + "/subs/pkg/.git", "gitdir: \(root)/missing/.git/worktrees/x/modules/pkg\n")
        // A copy whose `.git` links to a clone.
        let copies = try makeRepo("copies")
        try FileManager.default.createDirectory(atPath: copies + "-worktrees/linked", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: copies + "-worktrees/linked/.git", withDestinationPath: copies + "/.git")
        backdate(copies + "-worktrees/linked", days: 40)
        // Merged and pushed, but git cannot read its status.
        let broken = copies + "-worktrees/broken"
        addWT(copies, broken)
        let brokenRecord = try String(contentsOfFile: broken + "/.git", encoding: .utf8).dropFirst(8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try write(broken + "/.git", "garbage\n")
        backdate(broken, days: 2)
        backdate(brokenRecord, days: 2)
        // A clone inside a plain copy: its packages are not the copy's.
        let holder = copies + "-worktrees/holder"
        sh(["git", "init", "-q", holder + "/inner"], cwd: root)
        try write(holder + "/inner/node_modules/x/index.js", "x")
        backdate(holder, days: 5)
        sh(["git", "init", "-q", copies + "-worktrees/old/lib"], cwd: root)
        backdate(copies + "-worktrees/old", days: 40)

        let j = WorktreeJanitor(cfg: cfg(protecting: [moved, copies]), guards: try Guards.gather())
        XCTAssertEqual(j.repos, [copies, moved])
        XCTAssertEqual(j.disconnected, [w: moved])
        XCTAssertEqual(j.orphans, [orphan])
        XCTAssertEqual(j.plan().map(\.action.target), [])
        let reasons = Dictionary(uniqueKeysWithValues: j.skips.map { ($0.target, $0.reason) })
        XCTAssertEqual(reasons[w], "untouched for 40 days, but it is disconnected from \(moved)")
        XCTAssertEqual(reasons[orphan], "untouched for 40 days, but no repo found holds this worktree")
        XCTAssertEqual(reasons[copies + "-worktrees/old"], "abandoned: untouched for 40.0 days, but it contains the checkout \(copies)-worktrees/old/lib")
        XCTAssertEqual(reasons[copies + "-worktrees/linked"], "untouched for 40 days, but it is a git checkout of another repo")
        XCTAssertNil(reasons[broken])
        XCTAssertEqual(j.skips.filter { $0.target.hasPrefix(holder) }.map(\.target), [])
        XCTAssertTrue(j.issues.contains { $0.message.hasPrefix("1 worktrees look like ones \(moved) lost") && $0.message.hasSuffix(w) }, "\(j.issues)")
    }

    func testAFailureInsideStopsItsContainerAndCrossRepoWorktreesPlanOnce() throws {
        let repo = try makeRepo("repo")
        let outer = repo + "-worktrees/outer", inner = outer + "/sub"
        try write(outer + "/a.txt", "x")
        // Of a repo scanned after `repo`, so only the order of execution puts it first.
        let late = try makeRepo("zz")
        addWT(late, inner)
        try write(inner + "/.git", "garbage\n")
        backdate(outer, days: 40)
        let other = try makeRepo("other")
        let x = repo + "-worktrees/x"
        addWT(other, x)
        try write(x + "/node_modules/p/index.js", "x")
        age(other, x, days: 5)

        var c = cfg(protecting: [repo, other, late])
        c.disabled = [.worktree]
        XCTAssertEqual(WorktreeJanitor(cfg: c, guards: try Guards.gather()).plan().map(\.action.target), [x + "/node_modules"])

        c.disabled = [.nodeModules]
        let j = WorktreeJanitor(cfg: c, guards: try Guards.gather())
        let results = j.plan().filter { $0.action.target.hasPrefix(outer) }.map(j.execute)
        XCTAssertEqual(results.map(\.target), [inner, outer])
        XCTAssertEqual(results.map(\.status), [.failed, .failed])
        XCTAssertEqual(results.last?.error, "it contains \(inner), which stays")
        XCTAssertTrue(FS.exists(outer + "/a.txt"))
    }

    func testCopiedRepoMountsAndRepeatedIdsLeaveWorktreesAlone() throws {
        // A copy of a repo holds stale records of the original's worktree.
        let a = try makeRepo("a")
        let w = a + "-worktrees/w"
        addWT(a, w)
        try FileManager.default.copyItem(atPath: a, toPath: root + "/a2")
        sh(["git", "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "local"], cwd: w)
        age(a, w, days: 2)
        // A volume mounted in an abandoned plain copy.
        let copy = a + "-worktrees/copy", volume = copy + "/vol", dmg = root + "/v.dmg"
        try write(copy + "/a.txt", "x")
        sh(["hdiutil", "create", "-quiet", "-size", "2m", "-fs", "APFS", "-volname", "v", dmg], cwd: root)
        sh(["hdiutil", "attach", "-quiet", "-nobrowse", "-mountpoint", volume, dmg], cwd: root)
        defer { Shell.run(["hdiutil", "detach", "-quiet", "-force", volume]) }
        try write(volume + "/precious.txt", "x")
        backdate(copy, days: 40)
        try write(volume + "/fresh.txt", "x")
        // A gone repo's worktree whose id a live worktree of `a` also uses.
        let gone = try makeRepo("gone")
        let orphan = root + "/elsewhere/w"
        addWT(gone, orphan)
        try FileManager.default.removeItem(atPath: gone + "/.git")

        let j = WorktreeJanitor(cfg: cfg(protecting: [a, root + "/a2", gone]), guards: try Guards.gather())
        XCTAssertEqual(j.orphans, [orphan])
        XCTAssertEqual(j.disconnected, [:])
        XCTAssertEqual(j.plan().map(\.action.target), [])
        let reasons = Dictionary(uniqueKeysWithValues: j.skips.map { ($0.target, $0.reason) })
        XCTAssertEqual(reasons[copy], "abandoned: untouched for 40.0 days, but a volume is mounted at \(volume)")
    }

    func testCloneAtAStaleWorktreePathAndMountsAtOrIntoTargetsStay() throws {
        let r = try makeRepo("r")
        let w = r + "-worktrees/w"
        addWT(r, w)
        try FileManager.default.removeItem(atPath: w)
        sh(["git", "clone", "-q", r, w], cwd: root)
        sh(["git", "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "mine"], cwd: w)
        backdate(w, days: 40)
        let at = r + "-worktrees/vol", dmg = root + "/v.dmg"
        sh(["hdiutil", "create", "-quiet", "-size", "2m", "-fs", "APFS", "-volname", "v", dmg], cwd: root)
        try FileManager.default.createDirectory(atPath: at, withIntermediateDirectories: true)
        sh(["hdiutil", "attach", "-quiet", "-nobrowse", "-mountpoint", at, dmg], cwd: root)
        defer { Shell.run(["hdiutil", "detach", "-quiet", "-force", at]) }
        try write(at + "/precious.txt", "x")
        backdate(at, days: 40)
        let late = r + "-worktrees/late"
        try write(late + "/a.txt", "x")
        backdate(late, days: 40)
        // A merged worktree on a volume of its own.
        let onVolume = r + "-worktrees/mw"
        sh(["hdiutil", "create", "-quiet", "-size", "8m", "-fs", "APFS", "-volname", "mw", root + "/mw.dmg"], cwd: root)
        try FileManager.default.createDirectory(atPath: onVolume, withIntermediateDirectories: true)
        sh(["hdiutil", "attach", "-quiet", "-nobrowse", "-mountpoint", onVolume, root + "/mw.dmg"], cwd: root)
        defer { Shell.run(["hdiutil", "detach", "-quiet", "-force", onVolume]) }
        addWT(r, onVolume)
        age(r, onVolume, days: 2)

        let j = WorktreeJanitor(cfg: cfg(protecting: [r]), guards: try Guards.gather())
        let plan = j.plan()
        XCTAssertEqual(plan.map(\.action.target), [late])
        // Mounted after planning.
        sh(["hdiutil", "create", "-quiet", "-size", "2m", "-fs", "APFS", "-volname", "v2", root + "/v2.dmg"], cwd: root)
        sh(["hdiutil", "attach", "-quiet", "-nobrowse", "-mountpoint", late + "/vol", root + "/v2.dmg"], cwd: root)
        defer { Shell.run(["hdiutil", "detach", "-quiet", "-force", late + "/vol"]) }
        XCTAssertEqual(plan.map(j.execute).map(\.error), ["it contains \(late)/vol, which stays"])
        XCTAssertTrue(FS.exists(late + "/a.txt"))
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
