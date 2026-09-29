import XCTest
@testable import GoldieCore

/// Times each way of reading the iPad's free space, and checks the app's reading is fast and always has a value.
final class FreeSpaceTests: XCTestCase {
    func testFreeSpaceReadingIsFastAndPresent() throws {
        func timed<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
            let start = Date()
            let value = try body()
            print("FREE SPACE \(label): \(String(describing: value)) in \(String(format: "%.3f", Date().timeIntervalSince(start))) s")
            return value
        }
        let folder = URL.documentsDirectory
        _ = try? timed("importantUsage") {
            try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        }
        _ = try? timed("plainCapacity") {
            try folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        }

        let start = Date()
        let available = StorageGuard.availableBytes()
        let seconds = Date().timeIntervalSince(start)
        print("FREE SPACE app reading: \(String(describing: available)) in \(String(format: "%.3f", seconds)) s")
        XCTAssertNotNil(available, "the storage check needs a free-space value")
        XCTAssertGreaterThan(available ?? 0, 0)
        XCTAssertLessThan(seconds, 1, "it's read on the main thread, so it must be quick")
    }
}
