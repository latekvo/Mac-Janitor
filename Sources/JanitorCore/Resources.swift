import Foundation

enum DockerJanitor {
    /// When each image was last seen in use, or first seen at all. Docker records
    /// neither: a pulled image's dates are its upstream build time.
    static func lastActive(previous: [String: Date], images: [String], inUse: Set<String>, now: Date) -> [String: Date] {
        var next: [String: Date] = [:]
        for id in images { next[id] = inUse.contains(id) ? now : previous[id] ?? now }
        return next
    }

    /// An image is unused once no container (running, stopped or Docker Desktop's
    /// own) has been seen referencing it for the threshold. Every run, preview or
    /// not, records what it sees in `Paths.dockerSeen`.
    static func plan(_ cfg: Config, now: Date, skips: inout [Skip], issues: inout [Issue]) -> [Action] {
        let info = Shell.run(["docker", "info", "--format", "{{.ServerVersion}}"], timeout: 20)
        guard info.ok else {
            if !info.notFound { issues.append(Issue(.dockerImage, "Docker is not running")) }
            return []
        }
        // `docker system df -v` also lists Docker Desktop's own containers (Kubernetes,
        // kind), which `docker ps -a` hides; it names their images by reference.
        let df = Shell.run(["docker", "system", "df", "-v", "--format",
                            "{{range .Containers}}{{.Image}}\n{{end}}"], timeout: 60)
        guard df.ok else {
            issues.append(Issue(.dockerImage, "docker system df failed: \(df.stderr)"))
            return []
        }
        var inUse = Set<String>()
        for ref in Set(lines(df.stdout)) {
            let id = Shell.run(["docker", "image", "inspect", "--format", "{{.Id}}", ref]).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { inUse.insert(id) }
        }
        let imageIDs = Array(Set(lines(Shell.run(["docker", "image", "ls", "-q", "--no-trunc"]).stdout)))
        // Dry runs overlap each other and a real run; without this one's write drops another's.
        let seenLock = open(Paths.dockerSeen.path + ".lock", O_CREAT | O_RDWR, 0o644)
        if seenLock >= 0 { flock(seenLock, LOCK_EX) }
        let previous = (try? JSONDecoder.janitor.decode([String: Date].self, from: Data(contentsOf: Paths.dockerSeen))) ?? [:]
        let active = lastActive(previous: previous, images: imageIDs, inUse: inUse, now: now)
        try? JSONEncoder.janitor.encode(active).write(to: Paths.dockerSeen, options: .atomic)
        if seenLock >= 0 { close(seenLock) }
        guard !imageIDs.isEmpty else { return [] }

        let r = Shell.run(["docker", "image", "inspect", "--format", "{{.Id}}|{{.Size}}|{{join .RepoTags \",\"}}"] + imageIDs)
        var actions: [Action] = []
        for line in lines(r.stdout) {
            let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard p.count == 3, let since = active[p[0]] else { continue }
            let idle = now.timeIntervalSince(since) / 86400
            guard idle > cfg.dockerImageUnusedDays else { continue }
            let target = "\(p[2].isEmpty ? "<none>" : p[2]) (\(p[0].replacingOccurrences(of: "sha256:", with: "").prefix(12)))"
            let bytes = Int64(p[1]) ?? 0
            if cfg.isKept(target) {
                skips.append(Skip(category: .dockerImage, target: target, reason: "kept", kept: true, bytes: bytes))
                continue
            }
            actions.append(Action(category: .dockerImage, target: target,
                                  reason: "no container used it for \(Int(idle)) days", bytes: bytes, status: .planned))
        }
        return actions
    }

