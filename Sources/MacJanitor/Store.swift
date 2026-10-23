import AppKit
import Foundation
import JanitorCore
import ServiceManagement

@MainActor
final class Store: ObservableObject {
    enum Busy { case previewing, running }

    static let lowDiskBytes: Int64 = 20_000_000_000

    @Published private(set) var freeBytes: Int64 = freeDiskBytes()
    /// The last real run, as the CLI recorded it in `Paths.lastRun`.
    @Published private(set) var lastRun: Report? = Report.load()
    /// A dry run shown in place of the last run until dismissed or a real run lands.
    @Published private(set) var preview: Report?
    /// Set while "Run now" waits for the user to confirm `preview`.
    @Published private(set) var awaitingConfirmation = false
    @Published private(set) var busy: Busy?
    @Published var problem: String?
    @Published private(set) var paused = Config.load().paused
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published private(set) var loginProblem: String?

    private var timer: Timer?
    private var keyObserver: NSObjectProtocol?

    var isLowDisk: Bool { freeBytes > 0 && freeBytes < Self.lowDiskBytes }

    init() {
        // The menu-bar icon is visible with the window closed, so free space and the
        // launchd job's results are re-read on a timer as well as on open.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // The panel is this app's only window; it becomes key each time it opens.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        freeBytes = freeDiskBytes()
        lastRun = Report.load()
        paused = Config.load().paused
        loginStatus = SMAppService.mainApp.status
    }

    func runPreview() async {
        awaitingConfirmation = false
        guard let report = await dryRun() else { return }
        preview = report
    }

    /// Previews first, then waits for `confirmRun()`.
    func requestRun() async {
        guard let report = await dryRun() else { return }
        preview = report
        awaitingConfirmation = true
    }

    func confirmRun() async {
        awaitingConfirmation = false
        busy = .running
        problem = nil
        let outcome = await JanitorRunner.run(dryRun: false)
        busy = nil
        problem = outcome.problem
        refresh()
        if let report = outcome.report, !report.dryRun {
            lastRun = report
            preview = nil
        }
    }

    func cancelRun() { awaitingConfirmation = false }

    func dismissPreview() {
        awaitingConfirmation = false
        preview = nil
    }

    private func dryRun() async -> Report? {
        busy = .previewing
        problem = nil
        let outcome = await JanitorRunner.run(dryRun: true)
        busy = nil
        freeBytes = freeDiskBytes()
        problem = outcome.problem
        return outcome.report
    }

    func setPaused(_ on: Bool) {
        do {
            try Config.setPaused(on)
        } catch {
            problem = "Could not update \(Format.path(Paths.config.path)): \(error.localizedDescription)"
        }
        paused = Config.load().paused
    }

    func setLaunchAtLogin(_ on: Bool) {
        loginProblem = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginProblem = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
    }

    func openLog() {
        guard FileManager.default.fileExists(atPath: Paths.log.path) else {
            problem = "No log yet at \(Format.path(Paths.log.path))."
            return
        }
        NSWorkspace.shared.open(Paths.log)
    }
}
