import Foundation
import JanitorCore

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// `/Users/me/x` -> `~/x`.
    static func path(_ p: String) -> String {
        let home = Paths.home.path
        if p == home { return "~" }
        return p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func absolute(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension JanitorCore.Category {
    var title: String {
        switch self {
        case .worktree: return "Worktrees"
        case .nodeModules: return "node_modules"
        case .dockerImage: return "Docker images"
        case .avd: return "Android emulators"
        case .scratchpad: return "Scratchpads"
        }
    }
}

extension Report {
    func bytes(_ status: Action.Status) -> Int64 {
        actions.filter { $0.status == status }.reduce(0) { $0 + $1.bytes }
    }

    func count(_ status: Action.Status) -> Int {
        actions.filter { $0.status == status }.count
    }
}
