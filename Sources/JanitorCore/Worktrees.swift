import Foundation

public struct PRInfo: Decodable, Sendable {
    public var number: Int
    public var state: String
    public var headRefName: String
    public var headRefOid: String
    public var isCrossRepository: Bool

    public init(number: Int, state: String, headRefName: String, headRefOid: String, isCrossRepository: Bool) {
        self.number = number
        self.state = state
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.isCrossRepository = isCrossRepository
    }
}

/// What the rules need to know about one worktree.
public struct WorktreeFacts: Sendable {
    public var path: String
    /// False for a plain copy in a worktree root that git does not know about.
    public var isGit: Bool
    public var idleDays: Double
    public var locked: Bool = false
    /// Tracked files differ from HEAD.
    public var dirty: Bool = false
    /// Every commit in HEAD's history exists on some remote-tracking ref.
    public var headOnRemote: Bool = false
    public var mergedIntoMain: Bool = false
    /// A merged PR whose head contains HEAD (covers squash merges).
    public var mergedPR: Int?
    public var openPR: Int?

    public init(path: String, isGit: Bool, idleDays: Double) {
        self.path = path
        self.isGit = isGit
        self.idleDays = idleDays
    }

    public var noPendingPushes: Bool { !dirty && (headOnRemote || mergedPR != nil) }
}

public enum WorktreeRules {
    /// Why the whole worktree should go, or nil to keep it.
    public static func removalReason(_ f: WorktreeFacts, _ cfg: Config) -> String? {
        let idle = String(format: "%.1f", f.idleDays)
        if f.idleDays > cfg.abandonedIdleDays {
            return "abandoned: untouched for \(idle) days"
        }
        guard f.isGit, !f.locked else { return nil }
        if (f.mergedIntoMain || f.mergedPR != nil) && f.noPendingPushes && f.idleDays > cfg.mergedIdleDays {
            let what = f.mergedPR.map { "PR #\($0) merged" } ?? "HEAD is in main"
            return "merged (\(what)), nothing left to push, untouched for \(idle) days"
        }
        if let pr = f.openPR, f.idleDays > cfg.openPRIdleDays {
            return "PR #\(pr) is open and the worktree is untouched for \(idle) days"
        }
        return nil
    }

    /// The matching PRs for a checkout. Branch names only match same-repo PRs, so a
    /// fork's `fix-typo` is never confused with a local `fix-typo`.
    public static func matchPRs(branch: String?, head: String, prs: [PRInfo],
                                headIsAncestorOf: (String) -> Bool) -> (open: Int?, merged: Int?) {
        var open: Int?, merged: Int?
        for pr in prs {
            let byName = branch != nil && !pr.isCrossRepository && pr.headRefName == branch
            let byOid = pr.headRefOid == head
            switch pr.state {
            case "OPEN" where byName || byOid:
                open = open ?? pr.number
            case "MERGED" where byOid || (byName && headIsAncestorOf(pr.headRefOid)):
                merged = merged ?? pr.number
            default:
                break
            }
        }
        return (open, merged)
    }
}

/// One planned removal plus what has to happen before it.
struct Candidate {
    var action: Action
    var kind: Kind

    enum Kind {
        case gitWorktree(head: String)
        case plainDirectory
    }
}

/// A symlink in one checkout's node_modules pointing outside it, e.g. a worktree
/// that borrows a donor checkout's packages instead of running `npm ci`.
struct ForeignLink {
    var holder: String
    var target: String
}

final class WorktreeJanitor {
    let cfg: Config
    let guards: Guards
    let now = Date()
    var errors: [String] = []
    var skips: [Skip] = []
    private var mainRef = "origin/main"

    init(cfg: Config, guards: Guards) {
        self.cfg = cfg
        self.guards = guards
    }

    private func git(_ args: [String], cwd: String? = nil) -> ShellResult {
        Shell.run(["git", "--no-optional-locks"] + args, cwd: cwd ?? cfg.argentRepo)
    }

