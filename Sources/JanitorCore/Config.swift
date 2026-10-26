import Foundation

/// Thresholds and switches. `config.json` holds only the keys that differ from these defaults.
public struct Config: Codable, Equatable, Sendable {
    /// Automatic (launchd) runs do nothing while paused; `janitor run` still works.
    public var paused = false
    /// Hours between automatic runs.
    public var intervalHours = 6.0
    /// Below this much free space an automatic run starts without waiting for the interval.
    public var lowDiskGB = 20.0
    public var disabled: [Category] = []
    /// Searched for repos with worktrees and for worktrees whose repo is gone.
    public var worktreeSearchRoot = Paths.home.path
    /// Targets never removed; a path also keeps everything under it.
    public var keep: [String] = []

    public var nodeModulesIdleDays = 3.0
    public var openPRIdleDays = 3.0
    public var abandonedIdleDays = 30.0
    /// A merged worktree must also be idle this long, so one an agent created
    /// minutes ago at `origin/main` is not removed under it.
    public var mergedIdleDays = 1.0
    public var dockerImageUnusedDays = 7.0
    public var avdUnusedDays = 7.0
    public var scratchpadIdleDays = 14.0

    public var scratchpadRoot = "/private/tmp/claude-\(getuid())"
    public var avdHome = Paths.home.appendingPathComponent(".android/avd").path
    /// Where uncommitted work from removed worktrees is kept.
    public var salvageDir = Paths.salvage.path

    public init() {}

    public func enabled(_ c: Category) -> Bool { !disabled.contains(c) }

    /// The `keep` entries protecting `target`: the target itself, an ancestor, or for a
    /// path, something inside it, since removing a folder removes its contents too.
    public func keepEntries(for target: String) -> [String] {
        // Docker targets end in " (<image id>)"; retagging must not end the keep.
        func imageID(_ s: String) -> Substring? {
            s.hasSuffix(")") ? s.range(of: " (", options: .backwards).map { s[$0.upperBound...] } : nil
        }
        return keep.filter { entry in
            guard target.hasPrefix("/") else { return entry == target || (imageID(entry) != nil && imageID(entry) == imageID(target)) }
            let k = FS.canonical(FS.normalize(entry))
            return target == k || target.hasPrefix(k + "/") || k.hasPrefix(target + "/")
        }
    }

    public func isKept(_ target: String) -> Bool { !keepEntries(for: target).isEmpty }

    /// Defaults when the file is missing. A file that is not valid JSON, has an unknown
    /// key or a wrong value throws: guessing would unpause the job or drop the keep list.
    public static func load(from url: URL = Paths.config) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        let data = try Data(contentsOf: url)
        guard let overrides = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JanitorError("\(url.path) is not a JSON object")
        }
        let defaults = Config().dictionary
        if let unknown = overrides.keys.sorted().first(where: { defaults[$0] == nil }) {
            let near = defaults.keys.min { distance($0, unknown) < distance($1, unknown) }!
            throw JanitorError("\(url.path): unknown key \"\(unknown)\", did you mean \"\(near)\"?")
        }
        do {
            let merged = try JSONSerialization.data(withJSONObject: defaults.merging(overrides) { _, new in new })
            return try JSONDecoder().decode(Config.self, from: merged)
        } catch let DecodingError.dataCorrupted(ctx) {
            let key = ctx.codingPath.first?.stringValue ?? "?"
            throw JanitorError("\(url.path): bad value for \"\(key)\"; categories are \(Category.allCases.map(\.rawValue).joined(separator: ", "))")
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw JanitorError("\(url.path): wrong type for \"\(ctx.codingPath.first?.stringValue ?? "?")\"")
        }
    }

    /// Writes the keys that differ from the defaults, so later default changes still apply.
    public func save(to url: URL = Paths.config) throws {
        let defaults = Config().dictionary
        let diff = dictionary.filter { key, value in
            !(defaults[key].map { NSDictionary(dictionary: [key: $0]).isEqual(to: [key: value]) } ?? false)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: diff, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: url, options: .atomic)
    }

    /// Levenshtein distance.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return a.count + b.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }

    var dictionary: [String: Any] {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
    }
}
