import Foundation

public enum Janitor {
    /// Plans every rule and, unless `dryRun`, carries the plan out. Holds an
    /// exclusive lock for the duration, so overlapping runs fail fast.
    public static func run(_ cfg: Config, dryRun: Bool, log: (String) -> Void = { _ in }) throws -> Report {
        try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let lockFD = open(Paths.support.appendingPathComponent("run.lock").path, O_CREAT | O_RDWR, 0o644)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw JanitorError("another janitor run is in progress")
        }
        defer { close(lockFD) }

        let started = Date()
        let freeBefore = freeDiskBytes()
        Safety.protectedPaths = ([cfg.argentRepo, cfg.avdHome, cfg.scratchpadRoot] + cfg.worktreeRoots).map(FS.canonical)
        let guards = Guards.gather()
        var skips: [Skip] = []
        var errors: [String] = []
        var actions: [Action] = []

        let wt = WorktreeJanitor(cfg: cfg, guards: guards)
        let worktrees = wt.plan()
        skips += wt.skips
        errors += wt.errors
        let scratch = ScratchpadJanitor.plan(cfg, guards: guards, now: started, skips: &skips)
        let avds = AVDJanitor.plan(cfg, guards: guards, now: started, skips: &skips)
        let images = DockerJanitor.plan(cfg, now: started, skips: &skips)

        func record(_ a: Action) {
            actions.append(a)
            let size = ByteCountFormatter.string(fromByteCount: a.bytes, countStyle: .file)
            var line = "\(a.status.rawValue) \(a.category.rawValue) \(a.target) (\(size)): \(a.reason)"
            if let s = a.salvage { line += " [salvaged: \(s)]" }
            if let e = a.error { line += " [error: \(e)]" }
            log(line)
        }
        for c in worktrees { record(dryRun ? c.action : wt.execute(c)) }
        for a in scratch { record(dryRun ? a : ScratchpadJanitor.execute(a)) }
        for a in avds { record(dryRun ? a : AVDJanitor.execute(a, cfg)) }
        for a in images {
            let done = dryRun ? a : DockerJanitor.execute(a)
            // Docker Desktop's own containers (Kubernetes, kind) hold images
            // without showing up in `docker ps -a`; Docker refusing is not a failure.
            if done.status == .failed, let e = done.error, e.contains("is being used by") {
                skips.append(Skip(category: .dockerImage, target: a.target, reason: "\(a.reason), but \(e)"))
            } else {
                record(done)
            }
        }
        if !dryRun && !worktrees.isEmpty {
            Shell.run(["git", "worktree", "prune"], cwd: cfg.argentRepo)
        }
        for s in skips { log("skip \(s.category.rawValue) \(s.target): \(s.reason)") }
        for e in errors { log("error: \(e)") }

        let report = Report(startedAt: started, finishedAt: Date(), dryRun: dryRun,
                            freeBytesBefore: freeBefore, freeBytesAfter: freeDiskBytes(),
                            actions: actions, skips: skips, errors: errors)
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
