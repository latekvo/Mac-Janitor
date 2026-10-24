import Foundation
import JanitorCore

enum Format {
    /// "812 MB", "3.1 GB", "124 GB": decimal units like Finder, at most one decimal.
    static func bytes(_ n: Int64) -> String {
        let parts = byteParts(n)
        return "\(parts.number) \(parts.unit)"
    }

    static func byteParts(_ n: Int64) -> (number: String, unit: String) {
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(max(n, 0)) / 1000
        var i = 0
        while value >= 999.5, i < units.count - 1 {
            value /= 1000
            i += 1
        }
        let digits = value >= 99.95 ? 0 : 1
        return (value.formatted(.number.precision(.fractionLength(0...digits))), units[i])
    }

    /// `/Users/me/x` -> `~/x`.
    static func path(_ p: String) -> String {
        let home = Paths.home.path
        if p == home { return "~" }
        return p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }

    /// "now", "5m", "2h", "3d".
    static func span(_ seconds: TimeInterval) -> String {
        let s = abs(seconds)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = span(now.timeIntervalSince(date))
        return s == "now" ? s : "\(s) ago"
    }

    static func absolute(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// 3 -> "3", 0.5 -> "0.5".
    static func number(_ x: Double) -> String {
        x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x)
    }

    /// A node_modules by its worktree, a scratchpad by project and session, an image by
    /// its first tag without registry, anything else by its last path component.
    static func name(_ target: String, _ category: JanitorCore.Category) -> String {
        let parts = target.split(separator: "/").map(String.init)
        switch category {
        case .nodeModules:
            // ".../<repo>-worktrees/<worktree>/[<package path>/]node_modules"
            let owner = parts.dropLast()
            let start = (owner.lastIndex { $0.hasSuffix("-worktrees") }).map { $0 + 1 } ?? owner.count - 1
            return owner[max(start, owner.startIndex)...].joined(separator: "/")
        case .scratchpad:
            // ".../<project path with / as ->/<session id>"
            guard parts.count >= 2 else { return target }
            let project = parts[parts.count - 2].split(separator: "-").last.map(String.init) ?? ""
            return "\(project) · \(parts[parts.count - 1].prefix(8))"
        case .dockerImage:
            let parts = target.components(separatedBy: " (")
            let tags = parts[0]
            if tags == "<none>", parts.count > 1 { return String(parts[1].dropLast()) }
            let first = tags.components(separatedBy: ",").first ?? tags
            return first.components(separatedBy: "/").last ?? first
        default:
            return (target as NSString).lastPathComponent
        }
    }
}

extension JanitorCore.Category {
    var title: String {
        switch self {
        case .worktree: return "Worktrees"
        case .nodeModules: return "node_modules"
        case .dockerImage: return "Docker"
        case .avd: return "Emulators"
        case .scratchpad: return "Scratchpads"
        }
    }

    var symbol: String {
        switch self {
        case .worktree: return "arrow.triangle.branch"
        case .nodeModules: return "shippingbox"
        case .dockerImage: return "square.stack.3d.up"
        case .avd: return "iphone"
        case .scratchpad: return "note.text"
        }
    }
}