    static func execute(_ a: Action) -> Action {
        var a = a
        // The id sits in parentheses at the end of the target.
        let id = String(a.target.split(separator: "(").last!.dropLast())
        // -f so an image with several tags goes in one call; images used by a
        // container are never planned.
        let r = Shell.run(["docker", "rmi", "-f", id], timeout: 300)
        a.status = r.ok ? .removed : .failed
        if !r.ok { a.error = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
        return a
    }
}

enum AVDJanitor {
    static func plan(_ cfg: Config, guards: Guards, now: Date, skips: inout [Skip]) -> [Action] {
        let home = cfg.avdHome
        let running = Shell.run(["ps", "-axo", "command"]).stdout
        var actions: [Action] = []
        for ini in (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? [] where ini.hasSuffix(".ini") {
            let name = String(ini.dropLast(4))
            let dir = avdDirectory(home: home, name: name)
            guard FS.isDirectory(dir) else { continue }
            let newest = FS.newestMTime(dir) ?? .distantPast
            let age = now.timeIntervalSince(newest) / 86400
            guard age > cfg.avdUnusedDays else { continue }
            let reason = "unused for \(String(format: "%.1f", age)) days"
            if cfg.isKept(name) {
                skips.append(Skip(category: .avd, target: name, reason: "kept", kept: true, bytes: measure(dir)))
                continue
            }
            if running.contains("-avd \(name)") || running.contains("@\(name)") {
                skips.append(Skip(category: .avd, target: name, reason: "\(reason), but its emulator is running"))
                continue
            }
            if let veto = guards.veto(dir) {
                skips.append(Skip(category: .avd, target: name, reason: "\(reason), but \(veto)"))
                continue
            }
            actions.append(Action(category: .avd, target: name, reason: reason,
                                  bytes: measure(dir), status: .planned))
        }
        return actions + planImages(cfg, guards: guards, now: now, skips: &skips)
    }

    /// The SDK's `system-images/<api>/<tag>/<abi>` folders, which emulators boot from.
    static func systemImages(sdk: String) -> [String] {
        func dirs(_ path: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
                .map { path + "/" + $0 }.filter(FS.isDirectory)
        }
        return dirs(sdk + "/system-images").flatMap(dirs).flatMap(dirs)
    }

    /// A system image no AVD names in its `image.sysdir.1`, and no emulator read for
    /// `avdUnusedDays`; `sdkmanager` downloads it again.
    static func planImages(_ cfg: Config, guards: Guards, now: Date, skips: inout [Skip]) -> [Action] {
        let sdk = FS.canonical(cfg.androidSDK)
        var used = Set<String>()
        for ini in (try? FileManager.default.contentsOfDirectory(atPath: cfg.avdHome)) ?? [] where ini.hasSuffix(".ini") {
            let config = avdDirectory(home: cfg.avdHome, name: String(ini.dropLast(4))) + "/config.ini"
            for line in ((try? String(contentsOfFile: config, encoding: .utf8)) ?? "").split(separator: "\n")
            where line.hasPrefix("image.sysdir.") {
                let value = line.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                used.insert(FS.normalize(sdk + "/" + value))
            }
        }
        let cutoff = now.addingTimeInterval(-cfg.avdUnusedDays * 86400)
        return systemImages(sdk: sdk).compactMap { image -> Action? in
            guard !used.contains(image), let last = FS.lastUsed(image, newerThan: cutoff), last <= cutoff else { return nil }
            return planPath(.avd, image, reason: "no emulator uses it; unused for \(days(last, now)) days",
                            cfg: cfg, guards: guards, skips: &skips)
        }
    }

    /// What an AVD action removes: an AVD by name, or a system image by path.
    static func directory(of a: Action, _ cfg: Config) -> String {
        a.target.hasPrefix("/") ? a.target : avdDirectory(home: cfg.avdHome, name: a.target)
    }

    /// The `.ini` names the AVD's directory; it defaults to `<name>.avd` beside it.
    static func avdDirectory(home: String, name: String) -> String {
        let ini = (try? String(contentsOfFile: "\(home)/\(name).ini", encoding: .utf8)) ?? ""
        for line in ini.split(separator: "\n") where line.hasPrefix("path=") {
            return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        return "\(home)/\(name).avd"
    }

    static func execute(_ a: Action, _ cfg: Config) -> Action {
        if a.target.hasPrefix("/") {
            let done = removePath(a)
            // The emptied <tag> and <api> folders; rmdir refuses non-empty ones.
            let tag = (a.target as NSString).deletingLastPathComponent
            if rmdir(tag) == 0 { rmdir((tag as NSString).deletingLastPathComponent) }
            return done
        }
        var a = a
        do {
            try FS.remove(avdDirectory(home: cfg.avdHome, name: a.target))
            try FS.remove("\(cfg.avdHome)/\(a.target).ini")
            a.status = .removed
        } catch {
            a.status = .failed
            a.error = "\(error)"
        }
        return a
    }
}

enum ScratchpadJanitor {
    /// Claude Code keeps one directory per session under `<root>/<project>/<session>`.
    static func plan(_ cfg: Config, guards: Guards, now: Date, skips: inout [Skip]) -> [Action] {
        let cutoff = now.addingTimeInterval(-cfg.scratchpadIdleDays * 86400)
        var actions: [Action] = []
        let root = cfg.scratchpadRoot
        for project in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let pdir = root + "/" + project
            guard FS.isDirectory(pdir) else { continue }
            for session in (try? FileManager.default.contentsOfDirectory(atPath: pdir)) ?? [] {
                let sdir = pdir + "/" + session
                guard FS.isDirectory(sdir) else { continue }
                let newest = FS.newestMTime(sdir, newerThan: cutoff) ?? .distantPast
                guard newest <= cutoff else { continue }
                if let a = planPath(.scratchpad, sdir, reason: "untouched for \(days(newest, now)) days",
                                    cfg: cfg, guards: guards, skips: &skips) { actions.append(a) }
            }
        }
        return actions
    }

    static func execute(_ a: Action) -> Action {
        let done = removePath(a)
        // Drop the project folder once its last session is gone; rmdir refuses a non-empty one.
        if done.status == .removed { rmdir((a.target as NSString).deletingLastPathComponent) }
        return done
    }
}

func lines(_ s: String) -> [String] {
    s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}
