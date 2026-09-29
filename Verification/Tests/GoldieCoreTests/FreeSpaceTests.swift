import XCTest
@testable import GoldieCore

/// Reads the iPad's free space every way the app could, printing what each gives (or why it fails),
/// and checks the app's own reading always has a value, quickly.
final class FreeSpaceTests: XCTestCase {
    func testFreeSpaceReadingIsFastAndPresent() {
        let places: [(String, URL)] = [("documents", URL.documentsDirectory), ("home", URL.homeDirectory)]
        let keys: [(String, URLResourceKey)] = [
            ("importantUsage", .volumeAvailableCapacityForImportantUsageKey),
            ("plainCapacity", .volumeAvailableCapacityKey),
        ]
        for (placeName, place) in places {
            print("FREE SPACE \(placeName) folder exists: \(FileManager.default.fileExists(atPath: place.path))")
            for (keyName, key) in keys {
                do {
                    let values = try place.resourceValues(forKeys: [key])
                    let value = keyName == "importantUsage"
                        ? values.volumeAvailableCapacityForImportantUsage.map(String.init)
                        : values.volumeAvailableCapacity.map(String.init)
                    print("FREE SPACE \(placeName) \(keyName): \(value ?? "nil")")
                } catch {
                    print("FREE SPACE \(placeName) \(keyName): ERROR \(error.localizedDescription)")
                }
            }
        }

        let start = Date()
        let available = StorageGuard.availableBytes()
        let seconds = Date().timeIntervalSince(start)
        print("FREE SPACE app reading: \(available.map(String.init) ?? "nil") in \(String(format: "%.3f", seconds)) s")
        XCTAssertNotNil(available, "the storage check needs a free-space value")
        XCTAssertGreaterThan(available ?? 0, 0)
        XCTAssertLessThan(seconds, 1, "it's read on the main thread, so it must be quick")
    }
}
