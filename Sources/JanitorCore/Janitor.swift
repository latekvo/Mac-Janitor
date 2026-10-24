import Foundation

public enum Janitor {
    static var lockPath: String { Paths.support.appendingPathComponent("run.lock").path }

    /// True while some janitor process, scheduled or not, holds the run lock.
    public static func isRunning() -> Bool {
        let fd = open(lockPath, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    /// Why a scheduled run should not start now, or nil to run.
    public static func scheduledSkipReason(_ cfg: Config, lastStart: Date?, freeBytes: Int64, now: Date = Date()) -> String? {
        if cfg.paused { return "paused" }
        let lowDisk = freeBytes > 0 && Double(freeBytes) < cfg.lowDiskGB * 1e9
        if let lastStart, !lowDisk, now.timeIntervalSince(lastStart) < cfg.intervalHours * 3600 {
            return "last run under \(cfg.intervalHours) h ago"
        }
        return nil
    }

    /// Plans every enabled rule and, unless `dryRun`, carries the plan out. With
    /// `only`, a real run acts on just those action ids, if they are still planned.
    /// Holds an exclusive lock for the duration, so overlapping runs fail fast.
    public static func run(_ cfg: Config, dryRun: Bool, only: Set<String>? = nil,
                           log: (String) -> Void = { _ in }) throws -> Report {
        try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw JanitorError("another janitor run is in progress")
        }
        defer { close(lockFD) }

        let started = Date()
        let freeBefore = freeDiskBytes()
        Safety.protectedPaths = (cfg.repos + cfg.repos.map(WorktreeJanitor.root) + [cfg.avdHome, cfg.scratchpadRoot])
            .map(FS.canonical)
        let guards = Guards.gather()
        var skips: [Skip] = []
        var issues: [Issue] = []

        let wt = WorktreeJanitor(cfg: cfg, guards: guards, only: only)
        let worktrees = wt.plan()
        skips += wt.skips
        issues += wt.issues
        let scratch = cfg.enabled(.scratchpad) ? ScratchpadJanitor.plan(cfg, guards: guards, now: started, skips: &skips) : []
        let avds = cfg.enabled(.avd) ? AVDJanitor.plan(cfg, guards: guards, now: started, skips: &skips) : []
        let images = cfg.enabled(.dockerImage) ? DockerJanitor.plan(cfg, now: started, skips: &skips, issues: &issues) : []

        var actions: [Action] = []
        func wanted(_ a: Action) -> Bool { only?.contains(a.id) ?? true }
        func record(_ a: Action) {
            actions.append(a)
            let size = ByteCountFormatter.string(fromByteCount: a.bytes, countStyle: .file)
            var line = "\(a.status.rawValue) \(a.category.rawValue) \(a.target) (\(size)): \(a.reason)"
            if let s = a.salvage { line += " [salvaged: \(s)]" }
            if let e = a.error { line += " [error: \(e)]" }
            log(line)
        }
        for c in worktrees where wanted(c.action) { record(dryRun ? c.action : wt.execute(c)) }
        for a in scratch where wanted(a) { record(dryRun ? a : ScratchpadJanitor.execute(a)) }
        for a in avds where wanted(a) { record(dryRun ? a : AVDJanitor.execute(a, cfg)) }
        for a in images where wanted(a) { record(dryRun ? a : DockerJanitor.execute(a)) }
        if !dryRun && worktrees.contains(where: { $0.action.category == .worktree }) {
            for repo in cfg.repos { Shell.run(["git", "worktree", "prune"], cwd: repo) }
        }
        for s in skips { log("skip \(s.category.rawValue) \(s.target): \(s.reason)") }
        for i in issues { log("issue \(i.category.rawValue): \(i.message)") }

        let report = Report(startedAt: started, finishedAt: Date(), dryRun: dryRun,
                            freeBytesBefore: freeBefore, freeBytesAfter: freeDiskBytes(),
                            actions: actions, skips: skips, issues: issues)
        if !dryRun { try persist(report) }
        return report
    }

    static func persist(_ report: Report) throws {
        try JSONEncoder.janitor.encode(report).write(to: Paths.lastRun, options: .atomic)
        let removed = report.actions.filter { $0.status == .removed }
        let summary: [String: Any] = [
            "startedAt": ISO8601DateFormatter().string(from: report.startedAt),
            "freedBytes": report.freeBytesAfter - report.freeBytesBefore,
            "removed": removed.count,
            "failed": report.actions.filter { $0.status == .failed }.count,
            "removedBytes": removed.reduce(Int64(0)) { $0 + $1.bytes },
        ]
        var line = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        line.append(0x0A)
        if let h = FileHandle(forWritingAtPath: Paths.history.path) {
            h.seekToEndOfFile()
            h.write(line)
            h.closeFile()
        } else {
            try line.write(to: Paths.history)
        }
    }
}
