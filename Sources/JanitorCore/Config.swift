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
    /// Main checkouts. Their registered worktrees are in scope, and so is every
    /// folder in `<repo>-worktrees`, git-registered or not.
    public var repos = [Paths.home.appendingPathComponent("dev/engineering/argent").path]
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

    public func isKept(_ target: String) -> Bool {
        keep.contains { target == $0 || target.hasPrefix($0 + "/") }
    }

    public static func load(from url: URL = Paths.config) -> Config {
        guard let data = try? Data(contentsOf: url),
              let overrides = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return Config() }
        let merged = Config().dictionary.merging(overrides) { _, new in new }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let cfg = try? JSONDecoder().decode(Config.self, from: mergedData)
        else { return Config() }
        return cfg
    }

    /// Writes the keys that differ from the defaults, so later default changes still apply.
    public func save(to url: URL = Paths.config) throws {
        let defaults = Config().dictionary
        let diff = dictionary.filter { key, value in
            !(defaults[key].map { NSDictionary(dictionary: [key: $0]).isEqual(to: [key: value]) } ?? false)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: diff, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    var dictionary: [String: Any] {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
    }
}
