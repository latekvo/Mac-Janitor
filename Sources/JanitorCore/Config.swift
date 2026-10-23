import Foundation

/// Thresholds and switches. `config.json` may override any subset of keys.
public struct Config: Codable, Sendable {
    /// Automatic (launchd) runs do nothing while paused; `janitor run` still works.
    public var paused = false

    /// The main checkout; every worktree registered with it is in scope.
    public var argentRepo = Paths.home.appendingPathComponent("dev/engineering/argent").path
    /// Folders scanned for worktrees, including plain copies git does not know about.
    public var worktreeRoots = [Paths.home.appendingPathComponent("dev/engineering/argent-worktrees").path]

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

    public static func load(from url: URL = Paths.config) -> Config {
        guard let data = try? Data(contentsOf: url),
              let overrides = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return Config() }
        // Merge onto the defaults so a partial file keeps the rest.
        let base = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as! [String: Any]
        let merged = base.merging(overrides) { _, new in new }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let cfg = try? JSONDecoder().decode(Config.self, from: mergedData)
        else { return Config() }
        return cfg
    }

    /// Rewrites only `paused`, keeping any other overrides in the file.
    public static func setPaused(_ paused: Bool, at url: URL = Paths.config) throws {
        var obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        obj["paused"] = paused
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}
