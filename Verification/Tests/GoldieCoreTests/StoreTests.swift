import XCTest
@testable import GoldieCore

/// The real Store on real iOS file, bookmark and free-space APIs, with the real VideoBuilder.
@MainActor
final class StoreTests: XCTestCase {
    private let animations = URL.documentsDirectory.appending(path: "Animations")

    override func setUp() async throws {
        try? FileManager.default.removeItem(at: animations)
        UserDefaults.standard.removeObject(forKey: "screenshotFolderBookmark")
        UserDefaults.standard.removeObject(forKey: "storageLimitGB")
        UserDefaults.standard.removeObject(forKey: "keepUnbuiltDayIDs")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "screenshotFolderBookmark")
        UserDefaults.standard.removeObject(forKey: "storageLimitGB")
    }

    func testFullDayCycle() async throws {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: .now)
        let folder = try Fixtures.makeTemporaryFolder("Goldie")

        // Two finished days and today, saved the way the shortcut saves them.
        var files: [String: [URL]] = [:]
        func addDay(daysAgo: Int, count: Int) throws -> String {
            let dayStart = calendar.date(byAdding: .day, value: -daysAgo, to: todayStart)!
            for i in 0..<count {
                // Today: a few seconds after midnight, so the dates are never in the future.
                let created = daysAgo == 0 ? dayStart + Double(i) : dayStart + 8 * 3600 + Double(i) * 300
                let url = folder.appending(path: "\(daysAgo)-\(i).jpg")
                try Fixtures.write(Fixtures.screenshot(marker: CGPoint(x: 600 + Double(i) * 30, y: 300)), to: url, created: created)
                files[dayID(dayStart), default: []].append(url)
            }
            return dayID(dayStart)
        }
        let twoDaysAgo = try addDay(daysAgo: 2, count: 4)
        let yesterday = try addDay(daysAgo: 1, count: 5)
        let today = try addDay(daysAgo: 0, count: 3)

        // Choosing the folder (inside the app, so it needs no special access) loads the days.
        let store = Store()
        store.setFolder(folder)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.days.map(\.id), [today, yesterday, twoDaysAgo], "newest first")
        XCTAssertEqual(store.days.map(\.screenshots.count), [3, 5, 4])
        XCTAssertEqual(store.storageUsed, try totalSize(of: files.values.flatMap { $0 }))
        XCTAssertGreaterThan(try XCTUnwrap(store.availableSpace), 0, "real iOS free-space reading")
        XCTAssertNotNil(store.lastScreenshotDate)

        // The daily build makes animations for the finished days only.
        await store.buildMissingAnimations()
        XCTAssertNil(store.errorMessage)
        for id in [yesterday, twoDaysAgo] {
            let day = try XCTUnwrap(store.days.first { $0.id == id })
            XCTAssertNotNil(store.videoDate(for: day), "\(id) should have an animation")
            XCTAssertFalse(store.needsAnimation(day))
        }
        let todayDay = try XCTUnwrap(store.days.first { $0.id == today })
        XCTAssertNil(store.videoDate(for: todayDay), "today isn't built automatically")
        XCTAssertTrue(FileManager.default.fileExists(atPath: animations.appending(path: "\(yesterday).mp4").path))

        // Build Now makes today's.
        await store.buildNow(today)
        XCTAssertNil(store.errorMessage)
        XCTAssertNotNil(store.videoDate(for: todayDay))
        XCTAssertGreaterThan(store.storageUsed, try totalSize(of: files.values.flatMap { $0 }), "animations count toward storage")

        // A relaunch finds the folder again through the real bookmark.
        let relaunched = Store()
        XCTAssertEqual(relaunched.folderURL?.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertEqual(relaunched.days.count, 3)

        // While a heat map or Time Range animation is reading screenshots, cleanup waits.
        store.beginReadingScreenshots()
        store.storageLimitGB = 0
        for url in files[yesterday]! + files[twoDaysAgo]! {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "nothing removed while screenshots are being read")
        }
        store.endReadingScreenshots()

        // A limit of 0 forces every step of the cleanup: finished days' screenshots, then their animations.
        // Today is never touched.
        store.enforceStorageLimit()
        for url in files[yesterday]! + files[twoDaysAgo]! {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) should be removed")
        }
        for url in files[today]! {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "today's \(url.lastPathComponent) must stay")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: animations.appending(path: "\(today).mp4").path), "today's animation must stay")
        XCTAssertEqual(store.days.map(\.id), [today])
        store.storageLimitGB = StorageGuard.defaultLimitGB
    }

    func testFolderDeletedWhileRunningGoesBackToSetup() throws {
        let folder = try Fixtures.makeTemporaryFolder("Goldie-deleted")
        try Fixtures.write(Fixtures.screenshot(marker: nil), to: folder.appending(path: "a.jpg"), created: .now)
        let store = Store()
        store.setFolder(folder)
        XCTAssertEqual(store.days.count, 1)

        try FileManager.default.removeItem(at: folder)
        store.refresh()
        XCTAssertNil(store.folderURL)
        XCTAssertTrue(store.days.isEmpty)
        XCTAssertNotNil(store.errorMessage)

        store.errorMessage = nil
        store.refresh()
        XCTAssertNil(store.errorMessage, "no repeated alert")
    }

    func testScreenshotsInATimeRangeAcrossDays() throws {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: .now)
        let folder = try Fixtures.makeTemporaryFolder("Goldie-range")
        let twoDaysAgo8AM = calendar.date(byAdding: .day, value: -2, to: todayStart)! + 8 * 3600
        let yesterday8AM = calendar.date(byAdding: .day, value: -1, to: todayStart)! + 8 * 3600
        for (i, created) in (0..<6).map({ twoDaysAgo8AM + Double($0) * 300 }).enumerated() {
            try Fixtures.write(Fixtures.screenshot(marker: nil), to: folder.appending(path: "a\(i).jpg"), created: created)
        }
        for (i, created) in (0..<6).map({ yesterday8AM + Double($0) * 300 }).enumerated() {
            try Fixtures.write(Fixtures.screenshot(marker: nil), to: folder.appending(path: "b\(i).jpg"), created: created)
        }
        let store = Store()
        store.setFolder(folder)

        // 8:10 two days ago through 8:05 yesterday: the last 4 of the first day and the first 2 of the next.
        let range = store.screenshots(from: twoDaysAgo8AM + 600, to: yesterday8AM + 300)
        XCTAssertEqual(range.count, 6)
        XCTAssertEqual(range.first?.date, twoDaysAgo8AM + 600, "the start is included")
        XCTAssertEqual(range.last?.date, yesterday8AM + 300, "the end is included")
        XCTAssertEqual(range.map(\.date), range.map(\.date).sorted(), "oldest first, across days")
        XCTAssertEqual(store.firstScreenshotDate, twoDaysAgo8AM)
        XCTAssertTrue(store.screenshots(from: yesterday8AM + 3600, to: yesterday8AM + 7200).isEmpty)
    }

    func testDeletedAnimationStaysDeletedUntilBuildNow() async throws {
        let calendar = Calendar.current
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))!
        let folder = try Fixtures.makeTemporaryFolder("Goldie-delete")
        for i in 0..<3 {
            try Fixtures.write(Fixtures.screenshot(marker: nil), to: folder.appending(path: "\(i).jpg"), created: yesterdayStart + 3600 + Double(i) * 300)
        }
        let store = Store()
        store.setFolder(folder)
        await store.buildMissingAnimations()
        var day = try XCTUnwrap(store.days.first)
        XCTAssertNotNil(store.videoDate(for: day))

        store.deleteAnimation(for: day)
        XCTAssertNil(store.videoDate(for: day), "animation deleted")
        XCTAssertEqual(store.days.first?.screenshots.count, 3, "screenshots kept")
        await store.buildMissingAnimations()
        XCTAssertNil(store.videoDate(for: day), "the daily build doesn't bring it back")
        await Store().buildMissingAnimations()
        XCTAssertNil(store.videoDate(for: day), "nor after a relaunch")

        await store.buildNow(day.id)
        day = try XCTUnwrap(store.days.first)
        XCTAssertNotNil(store.videoDate(for: day), "Build Now rebuilds it")
        XCTAssertNil(store.errorMessage)
    }

    private func dayID(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func totalSize(of urls: [URL]) throws -> Int64 {
        try urls.reduce(0) { $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }
}
