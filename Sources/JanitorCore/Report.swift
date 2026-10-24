import Foundation

public enum Category: String, Codable, CaseIterable, Sendable {
    case worktree
    case nodeModules = "node_modules"
    case dockerImage = "docker-image"
    case avd
    case scratchpad
}

public struct Action: Codable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        /// Would be removed; recorded by a dry run.
        case planned
        case removed
        case failed
    }

    public var id: String { "\(category.rawValue):\(target)" }
    public var category: Category
    public var target: String
    public var reason: String
    /// Allocated size measured before removal. APFS clones and hard links make
    /// the space actually freed smaller; `Report.freeBytesAfter` is the truth.
    public var bytes: Int64
    public var status: Status
    public var error: String?
    /// Where uncommitted changes or unreachable commits were preserved, if anywhere.
    public var salvage: String?

    public init(category: Category, target: String, reason: String, bytes: Int64,
                status: Status, error: String? = nil, salvage: String? = nil) {
        self.category = category
        self.target = target
        self.reason = reason
        self.bytes = bytes
        self.status = status
        self.error = error
        self.salvage = salvage
    }
}

/// A candidate a rule matched but a guard or `Config.keep` protected.
public struct Skip: Codable, Sendable, Identifiable {
    public var id: String { "\(category.rawValue):\(target)" }
    public var category: Category
    public var target: String
    public var reason: String
    /// Protected by `Config.keep` rather than by a guard.
    public var kept: Bool
    public var bytes: Int64

    public init(category: Category, target: String, reason: String, kept: Bool = false, bytes: Int64 = 0) {
        self.category = category
        self.target = target
        self.reason = reason
        self.kept = kept
        self.bytes = bytes
    }
}

/// A rule that could not run, wholly or partly, e.g. Docker not running.
public struct Issue: Codable, Sendable, Hashable {
    public var category: Category
    public var message: String

    public init(_ category: Category, _ message: String) {
        self.category = category
        self.message = message
    }
}

public struct Report: Codable, Sendable {
    public var startedAt: Date
    public var finishedAt: Date
    public var dryRun: Bool
    public var freeBytesBefore: Int64
    public var freeBytesAfter: Int64
    public var actions: [Action]
    public var skips: [Skip]
    public var issues: [Issue]

    public init(startedAt: Date, finishedAt: Date, dryRun: Bool, freeBytesBefore: Int64,
                freeBytesAfter: Int64, actions: [Action], skips: [Skip], issues: [Issue]) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.dryRun = dryRun
        self.freeBytesBefore = freeBytesBefore
        self.freeBytesAfter = freeBytesAfter
        self.actions = actions
        self.skips = skips
        self.issues = issues
    }

    public static func load(from url: URL = Paths.lastRun) -> Report? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.janitor.decode(Report.self, from: data)
    }
}

extension JSONEncoder {
    public static var janitor: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    public static var janitor: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

public enum Paths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser
    public static let support = home.appendingPathComponent("Library/Application Support/MacJanitor")
    /// The last real (non-dry) run, written by the launchd job.
    public static let lastRun = support.appendingPathComponent("last-run.json")
    /// One compact JSON line per real run.
    public static let history = support.appendingPathComponent("history.jsonl")
    public static let salvage = support.appendingPathComponent("salvage")
    public static let config = support.appendingPathComponent("config.json")
    public static let log = home.appendingPathComponent("Library/Logs/mac-janitor.log")
    public static let launchdLabel = "com.ignacy.mac-janitor"
}

public func freeDiskBytes() -> Int64 {
    // What `df` reports; the "important usage" figure adds purgeable space that
    // macOS may never actually hand back.
    let values = try? Paths.home.resourceValues(forKeys: [.volumeAvailableCapacityKey])
    return Int64(values?.volumeAvailableCapacity ?? 0)
}
