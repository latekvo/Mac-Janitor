import CryptoKit
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
    /// The checkout the target is or sits in.
    var checkout: String

    enum Kind: Equatable {
        case gitWorktree(repo: String, head: String)
        case plainDirectory
        /// A node_modules symlink. Removing it would free nothing, so it is never
        /// removed or reported, but planning it releases the donor it points into.
        case link
    }
}

/// A symlink that is a checkout's node_modules or one of its (@scope) entries.
/// One pointing outside the checkout borrows a donor's packages instead of running `npm ci`.
struct NodeLink {
    var checkout: String
    /// The node_modules directory or link the symlink is, or sits in.
    var nodeModules: String
    var location: String
    var target: String

    var foreign: Bool { !target.hasPrefix(checkout + "/") }
}

final class WorktreeJanitor {
    let cfg: Config
    let guards: Guards
    let only: Set<String>?
    let now = Date()
    /// Main checkouts with linked worktrees or a `<repo>-worktrees` folder.
    let repos: [String]
    /// Worktrees whose repo is gone, or out of this run's reach.
    let orphans: [String]
    /// Worktrees whose repo moved, mapped to the repo still holding their record.
    let disconnected: [String: String]
    /// Every checkout found, so none is scanned or removed as part of another.
    let checkouts: Set<String>
    var issues: [Issue] = []
    var skips: [Skip] = []
    /// Targets left in place this run, which their containers must not take with them.
    var stayed: [String] = []
    /// Never walked into or removed with a folder: a stalled one hangs, a live one holds data.
    let mounts = FS.mountPoints()

    init(cfg: Config, guards: Guards, only: Set<String>? = nil) {
        self.cfg = cfg
        self.guards = guards
        self.only = only
        let found = cfg.enabled(.worktree) || cfg.enabled(.nodeModules)
            ? Self.discover(under: cfg.worktreeSearchRoot) : Discovery()
        (repos, orphans, disconnected, checkouts) = (found.repos, found.orphans, found.disconnected, found.checkouts)
    }

    /// Where a repo's worktrees live: `~/dev/x` -> `~/dev/x-worktrees`.
    static func root(_ repo: String) -> String { FS.normalize(repo) + "-worktrees" }

    /// The git directory a `.git` file points to, resolved against the checkout.
    static func gitdir(of checkout: String) -> String? {
        guard let text = try? String(contentsOfFile: checkout + "/.git", encoding: .utf8),
              text.hasPrefix("gitdir: ") else { return nil }
        let dir = text.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.hasPrefix("/") ? dir : FS.normalize(checkout + "/" + dir)
    }