    private func days(since date: Date?) -> Double {
        guard let date else { return 0 }
        return now.timeIntervalSince(date) / 86400
    }

    struct Entry {
        var path: String
        var head: String?
        var branch: String?
        var locked = false
    }

    func registeredWorktrees() -> [Entry] {
        let r = git(["worktree", "list", "--porcelain"])
        guard r.ok else {
            errors.append("git worktree list failed: \(r.stderr)")
            return []
        }
        var entries: [Entry] = []
        for block in r.stdout.components(separatedBy: "\n\n") {
            var e = Entry(path: "")
            var prunable = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { e.path = FS.canonical(String(line.dropFirst(9))) }
                if line.hasPrefix("HEAD ") { e.head = String(line.dropFirst(5)) }
                if line.hasPrefix("branch refs/heads/") { e.branch = String(line.dropFirst(18)) }
                if line == "locked" || line.hasPrefix("locked ") { e.locked = true }
                if line.hasPrefix("prunable") { prunable = true }
            }
            if !e.path.isEmpty && !prunable { entries.append(e) }
        }
        // The first entry is the main checkout.
        return Array(entries.dropFirst())
    }

    func fetchPRs() -> [PRInfo] {
        let r = Shell.run(["gh", "pr", "list", "--state", "all", "--limit", "5000",
                           "--json", "number,state,headRefName,headRefOid,isCrossRepository"],
                          cwd: cfg.argentRepo, timeout: 180)
        guard r.ok, let prs = try? JSONDecoder().decode([PRInfo].self, from: Data(r.stdout.utf8)) else {
            errors.append("gh pr list failed, PR-based worktree rules skipped: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            return []
        }
        return prs
    }

    /// Idle time ignores node_modules (tests write caches there) but counts the
    /// worktree's HEAD and index, which commits, checkouts and staging touch.
    /// Not logs/HEAD: `git gc` rewrites every worktree's reflog at once.
    func idleDays(_ path: String) -> Double {
        var newest = FS.newestMTime(path, skipping: ["node_modules"]) ?? .distantPast
        if let gitFile = try? String(contentsOfFile: path + "/.git", encoding: .utf8),
           gitFile.hasPrefix("gitdir: ") {
            let gitdir = gitFile.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
            for f in ["HEAD", "index"] {
                if let st = FS.lstatInfo(gitdir + "/" + f) { newest = max(newest, FS.mtime(st)) }
            }
        }
        return days(since: newest)
    }

    func facts(_ e: Entry, prs: [PRInfo]) -> WorktreeFacts {
        // Measured before any git command, so our own reads cannot reset it.
        var f = WorktreeFacts(path: e.path, isGit: true, idleDays: idleDays(e.path))
        f.locked = e.locked
        guard let head = e.head else { return f }
        f.dirty = !git(["status", "--porcelain", "--untracked-files=no", "--ignore-submodules=all"], cwd: e.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let unpushed = git(["rev-list", "-n1", head, "--not", "--remotes"])
        f.headOnRemote = unpushed.ok && unpushed.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        f.mergedIntoMain = git(["merge-base", "--is-ancestor", head, mainRef]).ok
        let match = WorktreeRules.matchPRs(branch: e.branch, head: head, prs: prs) { oid in
            self.git(["merge-base", "--is-ancestor", head, oid]).ok
        }
        f.openPR = match.open
        f.mergedPR = match.merged
        return f
    }

    /// node_modules directories (or links) inside a checkout, not descending into them.
    func nodeModulesDirs(_ root: String) -> [String] {
        var found: [String] = []
        FS.walk(root) { path, name, st, _ in
            if name == ".git" { return false }
            if name == "node_modules" {
                if st.st_mode & S_IFMT == S_IFDIR || st.st_mode & S_IFMT == S_IFLNK { found.append(path) }
                return false
            }
            return true
        }
        return found
    }

    /// Links from a checkout's root node_modules (and its @scope dirs) that leave the checkout.
    func foreignLinks(_ root: String) -> [ForeignLink] {
        let nm = root + "/node_modules"
        var links: [ForeignLink] = []
        func consider(_ path: String) {
            guard FS.isSymlink(path), let t = FS.linkTarget(path), !t.hasPrefix(root + "/") else { return }
            links.append(ForeignLink(holder: root, target: t))
        }
        consider(nm)
        guard FS.isDirectory(nm) else { return links }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: nm)) ?? [] {
            consider(nm + "/" + name)
            if name.hasPrefix("@"), FS.isDirectory(nm + "/" + name) {
                for sub in (try? FileManager.default.contentsOfDirectory(atPath: nm + "/" + name)) ?? [] {
                    consider(nm + "/" + name + "/" + sub)
                }
            }
        }
        return links
    }

    func plan() -> [Candidate] {
        let fetch = Shell.run(["git", "fetch", "origin", "--prune", "--quiet"], cwd: cfg.argentRepo, timeout: 300)
        if !fetch.ok { errors.append("git fetch failed, merge checks use stale refs: \(fetch.stderr)") }
        let head = git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
        if head.ok { mainRef = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }

        let registered = registeredWorktrees()
        let registeredPaths = Set(registered.map(\.path))
        let prs = fetchPRs()
        let mainCheckout = FS.canonical(cfg.argentRepo)

        var checkouts: [(facts: WorktreeFacts, entry: Entry?)] = registered.map { ($0.path, $0) }
            .filter { FS.isDirectory($0.0) }
            .map { (facts($0.1, prs: prs), $0.1) }
        for root in cfg.worktreeRoots.map(FS.canonical) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
                let path = root + "/" + name
                guard FS.isDirectory(path), !registeredPaths.contains(path) else { continue }
                checkouts.append((WorktreeFacts(path: path, isGit: false, idleDays: idleDays(path)), nil))
            }
        }

        var candidates: [Candidate] = []
        var removedWhole = Set<String>()
        for (f, entry) in checkouts {
            if !f.isGit && FS.exists(f.path + "/.git") {
                // Some other repo's checkout: its unpushed work is invisible from here.
                if f.idleDays > cfg.abandonedIdleDays {
                    skips.append(Skip(category: .worktree, target: f.path,
                                      reason: "untouched for \(Int(f.idleDays)) days, but it is a git checkout not registered with \(cfg.argentRepo)"))
                }
            } else if let reason = WorktreeRules.removalReason(f, cfg) {
                let kind: Candidate.Kind = entry?.head.map { .gitWorktree(head: $0) } ?? .plainDirectory
                candidates.append(Candidate(
                    action: Action(category: .worktree, target: f.path, reason: reason, bytes: 0, status: .planned),
                    kind: kind))
                removedWhole.insert(f.path)
                continue
            }
            // Tests and installs write here, so they count as use for this rule.
            var idle = f.idleDays
            for extra in ["node_modules", "node_modules/.cache", "node_modules/.vite", "node_modules/.package-lock.json"] {
                if let st = FS.lstatInfo(f.path + "/" + extra) { idle = min(idle, days(since: FS.mtime(st))) }
            }
            guard idle > cfg.nodeModulesIdleDays else { continue }
            for nm in nodeModulesDirs(f.path) {
                candidates.append(Candidate(
                    action: Action(category: .nodeModules, target: nm,
                                   reason: "worktree untouched for \(String(format: "%.1f", idle)) days",
                                   bytes: 0, status: .planned),
                    kind: .plainDirectory))
            }
        }

        // A donor's packages must outlive every checkout still linking into them.
        let allLinks = ([mainCheckout] + checkouts.map(\.facts.path)).flatMap(foreignLinks)
        var planned = candidates.indices.map { _ in true }
        var changed = true
        while changed {
            changed = false
            let nmGone = Set(candidates.indices.filter { planned[$0] && candidates[$0].action.category == .nodeModules }
                .map { candidates[$0].action.target })
            let wholeGone = Set(candidates.indices.filter { planned[$0] && candidates[$0].action.category == .worktree }
                .map { candidates[$0].action.target })
            let live = allLinks.filter { !wholeGone.contains($0.holder) && !nmGone.contains($0.holder + "/node_modules") }
            for i in candidates.indices where planned[i] {
                let t = candidates[i].action.target
                if let link = live.first(where: { ($0.target == t || $0.target.hasPrefix(t + "/")) }) {
                    planned[i] = false
                    changed = true
                    skips.append(Skip(category: candidates[i].action.category, target: t,
                                      reason: "\(candidates[i].action.reason), but \(link.holder) links into it"))
                }
            }
        }

        return candidates.indices.compactMap { i -> Candidate? in
            guard planned[i] else { return nil }
            var c = candidates[i]
            if let veto = guards.veto(c.action.target) {
                skips.append(Skip(category: c.action.category, target: c.action.target, reason: "\(c.action.reason), but \(veto)"))
                return nil
            }
            // A node_modules link frees nothing but the link itself.
            c.action.bytes = FS.isSymlink(c.action.target) ? 0 : FS.allocatedSize(c.action.target)
            return c
        }
    }

    func execute(_ c: Candidate) -> Action {
        var a = c.action
        do {
            switch c.kind {
            case .plainDirectory:
                try FS.remove(a.target)
            case .gitWorktree(let head):
                a.salvage = try salvage(a.target, head: head)
                try Safety.check(a.target)
                let r = git(["worktree", "remove", "--force", "--force", a.target])
                if !r.ok {
                    try FS.remove(a.target)
                    git(["worktree", "prune"])
                }
            }
            a.status = .removed
        } catch {
            a.status = .failed
            a.error = "\(error)"
        }
        return a
    }

    /// Keeps what removal would otherwise destroy: a ref for commits no branch
    /// or remote holds, and a patch plus tarball of uncommitted work.
    func salvage(_ path: String, head: String) throws -> String? {
        let name = (path as NSString).lastPathComponent
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
        var kept: [String] = []

        let held = git(["for-each-ref", "--count=1", "--contains", head, "refs/heads", "refs/remotes", "refs/janitor"])
        if held.ok && held.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let ref = "refs/janitor/\(name)-\(stamp)"
            guard git(["update-ref", ref, head]).ok else { throw JanitorError("could not create \(ref)") }
            kept.append(ref)
        }

        let dir = cfg.salvageDir
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let diff = git(["diff", "HEAD", "--binary"], cwd: path)
        guard diff.ok else { throw JanitorError("git diff failed in \(path): \(diff.stderr)") }
        if !diff.stdout.isEmpty {
            let patch = "\(dir)/\(name)-\(stamp).patch"
            try diff.stdout.write(toFile: patch, atomically: true, encoding: .utf8)
            kept.append(patch)
        }
        let untracked = git(["ls-files", "--others", "--exclude-standard", "-z"], cwd: path).stdout
            .split(separator: "\0").map(String.init)
        if !untracked.isEmpty {
            let size = untracked.reduce(Int64(0)) { $0 + FS.allocatedSize(path + "/" + $1) }
            if size <= 50_000_000 {
                let list = "\(dir)/\(name)-\(stamp).untracked"
                try untracked.joined(separator: "\n").write(toFile: list, atomically: true, encoding: .utf8)
                let tgz = "\(dir)/\(name)-\(stamp)-untracked.tgz"
                let tar = Shell.run(["tar", "-czf", tgz, "-T", list], cwd: path, timeout: 600)
                try? FileManager.default.removeItem(atPath: list)
                guard tar.ok else { throw JanitorError("tar of untracked files failed: \(tar.stderr)") }
                kept.append(tgz)
            } else {
                kept.append("\(untracked.count) untracked files (\(size / 1_000_000) MB) not saved: over 50 MB")
            }
        }
        return kept.isEmpty ? nil : kept.joined(separator: ", ")
    }
}
