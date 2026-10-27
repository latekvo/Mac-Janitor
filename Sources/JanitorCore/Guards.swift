import Foundation

/// Facts gathered once per run that veto removing a path: something has it
/// open or as its cwd, or a LaunchAgent refers to it.
public struct Guards {
    /// Sorted, so `veto` finds a path and what lies under it by binary search.
    var openPaths: [String]
    var launchAgentStrings: [(plist: String, value: String)]

    init(openPaths: [String], launchAgentStrings: [(plist: String, value: String)]) {
        self.openPaths = Set(openPaths).sorted()
        self.launchAgentStrings = launchAgentStrings
    }

    /// Without -b, lsof stats every mount point and file, waiting up to 15 s on each, so
    /// a stalled mount can run it past the timeout. Its paths come from the kernel either way.
    static let lsofArgs = ["lsof", "-n", "-b", "-w", "-Fn"]

    public static func gather() throws -> Guards {
        // Every process of this user: cwd, executables, mapped and open files.
        let r = Shell.run(lsofArgs, timeout: 60)
        // lsof exits 1 over a single unreadable process; no output means no guard at all.
        guard r.status == 0 || (r.status == 1 && !r.stdout.isEmpty) else {
            throw JanitorError("lsof failed, so nothing in use can be told apart: \(r.stderr)")
        }
        let open = r.stdout.split(separator: "\n").compactMap { line -> String? in
            line.hasPrefix("n/") ? String(line.dropFirst()) : nil
        }
        var agentStrings: [(String, String)] = []
        let dir = Paths.home.appendingPathComponent("Library/LaunchAgents").path
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".plist") {
            let path = dir + "/" + name
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
            else { continue }
            for s in strings(in: plist) { agentStrings.append((name, s)) }
        }
        return Guards(openPaths: open, launchAgentStrings: agentStrings)
    }

    static func strings(in value: Any) -> [String] {
        switch value {
        case let s as String: return [s]
        case let a as [Any]: return a.flatMap(strings)
        case let d as [String: Any]: return d.values.flatMap(strings)
        default: return []
        }
    }

    /// Why `path` must not be removed, or nil.
    public func veto(_ path: String) -> String? {
        // Everything under a folder sorts together, starting at the first string not below `path/`.
        func first(notBelow key: String) -> String? {
            var lo = 0, hi = openPaths.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if openPaths[mid] < key { lo = mid + 1 } else { hi = mid }
            }
            return lo < openPaths.count ? openPaths[lo] : nil
        }
        let prefix = path + "/"
        if let hit = first(notBelow: path), hit == path { return "in use (open: \(hit))" }
        if let hit = first(notBelow: prefix), hit.hasPrefix(prefix) { return "in use (open: \(hit))" }
        if let hit = launchAgentStrings.first(where: { $0.value == path || $0.value.contains(prefix) }) {
            return "referenced by LaunchAgent \(hit.plist)"
        }
        return nil
    }
}

/// Home folders no walk enters. macOS asks the user before a process reads Desktop,
/// Documents or Downloads, unless it has Full Disk Access; a background job must not
/// ask, so without it they are skipped. Music and Pictures hold media libraries,
/// never checkouts, and reading them asks for media access.
public enum Privacy {
    /// Readable only with Full Disk Access, and checking asks nothing.
    static let probe = Paths.home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path

    public static var hasFullDiskAccess: Bool {
        let fd = open(probe, O_RDONLY)
        if fd >= 0 { close(fd) }
        return fd >= 0
    }

    public static let askingFolders = ["Desktop", "Documents", "Downloads"].map { Paths.home.path + "/" + $0 }

    public static func unwalked(fullDiskAccess: Bool = hasFullDiskAccess) -> [String] {
        ["Music", "Pictures"].map { Paths.home.path + "/" + $0 } + (fullDiskAccess ? [] : askingFolders)
    }
}
