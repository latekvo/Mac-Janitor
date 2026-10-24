import AppKit
import JanitorCore
import SwiftUI

/// Renders the panel for fixture states, light and dark, to `<dir>/<fixture>-<appearance>.png`.
/// Offscreen AppKit rendering, because ImageRenderer cannot draw switches and steppers.
@MainActor
enum Snapshot {
    static func render(to dir: URL) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, make) in fixtures {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let url = dir.appendingPathComponent("\(name)-\(suffix).png")
                guard let png = image(make(), NSAppearance(named: appearance)!) else {
                    FileHandle.standardError.write(Data("could not render \(url.lastPathComponent)\n".utf8))
                    exit(1)
                }
                do {
                    try png.write(to: url)
                } catch {
                    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                    exit(1)
                }
                print(url.path)
            }
        }
    }

    private static func image(_ store: Store, _ appearance: NSAppearance) -> Data? {
        let host = NSHostingView(rootView: PanelView()
            .environmentObject(store)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = ActiveWindow(contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: 600),
                                  styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        // Measured heights (the item list) land a few layout passes later.
        for _ in 0..<2 {
            settle(host)
            window.setContentSize(host.fittingSize)
        }
        settle(host)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// Switches draw their grey, inactive look unless the app is active, which this
    /// process cannot become without stealing focus. Overrides a private AppKit hook.
    private final class ActiveWindow: NSWindow {
        @objc func _hasActiveControls() -> Bool { true }
    }

    private static func settle(_ view: NSView) {
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            view.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Fixtures

    private static let gb: Int64 = 1_000_000_000
    private static let total: Int64 = 994 * gb
    private static let home = Paths.home.path
    private static let worktrees = "\(home)/dev/engineering/argent-worktrees"

    private static func ago(_ hours: Double) -> Date { Date().addingTimeInterval(-hours * 3600) }

    private static var lastRun: Report {
        Report(startedAt: ago(2.1), finishedAt: ago(2), dryRun: false, freeBytesBefore: 120 * gb,
               freeBytesAfter: 124_900_000_000, actions: [], skips: [], issues: [])
    }

    private static func dryRun(_ actions: [Action], skips: [Skip] = [], issues: [Issue] = []) -> Report {
        Report(startedAt: ago(0.02), finishedAt: ago(0.01), dryRun: true, freeBytesBefore: 124 * gb,
               freeBytesAfter: 124 * gb, actions: actions, skips: skips, issues: issues)
    }

    private static func planned(_ c: JanitorCore.Category, _ target: String, _ bytes: Int64,
                                _ reason: String = "untouched for 4.2 days") -> Action {
        Action(category: c, target: target, reason: reason, bytes: bytes, status: .planned)
    }

    private static var mixedPreview: Report {
        dryRun([
            planned(.worktree, "\(worktrees)/harmony-flag", 2_310_000_000, "merged (PR #767 merged), untouched for 2.0 days"),
            planned(.worktree, "\(worktrees)/fix-tap-retry", 812_000_000, "PR #1490 open, untouched for 3.4 days"),
            planned(.nodeModules, "\(worktrees)/lens-variants/node_modules", 1_420_000_000),
            planned(.nodeModules, "\(worktrees)/vega-focus/node_modules", 1_180_000_000),
            planned(.nodeModules, "\(worktrees)/docs-reference/node_modules", 960_000_000),
            planned(.avd, "Pixel_6_API_34", 7_400_000_000, "unused for 9.3 days"),
            planned(.scratchpad, "/private/tmp/claude-501/-Users-me-dev/0c1d2e3f", 48_000_000, "untouched for 15.0 days"),
        ], issues: [Issue(.dockerImage, "Docker is not running")])
    }

    private static var expandedPreview: Report {
        var failed = planned(.worktree, "\(worktrees)/stale-ci-cache", 640_000_000, "untouched for 31.2 days")
        failed.status = .failed
        failed.error = "rm: Permission denied"
        return dryRun([
            planned(.worktree, "\(worktrees)/harmony-flag", 2_310_000_000, "merged (PR #767 merged), untouched for 2.0 days"),
            planned(.worktree, "\(worktrees)/fix-tap-retry-after-quiescence-stall", 812_000_000, "PR #1490 open, untouched for 3.4 days"),
            failed,
            planned(.nodeModules, "\(worktrees)/lens-variants/node_modules", 1_420_000_000),
        ], skips: [
            Skip(category: .worktree, target: "\(worktrees)/map-crawler", reason: "kept", kept: true, bytes: 1_760_000_000),
            Skip(category: .worktree, target: "\(worktrees)/donor-main",
                 reason: "merged (HEAD is in main), untouched for 12.3 days, but a kept checkout's node_modules links into it"),
            Skip(category: .dockerImage, target: "public.ecr.aws/supabase/studio:2026.10.12-sha-3699278 (24eda6a4098f)",
                 reason: "arrived 12 days ago, but container supabase_studio_argent-platform uses it"),
        ])
    }

    private static var fixtures: [(String, () -> Store)] {
        [
            ("a-normal", { Store(freeBytes: 124 * gb, totalBytes: total, lastRun: lastRun, preview: mixedPreview) }),
            ("b-expanded", {
                var cfg = Config()
                cfg.keep = ["\(worktrees)/map-crawler"]
                let s = Store(config: cfg, freeBytes: 124 * gb, totalBytes: total, lastRun: lastRun, preview: expandedPreview)
                s.expanded = .worktree
                s.hoveredItem = "worktree:\(worktrees)/harmony-flag"
                return s
            }),
            ("c-previewing", { Store(freeBytes: 124 * gb, totalBytes: total, lastRun: lastRun, busy: .previewing) }),
            ("d-low-disk", { Store(freeBytes: 12_400_000_000, totalBytes: total, lastRun: lastRun, preview: mixedPreview) }),
            ("e-settings", {
                var cfg = Config()
                cfg.repos.append("\(home)/dev/radon")
                cfg.keep = ["\(worktrees)/map-crawler", "Pixel_9_API_36"]
                cfg.nodeModulesIdleDays = 5
                let s = Store(config: cfg, freeBytes: 124 * gb, totalBytes: total, lastRun: lastRun,
                              loginStatus: .requiresApproval)
                s.showSettings = true
                return s
            }),
            ("f-nothing", {
                var cfg = Config()
                cfg.paused = true
                cfg.disabled = [.dockerImage]
                return Store(config: cfg, freeBytes: 312 * gb, totalBytes: total, lastRun: lastRun, preview: dryRun([]))
            }),
            ("g-error", {
                Store(freeBytes: 124 * gb, totalBytes: total, lastRun: lastRun, preview: mixedPreview,
                      problem: "janitor not found at ~/Applications/MacJanitor.app/Contents/MacOS/janitor")
            }),
            ("i-settings-error", {
                let s = Store(freeBytes: 124 * gb, totalBytes: total, lastRun: lastRun,
                              problem: "Launch at login: Operation not permitted")
                s.showSettings = true
                return s
            }),
            ("h-cleaning", { Store(freeBytes: 124 * gb, totalBytes: total, lastRun: lastRun, preview: mixedPreview, busy: .cleaning) }),
        ]
    }
}