    /// A `.git` directory, followed through a symlink.
    static func hasGitDirectory(_ checkout: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: checkout + "/.git", isDirectory: &isDir) && isDir.boolValue
    }

    /// A checkout git can still read: a `.git` directory, or a `.git` file whose gitdir exists.
    static func isLiveCheckout(_ path: String) -> Bool {
        hasGitDirectory(path) || gitdir(of: path).map(FS.exists) == true
    }

    /// A worktree whose git dir is gone: found by discovery, or in a `-worktrees` folder
    /// it never walked (a symlink to elsewhere).
    static func isLostWorktree(_ path: String) -> Bool {
        gitdir(of: path).map { isWorktreeGitdir($0) && !FS.exists($0) } == true
    }

    /// A linked worktree's gitdir is `<repo>/.git/worktrees/<id>`; a submodule's is not.
    static func isWorktreeGitdir(_ dir: String) -> Bool {
        (dir as NSString).deletingLastPathComponent.hasSuffix("/worktrees")
    }

    struct Discovery {
        var repos: [String] = [], orphans: [String] = []
        var disconnected: [String: String] = [:]
        var checkouts: Set<String> = []
    }

    /// One walk of `root`, never touching another volume (a stalled share would hang it),
    /// skipping `Library`, `.Trash` and node_modules and never entering a `.git`.
    static func discover(under root: String) -> Discovery {
        let root = FS.canonical(FS.normalize(root))
        var d = Discovery()
        var unreadable: [(checkout: String, id: String)] = []
        FS.walk(root, skipping: FS.mountPoints().union([root + "/Library", root + "/.Trash"])) { path, name, st, _ in
            if name == "node_modules" { return false }
            guard name == ".git" else { return true }
            let checkout = (path as NSString).deletingLastPathComponent
            if hasGitDirectory(checkout) {
                d.checkouts.insert(checkout)
                // A `.git` symlink borrows another repo, which is found where it lives.
                if st.st_mode & S_IFMT == S_IFDIR,
                   FS.isDirectory(path + "/worktrees") || FS.isDirectory(Self.root(checkout)) { d.repos.append(checkout) }
            } else if let dir = gitdir(of: checkout), isWorktreeGitdir(dir) {
                d.checkouts.insert(checkout)
                if !FS.exists(dir) { unreadable.append((checkout, (dir as NSString).lastPathComponent)) }
            }
            return false
        }
        d.repos.sort()
        // A moved repo still holds its worktrees' records, which `git worktree repair`
        // reconnects. The rest may only sit where this run cannot read (a protected
        // folder, an unmounted drive), so an orphan is never removed whole.
        for (checkout, id) in unreadable {
            // Ids repeat across repos: the record must itself be lost, or point here.
            let holder = d.repos.first { repo in
                guard let text = try? String(contentsOfFile: repo + "/.git/worktrees/" + id + "/gitdir", encoding: .utf8)
                else { return false }
                let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return !FS.exists(target) || FS.canonical(target) == checkout + "/.git"
            }
            if let repo = holder {
                d.disconnected[checkout] = repo
            } else {
                d.orphans.append(checkout)
            }
        }
        d.orphans.sort()
        return d
    }

    @discardableResult
    /// fsmonitor would leave a daemon holding each worktree open, which then vetoes its removal.
    private func git(_ args: [String], cwd: String) -> ShellResult {
        Shell.run(["git", "--no-optional-locks", "-c", "core.fsmonitor=false"] + args, cwd: cwd)
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

    struct Checkout {
        var repo: String
        var facts: WorktreeFacts
        var entry: Entry?
        var nodeModules: [String]
        /// Checkouts inside this one that no scan covers.
        var inner: [String]
        /// Days since the checkout or its installed packages last changed.
        var nodeModulesIdleDays: Double
    }

    func registeredWorktrees(_ repo: String) -> [Entry] {
        let r = git(["worktree", "list", "--porcelain"], cwd: repo)
        guard r.ok else {
            issues.append(Issue(.worktree, "git worktree list failed in \(repo): \(r.stderr)"))
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

    func fetchPRs(_ repo: String) -> [PRInfo] {
        let r = Shell.run(["gh", "pr", "list", "--state", "all", "--limit", "5000",
                           "--json", "number,state,headRefName,headRefOid,isCrossRepository"],
                          cwd: repo, timeout: 180)
        guard r.ok, let prs = try? JSONDecoder().decode([PRInfo].self, from: Data(r.stdout.utf8)) else {
            let why = r.notFound ? "gh is not installed" : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            issues.append(Issue(.worktree, "Open-PR rule skipped for \(repo): \(why)"))
            return []
        }
        return prs
    }

    /// One walk of a checkout, not entering node_modules, `.git` or `nested` checkouts:
    /// the newest file mtime and the node_modules directories or links.
    /// Directory mtimes are ignored, since removing node_modules bumps them.
    func scanTree(_ root: String, nested: Set<String>) -> (newest: Date?, nodeModules: [String], inner: [String]) {
        var newest: Date?
        var nodeModules: [String] = [], inner: [String] = []
        FS.walk(root, skipping: mounts) { path, name, st, _ in
            let type = st.st_mode & S_IFMT
            // Checkouts discovery never reached, as under /tmp; a submodule is part of this one.
            if name == ".git" && path != root + "/.git" {
                let checkout = (path as NSString).deletingLastPathComponent
                if Self.hasGitDirectory(checkout) || Self.gitdir(of: checkout).map(Self.isWorktreeGitdir) == true {
                    inner.append(checkout)
                }
            }
            if type == S_IFDIR && (name == ".git" || nested.contains(path)) { return false }
            if name == "node_modules" && (type == S_IFDIR || type == S_IFLNK) {
                nodeModules.append(path)
                return false
            }
            if type != S_IFDIR { newest = max(newest ?? .distantPast, FS.mtime(st)) }
            return true
        }
        return (newest, nodeModules, inner)
    }

    /// Idle time counts the worktree's git HEAD and index, which commits,
    /// checkouts and staging touch. Not logs/HEAD: `git gc` rewrites every reflog at once.
    func idleDays(_ path: String, newestFile: Date?) -> Double {
        var newest = newestFile ?? FS.lstatInfo(path).map(FS.mtime) ?? .distantPast
        if let gitdir = Self.gitdir(of: path) {
            for f in ["HEAD", "index"] {
                if let st = FS.lstatInfo(gitdir + "/" + f) { newest = max(newest, FS.mtime(st)) }
            }
        }
        return days(since: newest)
    }

    func addGitFacts(_ f: inout WorktreeFacts, _ e: Entry, repo: String, mainRef: String, prs: [PRInfo]) {
        guard let head = e.head else { return }
        // Untracked files count: work never added is still work.
        // A status git cannot read is not a clean one.
        let status = git(["status", "--porcelain", "--untracked-files=normal", "--ignore-submodules=all"], cwd: e.path)
        f.dirty = !status.ok || !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let unpushed = git(["rev-list", "-n1", head, "--not", "--remotes"], cwd: repo)
        f.headOnRemote = unpushed.ok && unpushed.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        f.mergedIntoMain = git(["merge-base", "--is-ancestor", head, mainRef], cwd: repo).ok
        let match = WorktreeRules.matchPRs(branch: e.branch, head: head, prs: prs) { oid in
            self.git(["merge-base", "--is-ancestor", head, oid], cwd: repo).ok
        }
        f.openPR = match.open
        f.mergedPR = match.merged
    }

    /// Symlinks among `nodeModules` itself, its entries and @scope entries.
    func links(checkout: String, nodeModules nm: String) -> [NodeLink] {
        var links: [NodeLink] = []
        func consider(_ path: String) {
            guard FS.isSymlink(path), let t = FS.linkTarget(path) else { return }
            links.append(NodeLink(checkout: checkout, nodeModules: nm, location: path, target: t))
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

    /// The checkouts of one repo, plus the foreign links of every checkout including the main one.
    func scan(_ repo: String) -> (checkouts: [Checkout], links: [NodeLink]) {
        guard git(["rev-parse", "--git-dir"], cwd: repo).ok else {
            issues.append(Issue(.worktree, "\(repo) is not a git repository"))
            return ([], [])
        }
        let wantWhole = cfg.enabled(.worktree)
        var mainRef = "origin/main"
        var prs: [PRInfo] = []
        // A local-only repo has nothing to fetch, and only GitHub has PRs to ask gh about.
        let origin = git(["remote", "get-url", "origin"], cwd: repo)
        if wantWhole && origin.ok {
            let fetch = Shell.run(["git", "fetch", "origin", "--prune", "--quiet"], cwd: repo, timeout: 300)
            if !fetch.ok { issues.append(Issue(.worktree, "git fetch failed in \(repo), merge checks use stale refs: \(fetch.stderr)")) }
            let head = git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: repo)
            if head.ok { mainRef = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
            if origin.stdout.contains("github.com") { prs = fetchPRs(repo) }
        }

        // A copy of a repo keeps records of the original's worktrees, with stale HEADs,
        // and a record outlives a worktree deleted without git: only the repo a worktree's
        // `.git` points into speaks for it. A clone there is not it; an unreadable `.git`
        // proves nothing, and its failing salvage keeps it.
        let all = registeredWorktrees(repo).filter { FS.isDirectory($0.path) && !mounts.contains($0.path) }
        let own = FS.canonical(repo + "/.git/worktrees")
        let registered = all.filter { e in
            guard !Self.hasGitDirectory(e.path) else { return false }
            return Self.gitdir(of: e.path).map { FS.canonical(($0 as NSString).deletingLastPathComponent) == own } ?? true
        }
        var paths: [(String, Entry?)] = registered.map { ($0.path, $0) }
        let known = Set(all.map(\.path))
        let root = FS.canonical(Self.root(repo))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let path = root + "/" + name
            if !mounts.contains(path) && FS.isDirectory(path) && !known.contains(path) { paths.append((path, nil)) }
        }
        let nested = Set(paths.map(\.0)).union(checkouts)

        var checkouts: [Checkout] = []
        var links: [NodeLink] = []
        for (path, entry) in paths {
            let c = checkout(path, entry: entry, repo: repo, nested: nested) { f in
                if let entry, wantWhole { self.addGitFacts(&f, entry, repo: repo, mainRef: mainRef, prs: prs) }
            }
            checkouts.append(c)
            links += c.nodeModules.flatMap { self.links(checkout: path, nodeModules: $0) }
        }
        links += scanTree(repo, nested: nested).nodeModules.flatMap { self.links(checkout: repo, nodeModules: $0) }
        return (checkouts, links)
    }

    func checkout(_ path: String, entry: Entry?, repo: String, nested: Set<String>,
                  gitFacts: (inout WorktreeFacts) -> Void = { _ in }) -> Checkout {
        let tree = scanTree(path, nested: nested)
        // Measured before any git command, so our own reads cannot reset it.
        var f = WorktreeFacts(path: path, isGit: entry != nil, idleDays: idleDays(path, newestFile: tree.newest))
        f.locked = entry?.locked ?? false
        gitFacts(&f)
        // Tests and installs write here, so they count as use for this rule.
        var nmIdle = f.idleDays
        for extra in ["node_modules", "node_modules/.cache", "node_modules/.vite", "node_modules/.package-lock.json"] {
            if let st = FS.lstatInfo(path + "/" + extra) { nmIdle = min(nmIdle, days(since: FS.mtime(st))) }
        }
        return Checkout(repo: repo, facts: f, entry: entry, nodeModules: tree.nodeModules, inner: tree.inner,
                        nodeModulesIdleDays: nmIdle)
    }

    func plan() -> [Candidate] {
        guard cfg.enabled(.worktree) || cfg.enabled(.nodeModules) else { return [] }
        var checkouts: [Checkout] = []
        var links: [NodeLink] = []
        for repo in repos {
            let s = scan(repo)
            checkouts += s.checkouts
            links += s.links
        }
        // Those in a `<repo>-worktrees` folder were already found as plain copies.
        let seen = Set(checkouts.map(\.facts.path))
        let nested = self.checkouts.union(seen)
        for path in orphans + disconnected.keys.sorted() where !seen.contains(path) {
            let c = checkout(path, entry: nil, repo: "", nested: nested)
            checkouts.append(c)
            links += c.nodeModules.flatMap { self.links(checkout: path, nodeModules: $0) }
        }

        for (repo, moved) in Dictionary(grouping: disconnected.keys, by: { disconnected[$0]! }).sorted(by: { $0.key < $1.key }) {
            issues.append(Issue(.worktree, "\(moved.count) worktrees look like ones \(repo) lost in a move, so none is removed whole; "
                                + "if they are, `git -C \(repo) worktree repair <paths>` reconnects them, e.g. \(moved.sorted()[0])"))
        }

        // A worktree of one repo in another's `-worktrees` folder was found by both.
        let gitPaths = Set(checkouts.filter(\.facts.isGit).map(\.facts.path))
        checkouts.removeAll { !$0.facts.isGit && gitPaths.contains($0.facts.path) }
        let orphaned = Set(orphans)

        var candidates: [Candidate] = []
        for c in checkouts {
            let f = c.facts
            if disconnected[f.path] == nil && (orphaned.contains(f.path) || Self.isLostWorktree(f.path)) {
                if cfg.enabled(.worktree) && f.idleDays > cfg.abandonedIdleDays {
                    skips.append(Skip(category: .worktree, target: f.path,
                                      reason: "untouched for \(Int(f.idleDays)) days, but no repo found holds this worktree"))
                }
            } else if let repo = disconnected[f.path] {
                if cfg.enabled(.worktree) && f.idleDays > cfg.abandonedIdleDays {
                    skips.append(Skip(category: .worktree, target: f.path,
                                      reason: "untouched for \(Int(f.idleDays)) days, but it is disconnected from \(repo)"))
                }
            } else if !f.isGit && Self.isLiveCheckout(f.path) {
                // Some other repo's checkout: its unpushed work is invisible from here.
                if cfg.enabled(.worktree) && f.idleDays > cfg.abandonedIdleDays {
                    skips.append(Skip(category: .worktree, target: f.path,
                                      reason: "untouched for \(Int(f.idleDays)) days, but it is a git checkout of another repo"))
                }
            } else if cfg.enabled(.worktree), let reason = WorktreeRules.removalReason(f, cfg) {
                let kind: Candidate.Kind = c.entry?.head.map { .gitWorktree(repo: c.repo, head: $0) } ?? .plainDirectory
                candidates.append(Candidate(
                    action: Action(category: .worktree, target: f.path, reason: reason, bytes: 0, status: .planned),
                    kind: kind, checkout: f.path))
                continue
            }
            guard cfg.enabled(.nodeModules), c.nodeModulesIdleDays > cfg.nodeModulesIdleDays else { continue }
            for nm in c.nodeModules {
                candidates.append(Candidate(
                    action: Action(category: .nodeModules, target: nm,
                                   reason: "worktree untouched for \(String(format: "%.1f", c.nodeModulesIdleDays)) days",
                                   bytes: 0, status: .planned),
                    kind: FS.isSymlink(nm) ? .link : .plainDirectory, checkout: f.path))
            }
        }

        // Links do nothing themselves, so `only` (ids the caller saw) never lists them.
        var planned = candidates.map { $0.kind == .link || (only?.contains($0.action.id) ?? true) }
        func skip(_ i: Int, _ why: String, kept: Bool = false) {
            planned[i] = false
            let a = candidates[i].action
            guard candidates[i].kind != .link else { return }
            skips.append(Skip(category: a.category, target: a.target, reason: kept ? "kept" : "\(a.reason), but \(why)",
                              kept: kept, bytes: kept ? FS.allocatedSize(a.target) : 0))
        }
        for i in candidates.indices where planned[i] {
            let c = candidates[i]
            if cfg.isKept(c.action.target) {
                skip(i, "kept", kept: true)
            } else if let veto = guards.veto(c.action.target) ?? guards.veto(c.checkout) {
                // A process in the worktree (a dev server writes nothing) still needs its packages.
                skip(i, veto)
            } else if let mount = mounts.first(where: { $0.hasPrefix(c.action.target + "/") }) {
                skip(i, "a volume is mounted at \(mount)")
            } else if case .gitWorktree = c.kind, let lost = unsalvageable(c.action.target) {
                skip(i, lost)
            }
        }

        // A donor's packages must outlive every checkout still linking into them,
        // including through links inside the donor (workspace packages), and a
        // worktree must outlive the worktrees nested in it.
        let allCheckouts = checkouts.flatMap { [$0.facts.path] + $0.inner } + self.checkouts
        var changed = true
        while changed {
            changed = false
            let gone = Set(candidates.indices.filter { planned[$0] }.map { candidates[$0].action.target })
            var reached: [String: String] = [:]
            var frontier: [String] = []
            for l in links where l.foreign && !gone.contains(l.checkout) && !gone.contains(l.nodeModules) {
                if reached[l.target] == nil { reached[l.target] = l.checkout; frontier.append(l.target) }
            }
            while let r = frontier.popLast() {
                for l in links where (l.location == r || l.location.hasPrefix(r + "/")) && reached[l.target] == nil {
                    reached[l.target] = reached[r]
                    frontier.append(l.target)
                }
            }
            for i in candidates.indices where planned[i] {
                let t = candidates[i].action.target
                if let (_, holder) = reached.first(where: { r, _ in r == t || r.hasPrefix(t + "/") || t.hasPrefix(r + "/") }) {
                    skip(i, "\(holder) links into it")
                    changed = true
                } else if let inner = allCheckouts.first(where: { $0.hasPrefix(t + "/") && !gone.contains($0) }) {
                    skip(i, "it contains the checkout \(inner)")
                    changed = true
                }
            }
        }

        // Nested targets first, so a failure inside stops its container (see `stayed`).
        return candidates.indices.compactMap { i -> Candidate? in
            guard planned[i], candidates[i].kind != .link else { return nil }
            var c = candidates[i]
            c.action.bytes = FS.allocatedSize(c.action.target)
            return c
        }.sorted { $0.action.target.count > $1.action.target.count }
    }

    static let salvageCap: Int64 = 50_000_000

    /// Untracked, non-ignored files: what salvage tars up.
    func untracked(_ path: String) -> (files: [String], bytes: Int64)? {
        let r = git(["ls-files", "--others", "--exclude-standard", "-z"], cwd: path)
        guard r.ok else { return nil }
        let files = r.stdout.split(separator: "\0").map(String.init)
        return (files, files.reduce(Int64(0)) { $0 + FS.allocatedSize(path + "/" + $1) })
    }

    /// Why removing this worktree would lose work salvage cannot keep, or nil.
    /// The submodule repos in a git dir's `modules/`, nested ones included.
    static func submoduleGitDirs(_ gitdir: String) -> [String] {
        var found: [String] = []
        var stack = [gitdir + "/modules"]
        while let dir = stack.popLast() {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                let path = dir + "/" + name
                guard FS.isDirectory(path) else { continue }
                // A name with slashes (`packages/x`) nests plain folders first.
                if FS.isDirectory(path + "/objects") {
                    found.append(path)
                    stack.append(path + "/modules")
                } else {
                    stack.append(path)
                }
            }
        }
        return found
    }

    func unsalvageable(_ path: String) -> String? {
        // A linked worktree's submodule repos live in its own git dir and go with it.
        // `S<c><m><u>`: new commits, changes or untracked files.
        let status = git(["-c", "status.showUntrackedFiles=normal", "status", "--porcelain=v2", "--ignore-submodules=none"], cwd: path)
        guard status.ok else { return "git status failed: \(status.stderr)" }
        let busy = status.stdout.split(separator: "\n").compactMap { line -> String? in
            let f = line.split(separator: " ", maxSplits: 8)
            guard f.count == 9, f[0] == "1" || f[0] == "2", f[2].hasPrefix("S"), f[2] != "S..." else { return nil }
            return String(f[8])
        }
        if let sub = busy.first { return "its submodule \(sub) has work salvage cannot keep" }
        // Commits on a branch or stash, or left behind by `submodule update` (the reflog), show in no status.
        for dir in Self.gitdir(of: path).map(Self.submoduleGitDirs) ?? [] {
            let r = Shell.run(["git", "--git-dir=\(dir)", "rev-list", "-n1", "--all", "--reflog", "--not", "--remotes"])
            if !r.ok || !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "its submodule repo \(dir) holds commits no remote has"
            }
        }
        guard let u = untracked(path) else { return "git ls-files failed" }
        guard u.bytes > Self.salvageCap else { return nil }
        return "its \(u.files.count) untracked files (\(u.bytes / 1_000_000) MB) are too big to salvage"
    }

    func execute(_ c: Candidate) -> Action {
        var a = c.action
        // Mounted since planning, which can take minutes.
        let inner = stayed.first { $0.hasPrefix(a.target + "/") }
            ?? FS.mountPoints().first { $0 == a.target || $0.hasPrefix(a.target + "/") }
        if let inner {
            a.status = .failed
            a.error = "it contains \(inner), which stays"
            stayed.append(a.target)
            return a
        }
        do {
            switch c.kind {
            case .plainDirectory, .link:
                try FS.remove(a.target)
            case .gitWorktree(let repo, let head):
                a.salvage = try salvage(a.target, head: head, repo: repo)
                try Safety.check(a.target)
                let record = Self.gitdir(of: a.target)
                let r = git(["worktree", "remove", "--force", "--force", a.target], cwd: repo)
                if !r.ok {
                    try FS.remove(a.target)
                    // Not `git worktree prune`, which drops every lost record, moved worktrees' too.
                    if let record, Self.isWorktreeGitdir(record), FS.exists(record) { try FS.remove(record) }
                }
            }
            a.status = .removed
        } catch {
            a.status = .failed
            a.error = "\(error)"
            stayed.append(a.target)
        }
        return a
    }

    /// Keeps what removal would otherwise destroy: a ref for commits no branch
    /// or remote holds, and a patch plus tarball of uncommitted work.
    func salvage(_ path: String, head: String, repo: String) throws -> String? {
        // The path hash keeps same-named worktrees of different folders apart.
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        // Also a ref name, which allows no spaces, `~`, `:` or leading dots.
        let base = (path as NSString).lastPathComponent.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" ? String($0) : "-" }.joined()
        let name = base + "-" + digest
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
        var kept: [String] = []

        let held = git(["for-each-ref", "--count=1", "--contains", head, "refs/heads", "refs/remotes", "refs/janitor"], cwd: repo)
        guard held.ok else { throw JanitorError("git for-each-ref failed: \(held.stderr)") }
        if held.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let ref = "refs/janitor/\(name)-\(stamp)"
            guard git(["update-ref", ref, head], cwd: repo).ok else { throw JanitorError("could not create \(ref)") }
            kept.append(ref)
        }

        let dir = cfg.salvageDir
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Written by git itself: the patch must survive non-UTF-8 content byte for byte.
        let patch = "\(dir)/\(name)-\(stamp).patch"
        // Pinned against config: diff.external, textconv, color, noprefix and context garble a patch.
        let diff = git(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "-U3",
                        "HEAD", "--binary", "--output=\(patch)"], cwd: path)
        guard diff.ok else { throw JanitorError("git diff failed in \(path): \(diff.stderr)") }
        if (FS.lstatInfo(patch)?.st_size ?? 0) > 0 {
            kept.append(patch)
        } else {
            try? FileManager.default.removeItem(atPath: patch)
        }
        guard let u = untracked(path) else { throw JanitorError("git ls-files failed in \(path)") }
        if !u.files.isEmpty {
            guard u.bytes <= Self.salvageCap else {
                throw JanitorError("\(u.files.count) untracked files (\(u.bytes / 1_000_000) MB) are too big to salvage")
            }
            let list = "\(dir)/\(name)-\(stamp).untracked"
            try u.files.joined(separator: "\n").write(toFile: list, atomically: true, encoding: .utf8)
            let tgz = "\(dir)/\(name)-\(stamp)-untracked.tgz"
            let tar = Shell.run(["tar", "-czf", tgz, "-T", list], cwd: path, timeout: 600)
            try? FileManager.default.removeItem(atPath: list)
            guard tar.ok else { throw JanitorError("tar of untracked files failed: \(tar.stderr)") }
            kept.append(tgz)
        }
        return kept.isEmpty ? nil : kept.joined(separator: ", ")
    }
}
