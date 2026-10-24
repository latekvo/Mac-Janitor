import Foundation

/// Parses Docker's RFC 3339 timestamps, whose nanosecond fractions ISO8601DateFormatter rejects.
func parseDockerDate(_ s: String) -> Date? {
    let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    let d = ISO8601DateFormatter().date(from: trimmed)
    // The zero time marks "never" (e.g. an image that was never tagged locally).
    return d.flatMap { $0.timeIntervalSince1970 < 0 ? nil : $0 }
}

enum DockerJanitor {
    struct Image {
        var id: String
        var tags: String
        var bytes: Int64
        /// When it last arrived locally: pull, build or tag, else its creation.
        var arrived: Date?
    }

    /// Docker keeps no last-used time, so an image counts as unused once no
    /// container (running or stopped) references it and it arrived locally
    /// longer ago than the threshold.
    static func plan(_ cfg: Config, now: Date, skips: inout [Skip], issues: inout [Issue]) -> [Action] {
        guard Shell.run(["docker", "info", "--format", "{{.ServerVersion}}"], timeout: 20).ok else {
            issues.append(Issue(.dockerImage, "Docker is not running"))
            return []
        }
        // `docker system df -v` also lists Docker Desktop's own containers (Kubernetes,
        // kind), which `docker ps -a` hides; it names their images by reference.
        let df = Shell.run(["docker", "system", "df", "-v", "--format",
                            "{{range .Containers}}{{.Image}}|{{.Names}}\n{{end}}"], timeout: 60)
        guard df.ok else {
            issues.append(Issue(.dockerImage, "docker system df failed: \(df.stderr)"))
            return []
        }
        var usedBy: [String: String] = [:]
        for line in lines(df.stdout) {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let id = Shell.run(["docker", "image", "inspect", "--format", "{{.Id}}", parts[0]]).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { usedBy[id] = parts[1] }
        }
        let imageIDs = Array(Set(lines(Shell.run(["docker", "image", "ls", "-q", "--no-trunc"]).stdout)))
        guard !imageIDs.isEmpty else { return [] }
        let r = Shell.run(["docker", "image", "inspect", "--format",
                           "{{.Id}}|{{.Size}}|{{.Metadata.LastTagTime}}|{{.Created}}|{{join .RepoTags \",\"}}"] + imageIDs)
        var actions: [Action] = []
        for line in lines(r.stdout) {
            let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard p.count == 5 else { continue }
            let img = Image(id: p[0], tags: p[4].isEmpty ? "<none>" : p[4], bytes: Int64(p[1]) ?? 0,
                            arrived: parseDockerDate(p[2]) ?? parseDockerDate(p[3]))
            guard let arrived = img.arrived else { continue }
            let age = now.timeIntervalSince(arrived) / 86400
            guard age > cfg.dockerImageUnusedDays else { continue }
            let target = "\(img.tags) (\(img.id.replacingOccurrences(of: "sha256:", with: "").prefix(12)))"
            if cfg.isKept(target) {
                skips.append(Skip(category: .dockerImage, target: target, reason: "kept", kept: true, bytes: img.bytes))
                continue
            }
            if let container = usedBy[img.id] {
                skips.append(Skip(category: .dockerImage, target: target,
                                  reason: "arrived \(Int(age)) days ago, but container \(container) uses it"))
                continue
            }
            actions.append(Action(category: .dockerImage, target: target,
                                  reason: "no container uses it; arrived \(Int(age)) days ago",
                                  bytes: img.bytes, status: .planned))
        }
        return actions
    }

    static func execute(_ a: Action) -> Action {
        var a = a
        // The id sits in parentheses at the end of the target.
        let id = String(a.target.split(separator: "(").last!.dropLast())
        // -f so an image with several tags goes in one call; images used by a
        // container never reach this point.
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
                skips.append(Skip(category: .avd, target: name, reason: "kept", kept: true, bytes: FS.allocatedSize(dir)))
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
                                  bytes: FS.allocatedSize(dir), status: .planned))
        }
        return actions
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
                let reason = "untouched for \(Int(now.timeIntervalSince(newest) / 86400)) days"
                if cfg.isKept(sdir) {
                    skips.append(Skip(category: .scratchpad, target: sdir, reason: "kept", kept: true,
                                      bytes: FS.allocatedSize(sdir)))
                    continue
                }
                if let veto = guards.veto(sdir) {
                    skips.append(Skip(category: .scratchpad, target: sdir, reason: "\(reason), but \(veto)"))
                    continue
                }
                actions.append(Action(category: .scratchpad, target: sdir, reason: reason,
                                      bytes: FS.allocatedSize(sdir), status: .planned))
            }
        }
        return actions
    }

    static func execute(_ a: Action) -> Action {
        var a = a
        do {
            try FS.remove(a.target)
            a.status = .removed
            // Drop the project folder once its last session is gone.
            let project = (a.target as NSString).deletingLastPathComponent
            if (try? FileManager.default.contentsOfDirectory(atPath: project))?.isEmpty == true {
                try? FileManager.default.removeItem(atPath: project)
            }
        } catch {
            a.status = .failed
            a.error = "\(error)"
        }
        return a
    }
}

func lines(_ s: String) -> [String] {
    s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}
