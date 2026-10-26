import Foundation

/// Facts gathered once per run that veto removing a path: something has it
/// open or as its cwd, or a LaunchAgent refers to it.
public struct Guards {
    var openPaths: [String]
    var launchAgentStrings: [(plist: String, value: String)]

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
        return Guards(openPaths: Array(Set(open)), launchAgentStrings: agentStrings)
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
        let prefix = path + "/"
        if let hit = openPaths.first(where: { $0 == path || $0.hasPrefix(prefix) }) {
            return "in use (open: \(hit))"
        }
        if let hit = launchAgentStrings.first(where: { $0.value == path || $0.value.contains(prefix) }) {
            return "referenced by LaunchAgent \(hit.plist)"
        }
        return nil
    }
}
