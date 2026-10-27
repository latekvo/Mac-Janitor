import AppKit
import Foundation
import JanitorCore
import ServiceManagement

/// One line in an expanded category.
struct Item: Identifiable {
    enum Kind {
        case planned, failed, kept, guarded
        /// Unpinned since the preview; whether it is planned is known after the next one.
        case pending
    }

    var id: String
    var target: String
    var name: String
    var bytes: Int64
    var kind: Kind
    var detail: String
}

@MainActor
final class Store: ObservableObject {
    enum Busy { case previewing, cleaning, scheduled }

    @Published private(set) var config: Config
    @Published private(set) var freeBytes: Int64
    @Published private(set) var totalBytes: Int64
    /// The last real run, as the CLI recorded it in `Paths.lastRun`.
    @Published private(set) var lastRun: Report?
    /// What a clean would remove: a dry run, or after a clean the items that failed.
    @Published private(set) var preview: Report?
    @Published private(set) var busy: Busy?
    @Published var problem: String?
    private var configProblem: String?
    @Published private(set) var loginStatus: SMAppService.Status
    @Published var showSettings = false
    @Published var expanded: JanitorCore.Category?
    @Published var hoveredItem: String?

    /// The config `preview` was planned with.
    private var previewedWith: Config?
    /// Identifies the latest preview; a clean bumps it to discard one in flight.
    private var previewID = 0
    private let live: Bool
    private var panelOpen = false
    private var timer: Timer?
    private var watchTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    static let previewMaxAge: TimeInterval = 300

    /// Unless `live`, the state stays as given: no disk, CLI or timers.
    init(config: Config = Config(), freeBytes: Int64, totalBytes: Int64, lastRun: Report? = nil,
         preview: Report? = nil, busy: Busy? = nil, problem: String? = nil,
         loginStatus: SMAppService.Status = .notRegistered, live: Bool = false) {
        self.config = config
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.lastRun = lastRun
        self.preview = preview
        self.previewedWith = preview == nil ? nil : config
        self.busy = busy
        self.problem = problem
        self.loginStatus = loginStatus
        self.live = live
    }

    static func live() -> Store {
        let (free, total) = Self.diskSpace()
        let store = Store(config: Config(), freeBytes: free, totalBytes: total, lastRun: Report.load(),
                          loginStatus: SMAppService.mainApp.status, live: true)
        store.reloadConfig()
        store.startObserving()
        return store
    }

