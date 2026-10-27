import XCTest
@testable import JanitorCore

final class LockTests: XCTestCase {
    func testDryRunNeitherWaitsForNorHoldsTheRunLock() throws {
        try XCTSkipIf(Janitor.isRunning(), "a real janitor run holds the run lock")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("janitor-lock-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        // An idle session is planned, so the dry run logs mid-run.
        try FileManager.default.createDirectory(atPath: root + "/project/session", withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30 * 86400)],
                                              ofItemAtPath: root + "/project/session")
        var cfg = Config()
        cfg.disabled = Category.allCases.filter { $0 != .scratchpad }
        cfg.worktreeSearchRoot = root
        cfg.scratchpadRoot = root

        let held = try Janitor.lock()
        XCTAssertTrue(Janitor.isRunning())
        XCTAssertThrowsError(try Janitor.lock())
        XCTAssertEqual(try Janitor.run(cfg, dryRun: true).actions.map(\.target), [root + "/project/session"])
        close(held)

        var lockedMidRun: Bool?
        _ = try Janitor.run(cfg, dryRun: true) { _ in
            guard lockedMidRun == nil else { return }
            lockedMidRun = Janitor.isRunning()
        }
        XCTAssertEqual(lockedMidRun, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/project/session"))
    }
}
