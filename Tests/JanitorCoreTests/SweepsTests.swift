import XCTest
@testable import JanitorCore

/// Trash, caches, build output, large files and system images against a scratch tree.
final class SweepsTests: XCTestCase {
    var root = ""
    let none = Guards(openPaths: [], launchAgentStrings: [])

    override func setUpWithError() throws {
        root = FS.canonical(FileManager.default.temporaryDirectory.path) + "/janitor-sweeps-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    func make(_ path: String, _ text: String = "x") throws -> String {
        let full = root + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: false, encoding: .utf8)
        return full
    }

    /// Sets access and modification times of `path` and everything under it.
    func backdate(_ path: String, days: Double) {
        let t = time_t(Date().addingTimeInterval(-days * 86400).timeIntervalSince1970)
        var times = [timeval(tv_sec: t, tv_usec: 0), timeval(tv_sec: t, tv_usec: 0)]
        FS.walk(path) { p, _, _, _ in lutimes(p, &times); return true }
        lutimes(path, &times)
    }

    func testTrashGoesByWhenItWasTrashedNotByItsAge() throws {
        var cfg = Config()
        cfg.trashDir = root + "/Trash"
        let old = try make("Trash/old.mov")
        backdate(old, days: 400)
        _ = try make("Trash/.DS_Store")
        var skips: [Skip] = [], issues: [Issue] = []
        // Just trashed: an ancient mtime does not count.
        XCTAssertEqual(TrashJanitor.plan(cfg, guards: none, now: Date(), skips: &skips, issues: &issues).map(\.target), [])
        let later = Date().addingTimeInterval(8 * 86400)
        XCTAssertEqual(TrashJanitor.plan(cfg, guards: none, now: later, skips: &skips, issues: &issues).map(\.target), [old])
        XCTAssertEqual(issues, [])
    }

    func testCacheEntryStaysWhileAFileInItIsRead() throws {
        var cfg = Config()
        cfg.cacheRoots = [root + "/Caches"]
        let stale = try make("Caches/stale/blob")
        let read = try make("Caches/read/blob")
        let apple = try make("Caches/com.apple.thing/blob")
        for p in [stale, read, apple] { backdate((p as NSString).deletingLastPathComponent, days: 40) }
        var times = [timeval(tv_sec: time_t(Date().timeIntervalSince1970), tv_usec: 0),
                     timeval(tv_sec: time_t(Date().addingTimeInterval(-40 * 86400).timeIntervalSince1970), tv_usec: 0)]
        lutimes(read, &times)
        var skips: [Skip] = []
        let plan = CacheJanitor.plan(cfg, guards: none, now: Date(), skips: &skips)
        XCTAssertEqual(plan.map(\.target), [root + "/Caches/stale"])
        XCTAssertEqual(plan.first?.reason, "unused for 40 days")
    }

    func testBuildOutputNeedsItsMarkerAndAnIdleProject() throws {
        _ = try make("idle/.git/HEAD", "ref: refs/heads/main")
        _ = try make("idle/package.json", "{}")
        _ = try make("idle/node_modules/a/index.js")
        _ = try make("idle/android/build.gradle")
        _ = try make("idle/android/build/out.apk")
        _ = try make("idle/docs/build/index.html")
        _ = try make("busy/package.json", "{}")
        _ = try make("busy/node_modules/a/index.js")
        _ = try make("fresh-output/Cargo.toml")
        _ = try make("fresh-output/target/debug/bin")
        _ = try make("owned/package.json", "{}")
        _ = try make("owned/node_modules/a/index.js")
        for p in ["idle", "busy", "fresh-output", "owned"] { backdate(root + "/" + p, days: 20) }
        _ = try make("busy/src/edited.js")
        _ = try make("fresh-output/target/debug/rebuilt")

        let scan = HomeScan.scan(root, skipping: [], largeFileBytes: nil)
        // `docs/build` has no Gradle or Xcode project beside it.
        XCTAssertFalse(scan.artifacts.contains { $0.path.hasSuffix("docs/build") })
        XCTAssertEqual(Set(scan.artifacts.filter { $0.path.hasPrefix(root + "/idle/") }.map(\.project)), [root + "/idle"])

        var skips: [Skip] = []
        let plan = BuildJanitor.plan(Config(), guards: none, now: Date(), scan: scan,
                                     owner: { $0.hasPrefix(self.root + "/owned/") ? "node_modules" : nil }, skips: &skips)
        XCTAssertEqual(plan.map(\.target), [root + "/idle/android/build", root + "/idle/node_modules"])
        XCTAssertEqual(plan.first?.reason, "idle untouched for 20 days")
    }

    func testLargeFilesSkipHiddenFoldersDiskImagesAndGitPacks() throws {
        func big(_ path: String) throws -> String {
            let p = try make(path, "")
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: p))
            try h.truncate(atOffset: 600_000_000)
            try h.close()
            return p
        }
        let stale = try big("Movies/take1.mov")
        let fresh = try big("Movies/take2.mov")
        let hidden = try big(".ollama/blob")
        let image = try big("vm/disk.img")
        let pack = try big("cache/repo/objects/pack/pack-1.pack")
        let small = try make("Movies/small.mov")
        for p in [stale, hidden, image, pack, small] { backdate(p, days: 90) }
        _ = fresh

        let scan = HomeScan.scan(root, skipping: [], largeFileBytes: 500_000_000)
        XCTAssertEqual(Set(scan.largeFiles), [stale, fresh])
        var skips: [Skip] = []
        let plan = LargeFileJanitor.plan(Config(), guards: none, now: Date(), scan: scan, skips: &skips)
        XCTAssertEqual(plan.map(\.target), [stale])
    }

    func testOnlyUnusedSystemImagesGo() throws {
        var cfg = Config()
        cfg.androidSDK = root + "/sdk"
        cfg.avdHome = root + "/avd"
        let used = try make("sdk/system-images/android-34/google_apis/arm64-v8a/system.img")
        let unused = try make("sdk/system-images/android-23/google_apis/arm64-v8a/system.img")
        let booted = try make("sdk/system-images/android-35/google_apis/arm64-v8a/system.img")
        _ = try make("avd/Pixel.ini", "path=\(root)/avd/Pixel.avd\n")
        _ = try make("avd/Pixel.avd/config.ini", "image.sysdir.1 = system-images/android-34/google_apis/arm64-v8a/\n")
        for p in [used, unused, booted] { backdate((p as NSString).deletingLastPathComponent, days: 30) }
        var times = [timeval(tv_sec: time_t(Date().timeIntervalSince1970), tv_usec: 0),
                     timeval(tv_sec: time_t(Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970), tv_usec: 0)]
        lutimes(booted, &times)

        var skips: [Skip] = []
        let plan = AVDJanitor.planImages(cfg, guards: none, now: Date(), skips: &skips)
        let dir = (unused as NSString).deletingLastPathComponent
        XCTAssertEqual(plan.map(\.target), [dir])

        Safety.protectedPaths = []
        XCTAssertEqual(AVDJanitor.execute(plan[0], cfg).status, .removed)
        // The emptied <tag> and <api> folders go with it.
        XCTAssertFalse(FS.exists(root + "/sdk/system-images/android-23"))
        XCTAssertTrue(FS.exists(root + "/sdk/system-images/android-34/google_apis/arm64-v8a"))
    }

    func testDeferredRemovalRenamesNowAndPurgesLater() throws {
        _ = try make("doomed/a/b/file")
        FS.deferRemoval = true
        defer { FS.deferRemoval = false }
        Safety.protectedPaths = []
        try FS.remove(root + "/doomed")
        XCTAssertFalse(FS.exists(root + "/doomed"))
        let parked = try FileManager.default.contentsOfDirectory(atPath: FS.purgeDir)
        XCTAssertFalse(parked.isEmpty)
        FS.purge(detached: false)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: FS.purgeDir), [])
    }

    func testOnlyPlansTheCategoriesItNames() throws {
        var cfg = Config()
        cfg.worktreeSearchRoot = root
        cfg.scratchpadRoot = root + "/scratch"
        cfg.trashDir = root + "/Trash"
        cfg.cacheRoots = []
        cfg.androidSDK = root + "/sdk"
        cfg.avdHome = root + "/avd"
        cfg.disabled = [.dockerImage]
        let session = try make("scratch/project/session/notes")
        backdate(root + "/scratch/project/session", days: 30)
        cfg.keep = [(session as NSString).deletingLastPathComponent]
        // A planned scratchpad shows up as a kept skip.
        XCTAssertTrue(try Janitor.run(cfg, dryRun: true).skips.contains { $0.category == .scratchpad })
        XCTAssertFalse(try Janitor.run(cfg, dryRun: true, only: ["trash:\(root)/Trash/x"]).skips.contains { $0.category == .scratchpad })
    }
}
