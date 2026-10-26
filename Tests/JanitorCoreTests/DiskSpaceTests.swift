import XCTest
@testable import JanitorCore

final class DiskSpaceTests: XCTestCase {
    func testFreeSpaceSeesAWriteInTheSameProcess() throws {
        let file = Paths.home.appendingPathComponent(".janitor-free-space-test-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: file) }
        let before = freeDiskBytes()
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data(count: 1_000_000_000)))
        XCTAssertLessThan(freeDiskBytes(), before - 500_000_000)
    }
}
