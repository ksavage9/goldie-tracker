import XCTest
@testable import GoldieCore

/// Times the two heavy jobs on full-size (2732 × 2048) screenshots, like a real iPad's, and prints the cost per
/// screenshot so changes can be compared run to run. The limits are generous: GitHub's simulators vary a lot.
@MainActor
final class PerformanceTests: XCTestCase {
    private let fullSize = CGSize(width: 2732, height: 2048)

    private func fullSizeDay(_ name: String, count: Int) throws -> [Screenshot] {
        let folder = try Fixtures.makeTemporaryFolder(name)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return try (0..<count).map { i in
            let marker = CGPoint(x: 1200 + Double(i % 6) * 60, y: 600 + Double(i / 6) * 40)
            return try Fixtures.write(Fixtures.screenshot(marker: marker, size: fullSize), to: folder.appending(path: "\(i).jpg"), created: start + Double(i) * 300)
        }
    }

    func testHeatMapSpeed() async throws {
        let shots = try fullSizeDay("perf-heatmap", count: 24)
        let reference = try XCTUnwrap(UIImage(contentsOfFile: shots[0].url.path))
        let template = try await HeatmapBuilder.makeTemplate(from: reference, tappedAt: CGPoint(x: 1200 / fullSize.width, y: 600 / fullSize.height))
        let start = Date()
        let heatmap = try await HeatmapBuilder.build(from: shots, template: template) { _ in }
        let perScreenshot = Date().timeIntervalSince(start) / Double(shots.count)
        print("PERF heat map: \(Int(perScreenshot * 1000)) ms per screenshot (\(shots.count) full-size screenshots, found \(heatmap.found))")
        XCTAssertLessThan(perScreenshot, 1.5, "a day of 288 screenshots should take a few minutes at most, even on a slow simulator")
    }

    /// A month of screenshots (30 days × 288) is about 8,640 files. Scanning them runs on the main thread every
    /// minute, so it must stay quick.
    func testFolderScanSpeedWithAMonthOfScreenshots() throws {
        let folder = try Fixtures.makeTemporaryFolder("perf-month")
        let today = Calendar.current.startOfDay(for: .now)
        for day in 0..<30 {
            let dayStart = Calendar.current.date(byAdding: .day, value: -day, to: today)!
            for i in 0..<288 {
                let url = folder.appending(path: "\(day)-\(i).jpg")
                FileManager.default.createFile(atPath: url.path, contents: Data(count: 16))
                try FileManager.default.setAttributes([.creationDate: dayStart + Double(i) * 300], ofItemAtPath: url.path)
            }
        }
        UserDefaults.standard.removeObject(forKey: "screenshotFolderBookmark")
        try? FileManager.default.removeItem(at: URL.documentsDirectory.appending(path: "Animations"))  // left by other tests
        let store = Store()
        store.setFolder(folder)
        XCTAssertEqual(store.days.count, 30)
        let start = Date()
        for _ in 0..<5 {
            store.refresh()
        }
        let perScan = Date().timeIntervalSince(start) / 5
        print("PERF folder scan: \(Int(perScan * 1000)) ms for 8,640 screenshots")
        XCTAssertLessThan(perScan, 0.5, "this runs on the main thread every minute")
        UserDefaults.standard.removeObject(forKey: "screenshotFolderBookmark")
    }

    /// Breaks the animation's cost down: decoding a screenshot vs. the whole build, for 1366- and 2732-wide sources.
    func testAnimationCostBreakdown() async throws {
        let small = try (0..<12).map { i in
            try Fixtures.write(Fixtures.screenshot(marker: CGPoint(x: 600, y: 300)), to: Fixtures.makeTemporaryFolder("perf-small-\(i)").appending(path: "s.jpg"), created: Date(timeIntervalSince1970: 1_790_000_000 + Double(i) * 300))
        }
        let large = try fullSizeDay("perf-large", count: 12)

        var start = Date()
        for shot in large { _ = ImageFile.downsampled(shot.url, maxPixelSize: 1280) }
        print("PERF decode one 2732-wide screenshot at 1280: \(Int(Date().timeIntervalSince(start) / 12 * 1000)) ms")

        for (label, shots) in [("1366-wide", small), ("2732-wide", large)] {
            let output = FileManager.default.temporaryDirectory.appending(path: "perf-\(UUID().uuidString).mp4")
            start = Date()
            try await VideoBuilder.makeVideo(from: shots, to: output) { _ in }
            print("PERF animation from \(label) screenshots: \(Int(Date().timeIntervalSince(start) / 12 * 1000)) ms per frame")
        }
    }

    func testAnimationSpeed() async throws {
        let shots = try fullSizeDay("perf-video", count: 24)
        let output = FileManager.default.temporaryDirectory.appending(path: "perf-\(UUID().uuidString).mp4")
        let start = Date()
        try await VideoBuilder.makeVideo(from: shots, to: output) { _ in }
        let perFrame = Date().timeIntervalSince(start) / Double(shots.count)
        print("PERF animation: \(Int(perFrame * 1000)) ms per frame (\(shots.count) full-size screenshots)")
        XCTAssertLessThan(perFrame, 1.5)
    }
}