    private func startObserving() {
        // The menu-bar icon is visible with the panel closed, so free space and the
        // launchd job are checked on a timer as well as on open.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                if self.busy == nil, Janitor.isRunning() { self.watchScheduledRun() }
            }
        }
        // The panel is this app's only window, key while it is open.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panelOpened() }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panelOpen = false }
        })
    }

    // MARK: - Derived state

    var isLowDisk: Bool { freeBytes > 0 && Double(freeBytes) < config.lowDiskGB * 1e9 }

    var usedFraction: Double {
        totalBytes > 0 ? Double(totalBytes - freeBytes) / Double(totalBytes) : 0
    }

    /// Whether `preview` has data for this category.
    func covers(_ c: JanitorCore.Category) -> Bool {
        preview != nil && (previewedWith?.enabled(c) ?? false)
    }

    func items(_ c: JanitorCore.Category) -> [Item] {
        guard let preview, config.enabled(c) else { return [] }
        var items: [Item] = []
        for a in preview.actions where a.category == c {
            let kind: Item.Kind = a.status == .failed ? .failed : config.isKept(a.target) ? .kept : .planned
            items.append(Item(id: a.id, target: a.target, name: Format.name(a.target, c), bytes: a.bytes,
                              kind: kind, detail: a.error ?? a.reason))
        }
        for s in preview.skips where s.category == c {
            let kind: Item.Kind = !s.kept ? .guarded : config.isKept(s.target) ? .kept : .pending
            items.append(Item(id: s.id, target: s.target, name: Format.name(s.target, c), bytes: s.bytes,
                              kind: kind, detail: s.reason))
        }
        func rank(_ k: Item.Kind) -> Int {
            switch k {
            case .failed: return 0
            case .planned: return 1
            case .pending: return 2
            case .kept: return 3
            case .guarded: return 4
            }
        }
        return items.sorted { (rank($0.kind), -$0.bytes, $0.name) < (rank($1.kind), -$1.bytes, $1.name) }
    }

    func plannedBytes(_ c: JanitorCore.Category) -> Int64 {
        items(c).filter { $0.kind == .planned }.reduce(0) { $0 + $1.bytes }
    }

    /// Exactly the items shown as planned; a clean removes these and nothing else.
    var planned: [Item] {
        JanitorCore.Category.allCases.flatMap { items($0) }.filter { $0.kind == .planned }
    }

    func issues(_ c: JanitorCore.Category) -> [String] {
        (preview ?? lastRun)?.issues.filter { $0.category == c }.map(\.message) ?? []
    }

    /// The config changed in a way the preview cannot reflect locally: another plan
    /// input, a re-enabled category, or an unpinned target.
    private var previewIsStale: Bool {
        guard let then = previewedWith else { return true }
        func planInputs(_ c: Config) -> Config {
            var c = c
            c.paused = false
            c.intervalHours = 0
            c.lowDiskGB = 0
            c.keep = []
            c.disabled = []
            return c
        }
        return planInputs(then) != planInputs(config)
            || !Set(then.disabled).subtracting(config.disabled).isEmpty
            || !Set(then.keep).subtracting(config.keep).isEmpty
    }

    /// A real run started after the preview did, so some of what it plans may be gone.
    private var previewPredatesRun: Bool {
        guard let preview, let lastRun else { return false }
        return lastRun.startedAt > preview.startedAt
    }

    /// When the next scheduled run is due, or nil when paused.
    var nextRun: Date? {
        guard !config.paused else { return nil }
        guard let lastRun, !isLowDisk else { return Date() }
        return max(Date(), lastRun.startedAt.addingTimeInterval(config.intervalHours * 3600))
    }

    // MARK: - Lifecycle

    private static func diskSpace() -> (free: Int64, total: Int64) {
        let total = (try? Paths.home.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity
        return (freeDiskBytes(), Int64(total ?? 0))
    }

    func refresh() {
        guard live else { return }
        (freeBytes, totalBytes) = Self.diskSpace()
        lastRun = Report.load()
        reloadConfig()
        loginStatus = SMAppService.mainApp.status
    }

    private func panelOpened() {
        panelOpen = true
        refresh()
        guard busy == nil else { return }
        if Janitor.isRunning() {
            watchScheduledRun()
        } else if !showSettings, previewIsStale || previewPredatesRun
                    || preview.map({ -$0.finishedAt.timeIntervalSinceNow > Self.previewMaxAge }) ?? true {
            Task { await runPreview() }
        }
    }

    /// Polls until another run releases the lock; what it removed makes the preview stale.
    private func watchScheduledRun() {
        busy = .scheduled
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, !Janitor.isRunning() else { return }
                timer.invalidate()
                self.busy = nil
                self.preview = nil
                self.previewedWith = nil
                self.refresh()
                if self.panelOpen { await self.runPreview() }
            }
        }
    }

    func runPreview() async {
        guard live, busy == nil else { return }
        if Janitor.isRunning() { return watchScheduledRun() }
        busy = .previewing
        previewID += 1
        let id = previewID
        let cfg = config
        let outcome = await JanitorRunner.run(dryRun: true)
        // A clean started meanwhile; this plan predates it.
        guard id == previewID else { return }
        busy = nil
        refresh()
        if Janitor.isRunning() { return watchScheduledRun() }
        problem = outcome.problem
        if let report = outcome.report {
            preview = report
            previewedWith = cfg
            // Settings changed, or a real run came and went, while it ran.
            if previewIsStale || previewPredatesRun, panelOpen { await runPreview() }
        }
    }

    /// Can run while a preview refreshes: the CLI acts only on ids it still plans.
    var canClean: Bool { (busy == nil || busy == .previewing) && !planned.isEmpty }

    func clean() async {
        let ids = planned.map(\.id)
        guard live, canClean else { return }
        previewID += 1
        busy = .cleaning
        problem = nil
        let outcome = await JanitorRunner.run(dryRun: false, only: ids)
        busy = nil
        refresh()
        if outcome.locked { return watchScheduledRun() }
        problem = outcome.problem
        guard var report = outcome.report else { return }
        // Removed items go and failures stay. Kept and guarded items were not part of
        // the run, so they carry over from the preview.
        let before = preview
        report.actions = report.actions.filter { $0.status == .failed }
            + (before?.actions.filter { config.isKept($0.target) } ?? [])
        report.skips = before?.skips ?? []
        preview = report
        previewedWith = config
    }

    // MARK: - Settings

    /// A broken config.json stays broken until fixed by hand: saving over it would
    /// drop whatever the user meant, and the CLI refuses to run on it meanwhile.
    @discardableResult
    private func reloadConfig() -> Bool {
        do {
            config = try Config.load()
            if configProblem != nil, problem == configProblem { problem = nil }
            configProblem = nil
            return true
        } catch {
            configProblem = "\(error)"
            problem = configProblem
            return false
        }
    }

    func update(_ change: (inout Config) -> Void) {
        guard !live || reloadConfig() else { return }
        var c = config
        change(&c)
        guard c != config else { return }
        guard live else { config = c; return }
        do {
            try c.save()
        } catch {
            problem = "Could not save \(Format.path(Paths.config.path)): \(error.localizedDescription)"
        }
        reloadConfig()
    }

    /// Applies config changes made in settings to the preview.
    func closeSettings() {
        showSettings = false
        if previewIsStale { Task { await runPreview() } }
    }

    func setEnabled(_ c: JanitorCore.Category, _ on: Bool) {
        update { cfg in
            cfg.disabled.removeAll { $0 == c }
            if !on { cfg.disabled.append(c) }
        }
        if on, previewIsStale { Task { await runPreview() } }
    }

    func pin(_ target: String) {
        update { $0.keep.append(target) }
    }

    /// Removes every `keep` entry that protects `target`.
    func unpin(_ target: String) {
        update { cfg in
            let entries = cfg.keepEntries(for: target)
            cfg.keep.removeAll { entries.contains($0) }
        }
        if !showSettings, previewIsStale { Task { await runPreview() } }
    }

    func setLaunchAtLogin(_ on: Bool) {
        problem = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            problem = "Launch at login: \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }

    func openLog() {
        guard FileManager.default.fileExists(atPath: Paths.log.path) else {
            problem = "No log yet at \(Format.path(Paths.log.path))"
            return
        }
        NSWorkspace.shared.open(Paths.log)
    }
}

